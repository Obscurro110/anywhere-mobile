import { EventEmitter } from 'node:events';
import WebSocket from 'ws';
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

/**
 * RelayClient (desktop side)
 * ------------------------------------------------------------------
 * Drop-in bridge that connects the Anywhere Desktop (Electron main process)
 * to the public relay, enabling:
 *   - two-way chat with the Android app
 *   - file transfer (upload/download)
 *   - notification push (e.g. scheduled task results)
 *
 * Usage (inside Anywhere Desktop main process):
 *
 *   import { RelayClient } from './relay-bridge/relay-client.js';
 *   const relay = new RelayClient({
 *     serverUrl: 'ws://your-server:8787/ws',
 *     token: process.env.RELAY_TOKEN,
 *     userId: 'default-user',
 *     deviceName: 'My PC',
 *   });
 *   relay.on('chat', (msg) => { ... });        // incoming chat from phone
 *   relay.on('file', (meta) => { ... });        // incoming file offer
 *   relay.on('notification:ack', (m) => {...}); // phone acked a push
 *   relay.connect();
 *
 *   // send a chat message from desktop -> phone
 *   relay.sendChat('hello phone', { role: 'assistant' });
 *
 *   // push a notification (e.g. task finished)
 *   relay.sendNotification('任务完成', '今日日报已生成');
 *
 *   // send a file
 *   await relay.sendFile('D:/reports/daily.md');
 */
export class RelayClient extends EventEmitter {
  constructor({ serverUrl, token, userId = 'default-user', deviceName = 'Desktop', deviceId }) {
    super();
    this.serverUrl = serverUrl;
    this.token = token;
    this.userId = userId;
    this.deviceName = deviceName;
    this.deviceId = deviceId || `desktop-${randomUUID().slice(0, 8)}`;
    this.ws = null;
    this._closedByUser = false;
    this._retry = 0;
    this._peers = new Map();
    this._pending = new Map(); // id -> { resolve, reject }
  }

  // ---- lifecycle ----
  connect() {
    this._closedByUser = false;
    const url =
      `${this.serverUrl}?token=${encodeURIComponent(this.token)}` +
      `&deviceId=${encodeURIComponent(this.deviceId)}` +
      `&deviceName=${encodeURIComponent(this.deviceName)}` +
      `&platform=desktop`;

    this.ws = new WebSocket(url);

    this.ws.on('open', () => {
      this._retry = 0;
      this.emit('connected', { deviceId: this.deviceId });
    });

    this.ws.on('message', (data) => this._onMessage(data));

    this.ws.on('close', () => {
      this.emit('disconnected');
      if (!this._closedByUser) this._scheduleReconnect();
    });

    this.ws.on('error', (err) => this.emit('error', err));
    return this;
  }

  _scheduleReconnect() {
    const delay = Math.min(30000, 2000 + this._retry * 2000);
    this._retry++;
    setTimeout(() => !this._closedByUser && this.connect(), delay);
  }

  disconnect() {
    this._closedByUser = true;
    try {
      this.ws?.close();
    } catch {}
  }

  get connected() {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  get peers() {
    return [...this._peers.values()];
  }

  // ---- messaging ----
  _onMessage(data) {
    let msg;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      return;
    }

    switch (msg.type) {
      case 'welcome':
        this.emit('ready', msg.payload);
        break;
      case 'presence': {
        this._peers.clear();
        for (const d of msg.payload?.devices || []) {
          if (d.deviceId !== this.deviceId) this._peers.set(d.deviceId, d);
        }
        this.emit('presence', this.peers);
        break;
      }
      case 'chat':
        this.emit('chat', { ...msg.payload, id: msg.id, from: msg.from, ts: msg.ts });
        break;
      case 'notification':
        this.emit('notification', { ...msg.payload, from: msg.from });
        break;
      case 'file_share':
        this.emit('file', msg.payload?.file);
        break;
      case 'delivery_status':
        this.emit('delivery_status', msg.payload);
        break;
      case 'file_stored':
        this._resolvePending(msg.id, msg.payload);
        break;
      case 'error':
        this._rejectPending(msg.id, msg.payload);
        this.emit('relay_error', msg.payload);
        break;
      default:
        this.emit('message', msg);
    }
  }

  _send(obj) {
    if (!this.connected) return false;
    obj.from = this.deviceId;
    obj.ts = obj.ts || Date.now();
    try {
      this.ws.send(JSON.stringify(obj));
      return true;
    } catch {
      return false;
    }
  }

  /** Chat from desktop -> phone. to='*' broadcasts to all other devices. */
  sendChat(text, { role = 'assistant', to = '*', conversationId } = {}) {
    return this._send({
      v: 1,
      type: 'chat',
      id: randomUUID(),
      to,
      payload: { role, text, conversationId },
    });
  }

  /** Push a notification to the phone (e.g. scheduled-task result). */
  sendNotification(title, body, { to = '*' } = {}) {
    return this._send({
      v: 1,
      type: 'notification',
      id: randomUUID(),
      to,
      payload: { title, body },
    });
  }

  /** Upload a local file and share its meta with the phone(s). */
  async sendFile(filePath, { to = '*', name } = {}) {
    const base = this._httpBase();
    const fname = name || filePath.split(/[\\/]/).pop();
    const buf = await readFile(filePath);
    const res = await httpRequest(
      `${base}/upload?token=${encodeURIComponent(this.token)}&name=${encodeURIComponent(fname)}`,
      buf,
    );
    const json = JSON.parse(res);
    if (!json.ok) throw new Error('upload failed: ' + res);
    this._send({
      v: 1,
      type: 'file_share',
      id: randomUUID(),
      to,
      payload: { file: json.file },
    });
    return json.file;
  }

  /** Download a relayed file to a local path. */
  async downloadFile(fileId, savePath) {
    const base = this._httpBase();
    const buf = await httpGet(`${base}/file/${fileId}?token=${encodeURIComponent(this.token)}`);
    const { writeFile } = await import('node:fs/promises');
    await writeFile(savePath, buf);
    return savePath;
  }

  _httpBase() {
    let u = this.serverUrl;
    if (u.startsWith('wss://')) u = u.replace('wss://', 'https://');
    else if (u.startsWith('ws://')) u = u.replace('ws://', 'http://');
    const i = u.indexOf('/ws');
    return i >= 0 ? u.slice(0, i) : u;
  }

  _resolvePending(id, payload) {
    const p = this._pending.get(id);
    if (p) {
      p.resolve(payload);
      this._pending.delete(id);
    }
  }

  _rejectPending(id, payload) {
    const p = this._pending.get(id);
    if (p) {
      p.reject(new Error(payload?.message || 'error'));
      this._pending.delete(id);
    }
  }
}

// ---- tiny http helpers (no extra deps) ----
function httpRequest(url, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      url,
      { method: 'POST', headers: { 'content-type': 'application/octet-stream' } },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => resolve(data));
      },
    );
    req.on('error', reject);
    req.end(body);
  });
}

function httpGet(url) {
  return new Promise((resolve, reject) => {
    http
      .get(url, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks)));
      })
      .on('error', reject);
  });
}

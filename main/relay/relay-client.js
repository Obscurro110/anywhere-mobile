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
    this._reconnectTimer = null;
    this._peers = new Map();
    this._pending = new Map(); // id -> { resolve, reject }
  }

  // ---- lifecycle ----
  connect() {
    this._closedByUser = false;
    // 取消排队中的自动重连，否则手动 connect 会和它各建一条连接
    if (this._reconnectTimer) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    // 拆掉上一条 socket：不摘监听就直接覆盖 this.ws 的话，
    // 旧 socket 的 close 回调仍会触发 _scheduleReconnect，
    // 越滚越多，最后同时存在好几条连接互相抢消息。
    this._teardownSocket();

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

    // ⚠️ 不能直接 emit('error')：Node 的 EventEmitter 在**没有 error 监听者**时
    // 会把错误当未捕获异常抛出。中继这边只要网络抖一下（DNS/TLS/断网）就会触发，
    // 主进程日志被刷爆，严重时整个 relay 静默死掉。
    // 这里改成：有人监听 'error' 才转发，否则降级成 'relay_error' + 日志。
    this.ws.on('error', (err) => {
      if (this.listenerCount('error') > 0) this.emit('error', err);
      else this.emit('relay_error', { message: String(err?.message || err) });
    });
    return this;
  }

  /** 摘掉当前 socket 的所有监听并关闭（不触发重连）。 */
  _teardownSocket() {
    const ws = this.ws;
    this.ws = null;
    if (!ws) return;
    try {
      ws.removeAllListeners();
    } catch {}
    try {
      // readyState: 0 CONNECTING / 1 OPEN / 2 CLOSING / 3 CLOSED
      if (ws.readyState === 0 || ws.readyState === 1) ws.terminate?.() ?? ws.close();
    } catch {}
  }

  _scheduleReconnect() {
    if (this._closedByUser) return;
    // 已经排了重连就别再排（close 和 error 可能都会走到这里）
    if (this._reconnectTimer) return;
    const delay = Math.min(30000, 2000 + this._retry * 2000);
    this._retry++;
    this._reconnectTimer = setTimeout(() => {
      this._reconnectTimer = null;
      if (!this._closedByUser) this.connect();
    }, delay);
  }

  disconnect() {
    this._closedByUser = true;
    if (this._reconnectTimer) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    this._teardownSocket();
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
  sendChat(text, { role = 'assistant', to = '*', conversationId, extra } = {}) {
    const payload = { role, text, conversationId };
    // extra: 透传附加字段。手机端要靠它拿到电脑端那条消息的 id / 下标，
    // 这样气泡上的「重新回答 / 删除这条」才能定位到正确的消息。
    if (extra && typeof extra === 'object') {
      for (const [k, v] of Object.entries(extra)) {
        if (v === undefined || k === 'role' || k === 'text') continue;
        payload[k] = v;
      }
    }
    return this._send({
      v: 1,
      type: 'chat',
      id: randomUUID(),
      to,
      payload,
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
// 必须带超时：中继不可达时 http.request 会一直挂着，
// 手机那边就永远停在「发送中」。
const HTTP_TIMEOUT_MS = 3 * 60 * 1000;

function httpRequest(url, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      url,
      { method: 'POST', headers: { 'content-type': 'application/octet-stream' }, timeout: HTTP_TIMEOUT_MS },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => resolve(data));
        res.on('error', reject);
      },
    );
    req.on('timeout', () => {
      req.destroy(new Error(`upload timeout after ${HTTP_TIMEOUT_MS}ms`));
    });
    req.on('error', reject);
    req.end(body);
  });
}

function httpGet(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: HTTP_TIMEOUT_MS }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    });
    req.on('timeout', () => {
      req.destroy(new Error(`download timeout after ${HTTP_TIMEOUT_MS}ms`));
    });
    req.on('error', reject);
  });
}

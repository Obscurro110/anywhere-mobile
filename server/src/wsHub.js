import { WebSocketServer } from 'ws';
import { randomUUID } from 'node:crypto';
import { userForToken } from './auth.js';

/**
 * WebSocket hub.
 *
 * Connection:  ws://host:port/ws?token=XXX&deviceId=YYY&deviceName=ZZZ&platform=android|desktop
 *
 * Every frame is a JSON envelope:
 *   { v:1, type, id, from, to, ts, payload }
 *
 * Routing:
 *   to = "*"            -> broadcast to every OTHER session of the same user
 *   to = "<deviceId>"   -> deliver to that exact session
 *   to = "<userId>"     -> deliver to all sessions of that user (multi-device)
 *
 * Control types handled by the server itself:
 *   presence  -> server replies with the live device list (also broadcasts on join/leave)
 *   ping      -> replies pong
 *   ack       -> routed through (app-level ack)
 */
export function createWss({ server, tokens, fileStore }) {
  const wss = new WebSocketServer({ server, path: '/ws' });

  /** Map<deviceId, session> */
  const sessions = new Map();

  wss.on('connection', (ws, req) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const token = url.searchParams.get('token');
    const userId = token ? userForToken(tokens, token) : null;
    if (!userId) {
      ws.send(JSON.stringify({ v: 1, type: 'error', payload: { code: 'unauthorized' } }));
      return ws.close(4001, 'unauthorized');
    }

    const deviceId = url.searchParams.get('deviceId') || randomUUID();
    const deviceName = url.searchParams.get('deviceName') || 'Unknown device';
    const platform = url.searchParams.get('platform') || 'unknown';

    const session = { ws, userId, deviceId, deviceName, platform, connectedAt: Date.now() };
    // replace any stale session with same deviceId
    if (sessions.has(deviceId)) {
      try { sessions.get(deviceId).ws.close(4000, 'replaced'); } catch {}
    }
    sessions.set(deviceId, session);

    send(ws, { v: 1, type: 'welcome', payload: { userId, deviceId, serverTime: Date.now() } });
    broadcastPresence(userId);
    log(`+ ${deviceName} (${platform}) [${deviceId.slice(0, 8)}] user=${userId}`);

    ws.on('message', async (data) => {
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return send(ws, { v: 1, type: 'error', payload: { code: 'bad_json' } });
      }
      await onMessage(session, msg);
    });

    ws.on('close', () => {
      if (sessions.get(deviceId) === session) sessions.delete(deviceId);
      broadcastPresence(userId);
      log(`- ${deviceName} [${deviceId.slice(0, 8)}]`);
    });

    ws.on('error', (err) => log(`! ws error ${deviceId.slice(0, 8)}: ${err.message}`));
  });

  async function onMessage(session, msg) {
    const type = msg.type;

    if (type === 'ping') {
      return send(session.ws, { v: 1, type: 'pong', ts: Date.now() });
    }

    if (type === 'presence') {
      return send(session.ws, {
        v: 1,
        type: 'presence',
        payload: { devices: listDevices(session.userId) },
      });
    }

    // Upload a (small) file referenced by base64 chunk; returns file id.
    if (type === 'file_chunk_upload') {
      try {
        const { name, mime, data } = msg.payload || {};
        const meta = await fileStore.saveBase64(data, name || 'file.bin', mime);
        return send(session.ws, {
          v: 1,
          type: 'file_stored',
          id: msg.id,
          payload: { ...meta },
        });
      } catch (err) {
        return send(session.ws, {
          v: 1,
          type: 'error',
          id: msg.id,
          payload: { code: 'file_store_failed', message: String(err.message || err) },
        });
      }
    }

    // For any other type, route it.
    const env = normalize(session, msg);
    route(env);
  }

  function normalize(session, msg) {
    return {
      v: 1,
      type: msg.type,
      id: msg.id || randomUUID(),
      from: msg.from || session.deviceId,
      to: msg.to || '*',
      ts: msg.ts || Date.now(),
      payload: msg.payload ?? null,
    };
  }

  function route(env) {
    const recipients = resolveRecipients(env.from, env.to);
    let delivered = 0;
    for (const s of recipients) {
      send(s.ws, env);
      delivered++;
    }
    // ack back to sender
    if (delivered === 0 && env.type !== 'ack') {
      // no listener -> notify sender so the app can show "offline / queued"
      // (real offline queueing is handled client-side; server is stateless relay)
      const sender = sessions.get(env.from);
      if (sender) {
        send(sender.ws, {
          v: 1,
          type: 'delivery_status',
          id: env.id,
          payload: { status: 'undelivered', to: env.to },
        });
      }
    }
  }

  function resolveRecipients(fromDeviceId, to) {
    const sender = sessions.get(fromDeviceId);
    const senderUser = sender?.userId;

    if (to === '*') {
      // same user, all sessions except sender
      return [...sessions.values()].filter(
        (s) => s.userId === senderUser && s.deviceId !== fromDeviceId,
      );
    }

    // direct device id
    if (sessions.has(to)) {
      const target = sessions.get(to);
      if (target.deviceId !== fromDeviceId) return [target];
      return [];
    }

    // user id -> all sessions of that user except sender
    return [...sessions.values()].filter((s) => s.userId === to && s.deviceId !== fromDeviceId);
  }

  function listDevices(userId) {
    return [...sessions.values()]
      .filter((s) => s.userId === userId)
      .map((s) => ({
        deviceId: s.deviceId,
        deviceName: s.deviceName,
        platform: s.platform,
        connectedAt: s.connectedAt,
        online: true,
      }));
  }

  function broadcastPresence(userId) {
    const devices = listDevices(userId);
    for (const s of sessions.values()) {
      if (s.userId === userId) {
        send(s.ws, { v: 1, type: 'presence', payload: { devices } });
      }
    }
  }

  function send(ws, obj) {
    if (ws.readyState === ws.OPEN) {
      try { ws.send(JSON.stringify(obj)); } catch {}
    }
  }

  function log(msg) {
    console.log(`[relay] ${new Date().toISOString()} ${msg}`);
  }

  return { wss, sessions, listDevices };
}

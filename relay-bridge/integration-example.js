/**
 * EXAMPLE: how to wire the relay bridge into Anywhere Desktop's Electron
 * main process. Copy the relevant parts into your `main/index.js` (or a new
 * `main/relay.js` module) and call `setupRelay()` during app startup.
 *
 * This file is a reference, not auto-loaded.
 */
import { RelayClient } from '../relay-bridge/relay-client.js';

let relay = null;

export function setupRelay({ win, getConfig }) {
  const cfg = getConfig(); // your own config reader
  // Only start if the user enabled relay sync in settings
  if (!cfg?.relay?.enabled) return null;

  relay = new RelayClient({
    serverUrl: cfg.relay.serverUrl, // ws://your-server:8787/ws
    token: cfg.relay.token,
    userId: cfg.relay.userId || 'default-user',
    deviceName: cfg.relay.deviceName || 'Anywhere Desktop',
  });

  // --- phone -> desktop ---
  relay.on('chat', async (msg) => {
    // Forward to the renderer so it appears in the active conversation and
    // is handled by your existing agent pipeline.
    win?.webContents.send('relay:incoming-chat', msg);

    // OPTIONAL: run your agent here and stream the reply back:
    //   const reply = await runAgent(msg.text);
    //   relay.sendChat(reply, { role: 'assistant', to: msg.from });
  });

  relay.on('file', (meta) => {
    win?.webContents.send('relay:incoming-file', meta);
  });

  relay.on('connected', () => console.log('[relay] desktop bridge connected'));
  relay.on('disconnected', () => console.log('[relay] desktop bridge disconnected'));

  relay.connect();
  return relay;
}

/** Call this from your scheduled-task completion handler. */
export function pushTaskNotification(title, body) {
  relay?.sendNotification(title, body);
}

/** Send an assistant reply from desktop to the phone. */
export function replyToPhone(text, to = '*') {
  relay?.sendChat(text, { role: 'assistant', to });
}

/** Push a produced file to the phone. */
export async function pushFile(filePath) {
  return relay?.sendFile(filePath);
}

export function getRelay() {
  return relay;
}

// Demo: runs the desktop bridge and talks to the relay.
// Requires the relay server running on 127.0.0.1:8787.
import { RelayClient } from './relay-client.js';

const relay = new RelayClient({
  serverUrl: process.env.RELAY_URL || 'ws://127.0.0.1:8787/ws',
  token: process.env.RELAY_TOKEN || 'CHANGE_ME_TOKEN',
  userId: 'default-user',
  deviceName: 'Demo Desktop',
});

relay.on('connected', () => console.log('[bridge] connected as', relay.deviceId));
relay.on('presence', (peers) => console.log('[bridge] peers:', peers.map((p) => `${p.deviceName}(${p.platform})`)));
relay.on('chat', (msg) => {
  console.log('[bridge] chat from', msg.from, '->', msg.text);
  // auto-reply so the phone sees a response
  relay.sendChat(`Echo: ${msg.text}`, { role: 'assistant', to: msg.from });
});
relay.on('notification', (n) => console.log('[bridge] notif:', n));
relay.on('file', (f) => console.log('[bridge] file offered:', f));
relay.on('delivery_status', (s) => console.log('[bridge] delivery:', s));

relay.connect();

// after 2s, push a sample notification
setTimeout(() => {
  console.log('[bridge] sending sample notification...');
  relay.sendNotification('定时任务完成', '今日日报已生成 ✅');
}, 2000);

// keep alive for 15s then exit
setTimeout(() => {
  relay.disconnect();
  process.exit(0);
}, 15000);

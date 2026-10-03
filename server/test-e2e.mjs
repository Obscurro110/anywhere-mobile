// End-to-end relay test: simulates a desktop client + an android client.
// Run with the server already listening on 127.0.0.1:8787
import WebSocket from 'ws';

const BASE = process.env.RELAY || 'ws://127.0.0.1:8787/ws';
const HTTP = BASE.replace('ws://', 'http://').replace('/ws', '');
const TOKEN = process.env.TOKEN || 'CHANGE_ME_TOKEN';

const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(deviceId, deviceName, platform) {
  const ws = new WebSocket(`${BASE}?token=${TOKEN}&deviceId=${deviceId}&deviceName=${encodeURIComponent(deviceName)}&platform=${platform}`);
  const queue = [];
  ws.on('message', (d) => queue.push(JSON.parse(d.toString())));
  return new Promise((resolve, reject) => {
    ws.on('open', () => resolve({ ws, queue, send: (o) => ws.send(JSON.stringify(o)) }));
    ws.on('error', reject);
  });
}

const results = [];
function check(name, cond, extra = '') {
  results.push({ name, ok: !!cond });
  log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  -> ' + extra : ''}`);
}

let idc = 0;
const nid = () => `t-${Date.now()}-${idc++}`;

const desktop = await connect('desktop-1', 'My PC', 'desktop');
const android = await connect('android-1', 'My Phone', 'android');
await sleep(300);

// 1. welcome
check('desktop receives welcome', desktop.queue.some((m) => m.type === 'welcome'));

// 2. presence: android should see desktop after join
await sleep(200);
const lastPresence = [...android.queue].reverse().find((m) => m.type === 'presence');
check('android sees desktop in presence', lastPresence?.payload?.devices?.some((d) => d.deviceId === 'desktop-1'));

// 3. chat android -> desktop (broadcast *)
android.send({ v: 1, type: 'chat', id: nid(), to: '*', payload: { role: 'user', text: 'hello from phone' } });
await sleep(300);
check('desktop receives chat from android', desktop.queue.some((m) => m.type === 'chat' && m.payload?.text === 'hello from phone'));
check('android does NOT receive its own chat', !android.queue.some((m) => m.type === 'chat' && m.payload?.text === 'hello from phone'));

// 4. chat desktop -> specific android device
desktop.send({ v: 1, type: 'chat', id: nid(), to: 'android-1', payload: { role: 'assistant', text: 'hi phone' } });
await sleep(300);
check('android receives directed chat', android.queue.some((m) => m.type === 'chat' && m.payload?.text === 'hi phone'));

// 5. notification desktop -> android
desktop.send({ v: 1, type: 'notification', id: nid(), to: 'android-1', payload: { title: 'Task done', body: 'Daily report ready' } });
await sleep(300);
check('android receives notification', android.queue.some((m) => m.type === 'notification' && m.payload?.title === 'Task done'));

// 6. file relay: android uploads a small file, gets id; desktop downloads it
const content = Buffer.from('Hello Anywhere file relay! ' + Date.now());
const uploadResp = await fetch(`${HTTP}/upload?token=${TOKEN}&name=hello.txt`, { method: 'POST', body: content });
const up = await uploadResp.json();
check('file upload returns id', up.ok && up.file?.id, JSON.stringify(up.file));

if (up.ok) {
  const dl = await fetch(`${HTTP}/file/${up.file.id}?token=${TOKEN}`);
  const body = Buffer.from(await dl.arrayBuffer());
  check('file download matches upload', body.equals(content), `${body.length} bytes`);
  // share the file meta to the other device over ws
  android.send({ v: 1, type: 'file_share', id: nid(), to: 'desktop-1', payload: { file: up.file } });
  await sleep(300);
  check('desktop receives file_share', desktop.queue.some((m) => m.type === 'file_share' && m.payload?.file?.id === up.file.id));
}

// 7. ping/pong
desktop.send({ v: 1, type: 'ping' });
await sleep(200);
check('server replies pong', desktop.queue.some((m) => m.type === 'pong'));

// 8. delivery status for unknown target
android.send({ v: 1, type: 'chat', id: nid(), to: 'ghost-device', payload: { text: 'x' } });
await sleep(300);
check('undelivered target reports delivery_status', android.queue.some((m) => m.type === 'delivery_status' && m.payload?.status === 'undelivered'));

desktop.ws.close();
android.ws.close();

const failed = results.filter((r) => !r.ok);
log(`\n==== ${results.length - failed.length}/${results.length} passed ====`);
process.exit(failed.length ? 1 : 0);

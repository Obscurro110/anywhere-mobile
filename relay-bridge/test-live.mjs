// Live connectivity test against a public relay (WSS/WS).
//
// Usage:
//   TEST_URL=ws://your-host:8787/ws TEST_TOKEN=your_token node test-live.mjs
//   TEST_URL=wss://relay.example.com/ws TEST_TOKEN=xxx TEST_PROXY=socks5h://127.0.0.1:10808 node test-live.mjs
//
// No secrets are stored in this file.
import WebSocket from 'ws';
import { SocksProxyAgent } from 'socks-proxy-agent';

const BASE = process.env.TEST_URL;
const TOKEN = process.env.TEST_TOKEN;
const PROXY = process.env.TEST_PROXY || ''; // empty => direct connection

if (!BASE || !TOKEN) {
  console.error('[test] Please set TEST_URL and TEST_TOKEN environment variables.');
  console.error('       e.g. TEST_URL=ws://1.2.3.4:8787/ws TEST_TOKEN=xxxx node test-live.mjs');
  process.exit(2);
}

const opts = { handshakeTimeout: 20000 };
if (PROXY) opts.agent = new SocksProxyAgent(PROXY);

const url =
  `${BASE}?token=${encodeURIComponent(TOKEN)}` +
  `&deviceId=test-desktop-01&deviceName=${encodeURIComponent('Connectivity Test (PC)')}` +
  `&platform=desktop`;

console.log('[test] connecting to', BASE, PROXY ? `via ${PROXY}` : '(direct)');

const ws = new WebSocket(url, opts);
const seen = [];
const timeout = setTimeout(() => {
  console.log('[test] TIMEOUT 25s. seen:', JSON.stringify(seen));
  process.exit(2);
}, 25000);

ws.on('open', () => console.log('[test] OK  WebSocket OPEN (upgrade OK)'));
ws.on('message', (d) => {
  const t = d.toString();
  seen.push(t);
  let m;
  try { m = JSON.parse(t); } catch { console.log('[test] raw:', t); return; }
  if (m.type === 'welcome') {
    console.log('[test] OK  AUTH OK - welcome:', JSON.stringify(m.payload));
    ws.send(JSON.stringify({ v: 1, type: 'presence' }));
  } else if (m.type === 'presence') {
    console.log('[test] presence:', JSON.stringify(m.payload));
    console.log('[test] OK  FULL CHAIN OK');
    clearTimeout(timeout);
    ws.close();
    process.exit(0);
  } else if (m.type === 'error') {
    console.log('[test] FAIL server error:', JSON.stringify(m.payload));
    clearTimeout(timeout);
    ws.close();
    process.exit(1);
  } else {
    console.log('[test] msg:', m.type);
  }
});
ws.on('unexpected-response', (req, res) => {
  console.log('[test] FAIL HTTP', res.statusCode);
  clearTimeout(timeout);
  process.exit(1);
});
ws.on('error', (e) => console.log('[test] FAIL error:', e.message));
ws.on('close', (c, r) => console.log('[test] closed', c, r?.toString()));

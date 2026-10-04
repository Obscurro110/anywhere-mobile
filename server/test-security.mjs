// 安全冒烟测试：验证越权修复 + 跨账号隔离 + 基本路由。
// 前置：服务器已监听 127.0.0.1:8799，AUTH_TOKENS=alice:token_ALICE_0123456789,bob:token_BOB_9876543210
import WebSocket from 'ws';

const BASE = 'ws://127.0.0.1:8799/ws';
const HTTP = 'http://127.0.0.1:8799';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (name, cond, extra = '') => {
  results.push({ name, ok: !!cond });
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  -> ' + extra : ''}`);
};

function connect(token, deviceId, deviceName, platform) {
  const ws = new WebSocket(`${BASE}?token=${token}&deviceId=${deviceId}&deviceName=${encodeURIComponent(deviceName)}&platform=${platform}`);
  const queue = [];
  ws.on('message', (d) => queue.push(JSON.parse(d.toString())));
  return new Promise((resolve, reject) => {
    ws.on('open', () => resolve({ ws, queue, send: (o) => ws.send(JSON.stringify(o)) }));
    ws.on('error', reject);
  });
}

const A = 'token_ALICE_0123456789';
const B = 'token_BOB_9876543210';

// 两个用户各连一个设备
const alice = await connect(A, 'alice-desktop', 'Alice PC', 'desktop');
const bob = await connect(B, 'bob-phone', 'Bob Phone', 'android');
await sleep(300);

// 1. 越权修复：alice 伪造 from=alice-desktop? 改为伪造 bob 的 deviceId
//    期望：即使 alice 说 "from=bob-phone"，服务端也应注入真实身份 alice-desktop
alice.send({ v: 1, type: 'chat', id: 'sec-1', from: 'bob-phone', to: '*', payload: { role: 'user', text: 'forged-from-test' } });
await sleep(300);

const bobGot = bob.queue.some((m) => m.type === 'chat' && m.payload?.text === 'forged-from-test');
check('伪造 from 不能把消息投递给别人（bob 不应收到）', !bobGot, bobGot ? 'bob 收到了! 漏洞!' : '');
const aliceEcho = alice.queue.some((m) => m.type === 'chat' && m.payload?.text === 'forged-from-test');
check('伪造 from 不会回显给发送者自己', !aliceEcho);

// 2. 跨账号隔离：alice 直接 to=bob 的 deviceId，bob 不应收到
alice.send({ v: 1, type: 'chat', id: 'sec-2', to: 'bob-phone', payload: { role: 'user', text: 'cross-user-direct' } });
await sleep(300);
check('跨账号直投被拦截（bob 不应收到）', !bob.queue.some((m) => m.type === 'chat' && m.payload?.text === 'cross-user-direct'));

// 3. 同账号广播仍正常：再加一个 alice 设备，alice-desktop 广播应能到 alice-phone
const alice2 = await connect(A, 'alice-phone', 'Alice Phone', 'android');
await sleep(300);
alice.send({ v: 1, type: 'chat', id: 'sec-3', to: '*', payload: { role: 'user', text: 'same-user-broadcast' } });
await sleep(300);
check('同账号广播正常（alice-phone 收到）', alice2.queue.some((m) => m.type === 'chat' && m.payload?.text === 'same-user-broadcast'));

// 4. 定向投递仍正常
alice.send({ v: 1, type: 'chat', id: 'sec-4', to: 'alice-phone', payload: { role: 'user', text: 'direct-to-alice-phone' } });
await sleep(300);
check('同账号定向投递正常', alice2.queue.some((m) => m.type === 'chat' && m.payload?.text === 'direct-to-alice-phone'));

// 5. 越权修复：真实 from 字段 = 服务端注入的 deviceId
const seen = alice2.queue.find((m) => m.type === 'chat' && m.payload?.text === 'same-user-broadcast');
check('from 字段被服务端注入为真实 deviceId', seen?.from === 'alice-desktop', `from=${seen?.from}`);

// 6. 坏 token 被拒
const badWs = new WebSocket(`${BASE}?token=wrong_token_0000&deviceId=x&deviceName=x&platform=desktop`);
const badRejected = await new Promise((resolve) => {
  badWs.on('close', (code) => resolve(code === 4001));
  badWs.on('error', () => resolve(false));
  setTimeout(() => resolve(false), 2000);
});
check('非法 token 被 4001 拒绝', badRejected);

// 7. 未认证文件下载 401
const un = await fetch(`${HTTP}/file/nonexistent`);
check('未认证 /file 返回 401', un.status === 401);

// 8. 健康检查
const h = await fetch(`${HTTP}/health`);
const hj = await h.json();
check('健康检查 ok', hj.ok === true);

alice.ws.close(); alice2.ws.close(); bob.ws.close();
const failed = results.filter((r) => !r.ok);
console.log(`\n==== ${results.length - failed.length}/${results.length} passed ====`);
process.exit(failed.length ? 1 : 0);

# 电脑端接入指南（Anywhere Desktop ⇆ 手机）

把 **Anywhere Desktop** 接入中继服务器，实现与手机的双向互通（对话 / 文件 / 通知）。

```
手机 App ──┐                        ┌── main/relay/  (本次接入的桥)
           ├── 公网中继 (wss://) ───┤
桌面 Desktop ┘                       └── 渲染进程 (复用你现有的 AI 流程)
```

---

## 一、准备文件

把本目录（`desktop-integration/`）里的文件复制到桌面项目：

| 本目录文件 | 复制到桌面项目 |
| --- | --- |
| `relay-client.js` | `main/relay/relay-client.js` |
| `main-relay.js` | `main/relay/index.js` |
| `renderer-example.js` | `render/window/src/relay.js`（示例，按需改）|

在桌面项目里新建目录 `main/relay/`：

```
Anywhere_desktop/
└── main/
    ├── index.js            ← 改动这个（见第二步）
    └── relay/              ← 新建
        ├── index.js        ← 复制自 main-relay.js
        └── relay-client.js ← 复制自 relay-client.js
```

---

## 二、修改 `main/index.js`（2 处）

### 1）顶部 import 区，加入：

```js
import { startRelay } from './relay/index.js'
```

建议放在已有的 `import { startTaskScheduler } from './core/task_scheduler.js'` 附近。

### 2）在 `app.whenReady().then(async () => { ... })` 里，**`await openWindow('main')` 之后**，加入一行：

```js
app.whenReady().then(async () => {
  electronApp.setAppUserModelId('com.komorebi.anywhere.desktop')
  installRequestHeaderBridge()
  // ...（原有代码不动）...
  await syncDesktopRuntimeFromConfig()
  ensureTray()
  await openWindow('main')

  // ✅ 新增：启动中继连接
  startRelay({ getWindowByRef, listWindows, dispatchWindowEvent })

  setTimeout(() => { preheatScreenshotWindow() }, ...)
})
```

`getWindowByRef`、`listWindows`、`dispatchWindowEvent` 在 `main/index.js` 顶部**已经 import 了**，直接传入即可，无需额外引入。

> 这样，手机发来的消息会以 `window:event-bus` 事件（`event='relay:incoming'`）广播给所有窗口，同时注册好 `relay:*` 的 IPC。

---

## 三、配置连接信息

三选一（优先级从高到低）：

### 方式 A：`userData/relay.json`（推荐）
在桌面应用的 userData 目录放一个 `relay.json`：

```json
{
  "serverUrl": "wss://anywhereapi.example.com/ws",
  "token": "***REDACTED-TOKEN***",
  "userId": "default-user",
  "deviceName": "My PC"
}
```

Windows 的 userData 路径一般是：
`C:\Users\<你>\AppData\Roaming\<应用名>\relay.json`

### 方式 B：环境变量（开发调试方便）
```powershell
$env:ANYWHERE_RELAY_URL="wss://anywhereapi.example.com/ws"
$env:ANYWHERE_RELAY_TOKEN="你的令牌"
$env:ANYWHERE_RELAY_USER_ID="default-user"
$env:ANYWHERE_RELAY_DEVICE_NAME="My PC"
pnpm dev
```

### 方式 C：运行期由界面设置
渲染进程调用：

```js
await window.electron.ipcRenderer.invoke('relay:setConfig', {
  serverUrl: 'wss://anywhereapi.example.com/ws',
  token: '你的令牌',
  userId: 'default-user',
  deviceName: 'My PC'
})
```

（会写入 `userData/relay.json` 并自动重连）

> ⚠️ 三项配置里 **`userId` 必须和手机端填的一致**（默认 `default-user`），否则双方看不到彼此。

---

## 四、渲染进程接入（让消息显示 + 回复）

参考 `renderer-example.js`，在聊天窗口挂载时：

```js
import { initRelayWindow, relaySendChat } from './relay'

initRelayWindow({
  onChat: async (msg) => {
    // 1) 把手机消息显示到会话里
    appendIncomingMessage({ role: 'user', text: msg.text, source: 'phone' })
    // 2) 走你已有的 AI 流程，拿到回复后发回手机
    const reply = await runAgentOnce(msg.text)   // ← 换成你真实的调用
    await relaySendChat(reply)
  },
  onNotification: (n) => toast(`${n.title}: ${n.body}`),
  onFile: (f) => addIncomingFile(f.file),
  onStatus: (s) => setRelayDot(s.connected),
})
```

> 💡 说明：桌面的 AI 调用（`chat:createChatCompletion`）需要 provider 配置，而这些配置在**渲染进程**里。所以「手机消息 → AI 回复」这一步放在渲染进程最自然——复用你现有的对话流程即可，主进程只负责中转。

---

## 五、（可选）定时任务完成后推送手机

在任务完成处（例如 `main/core/task_scheduler.js` 或任务回调里）调用：

```js
import { notifyFromDesktop } from './relay/index.js'

// 任务跑完后：
notifyFromDesktop('定时任务完成', '今日日报已生成 ✅')
```

也可以在渲染进程里直接触发：

```js
await window.electron.ipcRenderer.invoke('relay:sendNotification', {
  title: '任务完成',
  body: '日报已生成'
})
```

---

## 六、验证

1. 启动桌面端，看控制台是否出现：
   ```
   [relay] connected as desktop-xxxxxxxx
   ```
2. 打开手机 App（已填相同 `userId` + 相同服务器），进入**「设备」**页 —— 应能看到 `My PC (desktop)`。
3. 手机→电脑：在手机「对话」页发一条消息，桌面端应弹出/显示；桌面回复后手机能收到。
4. 电脑→手机：桌面调用 `relaySendChat('你好')` 或 `sendNotification(...)`，手机应收到。

---

## 七、常见问题

| 现象 | 排查 |
| --- | --- |
| 控制台无 `[relay] connected` | 没读到配置（检查 `relay.json` 路径 / 环境变量）；或 `serverUrl`/`token` 为空 |
| 连上但手机看不到设备 | 两端 `userId` 不一致 |
| 手机收不到桌面消息 | `relay:sendChat` 返回 `relay_not_connected`，说明未连上 |
| 消息没显示在 UI | 渲染进程没监听 `onWindowEvent`，或事件名不是 `relay:incoming` |
| `dispatchWindowEvent` 报错 | 确认 `startRelay(...)` 传入的三个函数与 `main/index.js` 顶部 import 的完全一致 |

---

## 八、接入后的数据流

```
手机 App
  │  chat / file_share / notification
  ▼
公网中继 (wss://anywhereapi.example.com/ws)
  │
  ▼
main/relay (RelayClient)
  │  dispatchWindowEvent(event='relay:incoming')
  ▼
渲染进程 window
  │  显示 + 调用 AI (chat:createChatCompletion)
  ▼
window.electron.ipcRenderer.invoke('relay:sendChat', { text })
  │
  ▼
main/relay → 中继 → 手机 App
```

# Anywhere Mobile

**Anywhere Desktop 的 Android 伴侣应用** —— 通过**公网中继服务器**实现手机与电脑的双向互通：

- 💬 **双向对话**：手机上给电脑端 Anywhere Desktop 发消息，接收 AI 回复
- 📁 **文件互传**：手机 ↔ 电脑双向传输文件
- 🔔 **通知推送**：电脑端定时任务完成后推送到手机
- 📱 **多设备**：同一账号下多台设备实时在线感知

```
┌───────────────┐        ┌──────────────────────┐        ┌───────────────────────┐
│ Android App   │  WS/HTTP│   Relay Server       │WS/HTTP │ Anywhere Desktop      │
│ (Flutter)     │◄───────►│ (Node.js, 公网部署)  │◄──────►│ (Electron + relay-    │
│               │        │  聊天/文件/通知中转   │        │  bridge 接入)         │
└───────────────┘        └──────────────────────┘        └───────────────────────┘
```

## 目录结构

```
anywhere-mobile/
├── server/            # 公网中继服务器 (Node.js + ws)
│   ├── src/
│   │   ├── index.js     # HTTP + WS 入口
│   │   ├── wsHub.js     # WebSocket 路由中枢
│   │   ├── fileStore.js # 文件暂存
│   │   └── auth.js      # token 鉴权
│   ├── test-e2e.mjs     # 端到端测试（11 项，全部通过）
│   └── env.example
├── app/               # Flutter Android 应用
│   ├── lib/
│   │   ├── core/        # 协议 + 配置
│   │   ├── models/      # 数据模型
│   │   ├── services/    # WS 客户端、应用状态、通知
│   │   ├── screens/     # 对话/设备/文件/通知/设置
│   │   └── widgets/
│   └── pubspec.yaml
├── relay-bridge/      # 桌面端接入模块 (Node.js)
│   ├── relay-client.js       # 可被 Electron 主进程引入
│   ├── integration-example.js# 接入 Anywhere Desktop 的示例
│   └── demo.js
└── docs/
    └── PROTOCOL.md    # 三方通信协议（契约）
```

## 快速开始

### 1. 启动中继服务器

#### 方式 A：Docker / 1Panel（推荐用于服务器部署）

```bash
cd server
cp env.docker.example .env   # 修改 AUTH_TOKENS
docker compose up -d --build
# 验证: http://<服务器IP>:8787/health
```

> **1Panel 用户**：见详细图文步骤 [`docs/DEPLOY_DOCKER_1PANEL.md`](docs/DEPLOY_DOCKER_1PANEL.md)（含反向代理启用 `wss://` 的配置）。

#### 方式 B：直接 Node 运行（本地调试）

```bash
cd server
cp env.example .env          # 修改 AUTH_TOKENS 等
npm install
npm start
# => listening on http://0.0.0.0:8787
```

`.env` 关键项：

```ini
PORT=8787
AUTH_TOKENS=default-user:你的令牌      # 格式 userId:token，可逗号分隔多组
FILE_TTL_HOURS=72
MAX_FILE_MB=512
```

> **公网部署**：把服务器放到有公网 IP 的机器/VPS 上，建议用 Nginx 反代并启用 `wss://`（TLS）。
> 手机与电脑都填写同一 `serverUrl` 与 `token` 即可。

### 2. 构建 Android App

项目已提供完整 Dart 源码；平台工程文件用 Flutter 生成（因本机未安装 Flutter SDK）：

```bash
cd app
flutter create .            # 补全 android/ 平台文件（不会覆盖已有 lib/）
flutter pub get
flutter build apk --release # 产物: build/app/outputs/flutter-apk/app-release.apk
```

或连接手机直接运行：`flutter run`

首次打开 App → **设置** 页填写：
- 中继服务器地址：`ws://你的服务器:8787/ws`
- 访问令牌：与 `.env` 中一致
- 用户 ID、本机名称

### 3. 让电脑端接入

在 Anywhere Desktop 的 Electron 主进程里引入 bridge：

```js
import { RelayClient } from './relay-bridge/relay-client.js';

const relay = new RelayClient({
  serverUrl: 'ws://你的服务器:8787/ws',
  token: '你的令牌',
  userId: 'default-user',
  deviceName: 'My PC',
});

relay.on('chat', (msg) => {
  // 转发到渲染进程，进入你的 Agent 流程
  win.webContents.send('relay:incoming-chat', msg);
  // 或直接回复：
  // relay.sendChat('收到！', { role: 'assistant', to: msg.from });
});

relay.on('file', (meta) => win.webContents.send('relay:incoming-file', meta));

relay.connect();

// 定时任务完成时：
relay.sendNotification('任务完成', '今日日报已生成');
```

完整接入示例见 [`relay-bridge/integration-example.js`](relay-bridge/integration-example.js)。

## 测试

```bash
# 先启动服务器，再运行端到端测试
cd server
node test-e2e.mjs
# => 11/11 passed
```

覆盖：welcome、presence、双向 chat 路由、定向投递、通知、文件上传/下载/分享、ping/pong、离线投递状态。

## 协议

三端通信契约详见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。

## 说明

- 本项目面向 [Komorebi-yaodong/anywheredesktop](https://github.com/Komorebi-yaodong/anywheredesktop) 做互通扩展。
- 桌面端主项目为 AGPL-3.0，本互通套件请遵循相同协议使用。

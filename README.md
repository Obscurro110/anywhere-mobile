# Anywhere Mobile

**Anywhere Desktop 的 Android 伴侣应用** —— 通过**公网中继服务器**实现手机与电脑的双向互通：

- 💬 **双向对话**：手机上给电脑端 Anywhere Desktop 发消息，接收 AI 回复（**流式滚动显示**，可看生成过程与工具执行状态）
- 🗂 **会话管理**：查看/打开/重命名/删除电脑端会话，会话按项目分组；新会话按首条消息**自动命名**
- 🧩 **助手与会话绑定**：手机可切换快捷助手、模型、思考预算、MCP、Skill、压缩，**换助手即开新会话**
- 📁 **文件互传**：手机 ↔ 电脑双向传输文件
- 🔔 **通知推送**：电脑端定时任务完成后推送到手机
- 📱 **多设备**：同一账号下多台设备实时在线感知

```
┌───────────────┐        ┌──────────────────────┐        ┌────────────────────────┐
│ Android App   │  WS/HTTP│   Relay Server       │WS/HTTP │ Anywhere Desktop       │
│ (Flutter)     │◄───────►│ (Node.js, 公网部署)  │◄──────►│ (Electron，自建 relay  │
│               │        │  聊天/文件/通知中转   │        │  版，绿色包发行)       │
└───────────────┘        └──────────────────────┘        └────────────────────────┘
```

手机与电脑端通过本仓库的补丁对齐协议；电脑端是**从源码自建**的绿色版，可跟随上游更新。

## 目录结构

```
anywhere-mobile/
├── server/                 # 公网中继服务器 (Node.js + ws)
│   ├── src/
│   │   ├── index.js         # HTTP + WS 入口
│   │   ├── wsHub.js         # WebSocket 路由中枢
│   │   ├── fileStore.js     # 文件暂存（仅上传者可下载）
│   │   └── auth.js          # token 鉴权
│   ├── test-e2e.mjs         # 端到端测试
│   ├── test-security.mjs    # 安全回归（畸形容错 / 越权下载等）
│   ├── Dockerfile           # 容器镜像
│   ├── docker-compose.yml   # 本机构建运行
│   ├── docker-compose.ghcr.yml  # 直接拉取 CI 镜像
│   └── env.example / env.docker.example
├── app/                    # Flutter Android 应用
│   ├── lib/
│   │   ├── core/            # 协议协议与配置（protocol.dart / app_config.dart）
│   │   ├── models/          # 数据模型
│   │   ├── services/        # WS 客户端、应用状态、通知、更新检查
│   │   ├── screens/         # 对话 / 电脑端会话 / 能力 / 任务 / 通知 / 设置
│   │   └── widgets/         # 会话参数条、连接状态、更新卡片等
│   └── pubspec.yaml
├── desktop-integration/    # ★ 桌面端接入（推荐路径）
│   ├── anywhere-desktop-relay.patch  # 对桌面源码的完整补丁
│   ├── apply-relay-patch.mjs         # 在 CI / 本地应用补丁
│   ├── main-relay.js / relay-client.js / renderer-example.js
│   ├── README.md            # 接入说明
│   ├── BUILD_CUSTOM.md      # 从源码构建带互通的自建版
│   ├── 新电脑安装说明.md      # 换电脑 / 首次部署步骤
│   └── 更新.ps1             # Windows 一键更新
├── relay-bridge/           # 独立 Bridge 模块（协议级示例，可选）
│   ├── relay-client.js
│   ├── integration-example.js
│   └── demo.js
├── scripts/                # 防泄露钩子
│   ├── pre-commit-secret-scan.mjs
│   └── install-git-hooks.mjs
├── docs/
│   ├── PROTOCOL.md         # 三方通信协议（契约）
│   └── DEPLOY_DOCKER_1PANEL.md
├── .github/workflows/      # CI：APK / 桌面绿色版 / 中继镜像
├── version.json            # ★ 唯一版本源（App 与桌面端共用）
└── README.md
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

#### 方式 A2：直接拉取已构建镜像（免服务器构建）

CI 已自动把镜像推到 GHCR，服务器直接拉取即可：

```bash
cd server
cp env.docker.example .env       # 修改 AUTH_TOKENS
docker compose -f docker-compose.ghcr.yml up -d
```

镜像：`ghcr.io/obscurro110/anywhere-relay:latest`（支持 amd64 / arm64）

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

### 2. 安装手机 App

**普通用户**：直接到仓库 **Releases** 下载 `apk-latest` 里的 `anywhere-mobile.apk` 安装（App 内「设置 → 关于 → 检查更新」也能自动检查新版本）。

**自己构建**：

```bash
cd app
flutter create .            # 补全 android/ 平台文件（不会覆盖已有 lib/）
flutter pub get
flutter build apk --release # 产物: build/app/outputs/flutter-apk/app-release.apk
```

或连接手机直接运行：`flutter run`

首次打开 App → **设置** 页填写：
- 中继服务器地址：`ws://你的服务器:8787/ws`（HTTPS 环境用 `wss://`）
- 访问令牌：与 `.env` 中一致
- 用户 ID、本机名称

### 3. 使用电脑端（自带互通的绿色版）

到 Releases 下载 `desktop-latest` 里的 `anywhere-desktop-relay-win-x64.zip`，解压后运行
`anywhere-desktop-relay.exe`，在 **设置 → 手机互通** 填好 `serverUrl` / `token` 即可。

> 📘 **从源码构建自建版**（推荐，不受官方更新覆盖）：
> 见 **[`desktop-integration/BUILD_CUSTOM.md`](desktop-integration/BUILD_CUSTOM.md)**；
> 换电脑/首次部署见 **[`desktop-integration/新电脑安装说明.md`](desktop-integration/新电脑安装说明.md)**；
> 接入细节（补丁内容、IPC 约定、定时任务推送）见 **[`desktop-integration/README.md`](desktop-integration/README.md)**。

> ⚠️ 自建版与官方版是**两个独立程序**，各自使用自己的数据目录：
> 自建版的会话/配置在程序目录下的 `user-data/`，互不干扰，可以同时开着。

#### 协议级接入（可选）

如果只想在自己的 Electron 应用里接入，而不打补丁：

```js
import { RelayClient } from './relay-bridge/relay-client.js';

const relay = new RelayClient({
  serverUrl: 'ws://你的服务器:8787/ws',
  token: '你的令牌',
  userId: 'default-user',
  deviceName: 'My PC',
});

relay.on('chat', (msg) => {
  relay.sendChat('收到！', { role: 'assistant', to: msg.from });
});
relay.on('file', (meta) => win.webContents.send('relay:incoming-file', meta));
relay.connect();
relay.sendNotification('任务完成', '今日日报已生成');
```

完整示例见 [`relay-bridge/integration-example.js`](relay-bridge/integration-example.js)。

## 测试

```bash
# 先启动服务器，再运行端到端测试
cd server
node test-e2e.mjs        # 协议端到端
node test-security.mjs   # 安全回归
```

覆盖：welcome、presence、双向 chat 路由、定向投递、通知、文件上传/下载/分享、ping/pong、离线投递状态；
以及畸形消息容错、文件越权下载等安全用例。

仓库内置 **pre-commit 防泄露钩子**（拦截 token / PAT 误提交）：

```bash
node scripts/install-git-hooks.mjs
```

## 协议

三端通信契约详见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。

## CI / CD（GitHub Actions）

仓库内置三个工作流，推送即自动运行：

| 工作流 | 触发 | 作用 |
| --- | --- | --- |
| **Build Android APK** | 改动 `app/**`、`version.json` 或手动 | 用 Flutter 构建 APK，发布到 `apk-latest`；打 `v*` tag 时另发带版本号的 Release |
| **Build Desktop (Relay 绿色版)** | 改动 `desktop-integration/**`、`version.json` 或手动 | clone 上游桌面源码 + 应用本仓库补丁 → 打包 Windows 绿色版，发布到 `desktop-latest` |
| **Build & Push Relay Image** | 改动 `server/**` 或手动 | 构建中继镜像并推送到 `ghcr.io/obscurro110/anywhere-relay`（amd64+arm64，含 `latest`/`sha-*`/tag）|

- 查看运行结果：仓库 **Actions** 标签页
- 手动触发：Actions → 选对应工作流 → **Run workflow**
- 发布带版本号的版本：改 `version.json` 后 `git tag v1.7.24 && git push origin v1.7.24`

> Release 里的 `version.json` 带 APK 的 `sha256`，App 内更新会校验后再安装。

## 版本 / 更新记录

版本号以仓库根 [`version.json`](version.json) 为准（App 与桌面端共用同一版本号），发版时改它即可，CI 自动构建发布。

### v1.7.24（当前）

- **生成过程实时同步**：电脑端一受理就回状态，手机上先显示「电脑端正在生成…」，再逐段滚动出正文（推送间隔 800ms → 150ms），不再一大段突然闪出来。
- **换助手 = 开新会话**：修复「切换助手后上一段会话记录残留」——重置逻辑不再依赖是否已绑定电脑端会话，且每次开新会话都换一份独立的历史存储，旧记录不会合并回来。
- **会话列表同步**：手机删除/重命名会话、电脑端自身增删改会话后，两边列表都会立即刷新。
- **新会话自动命名**：不再把所有手机会话都写成同一个名字，按首条消息生成，重名自动加序号。
- **桌面端独立运行**：绿色版与官方版各自使用独立数据目录与单实例锁，点开绿色版不会再唤起官方版。
- 修复电脑端 1.7.23 绿色版启动报 `Cannot find module '@peculiar/utils'`（打包时补齐漏掉的传递依赖）。

### v1.7.23

- **安全修复**：中继收到畸形消息不再整进程退出；文件只能由上传者下载。
- 聊天里的外部图片不再自动联网，避免被用来追踪 IP。
- 启动配置异常时不再白屏。
- 桌面中继合并上游远程网关和会话读取接口。

### v1.7.17

- **「会话 ↔ 助手」绑定修复**：换助手 = 开新会话；助手随会话存取，重启不丢。
- 新增会话绑定条（显示「会话 ｜ 助手」），会话列表卡片化、间隔更清楚。

### v1.7.16

- 修复「复用手机会话时用户消息被丢弃」「指定会话派发失败不回执且串窗」等 10 项缺陷。
- 修复 CI 写入上游提交号失效的问题。

### v1.7.15

- 安全加固：Skill 目录穿越、助手描述存储型 XSS、APK 下载校验 sha256 等。

### v1.7.13

- **顶部胶囊「设备 → 会话」两级选择**：先选电脑设备，再选该设备上的会话；切换后底部助手/模型/思考跟随该会话的助手。
- **修复正文开头出现 `<thinking></thinking>` 代码**：手机端渲染前剥掉残留思考标记，桌面中继同步处理。
- **token 挪到操作图标右侧**：「输入 x · 输出 y」改到复制/重试/删除右侧。
- **修复选项提交后回看仍显示「未选择」**：提交结果按 `toolCallId` 兜底查找并落盘，重启 / 消息重建后不再丢失。

### v1.7.12

- Markdown 表格列宽自适应。
- 修复「电脑端正在处理」重复显示两个时间。
- `ask_user_choice` 多题面板重写（一题一屏 + 圆点翻页 + 提交）。
- token 与操作按钮同一行。
- 电脑端回复流式逐字显示。

## 说明

- 本项目面向 [Komorebi-yaodong/anywheredesktop](https://github.com/Komorebi-yaodong/anywheredesktop) 做互通扩展。
- 桌面端主项目为 AGPL-3.0，本互通套件请遵循相同协议使用。

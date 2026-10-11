# Anywhere Mobile

**Anywhere Desktop 的 Android 伴侣应用** —— 通过**公网中继服务器**实现手机与电脑的双向互通：

- 💬 **双向对话**：手机上给电脑端 Anywhere Desktop 发消息，接收 AI 回复（流式滚动显示，支持思维链过程与工具调用展示）
- 🗂 **多会话并行与历史拉取**：手机端直接打开/管理电脑端会话，自动拉取历史消息，多会话后台并行互不干扰
- 🧩 **全量能力对齐**：手机端可直接切换电脑端的快捷助手、模型、思考预算、MCP 工具、Skill 技能与上下文压缩
- 📁 **文件与通知**：手机 ↔ 电脑文件双向互传，电脑端定时任务完成后实时推送到手机
- 🛡️ **安全加固**：中继服务器多重鉴权隔离与防 DoS、Token Header 传输防日志泄露、桌面端严格 URL 协议白名单与上下文隔离

```
┌───────────────┐        ┌──────────────────────┐        ┌────────────────────────┐
│ Android App   │  WS/HTTP│   Relay Server       │WS/HTTP │ Anywhere Desktop       │
│ (Flutter)     │◄───────►│ (Node.js, 公网部署)  │◄──────►│ (Electron，自建 relay  │
│               │        │  聊天/文件/通知中转   │        │  版，绿色包发行)       │
└───────────────┘        └──────────────────────┘        └────────────────────────┘
```

---

## 目录结构

```
anywhere-mobile/
├── server/                 # 公网中继服务器 (Node.js + ws)
│   ├── src/                # index.js (入口), wsHub.js (路由), fileStore.js (文件暂存), auth.js (鉴权)
│   ├── Dockerfile          # 容器镜像 (node:20-alpine 非 root 运行)
│   ├── docker-compose.yml  # 本地/服务器构建运行
│   └── docker-compose.ghcr.yml # 直接拉取 CI 预构建镜像
├── app/                    # Flutter Android 应用源码
│   └── lib/                # 业务逻辑、UI 页面、协议与中继客户端
├── desktop-integration/    # 桌面端接入（对齐补丁与说明）
│   ├── anywhere-desktop-relay.patch  # 对桌面源码的完整自建补丁
│   └── BUILD_CUSTOM.md     # 从源码自建桌面版教程
├── docs/                   # 协议文档与 1Panel 部署指南
└── version.json            # 统一版本控制源
```

---

## 快速开始

### 1. 部署中继服务器

#### 方式 A：Docker 快速运行（推荐）

```bash
cd server
cp env.docker.example .env   # 修改 AUTH_TOKENS=你的用户名:你的Token (例如: alice:token_0123456789)
docker compose up -d --build
# 验证服务健康状态: curl http://<服务器IP>:8787/health
```

> **1Panel / Nginx 用户**：反向代理时建议配置域名并启用 HTTPS / `wss://`（TLS 加密），详细配置参见 [`docs/DEPLOY_DOCKER_1PANEL.md`](docs/DEPLOY_DOCKER_1PANEL.md)。

#### 方式 B：直接拉取预构建镜像

```bash
cd server
cp env.docker.example .env
docker compose -f docker-compose.ghcr.yml up -d
```
镜像地址：`ghcr.io/obscurro110/anywhere-relay:latest`（支持 amd64 / arm64 架构）。

---

### 2. 安装与配置

#### 手机端（Android App）
1. 在仓库 **Releases** 下载最新 `anywhere-mobile.apk` 安装；
2. 首次打开 App → **设置** 页面：
   - **中继地址**：`ws://你的服务器:8787/ws`（配置了 TLS 则为 `wss://你的域名/ws`）
   - **访问令牌**：填写与服务器 `.env` 中一致的 `Token`
   - **用户 ID / 本机名称**：填写对应的用户标识。

#### 电脑端（桌面绿色版）
1. 在仓库 **Releases** 下载 `anywhere-desktop-relay-win-x64.zip`；
2. 解压运行 `anywhere-desktop-relay.exe`，在 **设置 → 手机互通** 填入相同的 `serverUrl` 与 `token`；
3. 绿色版拥有独立数据目录（`user-data/`），可与官方版共存运行。

---

## CI / CD 自动化构建

仓库已配置 GitHub Actions 自动化工作流，提交推送即自动打包产物：

| 工作流 | 产物目标 | 说明 |
| :--- | :--- | :--- |
| **Build Android APK** | `anywhere-mobile.apk` | 编译 Flutter APK 并自动签名，发布至 Releases |
| **Build Desktop (Relay 绿色版)** | Windows x64 便携包 | 拉取上游桌面源码 + 应用补丁自动打包发布 |
| **Build & Push Relay Image** | Docker 镜像 | 构建多架构镜像自动推送至 GHCR |

---

## 最近主要更新

版本号统一以 [`version.json`](version.json) 为准：

- **v1.7.41（当前版本）**
  - **核心安全加固**：
    - 桌面端开启全局窗口上下文隔离（`contextIsolation: true`），加固特权通信通道；
    - 外部链接跳转实施严格协议白名单（`http/https/mailto`），杜绝本地文件与危险 URL 协议唤起隐患；
    - 中继服务器与双端文件传输支持请求头认证（`Authorization: Bearer` 优先），防止 Token 在反向代理访问日志中泄露；
    - 中继服务器增加单用户最大并发连接数保护（防 DoS 耗尽连接池）；
    - Android 端禁用应用数据无痕备份（`allowBackup="false"`）。
  - **Bug 与健壮性修复**：
    - 修复重命名本机弹窗控制器的内存泄漏；
    - 修复桌面数据库历史消息增量同步过程中的 JSON 解析异常容错。
- **v1.7.38 ~ v1.7.40**
  - 打开电脑端会话自动向电脑拉取并同步完整历史消息；
  - 优化系统提示词展示，不在聊天主窗口中误显为人格设定消息；
  - 多会话并行支持，后台窗口自动保活与闲置回收。

---

## 开源协议与说明

- 本项目基于 [Komorebi-yaodong/anywheredesktop](https://github.com/Komorebi-yaodong/anywheredesktop) 扩展双端互通功能；
- 遵循与上游项目相同的开源协议。

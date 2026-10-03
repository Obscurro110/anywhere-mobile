# 从源码构建「带互通」的自建版

官方安装版（`anywhere-desktop.exe`）的代码打包在 `resources/app.asar` 里，**每次自动更新都会覆盖**，
所以要在桌面端接入手机互通，推荐**从源码构建一份自己的版本**——它独立于官方更新，且以后同步官方改动很方便。

> 本指南基于 **anywheredesktop v1.2.6 / Electron 39 / pnpm**。

---

## ⚡ 最快方式：一键应用补丁

本目录附带 [`anywhere-desktop-relay.patch`](./anywhere-desktop-relay.patch)（相对官方源码的完整改动）：

```bash
git clone --depth 1 https://github.com/Komorebi-yaodong/anywheredesktop.git anywhere-desktop-src
cd anywhere-desktop-src
git apply /path/to/anywhere-desktop-relay.patch
pnpm install
pnpm run build
npx electron-builder --dir --publish never "-c.electronDist=node_modules/electron/dist"
```

补丁含以下文件改动：
`electron-builder.yml` · `main/index.js` · `main/relay/*` · `package.json` · `preload/main_preload.js` · `render/main/components/Setting.vue` · `scripts/apply-relay-patch.mjs`

> 补丁里把那 2 处 `main/index.js` 改动也包含了，所以**不需要**再跑 `apply-relay-patch.mjs`。

---

## 手动方式（了解改了什么）

### 1）新增中继模块

```
desktop-integration/relay-client.js  ->  main/relay/relay-client.js
desktop-integration/main-relay.js    ->  main/relay/index.js
```

### 2）`main/index.js` 加 2 行

- import 区（`import { startTaskScheduler } ...` 之后）：
  ```js
  // [anywhere-mobile] 手机互通中继桥
  import { startRelay } from './relay/index.js'
  ```
- `await openWindow('main')` 之后：
  ```js
  // [anywhere-mobile] 启动与手机 App 的中继连接
  startRelay({ getWindowByRef, listWindows, dispatchWindowEvent })
  ```

> 也可用幂等脚本：`node scripts/apply-relay-patch.mjs`

### 3）`package.json` 加依赖

```json
"ws": "^8.18.0",
```

### 4）`preload/main_preload.js` 暴露 IPC

在 `const api = { ... }` 里（例如 `clearAppUpdateCache` 之后）加：

```js
  // ===== [anywhere-mobile] 手机互通中继 =====
  getRelayConfig: () => electronAPI.ipcRenderer.invoke('relay:getConfig'),
  setRelayConfig: (input = {}) => electronAPI.ipcRenderer.invoke('relay:setConfig', input),
  getRelayStatus: () => electronAPI.ipcRenderer.invoke('relay:status'),
  sendRelayChat: (payload = {}) => electronAPI.ipcRenderer.invoke('relay:sendChat', payload),
  sendRelayNotification: (payload = {}) => electronAPI.ipcRenderer.invoke('relay:sendNotification', payload),
  sendRelayFile: (payload = {}) => electronAPI.ipcRenderer.invoke('relay:sendFile', payload),
```

### 5）`render/main/components/Setting.vue` 加「手机互通」设置卡片

四处改动：

1. `collapsedCards` 加 `relay: false`
2. `cardDefinitions` 加 `relay: { id: 'relay', titleKey: null, staticTitle: '手机互通' }`
3. 默认卡片列表（`settingsCards.value = [...]`）加 `cardDefinitions.relay`
4. 脚本区加状态与函数（`relayForm` / `relayStatus` / `loadRelayConfig` / `refreshRelayStatus` / `saveRelayConfig`），并：
   - `onMounted` 里调用 `loadRelayConfig()`
   - `onActivated` 里调用 `refreshRelayStatus()`
   - `toggleCard` 里展开 `relay` 时 `refreshRelayStatus()`
5. 模板里在 webdav 卡片之后加 `<div v-if="element.id === 'relay'" class="card-body"> … </div>`

> 详细 diff 见 `anywhere-desktop-relay.patch`。
> 之后可在 **设置 → 手机互通** 里直接填：中继服务器地址 / Token / 用户ID / 设备名称，并看到连接状态。

---

## 与官方版并存（改应用名）

默认自建版与官方版**共用同一个应用标识**，Electron 单实例锁会导致**两个不能同时运行**。
若想让自建版与官方版**同时运行**（不覆盖、不卸载官方版），改应用名即可：

`package.json`：
```json
"name": "anywhere-desktop-relay",
```

`electron-builder.yml`：
```yaml
appId: com.komorebi.anywhere.desktop.relay
productName: AI Anywhere Desktop (Relay)
win:
  executableName: anywhere-desktop-relay
```

这样它的 userData 会变成 `%APPDATA%\anywhere-desktop-relay`（独立于官方），
单实例锁也不同 → **两者可并存**。

> 想让设置延续：把 `%APPDATA%\anywhere-desktop\anywhere-desktop.db.json`
> 复制到 `%APPDATA%\anywhere-desktop-relay\` 即可（数据库文件名是硬编码的）。

---

## 打包

### 免安装版

```bash
npx electron-builder --dir --publish never "-c.electronDist=node_modules/electron/dist"
```

产物：`dist/win-unpacked/anywhere-desktop.exe`（并存版为 `anywhere-desktop-relay.exe`），可直接运行。

> **关键技巧**：`-c.electronDist=node_modules/electron/dist` 让 electron-builder
> **复用本地已下载的 Electron**，避免它再下载（国内网络常报
> `access ... forbidden by its access permissions`）。

### 安装包版（NSIS setup.exe）

```bash
npx electron-builder --win nsis --publish never "-c.electronDist=node_modules/electron/dist"
```

---

## 配置连接

### 方式 A：设置界面（推荐）

打开 **设置 → 手机互通**，填：
- 中继服务器地址：`wss://你的中继域名/ws`
- Token：你的中继令牌
- 用户 ID：手机与电脑填**相同**
- 设备名称：显示在手机上的电脑名

点「保存」，会自动重连；上方会显示「在线 / 离线」和本机 ID。

### 方式 B：配置文件

`%APPDATA%\<应用名>\relay.json`：

```json
{
  "serverUrl": "wss://你的中继域名/ws",
  "token": "你的中继令牌",
  "userId": "default-user",
  "deviceName": "My PC"
}
```

也可用环境变量：`ANYWHERE_RELAY_URL` / `ANYWHERE_RELAY_TOKEN` / `ANYWHERE_RELAY_USER_ID` / `ANYWHERE_RELAY_DEVICE_NAME`。

---

## 怎样确认「电脑已连上中继」

1. **设置界面**：设置 → 手机互通 → 显示 **在线** + 本机 ID（`desktop-xxxx`）
2. **控制台日志**：启动后出现 `[relay] connected as desktop-xxxxxxxx`
3. **手机端**：手机 App「设备」页能看到这台电脑的名字
4. **服务器端**：中继 `/health` 正常，服务器日志显示该设备已连接
5. **在线设备**：手机与电脑都连上后，设置卡片里「在线设备」会列出对方

---

## 以后从源码更新

```bash
git pull                              # 拉官方最新代码
git apply /path/to/anywhere-desktop-relay.patch   # 或手工/脚本重注入
pnpm install
pnpm run build
npx electron-builder --dir --publish never "-c.electronDist=node_modules/electron/dist"
```

> 若 `git apply` 因冲突失败，可用 `node scripts/apply-relay-patch.mjs` 只重注入
> `main/index.js` 那 2 行（其余是新增文件，`git pull` 不会删）。

---

## 常见问题

| 现象 | 处理 |
| --- | --- |
| electron-builder 下载 Electron 失败（`access forbidden`） | 加 `-c.electronDist=node_modules/electron/dist` |
| `pnpm install` 卡在 electron postinstall | 等它下载/解压；或预先配好 Electron 缓存 |
| 构建报 `Expected ";" but found ")"` | 检查 `main/relay/index.js` 的 IPC handler 括号是否成对 |
| 启动后无 `[relay] connected` | 检查 relay.json / 设置里的地址与 token |
| 手机看不到电脑 | 两端 `userId` / `token` / 服务器必须一致 |
| 两个版本不能同时开 | 见「与官方版并存」（改应用名） |

---

## 改动清单（相对官方）

| 文件 | 类型 |
| --- | --- |
| `main/relay/relay-client.js` | 新增 |
| `main/relay/index.js` | 新增 |
| `main/index.js` | 改 2 行 |
| `package.json` | 加 `ws` 依赖（并存版还改 `name`） |
| `preload/main_preload.js` | 加 6 个 relay 方法 |
| `render/main/components/Setting.vue` | 新增「手机互通」设置卡片 |
| `electron-builder.yml` | 并存版改 appId/productName/executableName |
| `scripts/apply-relay-patch.mjs` | 新增（可选） |

# 从源码构建「带互通」的自建版

官方安装版（`anywhere-desktop.exe`）的代码打包在 `resources/app.asar` 里，**每次自动更新都会覆盖**，
所以要在桌面端接入手机互通，推荐**从源码构建一份自己的版本**——它独立于官方更新，且以后同步官方改动很方便。

> 本指南基于 **anywheredesktop v1.2.6 / Electron 39 / pnpm**。

---

## 一、克隆源码

```bash
git clone --depth 1 https://github.com/Komorebi-yaodong/anywheredesktop.git anywhere-desktop-src
cd anywhere-desktop-src
```

---

## 二、注入互通改动（只需 3 处）

### 1）新增中继模块

把本仓库 [`desktop-integration/`](./) 的两个文件复制进去：

```
desktop-integration/relay-client.js  ->  main/relay/relay-client.js
desktop-integration/main-relay.js    ->  main/relay/index.js
```

（新建目录 `main/relay/`）

### 2）给 `main/index.js` 加 2 行

- 顶部 import 区（`import { startTaskScheduler } ...` 之后）加：
  ```js
  // [anywhere-mobile] 手机互通中继桥
  import { startRelay } from './relay/index.js'
  ```
- 在 `app.whenReady().then(async () => { ... })` 内的 `await openWindow('main')` 之后加：
  ```js
  // [anywhere-mobile] 启动与手机 App 的中继连接
  startRelay({ getWindowByRef, listWindows, dispatchWindowEvent })
  ```

> `getWindowByRef` / `listWindows` / `dispatchWindowEvent` 在 `main/index.js` 顶部**已 import**，直接传即可。

不想手动改？运行幂等脚本自动注入：

```bash
node scripts/apply-relay-patch.mjs
```

（把本仓库的 `apply-relay-patch.mjs` 放到源码的 `scripts/` 下）

### 3）给 `package.json` 加依赖

`relay-client.js` 依赖 `ws`，在 `dependencies` 里加：

```json
"ws": "^8.18.0",
```

---

## 三、安装依赖并构建

```bash
pnpm install
pnpm run build
```

> ⚠️ `pnpm install` 会下载 Electron（约 100MB+），首次较慢。

---

## 四、打包

### 免安装版（推荐先跑这个）

```bash
npx electron-builder --dir --publish never "-c.electronDist=node_modules/electron/dist"
```

产物：`dist/win-unpacked/anywhere-desktop.exe`，可直接运行。

> **关键技巧**：`-c.electronDist=node_modules/electron/dist` 让 electron-builder
> **复用本地已下载的 Electron**，避免它再去下载（国内网络经常下载失败，报
> `access ... forbidden by its access permissions`）。

### 安装包版（NSIS setup.exe）

```bash
npx electron-builder --win nsis --publish never "-c.electronDist=node_modules/electron/dist"
```

产物：`dist/anywhere-desktop-<version>-setup.exe`（可安装到自定义目录）

---

## 五、配置连接

在应用 userData 目录放 `relay.json`（Windows：`%APPDATA%\anywhere-desktop\relay.json`）：

```json
{
  "serverUrl": "wss://你的中继域名/ws",
  "token": "你的中继令牌",
  "userId": "default-user",
  "deviceName": "My PC"
}
```

> 手机端 App 要填**相同**的 `userId` + `token` + 同一服务器。
> 也可用环境变量：`ANYWHERE_RELAY_URL` / `ANYWHERE_RELAY_TOKEN` / `ANYWHERE_RELAY_USER_ID` / `ANYWHERE_RELAY_DEVICE_NAME`。

启动后控制台应出现：`[relay] connected as desktop-xxxxxxxx`

---

## 六、以后从源码更新（重点）

```bash
git pull                              # 拉官方最新代码
node scripts/apply-relay-patch.mjs    # 重新注入那 2 行（幂等，已注入则跳过）
pnpm install                          # 依赖有变化时
pnpm run build
npx electron-builder --dir --publish never "-c.electronDist=node_modules/electron/dist"
```

- `main/relay/` 是**新增文件**，`git pull` 不会删
- 只有 `main/index.js` 的 2 行可能冲突 → 由脚本自动重应用

---

## 七、常见问题

| 现象 | 处理 |
| --- | --- |
| `electron-builder` 下载 Electron 失败（`access forbidden`） | 加 `-c.electronDist=node_modules/electron/dist` |
| `pnpm install` 卡在 electron postinstall | 等它下载/解压；或预先配好 Electron 缓存 |
| 构建报 `Expected ";" but found ")"` | 检查 `main/relay/index.js` 的 IPC handler 括号是否成对 |
| 启动后无 `[relay] connected` | 检查 `relay.json` 路径/内容，或环境变量 |
| 手机看不到电脑 | 两端 `userId` 必须一致 |

---

## 八、改动清单（相对官方）

| 文件 | 类型 |
| --- | --- |
| `main/relay/relay-client.js` | 新增 |
| `main/relay/index.js` | 新增 |
| `main/index.js` | 改 2 行（标 `[anywhere-mobile]`） |
| `package.json` | dependencies 加 `ws` |
| `scripts/apply-relay-patch.mjs` | 新增（可选） |

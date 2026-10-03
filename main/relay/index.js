/**
 * Anywhere Desktop ⇆ Relay bridge (main process / Electron)
 * =========================================================
 * Drop this file into the desktop project as:  main/relay/index.js
 * and copy relay-client.js next to it as:      main/relay/relay-client.js
 *
 * Then wire it in `main/index.js`:
 *
 *   import { startRelay } from './relay/index.js'
 *   ...
 *   app.whenReady().then(async () => {
 *     ...
 *     await openWindow('main')
 *     startRelay({
 *       getWindowByRef, listWindows, dispatchWindowEvent,
 *       openWindow, dataApi
 *     })
 *   })
 *
 * What it does
 * ------------
 *  - Connects the desktop to the public relay server (same server as the phone).
 *  - **Phone chat → AI**: an incoming phone message is routed into a dedicated
 *    chat window using the built-in `multiline-text` payload, which the window
 *    appends to the conversation and auto-sends into the AI pipeline
 *    (`handleAppendMessageEvent` → `askAI(true)`). No renderer hook needed.
 *  - **AI reply → phone**: the chat window sends the finished assistant message
 *    back through `relay:sendChat`.
 *  - **Capabilities**: the phone can ask for the list of models / MCP servers /
 *    skills so its UI can offer the same pickers as the desktop.
 *  - **Run options**: the phone can override model / reasoning effort / MCP /
 *    skills per message.
 *  - Other incoming events (notification / file) are still broadcast to windows
 *    as `relay:incoming` for UI display.
 *
 * IPC handlers exposed to the renderer:
 *   relay:status            -> { ok, connected, deviceId, peers }
 *   relay:sendChat          -> { ok, delivered }         (assistant -> phone)
 *   relay:sendNotification  -> { ok, delivered }
 *   relay:sendFile          -> { ok, file }
 *   relay:getConfig         -> { ok, config }
 *   relay:setConfig         -> { ok }                    (userData/relay.json)
 *   relay:capabilities      -> { ok, models, mcp, skills, ... }
 *
 * Config resolution order (first hit wins):
 *   1. userData/relay.json   { "serverUrl", "token", "userId", "deviceName" }
 *   2. env: ANYWHERE_RELAY_URL / ANYWHERE_RELAY_TOKEN / ANYWHERE_RELAY_USER_ID
 *          / ANYWHERE_RELAY_DEVICE_NAME
 */
import { app, ipcMain } from 'electron'
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { RelayClient } from './relay-client.js'
import { RELAY_VERSION, RELAY_VERSION_CODE } from './version.js'

let relay = null
let ctx = null // { getWindowByRef, listWindows, dispatchWindowEvent, openWindow, dataApi }

/** 专用于「手机对话」的聊天窗口 id（避免和其他聊天窗口串台） */
let phoneWindowId = null
/** 用于承载手机对话的 prompt 配置键（默认 'AI'） */
let phonePromptKey = 'AI'

const CONFIG_PATH = () => join(app.getPath('userData'), 'relay.json')

function readConfig() {
  // 1) userData/relay.json
  try {
    const p = CONFIG_PATH()
    if (existsSync(p)) {
      // strip UTF-8 BOM (PowerShell's Set-Content -Encoding UTF8 writes one,
      // and JSON.parse chokes on it)
      const raw = readFileSync(p, 'utf8').replace(/^\uFEFF/, '')
      const cfg = JSON.parse(raw)
      if (cfg?.serverUrl && cfg?.token) {
        if (typeof cfg.promptKey === 'string' && cfg.promptKey.trim()) {
          phonePromptKey = cfg.promptKey.trim()
        }
        return cfg
      }
    }
  } catch (err) {
    console.warn('[relay] failed to read relay.json:', err?.message || err)
  }
  // 2) env
  if (process.env.ANYWHERE_RELAY_URL && process.env.ANYWHERE_RELAY_TOKEN) {
    return {
      serverUrl: process.env.ANYWHERE_RELAY_URL,
      token: process.env.ANYWHERE_RELAY_TOKEN,
      userId: process.env.ANYWHERE_RELAY_USER_ID || 'default-user',
      deviceName: process.env.ANYWHERE_RELAY_DEVICE_NAME || 'Anywhere Desktop'
    }
  }
  return null
}

function emitToWindows(event, payload) {
  if (!ctx?.dispatchWindowEvent) return
  try {
    ctx.dispatchWindowEvent(
      { event, payload, target: 'broadcast' },
      { getWindowByRef: ctx.getWindowByRef, listWindows: ctx.listWindows }
    )
  } catch (err) {
    console.warn('[relay] dispatchWindowEvent failed:', err?.message || err)
  }
}

// ---------------------------------------------------------------------------
// 能力清单（模型 / MCP / Skill），供手机端渲染选择器
// ---------------------------------------------------------------------------
async function readCapabilities() {
  const result = {
    models: [],
    mcp: [],
    skills: [],
    promptKey: phonePromptKey,
    reasoningEffortOptions: [],
    desktopVersion: RELAY_VERSION,
    desktopVersionCode: RELAY_VERSION_CODE,
    upstreamVersion: app.getVersion()
  }
  try {
    if (!ctx?.dataApi?.getConfig) return result
    const res = await ctx.dataApi.getConfig()
    const config = res?.config && typeof res.config === 'object' ? res.config : null
    if (!config) return result

    // ---- 模型：providerOrder → provider.modelList ----
    const order = Array.isArray(config.providerOrder) ? config.providerOrder : Object.keys(config.providers || {})
    for (const pid of order) {
      const provider = config.providers?.[pid]
      if (!provider || provider.enable === false) continue
      const list = Array.isArray(provider.modelList) ? provider.modelList : []
      for (const m of list) {
        const name = typeof m === 'string' ? m : (m?.name || m?.id || '')
        if (!name) continue
        result.models.push({
          value: `${pid}|${name}`,
          label: typeof m === 'object' && m?.label ? m.label : name,
          provider: provider.name || pid
        })
      }
    }

    // ---- MCP：config.mcpServers ----
    const servers = config.mcpServers && typeof config.mcpServers === 'object' ? config.mcpServers : {}
    for (const [id, s] of Object.entries(servers)) {
      result.mcp.push({
        id,
        label: (s && (s.name || s.label)) || id,
        enabled: s?.enable !== false
      })
    }

    // ---- Skill：skillPath 下的目录/文件 ----
    const skillPath = typeof config.skillPath === 'string' ? config.skillPath : ''
    if (skillPath && existsSync(skillPath)) {
      try {
        for (const entry of readdirSync(skillPath)) {
          const full = join(skillPath, entry)
          let isDir = false
          try { isDir = statSync(full).isDirectory() } catch {}
          if (isDir) {
            result.skills.push({ id: entry, label: entry })
          } else if (/\.(md|json|ya?ml|txt)$/i.test(entry)) {
            result.skills.push({ id: entry.replace(/\.[^.]+$/, ''), label: entry.replace(/\.[^.]+$/, '') })
          }
        }
      } catch (err) {
        console.warn('[relay] list skills failed:', err?.message || err)
      }
    }

    // ---- 当前生效的默认值（让手机端能显示"当前"）----
    const promptCfg = config.prompts?.[phonePromptKey] || config.prompts?.['AI'] || {}
    result.current = {
      model: promptCfg.model || '',
      reasoningEffort: promptCfg.reasoning_effort || 'default',
      mcp: Array.isArray(promptCfg.defaultMcpServers) ? promptCfg.defaultMcpServers : [],
      skills: Array.isArray(promptCfg.defaultSkills) ? promptCfg.defaultSkills : []
    }
    result.reasoningEffortOptions = ['default', 'none', 'low', 'medium', 'high', 'xhigh', 'max']
  } catch (err) {
    console.warn('[relay] readCapabilities failed:', err?.message || err)
  }
  return result
}

// ---------------------------------------------------------------------------
// 手机消息 → 聊天窗口 → AI
// ---------------------------------------------------------------------------
function isWindowAlive(id) {
  if (!id || !ctx?.getWindowByRef) return false
  try {
    const w = ctx.getWindowByRef(id)
    return !!(w && typeof w.isDestroyed === 'function' && !w.isDestroyed())
  } catch {
    return false
  }
}

async function routePhoneChat(msg) {
  const role = String(msg?.role ?? 'user').toLowerCase()

  // 手机请求能力清单（模型 / MCP / Skill）
  if (role === 'capabilities-request') {
    try {
      const caps = await readCapabilities()
      relay?.sendChat(JSON.stringify({ __relayCapabilities: caps }), {
        role: 'capabilities',
        to: msg?.from || '*'
      })
    } catch (err) {
      console.warn('[relay] capabilities reply failed:', err?.message || err)
    }
    return
  }

  // 只处理普通用户消息
  if (role !== 'user') return

  const text = String(msg?.text ?? '').trim()
  if (!text) return
  const relayTo = msg?.from || '*'
  const opts = msg?.options && typeof msg.options === 'object' ? msg.options : null

  const relayFields = {
    relayTo,
    ...(opts ? { __relayOptions: opts } : {})
  }

  // 1) 已有专门的手机窗口 → 定向派发一条窗口事件
  //    （不设 triggerMode:'shortcut'，所以窗口会直接追加并自动 askAI(true)）
  if (isWindowAlive(phoneWindowId)) {
    try {
      ctx.dispatchWindowEvent(
        {
          event: 'relay:incoming',
          payload: { type: 'multiline-text', payload: text, ...relayFields },
          target: phoneWindowId
        },
        { getWindowByRef: ctx.getWindowByRef, listWindows: ctx.listWindows }
      )
      return
    } catch (err) {
      console.warn('[relay] dispatch to phone window failed:', err?.message || err)
    }
  }

  // 2) 否则开一个专用的「手机」会话窗口
  //    isDirectSend_normal 默认为 true → multiline-text 会直接追加并跑 AI
  if (typeof ctx?.openWindow !== 'function') {
    console.warn('[relay] openWindow unavailable; cannot route phone chat to AI')
    return
  }
  try {
    const res = await ctx.openWindow('window', {
      code: phonePromptKey,
      type: 'multiline-text',
      payload: text,
      conversationTitle: '手机',
      ...relayFields
    })
    if (res?.ok && res.id) {
      phoneWindowId = res.id
      console.log('[relay] opened phone chat window:', phoneWindowId)
    } else {
      console.warn('[relay] openWindow returned:', res)
    }
  } catch (err) {
    console.warn('[relay] open phone window failed:', err?.message || err)
  }
}

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------
let ipcRegistered = false

function registerIpc() {
  if (ipcRegistered) return
  ipcRegistered = true

  const guard = (fn) => async (...args) => {
    try {
      return await fn(...args)
    } catch (err) {
      return { ok: false, error: { message: String(err?.message || err) } }
    }
  }

  ipcMain.handle('relay:status', guard(async () => ({
    ok: true,
    connected: !!relay?.connected,
    deviceId: relay?.deviceId || null,
    peers: relay?.peers || [],
    version: RELAY_VERSION,
    versionCode: RELAY_VERSION_CODE,
    upstreamVersion: app.getVersion()
  })))

  ipcMain.handle('relay:version', guard(async () => ({
    ok: true,
    version: RELAY_VERSION,
    versionCode: RELAY_VERSION_CODE,
    upstreamVersion: app.getVersion(),
    appVersion: app.getVersion()
  })))

  ipcMain.handle('relay:getConfig', guard(async () => {
    // Return the full config (this is the user's own desktop app; the token
    // already lives in plaintext under userData/relay.json).
    return { ok: true, config: readConfig() || null, promptKey: phonePromptKey }
  }))

  ipcMain.handle('relay:setConfig', guard(async (_e, input = {}) => {
    const cfg = { ...readConfig(), ...input }
    if (!cfg.serverUrl || !cfg.token) {
      return { ok: false, error: { message: 'serverUrl and token are required' } }
    }
    if (typeof cfg.promptKey === 'string' && cfg.promptKey.trim()) {
      phonePromptKey = cfg.promptKey.trim()
    }
    writeFileSync(CONFIG_PATH(), JSON.stringify(cfg, null, 2), 'utf8')
    // reconnect with new config
    startRelay(ctx, cfg, { force: true })
    return { ok: true, config: cfg }
  }))

  ipcMain.handle('relay:capabilities', guard(async () => ({
    ok: true,
    ...(await readCapabilities())
  })))

  ipcMain.handle('relay:sendChat', guard(async (_e, { text, to } = {}) => {
    if (!relay?.connected) return { ok: false, error: { message: 'relay_not_connected' } }
    const delivered = relay.sendChat(text, { role: 'assistant', to: to || '*' })
    return { ok: true, delivered }
  }))

  ipcMain.handle('relay:sendNotification', guard(async (_e, { title, body, to } = {}) => {
    if (!relay?.connected) return { ok: false, error: { message: 'relay_not_connected' } }
    const delivered = relay.sendNotification(title, body, { to: to || '*' })
    return { ok: true, delivered }
  }))

  ipcMain.handle('relay:sendFile', guard(async (_e, { path: filePath, to } = {}) => {
    if (!relay?.connected) return { ok: false, error: { message: 'relay_not_connected' } }
    const file = await relay.sendFile(filePath, { to: to || '*' })
    return { ok: true, file }
  }))

  // 允许渲染进程主动重开手机会话窗口
  ipcMain.handle('relay:resetPhoneWindow', guard(async () => {
    phoneWindowId = null
    return { ok: true }
  }))
}

/**
 * Start (or restart) the relay connection.
 * @param {object} context { getWindowByRef, listWindows, dispatchWindowEvent, openWindow, dataApi }
 * @param {object} [overrideConfig] optional explicit config (used by setConfig)
 */
export function startRelay(context, overrideConfig = null, { force = false } = {}) {
  ctx = context || ctx

  // ALWAYS register IPC handlers first, even when there is no config yet.
  // Otherwise the settings UI can never save a config (chicken-and-egg).
  registerIpc()

  const cfg = overrideConfig || readConfig()

  if (!cfg?.serverUrl || !cfg?.token) {
    console.log('[relay] no config found; relay disabled. Set userData/relay.json or env vars.')
    return null
  }

  if (relay && !force) return relay
  if (relay && force) {
    try { relay.disconnect() } catch {}
    relay = null
    phoneWindowId = null
  }

  relay = new RelayClient({
    serverUrl: cfg.serverUrl,
    token: cfg.token,
    userId: cfg.userId || 'default-user',
    deviceName: cfg.deviceName || 'Anywhere Desktop'
  })

  relay.on('connected', () => {
    console.log('[relay] connected as', relay.deviceId)
    emitToWindows('relay:status', { connected: true, deviceId: relay.deviceId })
  })
  relay.on('disconnected', () => {
    console.log('[relay] disconnected')
    emitToWindows('relay:status', { connected: false })
  })
  relay.on('presence', (peers) => {
    emitToWindows('relay:presence', { peers })
  })

  // ---- phone -> desktop ----
  // 聊天：路由进 AI 管线（开窗口 / 定向派发）
  relay.on('chat', (msg) => {
    routePhoneChat(msg).catch((err) => {
      console.warn('[relay] routePhoneChat failed:', err?.message || err)
    })
  })
  // 通知 / 文件：只广播给界面展示
  relay.on('notification', (n) => emitToWindows('relay:incoming', { kind: 'notification', ...n }))
  relay.on('file', (file) => emitToWindows('relay:incoming', { kind: 'file', file }))

  relay.connect()
  registerIpc()
  return relay
}

/** Access the live client (e.g. from task_scheduler). */
export function getRelay() {
  return relay
}

/**
 * Push a notification to the phone(s). Call this when a scheduled task
 * finishes, e.g. in main/core/task_scheduler.js after a run completes.
 */
export function notifyFromDesktop(title, body, { to = '*' } = {}) {
  if (!relay?.connected) return false
  return relay.sendNotification(title, body, { to })
}

/** Send an assistant message from the desktop to the phone(s). */
export function replyToPhone(text, { to = '*' } = {}) {
  if (!relay?.connected) return false
  return relay.sendChat(text, { role: 'assistant', to })
}

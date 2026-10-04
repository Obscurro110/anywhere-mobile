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
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync, appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { RelayClient } from './relay-client.js'
import { RELAY_VERSION, RELAY_VERSION_CODE } from './version.js'
import { listLocalConversations, openConversation } from '../core/conversationStore.js'
import {
  renameConversation as storeRenameConversation,
  deleteConversation as storeDeleteConversation,
  getConversationRequestMessages as storeGetMessages,
  deleteMessages as storeDeleteMessages
} from '../core/conversationStore.js'
import { readLocalProjects } from '../core/projects.js'
import { listSkills, getSkillDetails, deleteSkill } from '../core/skill.js'
import { getModelCompactConfig, updateModelCompactConfig } from '../core/compact.js'

// ---------------------------------------------------------------------------
// 日志落盘
// ---------------------------------------------------------------------------
// 打包成 exe 后双击运行没有控制台，排障时看不到 console 输出。
// 这里把手机互通相关的日志同时写进 userData/relay.log，随时可以看。
let logFilePath = null

function relayFileLog(tag, ...args) {
  try {
    if (!logFilePath) logFilePath = join(app.getPath('userData'), 'relay.log')
    const line = `${new Date().toISOString()} [${tag}] ${args
      .map((a) => {
        if (a instanceof Error) return `${a.message}\n${a.stack || ''}`
        if (typeof a === 'string') return a
        try { return JSON.stringify(a) } catch { return String(a) }
      })
      .join(' ')}\n`
    appendFileSync(logFilePath, line, 'utf8')
  } catch {
    // 写日志失败不能影响主流程
  }
}

/** 主进程自己的日志 */
const rlog = (...args) => {
  console.log(...args)
  relayFileLog('main', ...args)
}
const rwarn = (...args) => {
  console.warn(...args)
  relayFileLog('main:WARN', ...args)
}

let relay = null
let ctx = null // { getWindowByRef, listWindows, dispatchWindowEvent, openWindow, dataApi }

/** 专用于「手机对话」的聊天窗口 id（避免和其他聊天窗口串台） */
let phoneWindowId = null
/** 用于承载手机对话的 prompt 配置键（默认 'AI'） */
let phonePromptKey = 'AI'
/**
 * 当前手机窗口承载的「内容标识」。
 *   'phone'           → 手机自己发起的临时会话
 *   'conv:<id>'       → 打开的某个电脑端已有会话
 * 用于判断复用窗口还是重开。
 */
let phoneWindowKey = 'phone'

// 为「某个电脑端会话」开过的窗口：conversationId -> windowId。
//
// 为什么要单独一张表：phoneWindowId 只有一个槽位，既可能指向手机聊天窗口，
// 又可能被「打开某个会话」覆盖掉 —— 结果手机想让电脑端操作 A 会话的消息时，
// 窗口可能已经被 B 会话占用了，只能报「会话没打开」。
// 有了这张表，每个会话各有各的窗口引用，互不干扰。
const convWindows = new Map()


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
    rwarn('[relay] failed to read relay.json:', err?.message || err)
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
    rwarn('[relay] dispatchWindowEvent failed:', err?.message || err)
  }
}

// ---------------------------------------------------------------------------
// 能力清单（模型 / MCP / Skill / 助手 / 定时任务），供手机端渲染
// ---------------------------------------------------------------------------

/** 把任务的时间配置拼成一句人话 */
function describeTaskSchedule(task = {}) {
  const t = (v) => (typeof v === 'string' && v ? v : '')
  switch (task.triggerType) {
    case 'daily':
      return `每天 ${t(task.dailyTime) || '--:--'}`
    case 'weekly': {
      const names = ['日', '一', '二', '三', '四', '五', '六']
      const days = Array.isArray(task.weeklyDays)
        ? task.weeklyDays.map((d) => names[Number(d)] ?? d).join('、')
        : ''
      return `每周${days || '?'} ${t(task.weeklyTime) || '--:--'}`
    }
    case 'monthly': {
      const days = Array.isArray(task.monthlyDays) ? task.monthlyDays.join('、') : ''
      return `每月 ${days || '?'} 日 ${t(task.monthlyTime) || '--:--'}`
    }
    case 'interval': {
      const mins = Number(task.intervalMinutes) || 0
      const ranges = Array.isArray(task.intervalTimeRanges) ? task.intervalTimeRanges.join(' / ') : ''
      return `每 ${mins || '?'} 分钟${ranges ? `（${ranges}）` : ''}`
    }
    case 'single':
      return `单次 ${t(task.singleDate) || '?'} ${t(task.singleTime) || '--:--'}`
    default:
      return t(task.triggerType) || '未设置'
  }
}

async function readCapabilities() {
  const result = {
    models: [],
    providers: [],
    mcp: [],
    skills: [],
    prompts: [],
    tasks: [],
    promptKey: phonePromptKey,
    reasoningEffortOptions: [],
  compact: null,
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

    // ---- 服务商明细（手机「模型」编辑页回填用）----
    // 注意：绝不带 api_key，只带 hasApiKey 布尔。
    const provOrder = Array.isArray(config.providerOrder)
      ? config.providerOrder
      : Object.keys(config.providers || {})
    for (const pid of provOrder) {
      const provider = config.providers?.[pid]
      if (!provider || typeof provider !== 'object') continue
      result.providers.push({
        id: String(pid),
        name: (provider.name || pid).toString(),
        url: (provider.url || '').toString(),
        apiType: (provider.apiType || 'chat_completions').toString(),
        enable: provider.enable !== false,
        retryCount: Number.isFinite(provider.retryCount) ? provider.retryCount : 3,
        headers: provider.headers && typeof provider.headers === 'object' ? { ...provider.headers } : {},
        modelList: Array.isArray(provider.modelList) ? [...provider.modelList] : [],
        hasApiKey: typeof provider.api_key === 'string' && provider.api_key.length > 0,
        folderId: (provider.folderId || '').toString()
      })
    }

    // ---- MCP：config.mcpServers ----
    // 带上 description / 连接方式，手机端才能解释「这个 MCP 是干什么的」
    const servers = config.mcpServers && typeof config.mcpServers === 'object' ? config.mcpServers : {}
    for (const [id, s] of Object.entries(servers)) {
      if (!s || typeof s !== 'object') continue
      const type = s.type || (s.url ? 'sse' : 'stdio')
      result.mcp.push({
        id,
        label: s.name || s.label || id,
        enabled: s.enable !== false && s.isActive !== false,
        description: (s.description || s.desc || '').toString(),
        type: String(type),
        // 连接信息（详情页展示 + 编辑页回填）
        command: (s.command || '').toString(),
        url: (s.url || s.baseUrl || '').toString(),
        baseUrl: (s.baseUrl || s.url || '').toString(),
        args: Array.isArray(s.args) ? [...s.args] : [],
        argsCount: Array.isArray(s.args) ? s.args.length : 0,
        env: s.env && typeof s.env === 'object' ? { ...s.env } : {},
        headers: s.headers && typeof s.headers === 'object' ? { ...s.headers } : {},
        isActive: s.isActive !== false && s.enable !== false,
        isPersistent: s.isPersistent === true,
        timeoutSeconds: Number(s.timeoutSeconds) || 120,
        tags: Array.isArray(s.tags) ? [...s.tags] : [],
        auth: s.auth && typeof s.auth === 'object' ? { type: s.auth.type || 'none' } : { type: 'none' },
        toolCount: Array.isArray(s.tools) ? s.tools.length : 0,
        builtin: s.type === 'builtin'
      })
    }

    // ---- Skill：用电脑端自己的 listSkills（能拿到 description）----
    // 以前是自己 readdir 拼目录名，结果只有名字、没有介绍。
    const skillPath = typeof config.skillPath === 'string' ? config.skillPath : ''
    if (skillPath) {
      try {
        const skills = listSkills(skillPath)
        for (const sk of Array.isArray(skills) ? skills : []) {
          if (!sk?.id) continue
          // 带上正文与元数据，手机编辑页才能改
          let skDetails = null
          try { skDetails = getSkillDetails(skillPath, sk.id) } catch (_) { skDetails = null }
          const skMeta = (skDetails?.metadata && typeof skDetails.metadata === 'object') ? skDetails.metadata : {}
          result.skills.push({
            id: sk.id,
            label: sk.name || sk.id,
            description: (sk.description || '').toString(),
            userInvocable: sk.userInvocable !== false,
            disabled: sk.disabled === true,
            context: sk.context || 'normal',
            allowedTools: Array.isArray(sk.allowedTools) ? sk.allowedTools : [],
            instructions: skDetails?.ok ? String(skDetails.content || '') : '',
            argumentHint: (skMeta['argument-hint'] || '').toString(),
            agent: (skMeta.agent || '').toString(),
            model: (skMeta.model || '').toString()
          })
        }
      } catch (err) {
        rwarn('[relay] listSkills failed:', err?.message || err)
      }
    }

    // ---- 助手：config.prompts ----
    // 每个助手自带一套预设（模型 / 思考预算 / MCP / Skill），
    // 手机端选中助手时要一并同步过去，否则只是换了 promptKey，
    // 助手配好的 MCP、Skill 不会生效。
    const prompts = config.prompts && typeof config.prompts === 'object' ? config.prompts : {}
    for (const [key, p] of Object.entries(prompts)) {
      if (key === '__DEFAULT__') continue
      if (!p || typeof p !== 'object') continue
      result.prompts.push({
        key,
        label: (p.name || p.title) || key,
        icon: p.icon || '',
        model: p.model || '',
        type: p.type || 'over',
        // ---- 助手预设（会话建立时电脑端本来就会应用这些）----
        reasoningEffort: p.reasoning_effort || p.reasoningEffort || '',
        mcp: Array.isArray(p.defaultMcpServers) ? [...p.defaultMcpServers] : [],
        skills: Array.isArray(p.defaultSkills) ? [...p.defaultSkills] : [],
        // ---- 其余字段：手机编辑页回填用（与电脑端弹窗一致）----
        promptText: (p.prompt || '').toString(),
        enable: p.enable !== false,
        showMode: (p.showMode || 'window').toString(),
        matchRegex: (p.matchRegex || '').toString(),
        stream: p.stream !== false,
        isTemperature: p.isTemperature === true,
        temperature: typeof p.temperature === 'number' ? p.temperature : 0.7,
        isDirectSend_normal: p.isDirectSend_normal !== false,
        isDirectSend_file: p.isDirectSend_file === true,
        isDirectSend_image: p.isDirectSend_image !== false,
        ifTextNecessary: p.ifTextNecessary === true,
        voice: (p.voice || '').toString(),
        window_width: Number(p.window_width) || 540,
        window_height: Number(p.window_height) || 700,
        isAlwaysOnTop: p.isAlwaysOnTop !== false,
        autoCloseOnBlur: p.autoCloseOnBlur !== false,
        backgroundOpacity: typeof p.backgroundOpacity === 'number' ? p.backgroundOpacity : 0.6,
        backgroundBlur: Number(p.backgroundBlur) || 0,
        autoSaveChat: p.autoSaveChat === true
      })
    }

    // ---- 定时任务：config.tasks ----
    const tasks = config.tasks && typeof config.tasks === 'object' ? config.tasks : {}
    for (const [id, task] of Object.entries(tasks)) {
      if (!task || typeof task !== 'object') continue
      const applied = Array.isArray(task.appliedDevices) ? task.appliedDevices : []
      result.tasks.push({
        id,
        label: (task.name || task.title || task.description || id).toString().slice(0, 60),
        description: (task.description || '').toString(),
        enabled: applied.length > 0,
        triggerType: task.triggerType || '',
        schedule: describeTaskSchedule(task),
        promptKey: task.promptKey || '__DEFAULT__',
        modelRoute: task.modelRoute || 'general',
        lastRunTime: task.lastRunTime || '',
        // 下面这些是手机端「编辑任务」要回填的完整配置
        intervalMinutes: Number(task.intervalMinutes) || 60,
        intervalStartTime: task.intervalStartTime || '00:00',
        dailyTime: task.dailyTime || '12:00',
        weeklyDays: Array.isArray(task.weeklyDays) ? task.weeklyDays : [],
        weeklyTime: task.weeklyTime || '12:00',
        monthlyDays: Array.isArray(task.monthlyDays) ? task.monthlyDays : [],
        monthlyTime: task.monthlyTime || '12:00',
        singleDate: task.singleDate || '',
        singleTime: task.singleTime || '12:00',
        historyCount: Array.isArray(task.history) ? task.history.length : 0
      })
    }
    result.tasks.sort((a, b) => String(a.id).localeCompare(String(b.id)))

    // ---- 当前生效的默认值（让手机端能显示"当前"）----
    const promptCfg = config.prompts?.[phonePromptKey] || config.prompts?.['AI'] || {}
    result.current = {
      model: promptCfg.model || '',
      reasoningEffort: promptCfg.reasoning_effort || 'default',
      mcp: Array.isArray(promptCfg.defaultMcpServers) ? promptCfg.defaultMcpServers : [],
      skills: Array.isArray(promptCfg.defaultSkills) ? promptCfg.defaultSkills : []
    }
    result.reasoningEffortOptions = ['default', 'none', 'low', 'medium', 'high', 'xhigh', 'max']

    // ---- 会话压缩配置（按模型存）----
    // 手机端的「压缩」以前只是个摆设（opts.compress 电脑端压根没读）。
    // 这里把真实配置报上去：自动压缩开关 + 上下文长度 + 已有摘要能不能还原。
    try {
      const activeModel = promptCfg.model || result.models[0]?.value || ''
      if (activeModel) {
        const cc = await getModelCompactConfig(activeModel)
        const cfgState = cc?.config && typeof cc.config === 'object' ? cc.config : {}
        result.compact = {
          model: activeModel,
          autoCompactEnabled: cfgState.autoCompactEnabled !== false,
          hideCompactedMessages: cfgState.hideCompactedMessages !== false,
          contextLength: Number(cfgState.contextLength) || 0,
          contextLengthSource: cfgState.contextLengthSource || '',
          compactPrompt: (cfgState.compactPrompt || '').toString()
        }
      }
    } catch (err) {
      rwarn('[relay] read compact config failed:', err?.message || err)
    }
  } catch (err) {
    rwarn('[relay] readCapabilities failed:', err?.message || err)
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

/**
 * 在电脑端立即运行一个定时任务（手机「立即运行」）。
 * 复刻 main/core/task_runner.js 的开窗口逻辑，但**跳过**"本机是否启用"检查
 * —— 用户既然在手机上主动点了，就直接跑。
 */
async function runTaskOnDesktop(taskId) {
  if (typeof ctx?.openWindow !== 'function') {
    return { ok: false, reason: 'openWindow_unavailable' }
  }
  if (!ctx?.dataApi?.getConfig) {
    return { ok: false, reason: 'dataApi_unavailable' }
  }
  const res = await ctx.dataApi.getConfig()
  const fullConfig = res?.config && typeof res.config === 'object' ? res.config : {}
  const tasks = fullConfig?.tasks && typeof fullConfig.tasks === 'object' ? fullConfig.tasks : {}
  const task = tasks[taskId]
  if (!task || typeof task !== 'object') {
    return { ok: false, reason: 'task_not_found' }
  }

  const promptKey = typeof task.promptKey === 'string' && task.promptKey ? task.promptKey : '__DEFAULT__'
  const modelRoute = ['superior', 'general', 'fast'].includes(task?.modelRoute) ? task.modelRoute : 'general'

  const tempPromptConfig =
    promptKey === '__DEFAULT__'
      ? {
          type: 'general',
          prompt: '',
          showMode: 'window',
          model:
            typeof ctx.dataApi.resolveDefaultAssistantModel === 'function'
              ? ctx.dataApi.resolveDefaultAssistantModel(fullConfig, modelRoute)
              : '',
          stream: true,
          isAlwaysOnTop: fullConfig.isAlwaysOnTop_global ?? true,
          autoCloseOnBlur: fullConfig.autoCloseOnBlur_global ?? true,
          window_width: 580,
          window_height: 740,
          icon: ''
        }
      : null

  const openResult = await ctx.openWindow('window', {
    code: promptKey,
    type: 'task',
    payload: typeof task.description === 'string' ? task.description : '',
    taskConfig: { id: taskId, ...task },
    tempPromptConfig
  })

  return { ok: Boolean(openResult?.ok), windowId: openResult?.id || null, promptKey }
}

/**
 * 读取电脑端的「本地会话目录」。
 * 电脑端把它存在 config.webdav.localChatPath（主界面「对话」页用的同一路径）。
 */
async function readChatDirPath() {
  const res = await ctx?.dataApi?.getConfig?.()
  const cfg = res?.config && typeof res.config === 'object' ? res.config : {}
  const fromConfig = cfg?.webdav?.localChatPath
  if (typeof fromConfig === 'string' && fromConfig.trim()) return fromConfig.trim()
  // 允许用 relay.json 覆盖（路径不标准时手填）
  const fromRelay = readConfig()?.chatDir
  return typeof fromRelay === 'string' ? fromRelay.trim() : ''
}

/** 把内部会话对象整理成手机端好显示的字段 */
function toPhoneConversation(item) {
  const id = String(item?.conversationId || item?.filename || item?.basename || '').trim()
  const title = String(item?.title || '').trim()
  return {
    id,
    title: title || (id ? id.replace(/\.json$/i, '') : '未命名会话'),
    updatedAt: item?.updatedAt || item?.lastmod || '',
    createdAt: item?.createdAt || '',
    size: Number(item?.size) || 0,
    format: item?.format || 'sqlite',
    basename: item?.basename || item?.filename || ''
  }
}

/**
 * 列出电脑端的本地会话（手机「电脑端对话」列表）。
 * 同时算出每条会话属于哪个项目（电脑端用 projects.yml 组织：
 *   projects: [{ id, name, files:[basename], conversationIds:[id] }]）
 */
async function listPhoneConversations() {
  const dirPath = await readChatDirPath()
  if (!dirPath) {
    return { ok: false, reason: 'chat_dir_not_configured', conversations: [], projects: [] }
  }
  const all = await listLocalConversations(dirPath)

  // conversationId -> { projectId, projectName }
  const projectOf = new Map()
  let projects = []
  try {
    const data = await readLocalProjects(dirPath)
    const rawProjects = Array.isArray(data?.projects) ? data.projects : []
    projects = rawProjects
      .filter((p) => p && typeof p === 'object')
      .map((p) => ({ id: String(p.id || ''), name: String(p.name || p.id || '') }))
      .filter((p) => p.id)
    for (const p of rawProjects) {
      const pid = String(p?.id || '')
      const pname = String(p?.name || pid)
      if (!pid) continue
      for (const cid of Array.isArray(p?.conversationIds) ? p.conversationIds : []) {
        if (cid) projectOf.set(String(cid), { projectId: pid, projectName: pname })
      }
    }
  } catch (err) {
    rwarn('[relay] read projects failed:', err?.message || err)
  }

  const list = (Array.isArray(all) ? all : [])
    .map((item) => {
      const c = toPhoneConversation(item)
      const hit = projectOf.get(c.id)
      return {
        ...c,
        projectId: hit?.projectId || '',
        projectName: hit?.projectName || ''
      }
    })
    .filter((c) => c.id)
    .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))

  return { ok: true, dirPath, conversations: list, projects }
}

/**
 * 读取某个会话的消息列表（手机看会话内容用）。
 * 只取 role/content，去掉向量、工具调用等大字段。
 *
 * 注意：`index` 是**在 chat_show 里的下标**，手机端「删除这条」要把它回传，
 * 电脑端 `deleteMessage(index)` 就是按这个下标删的。
 * `messageId` 是 assistant 气泡的 id，手机端「重新回答」要回传它。
 */
async function readPhoneConversationMessages(conversationId) {
  const dirPath = await readChatDirPath()
  if (!dirPath) return { ok: false, reason: 'chat_dir_not_configured', messages: [] }

  // 长会话要能看全：openConversation 默认只取尾部一条窗口（约 200 条），
  // 会话一长前面的消息就「显示不完整」。这里把页面上限调大。
  const opened = await openConversation({
    dirPath,
    reference: conversationId,
    activeOnly: true,
    pageSize: 5000
  })
  if (!opened?.ok || !opened.sessionData) {
    return { ok: false, reason: 'conversation_not_found', messages: [] }
  }
  const chatShow = Array.isArray(opened.sessionData.chat_show) ? opened.sessionData.chat_show : []

  const messages = []
  chatShow.forEach((m, index) => {
    if (!m || typeof m !== 'object') return
    const role = String(m.role || '')
    if (role !== 'user' && role !== 'assistant' && role !== 'system') return
    const text = extractMessageText(m.content)
    if (!text) return
    messages.push({
      index,
      id: String(m.id ?? ''), // assistant 气泡 id，「重新回答」用
      role,
      text,
      time: m.completedTimestamp || m.timestamp || ''
    })
  })
  return { ok: true, messages, count: messages.length }
}

/** 从 content（字符串 / [{type:'text',text}]）里抽纯文本 */
function extractMessageText(content) {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content
      .filter((p) => p && p.type === 'text')
      .map((p) => p.text || '')
      .join('')
  }
  return ''
}

/** 删除整个会话 */
async function deletePhoneConversation(conversationId) {
  const dirPath = await readChatDirPath()
  if (!dirPath) return { ok: false, reason: 'chat_dir_not_configured' }
  const ref = String(conversationId || '').trim()
  if (!ref) return { ok: false, reason: 'conversationId_required' }

  // 如果这个会话正在手机窗口里开着，先关掉窗口并解绑
  if (phoneWindowId && phoneWindowKey === `conv:${ref}` && isWindowAlive(phoneWindowId)) {
    try {
      ctx.getWindowByRef(phoneWindowId)?.destroy?.()
    } catch (err) {
      rwarn('[relay] destroy window before delete failed:', err?.message || err)
    }
    phoneWindowId = null
    phoneWindowKey = 'phone'
  }

  const res = await storeDeleteConversation({ dirPath, conversationId: ref })
  rlog('[relay] deleted conversation', ref, 'removed =', res?.removed)
  return { ok: res?.ok !== false, removed: !!res?.removed }
}

/** 重命名会话 */
async function renamePhoneConversation(conversationId, title) {
  const dirPath = await readChatDirPath()
  if (!dirPath) return { ok: false, reason: 'chat_dir_not_configured' }
  const ref = String(conversationId || '').trim()
  const next = String(title || '').trim()
  if (!ref) return { ok: false, reason: 'conversationId_required' }
  if (!next) return { ok: false, reason: 'title_required' }
  await storeRenameConversation({ dirPath, conversationId: ref, title: next })
  return { ok: true, title: next }
}

/** 删除会话里的若干条消息 */
async function deletePhoneMessages(conversationId, storageIds) {
  const dirPath = await readChatDirPath()
  if (!dirPath) return { ok: false, reason: 'chat_dir_not_configured' }
  const ids = (Array.isArray(storageIds) ? storageIds : []).map((x) => String(x)).filter(Boolean)
  if (!ids.length) return { ok: false, reason: 'storageIds_required' }
  await storeDeleteMessages({ dirPath, conversationId, storageIds: ids })
  return { ok: true, deleted: ids.length }
}

/**
 * 手机点开某个电脑端会话：
 * 把该会话在本机窗口里打开，并把回复回传目标绑到那个窗口。
 */
async function openPhoneConversation(conversationId, relayTo) {
  const dirPath = await readChatDirPath()
  if (!dirPath) return { ok: false, reason: 'chat_dir_not_configured' }
  if (typeof ctx?.openWindow !== 'function') return { ok: false, reason: 'openWindow_unavailable' }

  // 读会话内容（descriptor + sessionData），窗口靠它恢复历史
  const opened = await openConversation({ dirPath, reference: conversationId })
  if (!opened?.ok || !opened.descriptor || !opened.sessionData) {
    return { ok: false, reason: 'conversation_not_found' }
  }

  // 已经为这个会话开过窗口就复用
  const reuseKey = `conv:${opened.descriptor.conversationId}`
  if (phoneWindowId && phoneWindowKey === reuseKey && isWindowAlive(phoneWindowId)) {
    try {
      ctx.dispatchWindowEvent(
        {
          event: 'relay:incoming',
          payload: { type: 'empty', payload: '', relayTo, __relayArmOnly: true },
          target: phoneWindowId
        },
        { getWindowByRef: ctx.getWindowByRef, listWindows: ctx.listWindows }
      )
      convWindows.set(opened.descriptor.conversationId, phoneWindowId)
      return { ok: true, windowId: phoneWindowId, reused: true, title: opened.descriptor.title }
    } catch (err) {
      rwarn('[relay] reuse conversation window failed:', err?.message || err)
    }
  }

  const promptKey =
    opened.sessionData?.promptKey ||
    opened.sessionData?.sessionMetadata?.promptKey ||
    phonePromptKey

  const res = await ctx.openWindow('window', {
    code: promptKey,
    type: 'over',
    payload: '',
    conversation: {
      descriptor: opened.descriptor,
      sessionData: opened.sessionData
    },
    relayTo
  })

  if (res?.ok && res.id) {
    phoneWindowId = res.id
    phoneWindowKey = reuseKey
    convWindows.set(opened.descriptor.conversationId, res.id)
    rlog('[relay] opened conversation window:', res.id, 'conv =', opened.descriptor.conversationId)
    return { ok: true, windowId: res.id, title: opened.descriptor.title }
  }
  rwarn('[relay] openWindow for conversation returned:', res)
  return { ok: false, reason: 'open_window_failed' }
}

// ---------------------------------------------------------------------------
// 定时任务管理（手机端）
// 任务数据在 config.tasks[taskId]，改完用 updateConfigWithoutFeatures 落盘 ——
// 和电脑端 Tasks.vue 的 atomicSave 走的是同一条路径。
// ---------------------------------------------------------------------------
function newTaskDefaults(name, builtinMcpIds) {
  return {
    name,
    triggerType: 'interval',
    intervalMinutes: 60,
    intervalStartTime: '00:00',
    intervalTimeRanges: [],
    dailyTime: '12:00',
    weeklyDays: [1, 2, 3, 4, 5],
    weeklyTime: '12:00',
    monthlyDays: [1],
    monthlyTime: '12:00',
    singleDate: new Date().toLocaleDateString('sv-SE'),
    singleTime: '12:00',
    promptKey: '__DEFAULT__',
    modelRoute: 'general',
    description: '',
    extraMcp: Array.isArray(builtinMcpIds) ? builtinMcpIds : [],
    extraSkills: [],
    autoSave: true,
    autoSaveProjectId: '',
    autoClose: false,
    enabled: false,
    history: []
  }
}

/**
 * 读 config → 交给 mutate 改 → 落盘。返回落盘后的 config。
 *
 * 用队列串行化：read-modify-write 之间如果没有互斥，两个手机操作同时到
 * （或手机操作与电脑端界面同时改）会互相覆盖，后写的把先写的抹掉。
 * 电脑端 Tasks.vue 的 atomicSave 也是同样的排队思路。
 */
let configWriteQueue = Promise.resolve()

function mutateConfig(mutate) {
  const run = async () => {
    if (!ctx?.dataApi?.getConfig || !ctx?.dataApi?.updateConfigWithoutFeatures) {
      throw new Error('config_api_unavailable')
    }
    const res = await ctx.dataApi.getConfig()
    const config = res?.config && typeof res.config === 'object' ? res.config : {}
    if (!config.tasks || typeof config.tasks !== 'object') config.tasks = {}
    const ret = mutate(config)
    await ctx.dataApi.updateConfigWithoutFeatures({
      config: JSON.parse(JSON.stringify(config))
    })
    return { config, ret }
  }
  // 无论上一个成功还是失败都继续排队，否则一次异常会把队列永久卡死
  const next = configWriteQueue.then(run, run)
  configWriteQueue = next.catch(() => {})
  return next
}

/** 任务名不能含文件系统非法字符（电脑端同样限制） */
function validateTaskName(name) {
  const n = String(name || '').trim()
  if (!n) return 'name_required'
  if (/[\\/:*?"<>|]/.test(n)) return 'name_invalid_char'
  return ''
}

/** 新建任务 */
async function createPhoneTask(name) {
  const bad = validateTaskName(name)
  if (bad) return { ok: false, reason: bad }
  const taskId = `task_${Date.now()}`
  const { config } = await mutateConfig((cfg) => {
    const builtinIds = Object.entries(cfg.mcpServers || {})
      .filter(([, s]) => s && s.type === 'builtin' && s.isActive !== false)
      .map(([id]) => id)
    cfg.tasks[taskId] = newTaskDefaults(String(name).trim(), builtinIds)
  })
  rlog('[relay] created task', taskId, config.tasks[taskId]?.name)
  return { ok: true, taskId }
}

/** 删除任务 */
async function deletePhoneTask(taskId) {
  const id = String(taskId || '').trim()
  if (!id) return { ok: false, reason: 'taskId_required' }
  let existed = false
  await mutateConfig((cfg) => {
    existed = !!cfg.tasks[id]
    delete cfg.tasks[id]
  })
  rlog('[relay] deleted task', id, 'existed =', existed)
  return { ok: true, removed: existed }
}

/**
 * 更新任务字段（重命名 / 启停 / 改调度都走这里）。
 * 只允许改白名单里的键，避免手机端误写坏配置。
 */
const TASK_WRITABLE_KEYS = new Set([
  'name', 'description', 'triggerType',
  'intervalMinutes', 'intervalStartTime', 'intervalTimeRanges',
  'dailyTime', 'weeklyDays', 'weeklyTime',
  'monthlyDays', 'monthlyTime',
  'singleDate', 'singleTime',
  'promptKey', 'modelRoute', 'extraMcp', 'extraSkills',
  'autoSave', 'autoSaveProjectId', 'autoClose'
])

async function updatePhoneTask(taskId, patch) {
  const id = String(taskId || '').trim()
  if (!id) return { ok: false, reason: 'taskId_required' }
  if (!patch || typeof patch !== 'object') return { ok: false, reason: 'patch_required' }

  if (typeof patch.name === 'string') {
    const bad = validateTaskName(patch.name)
    if (bad) return { ok: false, reason: bad }
  }

  let found = false
  await mutateConfig((cfg) => {
    const task = cfg.tasks[id]
    if (!task || typeof task !== 'object') return
    found = true
    for (const [k, v] of Object.entries(patch)) {
      if (!TASK_WRITABLE_KEYS.has(k)) continue
      task[k] = v
    }
  })
  if (!found) return { ok: false, reason: 'task_not_found' }
  return { ok: true }
}

/**
 * 启用 / 停用任务。
 * 电脑端的 `enabled` 是由 appliedDevices 派生的，所以这里同步维护
 * appliedDevices —— 只加/删「本机」这一项，不动其他设备的授权。
 */
async function setPhoneTaskEnabled(taskId, enabled) {
  const id = String(taskId || '').trim()
  if (!id) return { ok: false, reason: 'taskId_required' }
  const identity = ctx?.dataApi?.getTaskDeviceIdentity
    ? ctx.dataApi.getTaskDeviceIdentity()
    : null

  let found = false
  await mutateConfig((cfg) => {
    const task = cfg.tasks[id]
    if (!task || typeof task !== 'object') return
    found = true
    const list = Array.isArray(task.appliedDevices) ? [...task.appliedDevices] : []
    const key = identity?.deviceId || identity?.id || identity?.deviceName || 'desktop'
    const idx = list.findIndex((d) => {
      const k = d?.deviceId || d?.id || d?.deviceName
      return k === key
    })
    if (enabled) {
      if (idx === -1) {
        list.push(
          identity && typeof identity === 'object'
            ? { ...identity }
            : { deviceId: key, deviceName: 'Desktop' }
        )
      }
      task.lastRunTime = Date.now()
    } else if (idx !== -1) {
      list.splice(idx, 1)
    }
    task.appliedDevices = list
  })
  if (!found) return { ok: false, reason: 'task_not_found' }
  rlog('[relay] task', id, 'enabled =', enabled)
  return { ok: true, enabled: !!enabled }
}

/** 清空某个任务的历史（只清记录，不删电脑上的会话文件） */
async function clearPhoneTaskHistory(taskId) {
  const id = String(taskId || '').trim()
  if (!id) return { ok: false, reason: 'taskId_required' }
  let count = 0
  let found = false
  await mutateConfig((cfg) => {
    const task = cfg.tasks[id]
    if (!task || typeof task !== 'object') return
    found = true
    count = Array.isArray(task.history) ? task.history.length : 0
    task.history = []
  })
  if (!found) return { ok: false, reason: 'task_not_found' }
  rlog('[relay] cleared task history', id, 'count =', count)
  return { ok: true, cleared: count }
}

/**
 * 找手机聊天窗口应该复用的那个「手机」会话。
 *
 * 为什么需要它：手机聊天窗口是电脑端自建的会话（标题就是「手机」）。
 * 以前每次窗口重建（切换助手、重连、重启）都会**新建一个**会话，
 * 结果目录里攒了一堆同名「手机」，手机端看着就像「多个会话内容重合」。
 * 现在改成：优先复用最近更新的那个「手机」会话。
 *
 * @param {string} promptKey 手机当前选的助手（不同助手各用一个会话）
 */
async function findReusablePhoneConversationId(promptKey) {
  try {
    const dirPath = await readChatDirPath()
    if (!dirPath) return ''
    const all = await listLocalConversations(dirPath)
    if (!Array.isArray(all) || !all.length) return ''

    // 只看标题是「手机」的会话（电脑端新建时写死的标题）
    const candidates = all.filter((c) => String(c?.title || '').trim() === '手机')
    if (!candidates.length) return ''

    // 按更新时间倒序，逐个验证能打开（db 文件可能已被删）
    candidates.sort((a, b) => String(b?.updatedAt || '').localeCompare(String(a?.updatedAt || '')))

    for (const c of candidates) {
      const id = String(c?.conversationId || '').trim()
      if (!id) continue
      try {
        const opened = await openConversation({ dirPath, reference: id, activeOnly: true, pageSize: 1 })
        if (!opened?.ok) continue
        // 助手换了就别复用旧会话（配置追不回来），除非没传 promptKey
        const samePrompt = String(
          opened.sessionData?.promptKey ||
          opened.sessionData?.sessionMetadata?.promptKey ||
          ''
        ) === String(promptKey || '')
        if (samePrompt || !promptKey) {
          rlog('[relay] reuse phone conversation:', id, 'title =', c.title)
          return id
        }
      } catch (err) {
        rwarn('[relay] probe phone conversation failed:', id, err?.message || err)
      }
    }
    return ''
  } catch (err) {
    rwarn('[relay] findReusablePhoneConversationId failed:', err?.message || err)
    return ''
  }
}

async function routePhoneChat(msg) {
  const role = String(msg?.role ?? 'user').toLowerCase()
  const to = msg?.from || '*'

  // 手机请求能力清单（模型 / MCP / Skill / 助手 / 任务）
  if (role === 'capabilities-request') {
    try {
      const caps = await readCapabilities()
      relay?.sendChat(JSON.stringify({ __relayCapabilities: caps }), {
        role: 'capabilities',
        to
      })
    } catch (err) {
      rwarn('[relay] capabilities reply failed:', err?.message || err)
    }
    return
  }

  // 手机请求定时任务列表
  if (role === 'tasks-request') {
    try {
      const caps = await readCapabilities()
      relay?.sendChat(JSON.stringify({ __relayTasks: caps.tasks || [], desktopVersion: caps.desktopVersion }), {
        role: 'tasks',
        to
      })
    } catch (err) {
      rwarn('[relay] tasks reply failed:', err?.message || err)
    }
    return
  }

  // 手机请求「立即运行」某个定时任务
  if (role === 'task-run') {
    try {
      const taskId = String(msg?.taskId ?? '').trim()
      if (!taskId) throw new Error('taskId required')
      const res = await runTaskOnDesktop(taskId)
      relay?.sendChat(JSON.stringify({ __relayTaskRun: { taskId, ...res } }), {
        role: 'task-run-result',
        to
      })
    } catch (err) {
      relay?.sendChat(JSON.stringify({ __relayTaskRun: { taskId: msg?.taskId, ok: false, reason: String(err?.message || err) } }), {
        role: 'task-run-result',
        to
      })
    }
    return
  }

  // 手机请求「电脑端已有会话」列表
  if (role === 'conversations-request') {
    try {
      const res = await listPhoneConversations()
      relay?.sendChat(
        JSON.stringify({
          __relayConversations: res.conversations || [],
          ok: res.ok,
          reason: res.reason || '',
          dirPath: res.dirPath || ''
        }),
        { role: 'conversations', to }
      )
    } catch (err) {
      rwarn('[relay] conversations reply failed:', err?.message || err)
      relay?.sendChat(
        JSON.stringify({ __relayConversations: [], ok: false, reason: String(err?.message || err) }),
        { role: 'conversations', to }
      )
    }
    return
  }

  // 手机点开某个电脑端会话 → 在电脑端打开它并把回复回传手机
  if (role === 'conversation-open') {
    const conversationId = String(msg?.conversationId ?? '').trim()
    try {
      if (!conversationId) throw new Error('conversationId required')
      const res = await openPhoneConversation(conversationId, to)
      relay?.sendChat(
        JSON.stringify({
          __relayConversationOpen: {
            conversationId,
            ok: !!res.ok,
            reason: res.reason || '',
            windowId: res.windowId || null,
            title: res.title || '',
            reused: !!res.reused
          }
        }),
        { role: 'conversation-open-result', to }
      )
    } catch (err) {
      rwarn('[relay] conversation open failed:', err?.message || err)
      relay?.sendChat(
        JSON.stringify({
          __relayConversationOpen: {
            conversationId,
            ok: false,
            reason: String(err?.message || err)
          }
        }),
        { role: 'conversation-open-result', to }
      )
    }
    return
  }

  // 手机读取某个会话的消息内容
  if (role === 'conversation-messages-request') {
    const conversationId = String(msg?.conversationId ?? '').trim()
    try {
      const res = await readPhoneConversationMessages(conversationId)
      relay?.sendChat(
        JSON.stringify({
          __relayConversationMessages: {
            conversationId,
            ok: res.ok !== false,
            reason: res.reason || '',
            count: res.count || 0,
            messages: res.messages || []
          }
        }),
        { role: 'conversation-messages', to }
      )
    } catch (err) {
      rwarn('[relay] conversation messages failed:', err?.message || err)
      relay?.sendChat(
        JSON.stringify({
          __relayConversationMessages: {
            conversationId,
            ok: false,
            reason: String(err?.message || err),
            messages: []
          }
        }),
        { role: 'conversation-messages', to }
      )
    }
    return
  }

  // 手机删除某个会话
  if (role === 'conversation-delete') {
    const conversationId = String(msg?.conversationId ?? '').trim()
    let res
    try {
      res = await deletePhoneConversation(conversationId)
    } catch (err) {
      rwarn('[relay] conversation delete failed:', err?.message || err)
      res = { ok: false, reason: String(err?.message || err) }
    }
    relay?.sendChat(
      JSON.stringify({
        __relayConversationActionResult: {
          action: 'delete',
          conversationId,
          ok: res.ok !== false,
          removed: !!res.removed,
          reason: res.reason || ''
        }
      }),
      { role: 'conversation-action-result', to }
    )
    return
  }

  // 手机重命名某个会话
  if (role === 'conversation-rename') {
    const conversationId = String(msg?.conversationId ?? '').trim()
    const title = String(msg?.title ?? '').trim()
    let res
    try {
      res = await renamePhoneConversation(conversationId, title)
    } catch (err) {
      rwarn('[relay] conversation rename failed:', err?.message || err)
      res = { ok: false, reason: String(err?.message || err) }
    }
    relay?.sendChat(
      JSON.stringify({
        __relayConversationActionResult: {
          action: 'rename',
          conversationId,
          title: res.title || title,
          ok: res.ok !== false,
          reason: res.reason || ''
        }
      }),
      { role: 'conversation-action-result', to }
    )
    return
  }

  // 手机删除会话里的若干条消息
  if (role === 'conversation-messages-delete') {
    const conversationId = String(msg?.conversationId ?? '').trim()
    const storageIds = Array.isArray(msg?.storageIds) ? msg.storageIds : []
    let res
    try {
      res = await deletePhoneMessages(conversationId, storageIds)
    } catch (err) {
      rwarn('[relay] conversation messages delete failed:', err?.message || err)
      res = { ok: false, reason: String(err?.message || err) }
    }
    relay?.sendChat(
      JSON.stringify({
        __relayConversationActionResult: {
          action: 'deleteMessages',
          conversationId,
          deleted: res.deleted || 0,
          ok: res.ok !== false,
          reason: res.reason || ''
        }
      }),
      { role: 'conversation-action-result', to }
    )
    return
  }

  // 手机对某条消息的操作（重新回答 / 删除这条）→ 转发给会话窗口执行
  if (role === 'message-action') {
    const action = String(msg?.action ?? '').trim()
    const reqId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
    const conversationId = String(msg?.conversationId ?? '').trim()

    const fail = (reason) => {
      relay?.sendChat(
        JSON.stringify({
          __relayMessageAction: { action, reqId, ok: false, reason }
        }),
        { role: 'message-action-result', to }
      )
    }

    if (!action) return fail('action_required')

    // 找到承载这个会话的窗口。
    //
    // 有两种窗口，key 不一样：
    //   · 'phone'        —— 手机聊天窗口（手机直接聊天，窗口里自动建了一个会话）
    //   · 'conv:<id>'    —— 手机点开某个已有电脑端会话的窗口
    //
    // 手机气泡带回来的 conversationId 是**窗口自己那个会话**的 id，
    // 所以在 'phone' 模式下它跟 key 对不上 —— 以前只做严格相等，
    // 结果「重新回答」「删除这条」永远找不到窗口（日志：no bound window）。
    // 现在改成：phone 模式的窗口一律接受；conv:<id> 模式必须 id 对得上。
    let targetWin = null

    // 1) 先看有没有为**这个会话**专门开着的窗口（最精确）
    if (conversationId) {
      const wid = convWindows.get(conversationId)
      if (wid && isWindowAlive(wid)) {
        targetWin = wid
      } else if (wid) {
        convWindows.delete(conversationId) // 窗口已关，清理掉
      }
    }

    // 2) 再看当前这个「手机窗口」能不能用
    //
    // 手机聊天窗口（key='phone'）一律接受：那个窗口就是手机自己在聊的会话，
    // 消息必然来自它。具体是不是同一条消息，由窗口自己按 messageId 查——
    // 窗口手里有真实的 chat_show，它比主进程更有发言权。
    if (!targetWin && isWindowAlive(phoneWindowId)) {
      if (phoneWindowKey === 'phone') {
        targetWin = phoneWindowId
      } else if (conversationId && phoneWindowKey === `conv:${conversationId}`) {
        targetWin = phoneWindowId
      } else if (!conversationId) {
        targetWin = phoneWindowId
      }
    }
    // 没窗口？那就**把那个会话开起来**再操作。
    //
    // 以前这里直接 fail('conversation_not_open')，用户就会看到
    // 「电脑端还没打开这个会话」—— 但手机明明能看到这条消息（从数据库读的）。
    // 两边不一致很难用：凭什么看得到却不能删？
    // 所以改为：自动 openWindow 打开该会话，等它初始化完再派发命令。
    if (!targetWin && conversationId) {
      try {
        rlog('[relay] message-action: auto-opening conversation', conversationId)
        const opened = await openPhoneConversation(conversationId, to)
        const autoWin = convWindows.get(conversationId) || phoneWindowId
        if (opened?.ok && autoWin && isWindowAlive(autoWin)) {
          targetWin = autoWin
          // 窗口刚建好，历史还在加载。等它 bootstrap 完成，
          // 否则 chat_show 还是空的 -> 窗口会回 message_not_found。
          await new Promise((r) => setTimeout(r, 1200))
        } else {
          rwarn('[relay] auto-open for message-action failed:', opened?.reason)
        }
      } catch (err) {
        rwarn('[relay] auto-open for message-action threw:', err?.message || err)
      }
    }

    if (!targetWin) {
      rlog('[relay] message-action but no bound window; conv =', conversationId, 'key =', phoneWindowKey)
      return fail('conversation_not_open')
    }

    try {
      const dispatched = ctx.dispatchWindowEvent(
        {
          event: 'relay:command',
          payload: {
            action,
            reqId,
            relayTo: to,
            messageId: msg?.messageId,
            index: msg?.index
          },
          target: targetWin
        },
        { getWindowByRef: ctx.getWindowByRef, listWindows: ctx.listWindows }
      )
      // dispatchWindowEvent 返回 { ok, delivered, reason }。
      // 之前没检查：窗口要是刚好在两步之间关掉了，这里会静默失败，
      // 手机端一直等一个永远不来的回执（表现为"点了没反应"）。
      if (dispatched && dispatched.ok === false) {
        rwarn('[relay] message-action dispatch not delivered:', dispatched.reason)
        return fail(dispatched.reason || 'dispatch_failed')
      }
      rlog('[relay] dispatched message-action', action, 'to window', targetWin, 'reqId =', reqId)
    } catch (err) {
      rwarn('[relay] dispatch message-action failed:', err?.message || err)
      fail(String(err?.message || err))
    }
    return
  }

  // 手机切换「自动压缩」开关（按模型的配置）
  if (role === 'set-auto-compact') {
    const enabled = msg?.enabled === true
    let model = String(msg?.model ?? '').trim()
    let res = { ok: false }
    try {
      if (!model) {
        const caps = await readCapabilities()
        model = caps?.compact?.model || caps?.current?.model || caps?.models?.[0]?.value || ''
      }
      if (!model) throw new Error('model_unknown')
      const out = await updateModelCompactConfig(model, { autoCompactEnabled: enabled })
      res = { ok: true, model, autoCompactEnabled: enabled, config: out?.config || null }
      rlog('[relay] autoCompact', model, '=', enabled)
    } catch (err) {
      rwarn('[relay] set-auto-compact failed:', err?.message || err)
      res = { ok: false, reason: String(err?.message || err) }
    }
    relay?.sendChat(
      JSON.stringify({ __relayAutoCompact: res }),
      { role: 'set-auto-compact-result', to }
    )
    return
  }

  // ---- 定时任务管理（新建 / 删除 / 改名 / 启停 / 改调度 / 清历史）----
  if (role === 'task-manage') {
    const op = String(msg?.op ?? '').trim()
    const taskId = String(msg?.taskId ?? '').trim()
    let res
    try {
      switch (op) {
        case 'create':
          res = await createPhoneTask(msg?.name)
          break
        case 'delete':
          res = await deletePhoneTask(taskId)
          break
        case 'update':
          res = await updatePhoneTask(taskId, msg?.patch)
          break
        case 'setEnabled':
          res = await setPhoneTaskEnabled(taskId, msg?.enabled === true)
          break
        case 'clearHistory':
          res = await clearPhoneTaskHistory(taskId)
          break
        default:
          res = { ok: false, reason: 'unknown_op' }
      }
    } catch (err) {
      rwarn('[relay] task-manage failed:', op, err?.message || err)
      res = { ok: false, reason: String(err?.message || err) }
    }

    // 回执里带上最新的任务列表，手机端不用再单独拉一次
    let tasks = []
    try {
      tasks = (await readCapabilities()).tasks || []
    } catch (_) {}

    relay?.sendChat(
      JSON.stringify({
        __relayTaskManageResult: {
          op,
          taskId: res?.taskId || taskId,
          ok: res?.ok !== false,
          removed: !!res?.removed,
          cleared: res?.cleared || 0,
          enabled: res?.enabled,
          reason: res?.reason || ''
        },
        __relayTasks: tasks
      }),
      { role: 'task-manage-result', to }
    )
    return
  }

  // ---------------------------------------------------------------------------
  // 手机端编辑电脑端能力（助手 / 模型(服务商) / MCP / Skill）
  //
  // 以前手机上这四类只能「看」，想改必须到电脑上操作。这里提供与电脑端
  // 设置页等价的编辑能力，写入走 mutateConfig 队列（与电脑端同一路径）。
  //
  // 安全边界：API key 只写不读 —— 回执只带 hasApiKey 布尔，绝不回显明文。
  // ---------------------------------------------------------------------------
  if (role === 'caps-edit') {
    const op = String(msg?.op || '').trim()
    const body = msg?.body && typeof msg.body === 'object' ? msg.body : {}

    const reply = async (ok, data) => {
      try {
        let caps = null
        try { caps = await readCapabilities() } catch (_) {}
        relay?.sendChat(
          JSON.stringify({ __relayCapsEditResult: { op, ok, ...(data || {}), capabilities: caps } }),
          { role: 'caps-edit-result', to }
        )
      } catch (err) {
        rwarn('[relay] caps-edit reply failed:', err?.message || err)
      }
    }
    const fail = (reason) => reply(false, { reason: String(reason || 'failed') })

    try {
      // ---- 助手（config.prompts）----
      // 字段与电脑端「快捷助手」编辑弹窗一一对应（Prompts.vue savePrompt）。
      if (op === 'prompt-save') {
        const key = String(body.key || '').trim()
        const oldKey = String(body.oldKey || key).trim()
        if (!key) return fail('key_required')
        if (!/^[\w-]{1,64}$/.test(key)) return fail('key_invalid')
        if (key === '__DEFAULT__') return fail('protected')
        await mutateConfig((cfg) => {
          cfg.prompts = cfg.prompts && typeof cfg.prompts === 'object' ? cfg.prompts : {}
          const src = cfg.prompts[oldKey] && typeof cfg.prompts[oldKey] === 'object' ? cfg.prompts[oldKey] : {}
          const next = { ...src }
          const str = (v, k) => { if (typeof v === 'string') next[k] = v }
          const bool = (v, k) => { if (typeof v === 'boolean') next[k] = v }
          const num = (v, k) => { if (typeof v === 'number' && Number.isFinite(v)) next[k] = v }

          str(body.label, 'name')
          str(body.type, 'type')
          str(body.showMode, 'showMode')
          str(body.matchRegex, 'matchRegex')
          str(body.prompt, 'prompt')
          str(body.model, 'model')
          str(body.icon, 'icon')
          str(body.voice, 'voice')
          str(body.reasoningEffort, 'reasoning_effort')
          str(body.backgroundImage, 'backgroundImage')
          str(body.autoSaveProjectId, 'autoSaveProjectId')
          bool(body.enable, 'enable')
          bool(body.stream, 'stream')
          bool(body.isTemperature, 'isTemperature')
          bool(body.isDirectSend_normal, 'isDirectSend_normal')
          bool(body.isDirectSend_file, 'isDirectSend_file')
          bool(body.isDirectSend_image, 'isDirectSend_image')
          bool(body.ifTextNecessary, 'ifTextNecessary')
          bool(body.isAlwaysOnTop, 'isAlwaysOnTop')
          bool(body.autoCloseOnBlur, 'autoCloseOnBlur')
          bool(body.autoSaveChat, 'autoSaveChat')
          num(body.temperature, 'temperature')
          num(body.window_width, 'window_width')
          num(body.window_height, 'window_height')
          num(body.backgroundOpacity, 'backgroundOpacity')
          num(body.backgroundBlur, 'backgroundBlur')
          if (Array.isArray(body.mcp)) next.defaultMcpServers = body.mcp.map((x) => String(x))
          if (Array.isArray(body.skills)) next.defaultSkills = body.skills.map((x) => String(x))
          if (!next.type) next.type = 'general'
          if (typeof next.stream !== 'boolean') next.stream = true

          if (key !== oldKey) delete cfg.prompts[oldKey]
          cfg.prompts[key] = next
          // tags 里引用旧 key 的也一起改名，避免助手从分组里消失
          if (key !== oldKey && cfg.tags && typeof cfg.tags === 'object') {
            for (const tag of Object.keys(cfg.tags)) {
              if (Array.isArray(cfg.tags[tag])) {
                cfg.tags[tag] = cfg.tags[tag].map((x) => (x === oldKey ? key : x))
              }
            }
          }
        })
        await reply(true, { key })
        return
      }
      if (op === 'prompt-delete') {
        const key = String(body.key || '').trim()
        if (!key) return fail('key_required')
        if (key === 'AI') return fail('protected')
        await mutateConfig((cfg) => {
          if (cfg.prompts && typeof cfg.prompts === 'object') delete cfg.prompts[key]
          if (cfg.tags && typeof cfg.tags === 'object') {
            for (const tag of Object.keys(cfg.tags)) {
              if (Array.isArray(cfg.tags[tag])) {
                cfg.tags[tag] = cfg.tags[tag].filter((x) => x !== key)
              }
            }
          }
        })
        await reply(true, { key })
        return
      }

      // ---- 模型 / 服务商（config.providers + providerOrder）----
      // 字段对齐电脑端 Providers.vue（name/url/api_key/modelList/enable/headers/retryCount/apiType）
      if (op === 'provider-save') {
        let id = String(body.id || '').trim()
        const name = String(body.name || '').trim()
        const url = String(body.url || '').trim()
        if (!name) return fail('name_required')
        const models = Array.isArray(body.models)
          ? body.models.map((x) => String(x).trim()).filter(Boolean)
          : null
        await mutateConfig((cfg) => {
          cfg.providers = cfg.providers && typeof cfg.providers === 'object' ? cfg.providers : {}
          if (!Array.isArray(cfg.providerOrder)) cfg.providerOrder = Object.keys(cfg.providers)
          let pid = id
          if (!pid || !cfg.providers[pid]) {
            pid = String(Date.now())
            if (!cfg.providerOrder.includes(pid)) cfg.providerOrder.push(pid)
          }
          const prev = cfg.providers[pid] && typeof cfg.providers[pid] === 'object' ? cfg.providers[pid] : {}
          const next = { ...prev }
          next.name = name
          if (url) next.url = url
          if (typeof body.apiKey === 'string' && body.apiKey.trim()) next.api_key = body.apiKey.trim()
          if (typeof body.enable === 'boolean') next.enable = body.enable
          if (typeof body.apiType === 'string' && body.apiType) next.apiType = body.apiType
          if (typeof body.retryCount === 'number' && Number.isFinite(body.retryCount)) {
            next.retryCount = Math.max(0, Math.floor(body.retryCount))
          }
          if (body.headers && typeof body.headers === 'object') next.headers = { ...body.headers }
          if (models) next.modelList = models
          if (!next.apiType) next.apiType = 'chat_completions'
          if (typeof next.retryCount !== 'number') next.retryCount = 3
          if (!next.headers || typeof next.headers !== 'object') next.headers = {}
          cfg.providers[pid] = next
          id = pid
        })
        await reply(true, { id })
        return
      }
      if (op === 'provider-delete') {
        const id = String(body.id || '').trim()
        if (!id) return fail('id_required')
        await mutateConfig((cfg) => {
          if (cfg.providers && typeof cfg.providers === 'object') delete cfg.providers[id]
          if (Array.isArray(cfg.providerOrder)) {
            cfg.providerOrder = cfg.providerOrder.filter((x) => x !== id)
          }
        })
        await reply(true, { id })
        return
      }

      // ---- MCP（config.mcpServers）----
      // 字段对齐电脑端 Mcp.vue（name/description/type/baseUrl/command/args/env/headers/auth/isActive/isPersistent/timeoutSeconds/tags）
      if (op === 'mcp-save') {
        const id = String(body.id || '').trim()
        if (!id) return fail('id_required')
        if (!/^[\w-]{1,64}$/.test(id)) return fail('id_invalid')
        await mutateConfig((cfg) => {
          cfg.mcpServers = cfg.mcpServers && typeof cfg.mcpServers === 'object' ? cfg.mcpServers : {}
          const prev = cfg.mcpServers[id] && typeof cfg.mcpServers[id] === 'object' ? cfg.mcpServers[id] : {}
          const next = { ...prev, id }
          const str = (v, k) => { if (typeof v === 'string') next[k] = v }
          str(body.name, 'name')
          str(body.description, 'description')
          str(body.type, 'type')
          str(body.command, 'command')
          // 电脑端 config 里 sse/http 用的是 baseUrl，历史数据也有 url —— 两个都写
          if (typeof body.baseUrl === 'string') {
            next.baseUrl = body.baseUrl
            next.url = body.baseUrl
          } else if (typeof body.url === 'string') {
            next.url = body.url
            next.baseUrl = body.url
          }
          if (Array.isArray(body.args)) next.args = body.args.map((x) => String(x))
          if (body.env && typeof body.env === 'object') next.env = { ...body.env }
          if (body.headers && typeof body.headers === 'object') next.headers = { ...body.headers }
          if (typeof body.isActive === 'boolean') {
            next.isActive = body.isActive
            next.enable = body.isActive
          }
          if (typeof body.isPersistent === 'boolean') next.isPersistent = body.isPersistent
          if (typeof body.timeoutSeconds === 'number' && Number.isFinite(body.timeoutSeconds)) {
            next.timeoutSeconds = Math.max(1, Math.floor(body.timeoutSeconds))
          }
          if (Array.isArray(body.tags)) next.tags = body.tags.map((x) => String(x))
          if (body.auth && typeof body.auth === 'object') {
            const t = String(body.auth.type || 'none')
            if (t === 'bearer') {
              next.auth = { type: 'bearer', bearerToken: String(body.auth.bearerToken || '') }
            } else {
              next.auth = { type: 'none' }
            }
          }
          if (!next.type) next.type = (next.baseUrl || next.url) ? 'sse' : 'stdio'
          if (typeof next.timeoutSeconds !== 'number') next.timeoutSeconds = 120
          cfg.mcpServers[id] = next
        })
        await reply(true, { id })
        return
      }
      if (op === 'mcp-delete') {
        const id = String(body.id || '').trim()
        if (!id) return fail('id_required')
        if (String(id).startsWith('builtin_')) return fail('builtin_readonly')
        await mutateConfig((cfg) => {
          if (cfg.mcpServers && typeof cfg.mcpServers === 'object') delete cfg.mcpServers[id]
          // 同时从所有助手的预设里摘掉，和电脑端删除逻辑一致
          if (cfg.prompts && typeof cfg.prompts === 'object') {
            for (const k of Object.keys(cfg.prompts)) {
              const pr = cfg.prompts[k]
              if (pr && Array.isArray(pr.defaultMcpServers)) {
                pr.defaultMcpServers = pr.defaultMcpServers.filter((x) => x !== id)
              }
            }
          }
        })
        await reply(true, { id })
        return
      }

      // ---- Skill（磁盘上的 SKILL.md）----
      if (op === 'skill-toggle' || op === 'skill-delete' || op === 'skill-save') {
        const id = String(body.id || '').trim()
        if (!id) return fail('id_required')
        const cfgRes = await (ctx?.dataApi?.getConfig?.() || Promise.resolve(null))
        const skillPath = cfgRes?.config?.skillPath || ''
        if (!skillPath) return fail('skill_dir_not_configured')
        const details = getSkillDetails(skillPath, id)
        if (!details?.ok) return fail('skill_not_found')
        const mdPath = join(skillPath, id, 'SKILL.md')

        if (op === 'skill-delete') {
          const ok = deleteSkill(skillPath, id)
          if (!ok) return fail('skill_not_found')
          await reply(true, { id })
          return
        }

        // 读取现有 frontmatter + 正文（保留未知字段）
        let content = ''
        try { content = readFileSync(mdPath, 'utf-8') } catch (_) { content = '' }
        if (!content) return fail('skill_md_missing')
        const meta = (details.metadata && typeof details.metadata === 'object') ? { ...details.metadata } : {}
        const bodyText = String(details.content || '')

        if (op === 'skill-toggle') {
          const disabled = body.disabled === true
          if (disabled) meta['disable-model-invocation'] = true
          else delete meta['disable-model-invocation']
        } else {
          // skill-save：名称 / 描述 / 启用 / fork / 允许工具 / 正文
          const str = (v, k) => { if (typeof v === 'string' && v.trim()) meta[k] = v.trim() }
          str(body.name, 'name')
          if (typeof body.description === 'string') meta.description = body.description
          if (typeof body.enabled === 'boolean') {
            if (body.enabled) delete meta['disable-model-invocation']
            else meta['disable-model-invocation'] = true
          }
          if (typeof body.forkMode === 'boolean') {
            if (body.forkMode) meta.context = 'fork'
            else delete meta.context
          }
          if (typeof body.allowedTools === 'string') {
            const tools = body.allowedTools.split(/[,，]/).map((x) => x.trim()).filter(Boolean)
            if (tools.length) meta['allowed-tools'] = tools
            else delete meta['allowed-tools']
          }
        }

        // 写回 YAML frontmatter（与电脑端 saveSkillContent 同样的字段顺序）
        const yamlScalar = (v) => (typeof v === 'boolean' ? (v ? 'true' : 'false') : String(v))
        const lines = ['---']
        const push = (k, v) => {
          if (v === undefined || v === null || v === '') return
          if (Array.isArray(v)) {
            if (!v.length) return
            lines.push(k + ': [' + v.map((x) => '"' + String(x).replace(/"/g, '\\"') + '"').join(', ') + ']')
            return
          }
          lines.push(k + ': ' + yamlScalar(v))
        }
        push('name', meta.name)
        push('description', meta.description)
        push('argument-hint', meta['argument-hint'])
        push('user-invocable', meta['user-invocable'])
        if (meta['disable-model-invocation'] === true) lines.push('disable-model-invocation: true')
        if (meta.context === 'fork') lines.push('context: fork')
        push('agent', meta.agent)
        push('model', meta.model)
        push('allowed-tools', meta['allowed-tools'])
        lines.push('---')
        lines.push('')
        const nextBody = op === 'skill-save' && typeof body.instructions === 'string'
          ? body.instructions
          : bodyText
        lines.push(nextBody || '')
        writeFileSync(mdPath, lines.join('\n'), 'utf-8')
        await reply(true, { id, disabled: meta['disable-model-invocation'] === true })
        return
      }

      await fail('unknown_op')
    } catch (err) {
      rwarn('[relay] caps-edit failed:', op, err?.message || err)
      await fail(String(err?.message || err))
    }
    return
  }

  // 只处理普通用户消息
  if (role !== 'user') return

  const text = String(msg?.text ?? '').trim()
  if (!text) return
  const relayTo = to
  const opts = msg?.options && typeof msg.options === 'object' ? msg.options : null

  // 手机切换了「快捷助手」→ 换一个 promptKey 承载这个会话
  if (opts?.promptKey && opts.promptKey !== phonePromptKey) {
    phonePromptKey = opts.promptKey
    // 关掉旧的手机窗口，让新助手用新的配置开一个新会话
    if (isWindowAlive(phoneWindowId)) {
      try {
        const w = ctx.getWindowByRef(phoneWindowId)
        w?.destroy?.()
      } catch (err) {
        rwarn('[relay] destroy old phone window failed:', err?.message || err)
      }
    }
    phoneWindowId = null
  }

  const relayFields = {
    relayTo,
    // 手机本地的消息 id —— 窗口 append 后会把它原样回传，
    // 手机就能精确把「电脑端位置」挂到对应气泡上（自己发的消息也能删）。
    __relayClientMsgId: msg?.__relayClientMsgId || '',
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
      rwarn('[relay] dispatch to phone window failed:', err?.message || err)
    }
  }

  // 2) 否则开一个专用的「手机」会话窗口
  //    isDirectSend_normal 默认为 true → multiline-text 会直接追加并跑 AI
  if (typeof ctx?.openWindow !== 'function') {
    rwarn('[relay] openWindow unavailable; cannot route phone chat to AI')
    return
  }
  try {
    // 先看能不能**复用**已有的「手机」会话。
    //
    // 以前这里无条件新建：每次窗口重建（切助手/重连/重启）都会多出一个
    // 标题为「手机」的会话，手机端列表里一堆同名项、内容还各不相同。
    // 现在优先接着上次那个「手机」会话聊。
    const reusableId = await findReusablePhoneConversationId(phonePromptKey)
    if (reusableId) {
      const opened = await openPhoneConversation(reusableId, relayTo)
      if (opened?.ok) {
        convWindows.set(reusableId, opened.windowId)
        rlog('[relay] routed phone chat into existing conversation:', reusableId)
        return
      }
      rwarn('[relay] reuse conversation failed, creating new one:', opened?.reason)
    }

    const res = await ctx.openWindow('window', {
      code: phonePromptKey,
      type: 'multiline-text',
      payload: text,
      conversationTitle: '手机',
      ...relayFields
    })
    if (res?.ok && res.id) {
      phoneWindowId = res.id
      rlog('[relay] opened phone chat window:', phoneWindowId)
    } else {
      rwarn('[relay] openWindow returned:', res)
    }
  } catch (err) {
    rwarn('[relay] open phone window failed:', err?.message || err)
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

  ipcMain.handle('relay:sendChat', guard(async (_e, { text, to, role, extra } = {}) => {
    rlog('[relay] <- relay:sendChat  to =', to, ' len =', String(text || '').length)
    if (!relay?.connected) {
      rwarn('[relay] relay:sendChat rejected: not connected')
      return { ok: false, error: { message: 'relay_not_connected' } }
    }
    const delivered = relay.sendChat(text, {
      role: role || 'assistant',
      to: to || '*',
      extra
    })
    rlog('[relay] -> sendChat delivered =', delivered)
    return { ok: true, delivered }
  }))

  // 渲染进程（窗口）的日志转发到主进程终端 + relay.log，方便排查手机互通问题
  ipcMain.on('relay:log', (_e, { level = 'log', args = [] } = {}) => {
    const list = Array.isArray(args) ? args : [args]
    if (level === 'warn' || level === 'error') {
      console.warn('[relay:window]', ...list)
      relayFileLog('window:WARN', ...list)
    } else {
      console.log('[relay:window]', ...list)
      relayFileLog('window', ...list)
    }
  })

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

  // 每次启动打一条分隔，方便在 relay.log 里区分会话
  relayFileLog('main', `==================== relay start v${RELAY_VERSION} (build ${RELAY_VERSION_CODE}) ====================`)

  // ALWAYS register IPC handlers first, even when there is no config yet.
  // Otherwise the settings UI can never save a config (chicken-and-egg).
  registerIpc()

  const cfg = overrideConfig || readConfig()

  if (!cfg?.serverUrl || !cfg?.token) {
    rlog('[relay] no config found; relay disabled. Set userData/relay.json or env vars.')
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
    rlog('[relay] connected as', relay.deviceId)
    emitToWindows('relay:status', { connected: true, deviceId: relay.deviceId })
  })
  relay.on('disconnected', () => {
    rlog('[relay] disconnected')
    emitToWindows('relay:status', { connected: false })
  })
  relay.on('presence', (peers) => {
    emitToWindows('relay:presence', { peers })
  })

  // ---- phone -> desktop ----
  // 聊天：路由进 AI 管线（开窗口 / 定向派发）
  relay.on('chat', (msg) => {
    routePhoneChat(msg).catch((err) => {
      rwarn('[relay] routePhoneChat failed:', err?.message || err)
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

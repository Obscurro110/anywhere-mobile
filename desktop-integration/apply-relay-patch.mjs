#!/usr/bin/env node
/**
 * [anywhere-mobile] Re-apply the relay patch to main/index.js
 * -----------------------------------------------------------
 * 从源码更新（git pull）后运行本脚本，即可把中继接入的 2 行改动重新注入。
 * 幂等：已注入则跳过。新增文件（main/relay/*）不受 git pull 影响。
 *
 * 用法：
 *   node scripts/apply-relay-patch.mjs
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const INDEX = join(root, 'main', 'index.js')

const IMPORT_ANCHOR = "import { startTaskScheduler } from './core/task_scheduler.js'"
const IMPORT_LINE = "// [anywhere-mobile] 手机互通中继桥\nimport { startRelay } from './relay/index.js'"

const CALL_ANCHOR = "await openWindow('main')"
const CALL_LINE = "\n  // [anywhere-mobile] 启动与手机 App 的中继连接\n  startRelay({ getWindowByRef, listWindows, dispatchWindowEvent })"

if (!existsSync(INDEX)) {
  console.error('[apply-relay-patch] main/index.js not found:', INDEX)
  process.exit(1)
}

let src = readFileSync(INDEX, 'utf8')
let changed = false

// 1) import
if (!src.includes('[anywhere-mobile] 手机互通中继桥')) {
  if (!src.includes(IMPORT_ANCHOR)) {
    console.error('[apply-relay-patch] anchor (startTaskScheduler import) not found; aborting.')
    process.exit(1)
  }
  src = src.replace(IMPORT_ANCHOR, `${IMPORT_ANCHOR}\n${IMPORT_LINE}`)
  changed = true
  console.log('[apply-relay-patch] inserted relay import')
} else {
  console.log('[apply-relay-patch] import already present')
}

// 2) startRelay call (only the FIRST occurrence of await openWindow('main'))
if (!src.includes('startRelay({ getWindowByRef, listWindows, dispatchWindowEvent })')) {
  const idx = src.indexOf(CALL_ANCHOR)
  if (idx === -1) {
    console.error("[apply-relay-patch] anchor (await openWindow('main')) not found; aborting.")
    process.exit(1)
  }
  const at = idx + CALL_ANCHOR.length
  src = src.slice(0, at) + CALL_LINE + src.slice(at)
  changed = true
  console.log('[apply-relay-patch] inserted startRelay() call')
} else {
  console.log('[apply-relay-patch] startRelay() call already present')
}

if (changed) {
  writeFileSync(INDEX, src, 'utf8')
  console.log('[apply-relay-patch] done. main/index.js updated.')
} else {
  console.log('[apply-relay-patch] nothing to do.')
}

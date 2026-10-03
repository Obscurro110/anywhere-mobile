#!/usr/bin/env node
/**
 * 安装 git 钩子（防泄露 pre-commit 扫描）
 * 用法：  node scripts/install-git-hooks.mjs
 *
 * 会在 .git/hooks/pre-commit 写入一个 sh 脚本，
 * 每次 commit 前调用 scripts/pre-commit-secret-scan.mjs。
 */
import { execSync } from 'node:child_process'
import { writeFileSync, chmodSync, existsSync, mkdirSync, copyFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim()
const HOOKS = join(ROOT, '.git', 'hooks')
const HOOK = join(HOOKS, 'pre-commit')

const SH = `#!/bin/sh
# ============================================================
#  anywhere-mobile 防泄露 pre-commit 钩子
#  由 scripts/install-git-hooks.mjs 生成 —— 请勿手工修改
#  绕过：git commit --no-verify
# ============================================================
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$ROOT" ] && exit 0
if ! command -v node >/dev/null 2>&1; then
  echo "[secret-scan] 未找到 node，跳过密钥扫描"
  exit 0
fi
node "$ROOT/scripts/pre-commit-secret-scan.mjs" || exit 1
exit 0
`

if (!existsSync(HOOKS)) mkdirSync(HOOKS, { recursive: true })

if (existsSync(HOOK)) {
  const backup = HOOK + '.bak'
  copyFileSync(HOOK, backup)
  console.log(`已备份旧钩子 -> ${backup}`)
}

writeFileSync(HOOK, SH, 'utf8')
try { chmodSync(HOOK, 0o755) } catch { /* Windows 忽略 */ }

console.log('')
console.log('[OK] 已安装 pre-commit 钩子:')
console.log(`     ${HOOK}`)
console.log('')
console.log('  以后每次 git commit 都会自动扫描 token / 密钥。')
console.log('  误报可写入仓库根的 .secretsignore（allow:<正则>）。')
console.log('  强行提交： git commit --no-verify')
console.log('')

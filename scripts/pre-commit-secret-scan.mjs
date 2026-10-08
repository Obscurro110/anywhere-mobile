#!/usr/bin/env node
/**
 * pre-commit 防泄露扫描
 * ---------------------
 * 在 git commit 之前，扫描「即将提交的内容」里有没有 token / 密钥。
 * 命中则阻止提交。
 *
 * 安装：  node scripts/install-git-hooks.mjs
 * 绕过： git commit --no-verify      （不推荐）
 *
 * 自定义：在仓库根放 .secretsignore，可加额外规则：
 *   pattern:<正则>        额外拦截正则
 *   allow:<正则>          命中即放行（白名单）
 *   # 注释行会被忽略
 */
import { execSync, execFileSync } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim()

/** 内置拦截规则 */
const PATTERNS = [
  ['GitHub PAT (classic)',        /\bghp_[A-Za-z0-9]{30,}\b/],
  ['GitHub PAT (fine-grained)',   /\bgithub_pat_[A-Za-z0-9_]{50,}\b/],
  ['GitHub OAuth/Server token',   /\b(?:gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b/],
  ['OpenAI API key',              /\bsk-[A-Za-z0-9_-]{20,}\b/],
  ['Anthropic API key',           /\bsk-ant-[A-Za-z0-9_-]{20,}\b/],
  ['AWS Access Key ID',           /\bAKIA[0-9A-Z]{16}\b/],
  ['Google API key',              /\bAIza[0-9A-Za-z_-]{35}\b/],
  ['Slack token',                 /\bxox[abprs]-[0-9A-Za-z-]{10,}\b/],
  ['Stripe secret key',           /\bsk_(?:live|test)_[0-9A-Za-z]{20,}\b/],
  ['Private key block',           /-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/],
  ['JWT',                         /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/],
  ['Anywhere relay token',        /\biHboYnf4[A-Za-z0-9]{20,}\b/],
]

/** 白名单：行里含这些就放行（占位符 / 文档示例） */
const ALLOW = [
  /CHANGE_ME/i,
  /\*\*\*REDACTED/i,
  /REDACTED-TOKEN/i,
  /你的(?:中继)?令牌/,
  /your[_-]?(?:token|key|secret)/i,
  /example\.com/i,
  /<[^>]*(?:token|key|secret)[^>]*>/i,
  /placeholder/i,
  /pre-commit-secret-scan/i,
]

/** 读取 .secretsignore 的额外规则 */
function loadIgnoreFile() {
  const p = join(ROOT, '.secretsignore')
  if (!existsSync(p)) return
  for (const raw of readFileSync(p, 'utf8').split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    try {
      if (line.startsWith('pattern:')) PATTERNS.push(['.secretsignore 规则', new RegExp(line.slice(8))])
      else if (line.startsWith('allow:')) ALLOW.push(new RegExp(line.slice(6)))
    } catch { /* 忽略非法正则 */ }
  }
}

/** 要忽略的路径 */
const SKIP_PATH = /(^|\/)(node_modules|\.git|dist|dist-out|out|build|\.cache)\//
const SKIP_EXT = /\.(png|jpe?g|gif|webp|ico|icns|woff2?|ttf|eot|mp[34]|wav|zip|gz|7z|exe|dll|node|bin|asar|pak|pdf)$/i

loadIgnoreFile()

// 取暂存区文件（新增/修改/改名）
const staged = execSync('git diff --cached --name-only --diff-filter=ACMR', { encoding: 'utf8' })
  .split(/\r?\n/).map(s => s.trim()).filter(Boolean)

const findings = []

for (const file of staged) {
  const norm = file.replace(/\\/g, '/')
  if (SKIP_PATH.test('/' + norm) || SKIP_EXT.test(norm)) continue

  let content = ''
  try {
    // ⚠️ 必须用 execFileSync（数组参数、不经 shell）：以前是
    // execSync(`git show :"${file}"`)，文件名一旦包含引号 / $(…) / 反引号
    // （git 允许这类文件名），提交时就会被 shell 解释执行 —— 命令注入。
    content = execFileSync('git', ['show', `:${file}`], {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
    })
  } catch { continue }

  if (content.includes('\u0000')) continue // 二进制

  const lines = content.split(/\r?\n/)
  lines.forEach((line, i) => {
    if (ALLOW.some(re => re.test(line))) return
    for (const [name, re] of PATTERNS) {
      const m = line.match(re)
      if (m) {
        findings.push({ file, line: i + 1, rule: name, sample: mask(m[0]) })
      }
    }
  })
}

function mask(s) {
  if (s.length <= 10) return s[0] + '*'.repeat(Math.max(0, s.length - 1))
  return s.slice(0, 6) + '…' + s.slice(-4) + ` (len=${s.length})`
}

if (findings.length === 0) {
  process.exit(0)
}

console.error('')
console.error('\x1b[41m\x1b[97m  提交被阻止：检测到疑似密钥 / token  \x1b[0m')
console.error('')
for (const f of findings) {
  console.error(`  \x1b[31m✗\x1b[0m ${f.file}:${f.line}  [${f.rule}]  ${f.sample}`)
}
console.error('')
console.error('  如果这是误报，可把这些加进仓库根的 .secretsignore：')
console.error('    allow:<正则>')
console.error('  确认无误要强行提交：  git commit --no-verify')
console.error('')
process.exit(1)

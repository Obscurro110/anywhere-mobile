# ============================================================
#  Anywhere Relay 自编译版 —— 一键更新脚本  (v2)
#  ------------------------------------------------------------
#  用法：右键此文件 -> 「使用 PowerShell 运行」
#       或在本目录打开终端执行：  .\更新.ps1
#
#  原理：源码目录里有一个分支 anywhere-relay，
#        它 = 官方最新代码 + 我们的互通改动。
#        更新 = 拉官方最新 -> rebase 我们的改动 -> 编译 -> 覆盖本目录。
# ============================================================
$ErrorActionPreference = 'Stop'

# ------------------ 可修改的配置 ------------------
$SRC    = 'D:\AI\anywhere\code\anywhere-desktop-src'   # 源码目录（含 anywhere-relay 分支）
$BRANCH = 'anywhere-relay'                              # 我们的分支名
$DEST   = 'D:\AnywhereRelay'                            # 固定运行目录（本目录）
$SELF   = '更新.ps1'                                    # 本脚本文件名（覆盖时保留）
$PROXY  = 'socks5://127.0.0.1:10808'                    # 拉 GitHub 的代理；不需要就设为 ''

function Step($n, $msg) { Write-Host "==> $n  $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }

Write-Host ''
Write-Host '=============================================' -ForegroundColor Magenta
Write-Host '  Anywhere Relay  自编译版  一键更新 (v2)' -ForegroundColor Magenta
Write-Host '=============================================' -ForegroundColor Magenta

# 0) 应用是否在运行
$running = Get-Process -Name 'anywhere-desktop-relay' -ErrorAction SilentlyContinue |
           Where-Object { $_.Path -like "$DEST*" }
if ($running) {
  Warn "$DEST 下的应用正在运行，请先关闭它，否则无法覆盖文件。"
  Read-Host '关闭后按回车继续（或按 Ctrl+C 取消）'
}

if (-not (Test-Path $SRC)) { throw "源码目录不存在: $SRC" }
Set-Location $SRC

# 1) 确保在 our 分支
Step '1/7' "切换到分支 $BRANCH"
$cur = (git branch --show-current).Trim()
if ($cur -ne $BRANCH) {
  git checkout $BRANCH
  if ($LASTEXITCODE -ne 0) { throw "切换分支失败：$BRANCH 不存在？" }
}
Ok "当前分支: $BRANCH"

# 2) 拉取官方最新（顺带解除浅克隆，方便 rebase）
Step '2/7' '拉取官方最新代码'
if ($PROXY) { git -c "http.proxy=$PROXY" fetch origin --unshallow 2>$null } else { git fetch origin --unshallow 2>$null }
if ($LASTEXITCODE -ne 0) {
  if ($PROXY) { git -c "http.proxy=$PROXY" fetch origin } else { git fetch origin }
}
Ok 'fetch 完成'

# 3) rebase 我们的改动到官方最新之上
Step '3/7' '把互通改动 rebase 到官方最新之上'
git rebase origin/main
if ($LASTEXITCODE -ne 0) {
  Warn 'rebase 出现冲突（官方改动较大）。'
  Warn '已执行 git rebase --abort，源码保持原样。'
  git rebase --abort 2>$null
  Warn '请把这些冲突告诉我，我来手工合并后再更新。'
  Read-Host '按回车关闭'
  exit 1
}
Ok 'rebase 成功，代码 = 官方最新 + 互通改动'

# 4) 安装依赖
Step '4/7' '安装依赖 (pnpm install)'
pnpm install

# 5) 编译
Step '5/7' '编译 (pnpm run build)'
pnpm run build

# 6) 打包
Step '6/7' '打包 (electron-builder)'
npx electron-builder --dir --publish never "-c.electronDist=node_modules/electron/dist" "-c.directories.output=dist-out"

# 7) 覆盖到运行目录（保留本脚本自身）
Step '7/7' "覆盖到 $DEST"
if (-not (Test-Path "$SRC\dist-out\win-unpacked")) { throw '未找到打包产物 dist-out\win-unpacked' }
Get-ChildItem $DEST -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne $SELF } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
robocopy "$SRC\dist-out\win-unpacked" $DEST /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "复制失败 (robocopy 退出码 $LASTEXITCODE)" }

Write-Host ''
Write-Host '更新完成！' -ForegroundColor Green
Write-Host "运行: $DEST\anywhere-desktop-relay.exe" -ForegroundColor Green
Write-Host ''
Read-Host '按回车关闭'

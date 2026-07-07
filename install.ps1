# -*- coding: utf-8 -*-
# claude-island · install.ps1 —— 接真实 Claude 事件 + 开机自启
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-NoAutostart]
# 卸载: uninstall.ps1
param([switch]$NoAutostart)
$ErrorActionPreference = 'Stop'

$isl      = Split-Path -Parent $MyInvocation.MyCommand.Path
$emit     = Join-Path $isl 'emit.js'
$daemon   = Join-Path $isl 'daemon.ps1'
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'
$run      = Join-Path $env:USERPROFILE '.claude\hooks\claude-island'
New-Item -ItemType Directory -Force $run | Out-Null

# ---- 组装 hook 命令(hooks 在 git-bash 里跑,用 MSYS 路径) ----
function To-Msys($winPath) { '/' + $winPath.Substring(0,1).ToLower() + ($winPath.Substring(2) -replace '\\','/') }
$nodeWin = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeWin) { throw 'node 不在 PATH,先装 Node 或修 PATH' }
$hookCmd = '"' + (To-Msys $nodeWin) + '" "' + (To-Msys $emit) + '"'
Write-Output "hook 命令: $hookCmd"

# ---- 读 + 备份 settings.json ----
if (Test-Path $settings) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bak = "$settings.island-bak-$stamp"
  Copy-Item $settings $bak -Force
  Write-Output "已备份原 settings.json -> $bak"
  $s = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
  $s = [pscustomobject]@{}
  Write-Output "settings.json 不存在,将新建"
}

# ---- 合并 hooks(只追加我们的,不覆盖你已有的) ----
if (-not ($s.PSObject.Properties.Name -contains 'hooks')) {
  $s | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
$events = 'Stop','SubagentStop','Notification','PostToolUseFailure','PermissionRequest'
$entry = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $hookCmd }) }
foreach ($ev in $events) {
  $has = $false
  if ($s.hooks.PSObject.Properties.Name -contains $ev) {
    foreach ($grp in @($s.hooks.$ev)) { foreach ($h in @($grp.hooks)) { if ($h.command -eq $hookCmd) { $has = $true } } }
    if (-not $has) { $s.hooks.$ev = @(@($s.hooks.$ev) + $entry) }
  } else {
    $s.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue @($entry)
  }
  Write-Output ("hook {0}: {1}" -f $ev, $(if ($has) { '已存在,跳过' } else { '已添加' }))
}

# ---- 写回(JSON 用 UTF-8 无 BOM) ----
$json = $s | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding $false))
# 校验能否解析回来
$null = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Output "settings.json 写回并校验通过"

# ---- events.jsonl 就位 ----
$ev = Join-Path $run 'events.jsonl'
if (-not (Test-Path $ev)) { New-Item -ItemType File -Force $ev | Out-Null }

# ---- 开机自启(启动目录快捷方式) ----
if (-not $NoAutostart) {
  $startup = [Environment]::GetFolderPath('Startup')
  $lnkPath = Join-Path $startup 'ClaudeIsland.lnk'
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $sh = New-Object -ComObject WScript.Shell
  $lnk = $sh.CreateShortcut($lnkPath)
  $lnk.TargetPath = $psExe
  $lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File `"$daemon`""
  $lnk.WorkingDirectory = $isl
  $lnk.WindowStyle = 7
  $lnk.Description = 'Claude 灵动岛通知器'
  $lnk.Save()
  Write-Output "开机自启已装 -> $lnkPath"
} else {
  Write-Output "跳过开机自启(-NoAutostart)"
}

Write-Output ''
Write-Output '完成。让 hooks 生效:在 Claude Code 里打开一次 /hooks(或重启 Claude)。'

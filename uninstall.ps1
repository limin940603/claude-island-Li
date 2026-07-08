# -*- coding: utf-8 -*-
# claude-island · uninstall.ps1 —— 移除 hooks + 自启 + 停 daemon
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
$ErrorActionPreference = 'Stop'
$isl      = Split-Path -Parent $MyInvocation.MyCommand.Path
$emit     = Join-Path $isl 'emit.js'
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'

function To-Msys($winPath) { '/' + $winPath.Substring(0,1).ToLower() + ($winPath.Substring(2) -replace '\\','/') }

# ---- 停 daemon ----
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*daemon.ps1*' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -EA Stop; Write-Output "停 daemon $($_.ProcessId)" } catch {} }

# ---- 移除我们的 hooks ----
if (Test-Path $settings) {
  $s = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
  $emitMsys = To-Msys $emit
  if ($s.PSObject.Properties.Name -contains 'hooks') {
    foreach ($ev in @($s.hooks.PSObject.Properties.Name)) {
      $kept = @()
      foreach ($grp in @($s.hooks.$ev)) {
        $hs = @($grp.hooks | Where-Object { $_.command -notlike "*$emitMsys*" })
        if ($hs.Count -gt 0) { $grp.hooks = $hs; $kept += $grp }
      }
      if ($kept.Count -gt 0) { $s.hooks.$ev = $kept }
      else { $s.hooks.PSObject.Properties.Remove($ev) }
    }
    $json = $s | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-Output "已从 settings.json 移除灵动岛 hooks"
  }
}

# ---- 移除自启 ----
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeIsland.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Output "已移除开机自启" }

# ---- 移除开始菜单入口 ----
$menuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude 灵动岛.lnk'
if (Test-Path $menuLnk) { Remove-Item $menuLnk -Force; Write-Output "已移除开始菜单入口" }

Write-Output '灵动岛已卸载(源码与资产保留)。'

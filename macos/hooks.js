#!/usr/bin/env node
/*
 * claude-island · hooks.js —— 合并/移除 Claude Code settings.json 里的灵动岛 hooks
 * 用法:
 *   node hooks.js add    <settings.json 路径> <hook命令>       # 合并(先备份)
 *   node hooks.js remove <settings.json 路径> <emit.js 路径子串>  # 移除
 * 跨平台(Windows install.ps1 用 PowerShell 版;此脚本供 macOS/Linux install.sh 用)。
 */
'use strict';
const fs = require('fs');
const [, , mode, settingsPath, arg] = process.argv;
const EVENTS = ['Stop', 'SubagentStop', 'Notification', 'PostToolUseFailure', 'PermissionRequest'];

if (!mode || !settingsPath) {
  console.error('用法: node hooks.js add|remove <settings.json> <hookCmd|emitSubstr>');
  process.exit(2);
}

let s = {};
if (fs.existsSync(settingsPath)) {
  const bak = settingsPath + '.island-bak-' + Date.now();
  fs.copyFileSync(settingsPath, bak);
  console.log('已备份 -> ' + bak);
  try {
    s = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  } catch (e) {
    console.error('settings.json 解析失败,已中止(备份在 ' + bak + ')');
    process.exit(1);
  }
} else if (mode === 'remove') {
  console.log('settings.json 不存在,无需移除');
  process.exit(0);
}

if (!s.hooks || typeof s.hooks !== 'object') s.hooks = {};

if (mode === 'add') {
  const hookCmd = arg;
  for (const ev of EVENTS) {
    const arr = Array.isArray(s.hooks[ev]) ? s.hooks[ev] : [];
    const has = arr.some((g) => (g.hooks || []).some((h) => h.command === hookCmd));
    if (has) { console.log('hook ' + ev + ': 已存在,跳过'); continue; }
    arr.push({ hooks: [{ type: 'command', command: hookCmd }] });
    s.hooks[ev] = arr;
    console.log('hook ' + ev + ': 已添加');
  }
} else if (mode === 'remove') {
  const sub = arg || 'claude-island';
  for (const ev of Object.keys(s.hooks)) {
    const kept = [];
    for (const g of (Array.isArray(s.hooks[ev]) ? s.hooks[ev] : [])) {
      const hs = (g.hooks || []).filter((h) => !(h.command || '').includes(sub));
      if (hs.length) { g.hooks = hs; kept.push(g); }
    }
    if (kept.length) s.hooks[ev] = kept;
    else delete s.hooks[ev];
  }
  console.log('已移除含 "' + sub + '" 的 hooks');
} else {
  console.error('未知 mode: ' + mode);
  process.exit(2);
}

fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2));
console.log('settings.json 写回完成');

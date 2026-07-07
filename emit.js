#!/usr/bin/env node
/*
 * claude-island · emit.js  —— Claude Code hook 事件处理器
 * 读 stdin 的 hook JSON → 分类成灵动岛事件 → append 到 events.jsonl 环形缓冲(最近 N 条)。
 * 由 settings.json 的 hooks 以 async:true 调用,只写文件立即返回,不阻塞 Claude。
 * 用 node(避开 Windows 的 python3.bat shim);跨平台。
 */
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

const RING_MAX = 40; // events.jsonl 保留最近多少条
const DIR = path.join(os.homedir(), '.claude', 'hooks', 'claude-island');
const EVENTS = path.join(DIR, 'events.jsonl');

// ---- 读 stdin(hook 把事件 JSON 从 stdin 传入) ----
function readStdin() {
  try {
    const data = fs.readFileSync(0, 'utf8'); // fd 0 = stdin
    return data && data.trim() ? JSON.parse(data) : {};
  } catch (_) {
    return {};
  }
}

// cwd → 项目名(取末段;按 / 和 \ 双分隔符切,平台无关——path.basename 的平台模式在混合 shell 下不可靠)
function projectOf(cwd) {
  if (!cwd) return 'Claude';
  const parts = String(cwd).split(/[\\/]+/).filter(Boolean);
  return parts.length ? parts[parts.length - 1] : 'Claude';
}

// hook 事件 → 灵动岛状态 {state,title,sub,sound}
// state 语义化(与颜色/小熊表情解耦):
//   done(完成,绿) / authorize(需授权,蓝) / error(报错,红) / waiting(等待,琥珀) / idle(空闲,灰)
function classify(h) {
  const ev = h.hook_event_name || '';
  const project = projectOf(h.cwd);
  const tool = h.tool_name || '';
  switch (ev) {
    case 'Stop':
      return { state: 'done', title: '任务完成', sub: '', sound: 'chime' };
    case 'SubagentStop':
      return { state: 'done', title: '子代理完成', sub: '', sound: 'chime' };
    case 'PostToolUseFailure':
      return { state: 'error', title: '命令报错', sub: tool ? `工具: ${tool}` : '', sound: 'error' };
    case 'PermissionRequest':
      return { state: 'authorize', title: '需要授权', sub: tool ? `工具: ${tool}` : '', sound: 'notification' };
    case 'Notification': {
      const nt = h.notification_type || '';
      if (nt === 'permission_prompt')
        return { state: 'authorize', title: '需要授权', sub: h.message || '', sound: 'notification' };
      if (nt === 'idle_prompt')
        return { state: 'waiting', title: '等待输入', sub: '', sound: 'pop' };
      // 其它通知(auth_success 等)当轻提示,归完成态
      return { state: 'done', title: '通知', sub: h.message || nt || '', sound: 'chime' };
    }
    default:
      return { state: 'idle', title: ev || '事件', sub: '', sound: '' };
  }
}

function main() {
  const h = readStdin();
  const c = classify(h);
  const rec = {
    ts: Date.now(),
    state: c.state,
    title: c.title,
    sub: c.sub,
    sound: c.sound,
    project: projectOf(h.cwd),
    session: (h.session_id || '').slice(0, 8),
    read: false,
  };

  fs.mkdirSync(DIR, { recursive: true });

  // 读旧环形缓冲 → 追加新事件 → 截断到最近 RING_MAX 条 → 原子写回
  let lines = [];
  try {
    lines = fs.readFileSync(EVENTS, 'utf8').split('\n').filter(Boolean);
  } catch (_) { /* 首次不存在 */ }
  lines.push(JSON.stringify(rec));
  if (lines.length > RING_MAX) lines = lines.slice(lines.length - RING_MAX);

  const tmp = EVENTS + '.tmp';
  fs.writeFileSync(tmp, lines.join('\n') + '\n', 'utf8');
  fs.renameSync(tmp, EVENTS); // 原子替换,daemon 的 FileSystemWatcher 只看到完整文件
}

try { main(); } catch (_) { /* hook 永不因通知器出错而影响 Claude */ }
process.exit(0);

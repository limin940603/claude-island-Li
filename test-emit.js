/* emit.js 端到端单元测:用 child_process 直接喂 JSON 对象(无 shell 转义),读 events.jsonl 断言 */
'use strict';
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const EMIT = path.join(__dirname, 'emit.js');
const EV = path.join(os.homedir(), '.claude', 'hooks', 'claude-island', 'events.jsonl');

// 清空
try { fs.unlinkSync(EV); } catch (_) {}

// 测试用例:[hook 输入对象, 期望 {state,title,project}]
const cases = [
  [{ hook_event_name: 'Stop', cwd: 'C:\\Users\\nn517\\Desktop\\AI问老李', session_id: 'abc12345xyz' },
   { state: 'done', title: '任务完成', project: 'AI问老李' }],
  [{ hook_event_name: 'Notification', notification_type: 'permission_prompt', cwd: 'C:\\proj\\demo', tool_name: 'Bash', session_id: 'def678' },
   { state: 'authorize', title: '需要授权', project: 'demo' }],
  [{ hook_event_name: 'Notification', notification_type: 'idle_prompt', cwd: 'C:/proj/demo', session_id: 'def678' },
   { state: 'waiting', title: '等待输入', project: 'demo' }],
  [{ hook_event_name: 'PostToolUseFailure', cwd: 'C:/proj/demo', tool_name: 'Bash', session_id: 'def678' },
   { state: 'error', title: '命令报错', project: 'demo' }],
  [{ hook_event_name: 'SubagentStop', cwd: 'D:\\work\\myapp', session_id: 's9' },
   { state: 'done', title: '子代理完成', project: 'myapp' }],
];

// 逐条喂给真 emit.js(stdin = JSON.stringify,无 shell)
for (const [input] of cases) {
  execFileSync(process.execPath, [EMIT], { input: JSON.stringify(input) });
}

// 读回断言
const lines = fs.readFileSync(EV, 'utf8').trim().split('\n').filter(Boolean);
let allPass = true;
lines.forEach((l, i) => {
  const got = JSON.parse(l);
  const exp = cases[i][1];
  const pass = got.state === exp.state && got.title === exp.title && got.project === exp.project;
  if (!pass) allPass = false;
  console.log(`${pass ? 'PASS' : 'FAIL'}  #${i} state=${got.state} title=${got.title} project=${got.project}` +
    (pass ? '' : `  (期望 state=${exp.state} title=${exp.title} project=${exp.project})`));
});
console.log(`行数=${lines.length}/${cases.length}  ${allPass && lines.length === cases.length ? '✅ ALL PASS' : '❌ HAS FAIL'}`);
process.exit(allPass ? 0 : 1);

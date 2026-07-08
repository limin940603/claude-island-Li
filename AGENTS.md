# AGENTS.md · claude-island

给 AI agent(Codex 等)的入口。人看 `README.md`。

## 这是什么
给 Claude Code 的跨平台桌面通知器(Windows + macOS)。Claude 任务完成/需授权/报错/等待时,顶部一颗暖调玻璃胶囊(问号小熊)切状态弹通知+音效;点开看多会话面板。架构见 README:`hooks → node emit.js → events.jsonl → 平台 daemon`。

- Windows daemon:`daemon.ps1`(PowerShell+WPF)——**已完成、已验证、在用,是行为规格的唯一真相源**。
- macOS daemon:`macos/Sources/ClaudeIsland/main.swift`(Swift+AppKit)——基础版已在 Mac 实机构建验证通过(2026-07-08,报告 `reports/mac-verify.md`),**当前任务=同步 Windows 新功能,见下**。

---

## 🎯 当前任务 B1 · macOS 同步 Windows 新功能(给 Mac 上的 Codex)

### 背景
Mac 基础版验证合并(a522aec)之后,Windows 又落了 9 个功能提交(1f4083b→a93e5eb):设置控制台、按状态音效+试听、硬件监控、贴边隐藏、暗亮主题等。任务 = 把下列功能移植进 `macos/`,**行为规格一律以 `daemon.ps1` 为准**(各条已标行号,动手前先读对应段),两端体验一致。

**你可以自由修改 `macos/` 下任何代码**;**不要改**共享层 `emit.js` / `assets/`(两端共用、Windows 已验证),除非确认是 bug。

### 共享契约(先读,格式两端必须一致)

`config.json` 完整 schema(daemon.ps1:54-85):

```json
{
  "silent": false, "volume": 0.6, "muteStates": [], "opacity": 0.94,
  "theme": "dark", "paused": false,
  "sounds": { "done": "chime.mp3", "authorize": "notification.mp3", "error": "error.mp3", "waiting": "pop.mp3" },
  "hwMonitor": false, "edgeHide": false
}
```

- `sounds` 每键三态:`"none"`(该状态不响)/ `assets/sfx` 内置文件名 / 绝对路径(用户自选系统音,Mac 用 `/System/Library/Sounds/*.aiff`)。
- `opacity` 读入钳制 0.35–1.0;`theme` 只认 `dark|light`,非法值忽略。
- `stats.json`(daemon.ps1:93-135):`{ lastTs, days: { "yyyy-MM-dd": {done,error,authorize,waiting} } }`。`lastTs` 是已计数水位——daemon 重启会重读整个事件环形缓冲,**只有 `ts > lastTs` 的事件才计数**(防重复);只保留最近 14 天。Mac 若尚无统计,照此格式实现。

### 功能清单(按优先级做)

**P0 · 设置控制台**(daemon.ps1:639-1200 Show-Console;视觉对标 `docs/控制台概念稿v0.3.html`,浏览器打开看目标样)
- 入口两处:菜单栏菜单加「设置…」+ 展开面板右上角齿轮 ⚙。
- 卡片与控件:
  1. 常规:开机自启(launchctl load/unload 该 plist)/ 静默 / 音量滑块 0-100% / 不透明度滑块 35-100%(**拖动实时应用到胶囊**)/ 暗·亮主题分段切换(实时应用)。
  2. 按状态静音:done/authorize/error/waiting 四个开关 ↔ `muteStates` 数组(整条不弹,注意与 silent「只弹不响」语义不同,别合并)。
  3. 提示音效:四状态各一个下拉(无 + 内置 4 首 + 系统音精选)+ ▶ 试听按钮(试听走与真实播放同一条解析逻辑,选 none 试听即静音)。
  4. 统计:今日各状态计数 + 近 7 日总量趋势柱(数据源 stats.json,daemon.ps1:673-745)。
  5. 硬件监控、贴边隐藏两个开关。
- **所有改动即时写 config.json 且即时生效**,不要求重启。

**P1 · 硬件监控 hwMonitor**(daemon.ps1:556-584)
- 3 秒采样;距上次通知事件 <30 秒时让位不显示(新事件到 → 立即恢复通知显示)。
- 显示态:idle 灰环 + 灰熊,标题「系统监控」,副题 `CPU x%  ·  内存 y%`。
- Mac 采样用原生 API(`host_processor_info` / `host_statistics64`),**别 shell 出去跑 top**(功耗+延迟)。

**P1 · 贴边隐藏 edgeHide**(daemon.ps1:586-637)
- 空闲 30 秒(无事件、鼠标不在岛上、面板收起、且岛贴顶 Top≤60)→ 约 0.3s 指数缓动滑入屏幕顶边,只露 ~6px 细条。
- 细条上**悬停满 0.4 秒**才唤出(意图判定,防鼠标扫过标签栏误触);新事件 → 立即唤出;开关关掉时若处于隐藏态自动弹回。
- Mac 注意:顶部有系统菜单栏,细条应露在菜单栏下沿;若窗口 level/遮挡处理不顺,可退化为「淡出+缩成小圆点停靠」,行为语义(30s 缩/悬停唤/事件唤)不变。

**P2 · 视觉细节**
- 滑块:暖橙轨道 + 白底橙描边圆钮(概念稿 v0.3 样式)。
- 胶囊阴影:柔和大半径低透明度(参考 daemon.ps1 Apply-Style)。

**不移植(Windows 专属,勿动)**:`-RenderShot`/`-RenderClip` 离屏导出(内容生产工具);开始菜单快捷方式(Mac 有 launchd + 菜单栏,无对应物)。

### 已知坑(Windows 踩过,Mac 对应自查)
1. **可拖容器吞点击**:Windows 上标题栏 DragMove 吞掉 MouseUp,按钮全失灵,改按下阶段处理才好——Mac 控制台窗口里所有按钮/开关必须逐个点验,警惕 hitTest/mouseDown 链被拖动逻辑截胡。
2. **统计防重复**:先读 lastTs 再比对,重启不重复计数——喂同一批事件重启两次,数字必须一样。
3. 试听与真实播放共用一条音源解析,别写两套。
4. **启动恢复 pos.json 坐标必须先钳制到当前屏幕范围,越界则重置默认位**(Windows 换 4K 屏实测踩过:屏外坐标残留导致岛不可见,094bfc4 修复)——Mac 的 pos.json 恢复同样要加这道闸,顺手在换分辨率/插拔显示器场景验一遍。

### 测试与验收
喂事件用仓库根的 `test-emit.js` 或(见 git 历史里旧版 AGENTS.md 的逐条 echo 命令):

```bash
node ../test-emit.js   # 或逐条 echo '{"hook_event_name":"Stop",...}' | node ../emit.js
```

- [ ] `swift build -c release` 通过
- [ ] 控制台每项改动即写 config.json 且立即生效(逐项截图)
- [ ] 四状态音效可换、可试听;muteStates 与 silent 行为区分正确
- [ ] hwMonitor 开:空闲 30s 显示 CPU/内存,喂事件立即让位
- [ ] edgeHide 开:30s 缩回 → 悬停 0.4s 唤出 → 事件唤出 → 关掉开关自动弹回(录屏或日志为证)
- [ ] stats.json 与 Windows 同格式,重启不重复计数
- [ ] 执行报告写 `reports/mac-sync-b1.md`:改了什么 / 截图 / 仍存差异 / 遗留风险

---

## 通用红线
- 不编造、不假装跑通;报错如实暴露。
- 改动保持与 `daemon.ps1` 的行为一致;共享层(emit.js/assets)非确有 bug 不动。
- 中文注释与提交信息。

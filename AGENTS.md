# AGENTS.md · claude-island

给 AI agent(Codex 等)的入口。人看 `README.md`。

## 这是什么
给 Claude Code 的跨平台桌面通知器(Windows + macOS)。Claude 任务完成/需授权/报错/等待时,顶部一颗暖调玻璃胶囊(问号小熊)切状态弹通知+音效;点开看多会话面板。架构见 README:`hooks → node emit.js → events.jsonl → 平台 daemon`。

- Windows daemon:`daemon.ps1`(PowerShell+WPF)——**已完成、已验证、在用**。
- macOS daemon:`macos/Sources/ClaudeIsland/main.swift`(Swift+AppKit)——**见下,需要你构建验证**。

---

## 🎯 macOS 构建与验证任务(给 Mac 上的 Codex)

### 背景(重要)
`macos/` 下的 Swift 是**在 Windows 机器上盲写的,从未编译/运行过**——几乎肯定有编译错、AppKit API 签名不符、或布局/视觉问题。你在 Mac 上有完整工具链(能 `swift build`、能截图),**任务 = 让它真跑起来,修到与 Windows 版效果一致**。

**你可以自由修改 `macos/` 下的任何代码**(Swift、脚本)来修 bug、达成目标。**不要改**共享的 `emit.js` / `assets/` 逻辑(除非确认是 bug),那是两端共用、Windows 上已验证的。保持与 `daemon.ps1` 的行为一致(状态、颜色、动效、面板)。

### 前置
```bash
swift --version      # 需 Xcode 或 CLT;没有则 xcode-select --install
node --version       # 需 Node.js
```

### 步骤 1 · 构建(修所有编译错)
```bash
cd macos
swift build -c release
```
逐个修编译错,保持行为语义不变。产物:`macos/.build/release/ClaudeIsland`。

### 步骤 2 · 首次运行 + 截图
```bash
# 资产用仓库里的 assets(install 前手动指定)
./.build/release/ClaudeIsland --assets "$(cd ../assets && pwd)" &
```
预期:屏幕**顶部中央**出现一颗暖黑毛玻璃圆角胶囊,左侧圆形小熊(灰·就绪态)在**轻微呼吸**,描边环带光晕。**截图**核对。

### 步骤 3 · 喂各状态测试(每条间隔 >0.5s)
```bash
E=../emit.js
echo '{"hook_event_name":"Stop","cwd":"/Users/x/AI问老李","session_id":"t"}' | node $E ; sleep 1
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"/x/demo","tool_name":"Bash","session_id":"t"}' | node $E ; sleep 1
echo '{"hook_event_name":"PostToolUseFailure","cwd":"/x/个人网站","tool_name":"Bash","session_id":"t"}' | node $E ; sleep 1
echo '{"hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"/x/myapp","session_id":"t"}' | node $E ; sleep 1
echo '{"hook_event_name":"SubagentStop","cwd":"/x/AI问老李","session_id":"t"}' | node $E
```
预期每条:胶囊**边框环变色**(绿/蓝/红/琥珀/绿)+ **换对应表情小熊** + **弹跳一下** + **响音效** + 徽章计数。截图核对。

### 步骤 4 · 交互
- **单击**胶囊 → 向下展开面板,列最近 6 条(色条+圆熊+标题+`项目 · 相对时间`),多会话不同项目名;再点或等 8 秒收起。
- **拖动**胶囊 → 移动,位置存 `~/.claude/hooks/claude-island/pos.json`。
- **菜单栏**图标 → 菜单:静默(勾选,勾上后喂事件只弹不响)/ 打开配置文件 / 退出。

### 步骤 5 · 安装 + 真事件
```bash
bash install.sh        # 构建+拷资产+合并 settings.json hooks(先备份)+ launchd 自启
```
然后在 Claude Code 里打开一次 `/hooks`(或重启 Claude)激活。跑一个真任务 → Stop 事件 → 胶囊绿+chime = 通了。重启 Mac 验证 launchd 自启。

### 验收标准(与 Windows 版对齐)
- [ ] `swift build` 通过、无警告阻塞
- [ ] 5 状态:颜色 done绿`#2FA84F`/authorize蓝`#2B7FD4`/error红`#D64545`/waiting琥珀`#E8A24A`/idle灰`#A89F95`,各态换对应小熊
- [ ] 毛玻璃胶囊 + 圆形小熊 + 状态色**描边环 + 光晕**(不是纯边框)
- [ ] 呼吸(常态)+ 弹跳(新事件,从**中心**缩放)+ 光晕脉动
- [ ] 展开面板:多会话、相对时间、8 秒自动收起、清空/全部已读
- [ ] 音效随状态;config `silent`/`volume`/`muteStates` 生效;菜单栏静默勾选可切
- [ ] 拖动记忆位置;单实例;install/uninstall 正常;launchd 自启
- [ ] 视觉尽量对齐概念稿 `docs/灵动岛概念稿.html`(浏览器打开看目标样)

### ⚠ 重点排查区(盲写高风险,优先验证/大概率要修)
1. **NSVisualEffectView 毛玻璃**:material `.hudWindow` + `.behindWindow` + 窗口 `isOpaque=false`/`backgroundColor=.clear`/`hasShadow=true` 是否真出毛玻璃圆角+投影;不行就换 material 或退化为半透纯色层。
2. **hitTest 覆写**(PillView.hitTest 返回 self):是否让**拖动和单击都正常**、且子视图(文本)不拦截。这是点击/拖动能不能用的关键。
3. **CASpringAnimation 参数**:`damping/stiffness/initialVelocity/mass/settlingDuration` API 是否可用;弹跳是否自然。
4. **弹跳锚点**:pop 挂在 `avatarGroup`(手工 CALayer,anchorPoint 0.5)应从中心缩放;若从角落缩放,查 anchorPoint/position。
5. **layer 时机**:`avatarHost.wantsLayer=true` 后才 `.layer?.addSublayer`(已这样写,确认 layer 非 nil)。
6. **FlippedView + CALayer 坐标**:`isFlipped` 只翻转子 NSView 布局,**不翻转子 CALayer**。头像/面板里的 CALayer 都是**填满宿主 bounds 或居中对称**的,理论上不受影响;但请截图确认小熊没上下颠倒、面板行没错位。
7. **Retina 清晰度**:`contentsScale = backingScaleFactor`(已设),确认小熊不糊。
8. **窗口随内容变宽**:apply 里 `setContentSize` + `invalidateShadow`;确认胶囊宽度随标题变化、投影跟着更新、不跳位。
9. **NSSound 音量**:`s.volume` 是 Float(已转);确认能响、音量受 config 控。
10. **launchd**:plist 占位替换(`__BIN__/__ASSETS__/__LOG__`)、`launchctl load` 是否成功;`--assets` 传的是运行时目录 `~/.claude/hooks/claude-island/assets`(install.sh 已拷)。

### 报告
把「修了哪些编译错 / 改了什么 / 截图 / 仍存问题 / 与 Windows 版差异」写成执行报告(可放 `reports/` 或直接回给 Jevin)。目标是两端体验一致,之后开源。

---

## 通用红线
- 不编造、不假装跑通;报错如实暴露。
- 改动保持与 `daemon.ps1` 的行为一致;共享层(emit.js/assets)非确有 bug 不动。
- 中文注释与提交信息。

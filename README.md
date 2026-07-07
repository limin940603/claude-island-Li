# Claude 灵动岛 · claude-island

给 [Claude Code](https://claude.com/claude-code) 的**跨平台桌面通知器**(Windows + macOS)。当 Claude **任务完成 / 需要授权 / 命令报错 / 等待输入** 时,屏幕顶部一颗暖调玻璃胶囊(问号小熊头像)切换状态、弹通知 + 音效;点胶囊展开「最近消息面板」看多会话历史。灵感来自苹果灵动岛,配色走「AI问老李」品牌暖调。

> 出品:**AI问老李** · 一个讲清楚 AI 怎么真用起来的 IP。

## 特性

- **5 状态**:任务完成(绿)/ 需要授权(蓝)/ 命令报错(红)/ 等待输入(琥珀)/ 就绪(灰),每态一张对应表情的圆形小熊。
- **跨平台**:Windows(PowerShell + WPF)、macOS(Swift + AppKit 原生),共享事件层与资产。
- **接真实事件**:通过 Claude Code hooks 自动驱动,无需盯终端。
- **动效**:小熊常态呼吸、新事件弹跳、状态色光晕脉动。
- **展开面板**:最近 6 条、多会话(按项目名区分)、相对时间、未读徽章、8 秒自动收起。
- **配置**:静默(只弹不响)、音量、按状态静音;菜单栏/托盘一键切换。
- **开机自启**、拖动记忆位置、单实例。

## 架构

```
Claude Code 事件
  → ~/.claude/settings.json 的 hooks(node emit.js)
    → emit.js  读 stdin 的 hook JSON → 分类 → append 到 events.jsonl(最近 40 条环形缓冲)
      → 平台 daemon 轮询 events.jsonl 并呈现:
         · Windows:daemon.ps1(PowerShell 5.1 + WPF,运行时 XamlReader,零安装)
         · macOS:  ClaudeIsland(Swift + AppKit,NSPanel + Core Animation)
```

**共享**(两端复用):`emit.js`、`events.jsonl` 格式、`config.json` 格式、`assets/`(5 张小熊 + 音效)、状态语义与配色。IPC 用文件监听(events.jsonl),不占端口。运行时文件在 `~/.claude/hooks/claude-island/`。

## 状态映射

| Claude hook | 判据 | 状态 | 颜色 | 小熊 | 音效 |
|---|---|---|---|---|---|
| Stop / SubagentStop | — | done 任务完成 | 绿 `#2FA84F` | 竖赞月牙眼 | chime |
| Notification | `permission_prompt` | authorize 需要授权 | 蓝 `#2B7FD4` | 举爪请示 | notification |
| PermissionRequest | — | authorize 需要授权 | 蓝 | 举爪请示 | notification |
| PostToolUseFailure | — | error 命令报错 | 红 `#D64545` | 捂脸冒汗 | error |
| Notification | `idle_prompt` | waiting 等待输入 | 琥珀 `#E8A24A` | 托腮问号 | pop |
| (空闲默认) | — | idle 就绪 | 灰 `#A89F95` | 半眯眼 | — |

## 安装 · Windows

```powershell
cd windows-or-repo-root
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
# 只接事件不加自启:  ... -File install.ps1 -NoAutostart
```

装完在 Claude Code 里打开一次 `/hooks`(或重启 Claude)让 hooks 生效。

## 安装 · macOS

前置:Xcode 命令行工具(`xcode-select --install`,提供 `swift`)+ Node.js。

```bash
cd macos
bash install.sh        # 自动 swift build + 拷资产 + 合并 hooks + launchd 自启
```

装完同样在 Claude Code 里打开一次 `/hooks`(或重启)。未签名二进制若被 Gatekeeper 拦,`xattr -dr com.apple.quarantine .build/release/ClaudeIsland`。

## 配置

`~/.claude/hooks/claude-island/config.json`(菜单栏/托盘可改,或手动编辑):

```json
{ "silent": false, "volume": 0.6, "muteStates": [] }
```

- `silent`:静默,弹但不响。
- `volume`:音量 0–1。
- `muteStates`:完全忽略的状态,如 `["waiting"]` 就不再被「等待输入」打扰。

## 用法

- **拖动**胶囊 = 移动位置(记忆到 `pos.json`)。
- **单击**胶囊 = 展开/收起最近消息面板(8 秒无操作自动收起)。
- 菜单栏(mac)/托盘(win):静默切换、打开配置、退出。

## 卸载

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```
```bash
# macOS
bash macos/uninstall.sh
```

## 目录结构

```
claude-island/
  emit.js  test-emit.js        共享:hook 事件处理器 + 单测
  assets/  bear-*.png  sfx/     共享:5 态小熊 + 音效
  daemon.ps1                    Windows daemon(WPF)
  install.ps1  uninstall.ps1    Windows 安装/卸载
  macos/
    Package.swift  Sources/     macOS daemon(Swift/AppKit)
    build.sh  install.sh  uninstall.sh  hooks.js
    com.ailaoli.claude-island.plist.template
  docs/                         设计概念稿等
  AGENTS.md                     给 AI agent(Codex 等)的构建/验证入口
```

## 开发 / 构建

- **Windows**:直接改 `daemon.ps1`(PowerShell 5.1;改后需重存 UTF-8 **带 BOM**,否则中文按 GBK 读会崩)。
- **macOS**:`cd macos && swift build -c release`,产 `.build/release/ClaudeIsland`;手动跑 `./.build/release/ClaudeIsland --assets ../assets`。
- 视觉概念稿:`docs/` 下的 HTML(baoyu-design 产)。

## 已知坑

- **Windows**:PS 5.1 按 GBK 读无 BOM 的 `.ps1` → 中文乱码崩;圆形头像须用 `Ellipse+ImageBrush`(非 `Border+Clip`);hook 命令走 git-bash,node 用 MSYS 路径。
- **macOS**:未签名 app 首次被 Gatekeeper 拦;NSPanel 浮动层级/毛玻璃/CALayer 点击穿透等细节见 `AGENTS.md`。

## 致谢

架构与状态设计参考 [Peon-Ping](https://github.com/PeonPing/peon-ping) 的 macOS dock 模式。

## License

MIT © 2026 AI问老李 (Jevin Li)。见 [LICENSE](LICENSE)。

# macOS 灵动岛构建验证报告

时间: 2026-07-08 07:24 Asia/Shanghai

## 结论

macOS 版已在本机完成构建、首次运行、5 状态事件、展开面板、拖动记忆、安装脚本、launchd 启动与共享事件层测试。当前已安装到 `~/.claude/hooks/claude-island/`，launchd label 为 `com.ailaoli.claude-island`。

## 修复内容

1. `macos/Sources/ClaudeIsland/main.swift`
   - 修复编译错误: `FlippedView` 原来是 `final class`，但 `PillView` 需要继承它；改为普通 `class`。
   - 修复胶囊点击命中: `hitTest(_:)` 的 `point` 本来就是本视图坐标，原逻辑再次 `convert` 会导致自动/真实点击判断不稳；改为 `bounds.contains(point)`。
   - 修复首次配置文件体验: `Config.load()` 在 `config.json` 缺失或损坏时会写入默认 `{ silent:false, volume:0.6, muteStates:[] }`，避免菜单“打开配置文件”前文件不存在。

2. `macos/uninstall.sh`
   - 修复卸载 hook 残留: macOS 安装的 hook 命令指向当前仓库 `emit.js`，原卸载匹配 `"claude-island/emit.js"` 移不掉；改为匹配 `$ROOT/emit.js`，并用临时 settings 副本验证 5 类 hook 均可移除。

## 验证结果

- 前置工具:
  - Swift: Apple Swift 6.3.3, target `arm64-apple-macosx26.0`
  - Node: `v25.9.0`
- 构建:
  - `cd macos && swift build -c release` 通过。
  - 产物: `macos/.build/release/ClaudeIsland`
- 首次运行:
  - `./.build/release/ClaudeIsland --assets "$(cd ../assets && pwd)"` 可启动。
  - 顶部胶囊、毛玻璃、圆形小熊、状态环、徽章显示正常。
- 5 状态测试:
  - `Stop` -> done 绿。
  - `Notification permission_prompt` -> authorize 蓝。
  - `PostToolUseFailure` -> error 红。
  - `Notification idle_prompt` -> waiting 琥珀。
  - `SubagentStop` -> done 绿。
- 面板:
  - CGEvent 点击胶囊后展开成功。
  - 最近消息、多项目名、相对时间、清空/全部已读区域显示正常。
- 拖动:
  - CGEvent 拖动后写入 `~/.claude/hooks/claude-island/pos.json`，验证值: `{"x":1019,"y":915}`。
- 安装:
  - `bash macos/install.sh` 通过。
  - assets 已拷贝到 `~/.claude/hooks/claude-island/assets`。
  - `~/.claude/settings.json` 已备份，安装时备份为 `~/.claude/settings.json.island-bak-1783466618911`；本报告目录也保留了安装前副本 `reports/settings.before-mac-install.json`。
  - 5 类 hooks 每类 1 条: `Stop` / `SubagentStop` / `Notification` / `PostToolUseFailure` / `PermissionRequest`。
  - launchd plist 已安装到 `~/Library/LaunchAgents/com.ailaoli.claude-island.plist`。
  - launchd 启动进程验证通过，参数为 `ClaudeIsland --assets ~/.claude/hooks/claude-island/assets`。
- 安装后事件:
  - 再喂 `permission_prompt`，launchd 启动的 daemon 成功切到蓝色授权态。
- 共享事件层:
  - `node test-emit.js` 全部通过，输出 `行数=5/5  ✅ ALL PASS`。

## 截图

> 合并注(2026-07-08):截图为全桌面截屏含隐私信息,不入仓库,原件保留在 Drive 交接包 `Codex\mac 老李灵动岛\reports\`。开源前如需展示图,另做脱敏截图。

- 首次运行: `reports/mac-island-idle.png`
- 5 状态后: `reports/mac-island-states.png`
- 面板展开: `reports/mac-island-panel-cgevent.png`
- 拖动后: `reports/mac-island-dragged.png`
- 安装后事件: `reports/mac-island-installed-event.png`

## 未完成/差异

- 未做重启 Mac 后自启验证；当前仅验证了 `launchctl load` 后进程正常启动。
- 音效是否实际听感合适只做了运行路径验证，未做分贝/录音级验证。
- macOS 首次 launchd 启动会触发系统“App 后台活动”提示，这是 macOS 系统行为，不是应用崩溃。


#!/usr/bin/env bash
# claude-island · macOS 卸载:停 daemon + 移 hooks + 删 launchd(保留源码资产)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SETTINGS="$HOME/.claude/settings.json"
PLIST="$HOME/Library/LaunchAgents/com.ailaoli.claude-island.plist"

launchctl unload "$PLIST" 2>/dev/null || true
[ -f "$PLIST" ] && rm -f "$PLIST" && echo "已移除 launchd 自启"
pkill -f "ClaudeIsland" 2>/dev/null || true
rm -f "$HOME/.claude/hooks/claude-island/.daemon.pid" 2>/dev/null || true

NODE="$(command -v node || true)"
if [ -n "$NODE" ]; then
  node "$HERE/hooks.js" remove "$SETTINGS" "$ROOT/emit.js" || true
fi
echo "灵动岛已卸载(源码与资产保留)。"

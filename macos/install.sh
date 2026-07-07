#!/usr/bin/env bash
# claude-island · macOS 安装:构建 + 拷资产 + 合并 settings.json hooks + launchd 自启
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"          # .../macos
ROOT="$(cd "$HERE/.." && pwd)"                  # .../claude-island
RUN="$HOME/.claude/hooks/claude-island"
SETTINGS="$HOME/.claude/settings.json"
EMIT="$ROOT/emit.js"
BIN="$HERE/.build/release/ClaudeIsland"
PLIST="$HOME/Library/LaunchAgents/com.ailaoli.claude-island.plist"

mkdir -p "$RUN/assets" "$HOME/Library/LaunchAgents"

# 1. node 必须有(hook + 合并脚本都用)
NODE="$(command -v node || true)"
[ -z "$NODE" ] && { echo "找不到 node,请先安装 Node.js"; exit 1; }

# 2. 构建(若无二进制)
if [ ! -x "$BIN" ]; then
  echo "未见二进制,开始构建..."
  ( cd "$HERE" && swift build -c release )
fi
[ -x "$BIN" ] || { echo "构建失败,$BIN 不存在"; exit 1; }

# 3. 拷资产到运行时目录(daemon 自包含,不依赖仓库位置)
cp -R "$ROOT/assets/." "$RUN/assets/"
echo "资产已拷到 $RUN/assets"

# 4. events.jsonl 就位
[ -f "$RUN/events.jsonl" ] || : > "$RUN/events.jsonl"

# 5. 合并 hooks(mac hook 命令:绝对 node 路径 + emit.js)
HOOKCMD="\"$NODE\" \"$EMIT\""
node "$HERE/hooks.js" add "$SETTINGS" "$HOOKCMD"

# 6. launchd 自启
sed -e "s|__BIN__|$BIN|g" -e "s|__ASSETS__|$RUN/assets|g" -e "s|__LOG__|$RUN/daemon.log|g" \
    "$HERE/com.ailaoli.claude-island.plist.template" > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "launchd 自启已装 -> $PLIST"

echo ""
echo "完成。让 hooks 生效:在 Claude Code 里打开一次 /hooks(或重启 Claude)。"
echo "手动起/停:launchctl load|unload \"$PLIST\""

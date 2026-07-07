#!/usr/bin/env bash
# 构建 macOS 灵动岛可执行文件
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
swift build -c release
echo "构建完成: $HERE/.build/release/ClaudeIsland"

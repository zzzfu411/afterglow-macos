#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TEAM="${1:-}"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "完整 Xcode 尚不可用。安装后用 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer 运行此脚本。" >&2
  exit 2
fi
if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "用法：scripts/build-xcode.sh YOUR_TEAM_ID；传入真实的 10 位 Apple Development Team ID。" >&2
  exit 2
fi
xcodebuild -project "$ROOT/Afterglow.xcodeproj" -scheme Afterglow \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build/xcode" DEVELOPMENT_TEAM="$TEAM" build
echo "$ROOT/.build/xcode/Build/Products/Debug/Afterglow.app"
echo "启动一次宿主 App，再到桌面 → 编辑小组件 → 留白。"

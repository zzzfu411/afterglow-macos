#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/render"
mkdir -p "$BUILD/module-cache"
swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Preview/RenderIcon.swift" -o "$BUILD/RenderIcon"
"$BUILD/RenderIcon" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ROOT/Preview/AppIcon.icns"

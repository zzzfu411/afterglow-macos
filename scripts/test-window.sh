#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/window-tests"
mkdir -p "$BUILD/module-cache"
swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Shared/FocusTodo.swift" "$ROOT/Shared/FocusState.swift" "$ROOT/Shared/FocusStore.swift" "$ROOT/Shared/TodoWidgetSnapshot.swift" "$ROOT/Shared/FocusViews.swift" \
  "$ROOT/App/NativeMaterial.swift" "$ROOT/App/FocusLayout.swift" \
  "$ROOT/Tests/WindowBehaviorTests.swift" -o "$BUILD/WindowBehaviorTests"
"$BUILD/WindowBehaviorTests"

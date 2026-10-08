#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/runtime-tests"
mkdir -p "$BUILD/module-cache"
swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Shared/FocusTodo.swift" "$ROOT/Shared/FocusState.swift" "$ROOT/Shared/FocusStore.swift" "$ROOT/Shared/TodoWidgetSnapshot.swift" \
  "$ROOT/App/FocusReminders.swift" "$ROOT/App/TodoReminders.swift" \
  "$ROOT/App/FocusStoreObservation.swift" "$ROOT/App/TodoPresentation.swift" "$ROOT/App/TodoTransfer.swift" \
  "$ROOT/App/FocusModel.swift" "$ROOT/Tests/RuntimeTests.swift" \
  -o "$BUILD/RuntimeTests"
"$BUILD/RuntimeTests"

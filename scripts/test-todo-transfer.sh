#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/todo-transfer-tests"
mkdir -p "$BUILD/module-cache"
swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Shared/FocusTodo.swift" "$ROOT/Shared/FocusState.swift" "$ROOT/Shared/FocusStore.swift" \
  "$ROOT/App/TodoTransfer.swift" "$ROOT/Tests/TodoTransferTests.swift" \
  -o "$BUILD/TodoTransferTests"
"$BUILD/TodoTransferTests"

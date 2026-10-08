#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/widget-snapshot-tests"
mkdir -p "$BUILD/module-cache"
swiftc -swift-version 5 -parse-as-library -D MORO_WIDGET_SNAPSHOT_TESTS \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Shared/FocusTodo.swift" "$ROOT/Shared/FocusState.swift" "$ROOT/Shared/FocusStore.swift" \
  "$ROOT/Shared/TodoWidgetSnapshot.swift" "$ROOT/Widget/AfterglowWidget.swift" \
  "$ROOT/Tests/WidgetSnapshotTests.swift" -o "$BUILD/WidgetSnapshotTests"
"$BUILD/WidgetSnapshotTests"

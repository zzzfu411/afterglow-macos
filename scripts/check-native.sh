#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/check"
mkdir -p "$BUILD/module-cache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SHARED=("$ROOT/Shared/FocusState.swift" "$ROOT/Shared/FocusStore.swift" "$ROOT/Shared/FocusViews.swift")
FLAGS=(-swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" -module-cache-path "$BUILD/module-cache")
swiftc "${FLAGS[@]}" -typecheck "${SHARED[@]}" "$ROOT"/App/*.swift "$ROOT/Widget/TimerIntents.swift"
swiftc "${FLAGS[@]}" -D AFTERGLOW_WIDGET -application-extension "${SHARED[@]}" "$ROOT/Widget/TimerIntents.swift" "$ROOT/Widget/AfterglowWidget.swift" -o "$BUILD/AfterglowWidgets"
echo "App typecheck and WidgetKit extension compile/link passed."
echo "Desktop registration and AppIntent execution still require the signed Xcode build."

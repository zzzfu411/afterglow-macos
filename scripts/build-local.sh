#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/local"
APP="$BUILD/Moro.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/module-cache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Shared/FocusTodo.swift" "$ROOT/Shared/FocusState.swift" "$ROOT/Shared/FocusStore.swift" \
  "$ROOT/Shared/FocusViews.swift" "$ROOT/App/FocusLayout.swift" "$ROOT/App/FocusWindow.swift" "$ROOT/App/FocusTodosView.swift" "$ROOT/App/FocusSettings.swift" "$ROOT/App/NativeMaterial.swift" \
  "$ROOT/App/FocusModel.swift" "$ROOT/App/FocusReminders.swift" "$ROOT/App/FocusStoreObservation.swift" \
  "$ROOT/App/AfterglowApp.swift" -o "$APP/Contents/MacOS/Moro"
cp "$ROOT/Preview/LocalInfo.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Preview/AppIcon.icns" ]]; then
  cp "$ROOT/Preview/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"
echo "$APP"
echo "Local app built. This build does not install a WidgetKit extension."

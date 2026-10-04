#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/smoke"
APP="$BUILD/留白检查.app"
mkdir -p "$APP/Contents/MacOS" "$BUILD/module-cache"
swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path "$BUILD/module-cache" \
  "$ROOT"/Shared/*.swift "$ROOT/App/FocusWindow.swift" "$ROOT/App/FocusTodosView.swift" "$ROOT/App/FocusSettings.swift" "$ROOT/App/FocusLayout.swift" \
  "$ROOT/App/NativeMaterial.swift" "$ROOT/App/FocusModel.swift" "$ROOT/App/FocusReminders.swift" \
  "$ROOT/App/FocusStoreObservation.swift" "$ROOT/Tests/SmokeApp.swift" \
  -o "$APP/Contents/MacOS/AfterglowSmoke"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.afterglow.smoke</string>
<key>CFBundleName</key><string>留白检查</string>
<key>CFBundleExecutable</key><string>AfterglowSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"

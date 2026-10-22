#!/bin/bash
# Builds "Machine Mark.app" into build/. Needs only the Xcode command line
# tools (xcode-select --install).
#   ./build.sh            build
#   ./build.sh install    build and copy to /Applications, then open it
#   ./build.sh run        build and open the window straight away
set -euo pipefail

cd "$(dirname "$0")"
app="build/Machine Mark.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework WebKit -framework Carbon -framework IOKit \
  Sources/*.swift -o "$app/Contents/MacOS/MachineMark"

cp -R web "$app/Contents/Resources/web"
rm -f "$app/Contents/Resources/web/sample.json"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Machine Mark</string>
  <key>CFBundleDisplayName</key><string>Machine Mark</string>
  <key>CFBundleIdentifier</key><string>io.github.macos-machine-mark</string>
  <key>CFBundleExecutable</key><string>MachineMark</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "Built $app"

case "${1:-}" in
  install)
    pkill -x MachineMark 2>/dev/null || true
    rm -rf "/Applications/Machine Mark.app"
    cp -R "$app" /Applications/
    # Only the installed copy, so Spotlight doesn't list the app twice.
    rm -rf build
    open "/Applications/Machine Mark.app"
    echo "Installed to /Applications. Press ⌃⌥⌘A, or use the menu bar icon."
    ;;
  run)
    pkill -x MachineMark 2>/dev/null || true
    open "$app"
    ;;
esac

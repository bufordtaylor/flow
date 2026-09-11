#!/bin/sh
# Assemble build/Flow.app from the SwiftPM release binary and sign it.
set -e
cd "$(dirname "$0")/.."
BIN_DIR=$(swift build -c release --show-bin-path)
APP=build/Flow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Flow" "$APP/Contents/MacOS/Flow"
cp Resources/AppIcon.icns Resources/start.aiff Resources/stop.aiff "$APP/Contents/Resources/"
# The Settings "Test" buttons use these.
cp fixtures/hello_world.wav fixtures/transcripts/sample.txt "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Flow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.yourname.flow</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Flow</string>
  <key>CFBundleDisplayName</key><string>Flow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Flow listens only while you hold the hotkey. Audio is transcribed on this Mac and never leaves it.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
echo "APPL????" > "$APP/Contents/PkgInfo"

# Sign with the "Flow Dev" identity when it exists so the Accessibility grant survives rebuilds.
# An ad hoc signature changes with every build, and macOS silently drops the grant each time.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Flow Dev"'; then
  IDENTITY="Flow Dev"
else
  IDENTITY="-"
  echo "warning: no 'Flow Dev' signing identity; signing ad hoc. Every rebuild will lose the Accessibility grant." >&2
  echo "         Run scripts/make_signing_cert.sh once to fix that." >&2
fi
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"

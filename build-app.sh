#!/usr/bin/env bash
set -euo pipefail
# Build AgentBench.app from the Swift package (no Xcode required).
# Usage: ./build-app.sh [--release|--debug]

cd "$(dirname "$0")"
CONFIG="${1:---release}"
MODE="release"; [[ "$CONFIG" == "--debug" ]] && MODE="debug"

echo "▸ swift build ($MODE)…"
if [[ "$MODE" == "release" ]]; then
  swift build -c release
else
  swift build
fi

BIN=".build/$MODE/AgentBench"
APP="build/AgentBench.app"
CONTENTS="$APP/Contents"

echo "▸ 打包 $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/AgentBench"

# app icon (generate if missing)
[[ -f Resources/AppIcon.icns ]] || ./Tools/make-icns.sh
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentBench</string>
  <key>CFBundleDisplayName</key><string>AgentBench</string>
  <key>CFBundleIdentifier</key><string>app.agentbench.mac</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>CFBundleShortVersionString</key><string>1.0.6</string>
  <key>CFBundleExecutable</key><string>AgentBench</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>AgentBench · 模型评测工具</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc sign so it launches without quarantine prompts on the build machine.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ 完成: $APP"
echo "  运行: open $APP"

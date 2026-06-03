#!/usr/bin/env bash
set -euo pipefail
# Build → sign (Developer ID + hardened runtime) → DMG → notarize → staple.
# Produces a DMG you can send to anyone; it opens without Gatekeeper warnings.
cd "$(dirname "$0")"

# pinned by hash (two identities share the same name → name would be ambiguous)
DEVID="${AGENTBENCH_SIGN_ID:-9E96E6F329CAC93BD47EBD01100ABD51C32A4D1B}"
PROFILE="siku"
VERSION="1.0.6"
APP="build/AgentBench.app"
DMG="build/AgentBench-$VERSION.dmg"

echo "▸ 1/6 构建 .app（含图标）"
./build-app.sh --release

echo "▸ 2/6 签名（Developer ID + Hardened Runtime + 时间戳）"
codesign --force --deep --options runtime --timestamp \
  --sign "$DEVID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "  签名主体: $(codesign -dvv "$APP" 2>&1 | grep Authority | head -1)"

echo "▸ 3/6 打 DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/AgentBench.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AgentBench" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$DEVID" "$DMG" || true

echo "▸ 4/6 公证（notarytool, profile=$PROFILE，等待 Apple 处理…）"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "▸ 5/6 staple DMG"
xcrun stapler staple "$DMG"

echo "▸ 6/6 staple .app（便于解压后离线也通过）"
xcrun stapler staple "$APP" || true

echo
echo "✓ 完成: $DMG"
echo "  Gatekeeper 校验:"
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/    /' || true
echo "  直接把这个 DMG 发给朋友即可。"

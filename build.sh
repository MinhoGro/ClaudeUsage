#!/bin/bash
# Build ClaudeUsage.app (menu-bar app + WidgetKit widget) via XcodeGen + xcodebuild.
#
# Signing:
#   • Set DEVELOPMENT_TEAM=XXXXXXXXXX, or let this script auto-detect the Team ID
#     from an "Apple Development" certificate in your keychain (a free Apple ID
#     works — add it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates).
#   • A real Team-ID signature is REQUIRED for the native widget to appear in the
#     macOS "Edit Widgets" gallery. Without one, the script still produces an
#     ad-hoc build: the menu-bar app + floating widget work, but the gallery
#     widget will not (macOS purges descriptors of untrusted extensions).
#
# Output: ./build/ClaudeUsage.app
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

command -v xcodegen >/dev/null || { echo "✗ 需要 XcodeGen: brew install xcodegen" >&2; exit 1; }
[ -f AppIcon.icns ] || ./make-icon.sh

# ── Resolve signing identity ─────────────────────────────────────
TEAM="${DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
         | openssl x509 -noout -subject 2>/dev/null \
         | sed -nE 's/.*OU *= *([A-Z0-9]{10}).*/\1/p' | head -1)
fi
SIGN_ID="-"
if [ -n "$TEAM" ]; then
  SIGN_ID=$(security find-identity -p codesigning 2>/dev/null \
            | grep -E "Apple Development|Developer ID Application" \
            | head -1 | sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}) .*/\1/p')
  [ -z "$SIGN_ID" ] && SIGN_ID="-"
fi

echo "▶ XcodeGen: 生成 .xcodeproj"
xcodegen generate --spec project.yml >/dev/null

echo "▶ xcodebuild"
if [ -n "$TEAM" ] && [ "$SIGN_ID" != "-" ]; then
  echo "  签名身份 Team: $TEAM"
  xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
    -derivedDataPath .xcodegen/dd -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" build 2>&1 | tail -12
else
  echo "  ⚠ 未找到 Apple Development 证书 → ad-hoc 构建（原生小组件画廊将不可用）"
  xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
    -derivedDataPath .xcodegen/dd \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -12
fi

APP=".xcodegen/dd/Build/Products/Release/ClaudeUsage.app"
[ -d "$APP" ] || { echo "✗ 构建失败，未找到 $APP" >&2; exit 1; }
rm -rf build; mkdir -p build
cp -R "$APP" build/ClaudeUsage.app

# XcodeGen doesn't populate Contents/Resources — restore the icon + statusLine
# hook (Info.plist already references CFBundleIconFile=AppIcon), then re-seal.
RES="build/ClaudeUsage.app/Contents/Resources"
mkdir -p "$RES"
cp AppIcon.icns "$RES/AppIcon.icns"
cp statusline.py "$RES/statusline.py"; chmod +x "$RES/statusline.py"
codesign --force --sign "$SIGN_ID" build/ClaudeUsage.app >/dev/null 2>&1 || true

echo "✓ 已构建: build/ClaudeUsage.app"
codesign -dvvv build/ClaudeUsage.app/Contents/PlugIns/ClaudeUsageWidget.appex 2>&1 \
  | grep -iE "Authority=Apple Develop|Authority=Developer ID|TeamIdentifier|Signature=adhoc" | head -3
echo "→ 安装: cp -R build/ClaudeUsage.app /Applications/ && open /Applications/ClaudeUsage.app"

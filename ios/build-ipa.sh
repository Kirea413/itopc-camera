#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
PACKAGE_DIR="$BUILD_DIR/package"
OUTPUT_PATH="$BUILD_DIR/iToPC-unsigned.ipa"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen が必要です。macOSで 'brew install xcodegen' を実行してください。" >&2
  exit 1
fi

cd "$SCRIPT_DIR"
xcodegen generate --spec project.yml

xcodebuild \
  -project iToPC.xcodeproj \
  -scheme iToPC \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/iToPC.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ビルド済みアプリが見つかりません: $APP_PATH" >&2
  exit 1
fi

CAMERA_USAGE_DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$APP_PATH/Info.plist")"
LOCAL_NETWORK_USAGE_DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$APP_PATH/Info.plist")"
if [[ -z "$CAMERA_USAGE_DESCRIPTION" || -z "$LOCAL_NETWORK_USAGE_DESCRIPTION" ]]; then
  echo "ビルド済みInfo.plistにプライバシー利用目的がありません。" >&2
  exit 1
fi

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/Payload"
cp -R "$APP_PATH" "$PACKAGE_DIR/Payload/"
rm -f "$OUTPUT_PATH"
(cd "$PACKAGE_DIR" && /usr/bin/zip -qry "$OUTPUT_PATH" Payload)

echo "未署名IPAを作成しました: $OUTPUT_PATH"
echo "SideloadlyでこのIPAを選び、Apple IDで署名してiPhoneへ導入してください。"

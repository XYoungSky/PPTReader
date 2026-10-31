#!/bin/zsh
# 编译并打包 PPTReader.app。用法：
#   ./scripts/build-app.sh            # 生成 build/PPTReader.app
#   ./scripts/build-app.sh --install  # 同时复制到 /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/PPTReader.app"

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PPTReader" "$APP/Contents/MacOS/PPTReader"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Web "$APP/Contents/Resources/Web"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
# 本地使用的临时签名（ad-hoc），无需开发者账号
codesign --force --deep --sign - "$APP" >/dev/null

echo "✅ 已生成 $APP（$(du -sh "$APP" | cut -f1)）"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/PPTReader.app"
  cp -R "$APP" /Applications/
  echo "✅ 已安装到 /Applications/PPTReader.app"
fi

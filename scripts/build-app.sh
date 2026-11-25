#!/bin/zsh
# 编译并打包 PPTReader.app。用法：
#   ./scripts/build-app.sh            # 生成 build/Products.noindex/PPTReader.app
#   ./scripts/build-app.sh --install  # 同时复制到 /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

# 构建副本不参与 Spotlight / 应用搜索，正式入口固定在 /Applications。
APP="build/Products.noindex/PPTReader.app"

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

# 在不受 iCloud 同步的临时目录里组装和签名：项目放在同步的文件夹（如桌面）里时，
# 系统可能在 xattr -cr 之后、codesign 之前又给文件加上扩展属性，签名就会偶尔失败。
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pptreader-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
STAGED="$STAGE/PPTReader.app"

mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"
cp "$BIN_DIR/PPTReader" "$STAGED/Contents/MacOS/PPTReader"
cp Resources/Info.plist "$STAGED/Contents/Info.plist"
cp -R Resources/Web "$STAGED/Contents/Resources/Web"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$STAGED/Contents/Resources/AppIcon.icns"

# Finder 在资源目录里留下的 .DS_Store 不放进应用包
find "$STAGED" -name .DS_Store -delete
xattr -cr "$STAGED"
# 有固定的自签名证书（./scripts/signing.sh create）就用它：应用的身份不随构建变化，
# 升级后钥匙串和麦克风的授权都还有效。没有就退回临时签名（ad-hoc），每次升级都要重新允许。
SIGN_KEYCHAIN="$HOME/Library/Keychains/PPTReader-Signing.keychain-db"
if SIGN_ID=$(./scripts/signing.sh unlock 2>/dev/null); then
  codesign --force --deep --timestamp=none --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_ID" "$STAGED" >/dev/null
  SIGNED_WITH="证书 PPTReader Signing"
else
  codesign --force --deep --sign - "$STAGED" >/dev/null
  SIGNED_WITH="临时签名（没有固定证书，升级后要重新允许钥匙串；运行 ./scripts/signing.sh create 生成）"
fi
codesign --verify --deep --strict "$STAGED"

rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto "$STAGED" "$APP"
echo "✅ 已生成 $APP（$(du -sh "$APP" | cut -f1)，$SIGNED_WITH）"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/PPTReader.app"
  ditto "$STAGED" /Applications/PPTReader.app
  echo "✅ 已安装到 /Applications/PPTReader.app"
fi

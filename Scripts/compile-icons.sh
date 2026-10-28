#!/bin/zsh
# 图形或玻璃参数修改后运行一次；普通构建直接使用已编译资源。
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$ICON_BUILD_DIR"' EXIT
mkdir -p "$ICON_BUILD_DIR/native" "$ICON_BUILD_DIR/AppIcon.iconset"
xcrun actool --compile "$ICON_BUILD_DIR/native" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$ICON_BUILD_DIR/IconInfo.plist" Resources/AppIcon.icon
[[ -s "$ICON_BUILD_DIR/native/Assets.car" ]] || { echo "未生成系统图标资源" >&2; exit 1; }
for entry in '16 icon_16x16' '32 icon_16x16@2x' '32 icon_32x32' '64 icon_32x32@2x' \
    '128 icon_128x128' '256 icon_128x128@2x' '256 icon_256x256' '512 icon_256x256@2x' \
    '512 icon_512x512' '1024 icon_512x512@2x'; do
    size=${entry%% *}
    name=${entry#* }
    sips -s format png -z "$size" "$size" Resources/AppIcon.png \
        --out "$ICON_BUILD_DIR/AppIcon.iconset/$name.png" >/dev/null
done
iconutil -c icns "$ICON_BUILD_DIR/AppIcon.iconset" -o "$ICON_BUILD_DIR/AppIcon.icns"
cp -X "$ICON_BUILD_DIR/native/Assets.car" Resources/Assets.car
cp -X "$ICON_BUILD_DIR/AppIcon.icns" Resources/AppIcon.icns
printf '%s\n' '已更新系统分层图标和旧版兼容图标。'

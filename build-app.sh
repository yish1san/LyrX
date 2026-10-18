#!/bin/zsh
# 构建 LyrX，每次创建独立发布文件夹，App 名称保持 LyrX.app。
set -euo pipefail
cd "$(dirname "$0")"
VERSION="1.0.0"
BUILD_NUMBER="142"
RELEASE_DIR="${1:-releases/LyrX-${VERSION}-$(date +%Y%m%d-%H%M%S)}"
if [[ -e "$RELEASE_DIR" ]]; then
    echo "输出目录已存在，请使用新文件夹：$RELEASE_DIR" >&2
    exit 1
fi
swift build -c release --disable-sandbox \
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/LyrX" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/LyrX"
APP="$RELEASE_DIR/LyrX.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X .build/release/LyrX "$APP/Contents/MacOS/LyrX"
cp -X Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -X LICENSE "$APP/Contents/Resources/LICENSE"
# 先移除调试和本地符号，再签名；Swift 的运行时元数据保持可用。
strip -S -x "$APP/Contents/MacOS/LyrX"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LyrX</string>
    <key>CFBundleDisplayName</key><string>LyrX</string>
    <key>CFBundleIdentifier</key><string>com.local.lyrx</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>LyrX</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>LyrX 需要读取 Apple Music 当前歌曲、进度、专辑封面和内嵌歌词，以同步显示歌词。</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
xattr -cr "$APP"
python3 Scripts/verify-release.py "$APP"
# 可通过 CODE_SIGN_IDENTITY 选择自己的开发者证书，以便跨版本保持系统授权身份。
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --identifier com.local.lyrx "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p releases
printf '%s\n' "$RELEASE_DIR" > releases/latest-release.txt
printf '已生成：%s/%s\n' "$PWD" "$APP"

#!/bin/zsh
# 保留已有发布，每个版本文件夹内生成 LyrX.app 与对应 DMG。
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${1:-}" == "--skip-build" ]]; then
    RELEASE_DIR="${2:-$(cat releases/latest-release.txt)}"
else
    RELEASE_DIR="releases/LyrX-1.0.0-$(date +%Y%m%d-%H%M%S)"
    ./build-app.sh "$RELEASE_DIR"
fi
APP="$RELEASE_DIR/LyrX.app"
[[ -d "$APP" ]] || { echo "找不到 $APP" >&2; exit 1; }
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
OUT="$RELEASE_DIR/LyrX-${VERSION}.dmg"
[[ ! -e "$OUT" ]] || { echo "已有 $OUT，请保留旧发布并使用新文件夹。" >&2; exit 1; }
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/dmg"
cp -R -X "$APP" "$STAGE/dmg/LyrX.app"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -volname LyrX -srcfolder "$STAGE/dmg" -format UDZO "$OUT" >/dev/null
hdiutil imageinfo "$OUT" >/dev/null
printf '已生成：%s\n' "$OUT"

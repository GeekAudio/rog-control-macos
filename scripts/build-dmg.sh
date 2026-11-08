#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) 2026 thanhnndev and contributors
# Packs build/RogControl.app into build/RogControl-<version>.dmg: a window with the app, an Applications shortcut and a
# background that says to drag one onto the other. Run scripts/build-rogcontrol.sh first.
# Finder sets the window layout through AppleScript; the first run may ask to allow automation of Finder. Without it the
# DMG still works, just without the background and icon positions.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/RogControl.app
[ -d "$APP" ] || { echo "build $APP first: bash scripts/build-rogcontrol.sh" >&2; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
NAME="ROG Control"
OUT="build/RogControl-$VER.dmg"
WORK=$(mktemp -d); trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT
MNT=""

mkdir -p "$WORK/stage/.background"
cp -R "$APP" "$WORK/stage/$NAME.app"
ln -s /Applications "$WORK/stage/Applications"
swiftc macos/RogControl/dmg/render-background.swift -o "$WORK/render-bg"
"$WORK/render-bg" "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/stage/.background/background.tiff" 2>/dev/null

hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
MNT=$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')
# CI 上没有可交互的 Finder 会话，osascript 会卡在自动化授权上：直接跳过窗口布局，DMG 仍然可用
if [ -n "${CI:-}" ]; then
  echo "CI: 跳过 Finder 窗口布局（图标位置与背景由脚本外置）" >&2
else
osascript <<OSA || echo "Finder 布局已跳过（未获自动化授权）；DMG 仍可正常使用" >&2
tell application "Finder"
  tell disk "$(basename "$MNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
fi
chflags hidden "$MNT/.background" 2>/dev/null || true
sync
hdiutil detach "$MNT" -quiet; MNT=""
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
shasum -a 256 "$OUT" | sed 's#build/##' > "$OUT.sha256"
echo "已生成 $OUT"; cat "$OUT.sha256"

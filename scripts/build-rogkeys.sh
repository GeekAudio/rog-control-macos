#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) 2026 thanhnndev and contributors
# Builds rogkeyd (the GA403WM Fn keys, macos/RogKeys) into build/rogkeyd.app. Ad-hoc signed.
#
#   scripts/build-rogkeys.sh --install   build, copy to ~/Library/Application Support/RogControl/rogkeyd.app, run it at every
#                                        login (LaunchAgent com.itlmt7925.rogkeyd), start it now
#   scripts/build-rogkeys.sh --uninstall
# macOS ties the Input Monitoring grant to the binary. The install keeps the installed copy when the new build is
# byte-identical, so a rebuild does not lose the grant; a changed binary needs the grant again.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/rogkeyd.app
DEST="$HOME/Library/Application Support/RogControl/rogkeyd.app"
PLIST="$HOME/Library/LaunchAgents/com.itlmt7925.rogkeyd.plist"
if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/com.itlmt7925.rogkeyd" 2>/dev/null || true
  rm -f "$PLIST"; rm -rf "$DEST"; echo "removed rogkeyd"; exit 0
fi
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp macos/RogKeys/Info.plist "$APP/Contents/Info.plist"
swiftc -O -target x86_64-apple-macos13.0 macos/RogKeys/rogkeyd.swift -o "$APP/Contents/MacOS/rogkeyd" \
  -framework IOKit -framework CoreAudio -framework CoreWLAN -framework AppKit
codesign --force --sign - --identifier com.itlmt7925.rogkeyd "$APP" >/dev/null
echo "built $APP"
[ "${1:-}" = "--install" ] || exit 0
if [ -f "$DEST/Contents/MacOS/rogkeyd" ] && cmp -s "$APP/Contents/MacOS/rogkeyd" "$DEST/Contents/MacOS/rogkeyd"; then
  echo "installed rogkeyd is the same build: kept (Input Monitoring grant stays)"
else
  mkdir -p "$(dirname "$DEST")"; rm -rf "$DEST"; cp -R "$APP" "$DEST"
  echo "installed $DEST (new binary: allow it in Input Monitoring)"
fi
python3 - "$PLIST" "$DEST/Contents/MacOS/rogkeyd" "$HOME/Library/Logs/rogkeyd.log" <<'PY'
import plistlib, sys
p, exe, log = sys.argv[1:]
plistlib.dump({"Label": "com.itlmt7925.rogkeyd", "ProgramArguments": [exe], "RunAtLoad": True, "KeepAlive": True,
               "ProcessType": "Interactive", "StandardOutPath": log, "StandardErrorPath": log}, open(p, "wb"))
PY
launchctl bootout "gui/$(id -u)/com.itlmt7925.rogkeyd" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "started (log ~/Library/Logs/rogkeyd.log)"

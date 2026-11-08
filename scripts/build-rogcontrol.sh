#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) 2026 thanhnndev and contributors
# Builds the RogControl menu bar app (ROG Control Center for macOS) into build/RogControl.app (Xcode command line tools, no Xcode project). Ad-hoc signed.
#   scripts/build-rogcontrol.sh            build
#   scripts/build-rogcontrol.sh --install  build, copy to /Applications, start it at every login (user LaunchAgent), start it now
#                                       (no sudo: /Applications is writable for admins). Turn the login start off in its menu.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/RogControl.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp macos/RogControl/Info.plist "$APP/Contents/Info.plist"
# App icon: the layered Icon Composer file compiles to Assets.car (Liquid Glass, dark and tinted on Tahoe) plus AppIcon.icns
# for macOS 13-15. Needs Xcode's actool; without it the app builds with the generic icon.
mkdir -p "$APP/Contents/Resources"
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$PWD/macos/RogControl/icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 13.0 --output-partial-info-plist "$PWD/$APP/icon-partial.plist" >/dev/null
  rm -f "$APP/icon-partial.plist"
else
  echo "actool not found (install Xcode): building without the app icon" >&2
fi
swiftc -O -target x86_64-apple-macos13.0 macos/RogControl/RogControl.swift -o "$APP/Contents/MacOS/RogControl" -framework IOKit -framework SwiftUI -framework CoreAudio -framework CoreMediaIO
codesign --force --sign - "$APP" >/dev/null
echo "已生成 $APP"
if [ "${1:-}" = "--install" ]; then
  pkill -x RogControl 2>/dev/null || true
  rm -rf /Applications/RogControl.app
  cp -R "$APP" /Applications/
  LA="$HOME/Library/LaunchAgents/com.itlmt7925.RogControl.plist"      # same label and keys the app's "Open at Login" writes
  mkdir -p "$(dirname "$LA")"
  /usr/bin/python3 -I - "$LA" <<'PY'
import plistlib, sys
plistlib.dump({"Label": "com.itlmt7925.RogControl", "ProgramArguments": ["/Applications/RogControl.app/Contents/MacOS/RogControl", "--background"],
               "RunAtLoad": True, "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"}, open(sys.argv[1], "wb"))
PY
  plutil -lint "$LA" >/dev/null
  open /Applications/RogControl.app
  echo "installed /Applications/RogControl.app; starts at login ($LA)"
fi

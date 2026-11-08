#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) 2026 thanhnndev and contributors
# 把 build/ 里的产物整理成可发布的 dist/：DMG、各组件 zip、LICENSE / NOTICE 与 SHA256SUMS.txt。
# 先跑 scripts/build-rogcontrol.sh、build-rogkeys.sh、build-amdcppc-policy.sh 和 build.sh。
#   scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/RogControl.app
[ -d "$APP" ] || { echo "先编译应用：bash scripts/build-rogcontrol.sh" >&2; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

rm -rf dist
mkdir -p dist

# 内核扩展
for k in AsusWmi AmdCppc; do
  [ -d "build/$k.kext" ] || { echo "缺少 build/$k.kext：先跑 bash scripts/build.sh" >&2; exit 1; }
  (cd build && zip -qry "../dist/$k.kext.zip" "$k.kext")
done

# 应用与守护进程
(cd build && zip -qry ../dist/RogControl.app.zip RogControl.app \
             && zip -qry ../dist/rogkeyd.app.zip rogkeyd.app \
             && zip -qj  ../dist/AmdCppcPolicy.zip AmdCppcPolicy)

# 安装用 DMG（内含 Applications 快捷方式，拖放即可）
bash scripts/build-dmg.sh >/dev/null
mv "build/RogControl-${VER}.dmg" dist/
[ -f "build/RogControl-${VER}.dmg.sha256" ] && mv "build/RogControl-${VER}.dmg.sha256" dist/

cp LICENSE NOTICE.md dist/
(cd dist && shasum -a 256 *.dmg *.zip LICENSE NOTICE.md > SHA256SUMS.txt)

echo "dist/ 已生成（版本 ${VER}）："
ls -lh dist

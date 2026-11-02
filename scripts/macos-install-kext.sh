#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) 2026 thanhnndev and contributors
# Installs a freshly built kext from build/ into EFI/OC/Kexts on the ESP OpenCore booted from. RUN ON macOS (asks for sudo).
#   scripts/macos-install-kext.sh itlmt7925          install build/itlmt7925.kext
#   scripts/macos-install-kext.sh --undo itlmt7925   put the newest backup back
# * The old kext is moved to EFI/OC/Kexts-backup/<name>.kext.<time> (OpenCore only loads what config.plist lists, by path).
# * For itlmt7925 the Wi-Fi credentials (itl_ssid*/itl_psk*) of the installed kext are carried over into the new Info.plist.
#   They are never printed and never written anywhere in the repository.
# * config.plist is not touched: the kext must already be listed there (it is, for everything this repo builds).
set -euo pipefail
cd "$(dirname "$0")/.."
UNDO=0; [ "${1:-}" = "--undo" ] && { UNDO=1; shift; }
NAME="${1:?kext name, e.g. itlmt7925}"
NEW="build/$NAME.kext"
[ $UNDO = 1 ] || [ -d "$NEW" ] || { echo "no $NEW: run scripts/build.sh $NAME first"; exit 1; }
sudo -v

# The ESP OpenCore booted from: OpenCore publishes its partition in NVRAM (boot-path / efi-boot-device). Fall back to the
# EFI partition of the disk that holds the root volume.
ESP=""
UUID=$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | cut -f2- | grep -oE '[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}' | head -1 || true)
[ -n "$UUID" ] && ESP=$(diskutil info "$UUID" 2>/dev/null | awk -F': *' '/Device Identifier/{print $2}' || true)
if [ -z "$ESP" ]; then
  ROOTDISK=$(diskutil info / | awk -F': *' '/Part of Whole/{print $2}')
  PHYS=$(diskutil apfs list 2>/dev/null | awk -v d="$ROOTDISK" '$0 ~ "Container Reference: *"d"$" {f=1} f && /Physical Store/ {print; exit}' |
         grep -oE 'disk[0-9]+s[0-9]+' | head -1 | sed -E 's/s[0-9]+$//')
  ESP=$(diskutil list "${PHYS:-disk0}" | awk '/EFI/ {print $NF; exit}')
fi
[ -n "$ESP" ] || { echo "could not find the ESP"; exit 1; }
MP=$(diskutil info "$ESP" | awk -F': *' '/Mount Point/{print $2}')
MOUNTED=0
if [ -z "$MP" ]; then
  sudo diskutil mount "$ESP" >/dev/null || {
    echo "the ESP did not mount. With ItlDiag loaded (itlfile on) it holds the ESP open for ITLLOG.BIN, so macOS cannot"
    echo "mount it: install from Linux instead (scripts/linux-install-kext.sh $NAME, reads build/ from the macOS volume)"; exit 1; }
  MOUNTED=1; MP=$(diskutil info "$ESP" | awk -F': *' '/Mount Point/{print $2}'); fi
trap '[ $MOUNTED = 1 ] && sudo diskutil unmount "$ESP" >/dev/null 2>&1 || true' EXIT
K="$MP/EFI/OC/Kexts"; B="$MP/EFI/OC/Kexts-backup"
[ -d "$K" ] || { echo "$K not found on $ESP"; exit 1; }
echo "ESP $ESP at $MP"

if [ $UNDO = 1 ]; then
  LAST=$(ls -1d "$B/$NAME.kext."* 2>/dev/null | sort | tail -1)
  [ -n "$LAST" ] || { echo "no backup of $NAME in $B"; exit 1; }
  sudo rm -rf "$K/$NAME.kext"
  sudo mv "$LAST" "$K/$NAME.kext"
  echo "restored $(basename "$LAST") -> $K/$NAME.kext"
  exit 0
fi

grep -q "<string>Kexts/\?$NAME.kext</string>\|<string>$NAME.kext</string>" "$MP/EFI/OC/config.plist" ||
  echo "WARNING: $NAME.kext is not listed in config.plist Kernel/Add; OpenCore will not load it"

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"; [ $MOUNTED = 1 ] && sudo diskutil unmount "$ESP" >/dev/null 2>&1 || true' EXIT
cp -R "$NEW" "$STAGE/"
if [ "$NAME" = itlmt7925 ] && [ -f "$K/$NAME.kext/Contents/Info.plist" ]; then
  n=$(/usr/bin/python3 -I - "$K/$NAME.kext/Contents/Info.plist" "$STAGE/$NAME.kext/Contents/Info.plist" <<'PY'
import plistlib, sys
old = plistlib.load(open(sys.argv[1], "rb"))["IOKitPersonalities"]["itlmt7925"]
with open(sys.argv[2], "rb") as f: new = plistlib.load(f)
per = new["IOKitPersonalities"]["itlmt7925"]; n = 0
for k in ("itl_ssid", "itl_psk", "itl_ssid2", "itl_psk2", "itl_ssid3", "itl_psk3", "itl_ssid4", "itl_psk4"):
    if isinstance(old.get(k), str) and old[k]: per[k] = old[k]; n += 1
with open(sys.argv[2], "wb") as f: plistlib.dump(new, f)
print(n)
PY
)
  echo "credentials carried over: $n key(s)"
fi
sudo mkdir -p "$B"
TS=$(date +%Y%m%d-%H%M%S)
[ -d "$K/$NAME.kext" ] && sudo mv "$K/$NAME.kext" "$B/$NAME.kext.$TS"
sudo cp -R "$STAGE/$NAME.kext" "$K/"
echo "installed $K/$NAME.kext (old one: $B/$NAME.kext.$TS); reboot to load it. Undo: $0 --undo $NAME"

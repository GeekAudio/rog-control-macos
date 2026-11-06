# GA403WM Fn keys

Traced 2026-11-05 on the GA403WM (macOS 26.7.1) with an IOHIDManager listener on the N-KEY keyboard (USB HID 0b05:19b6).

Every Fn key comes from the keyboard. None of them reach the ATKD WMI path: `Notify (ATKD, 0xFF)` and `_WED` stayed silent
for all keys. The keyboard sends them in two ways.

| Key | N-KEY report | Handled by |
|---|---|---|
| Fn+F1 | consumer Mute (02 e2) | macOS |
| Fn+F2 / F3 | 5A c5 / 5A c4 | AsusWmi: keyboard light down / up |
| Fn+F4 | 5A b3 | AsusWmi: next Aura mode (static, breathe, strobe; report 5D B3/B5/B4 as G-Helper) |
| Fn+F5 | 5A ae | AsusWmi: next profile |
| Fn+F6 | keyboard Win+Shift+S | macOS (arrives as Cmd+Shift+S) |
| Fn+F7 / F8 | 5A 10 / 5A 20 | AsusWmi: Notify (VGA.LCD, 0x87 / 0x86) to BrightnessKeys |
| Fn+F9 | keyboard Win+P | rogkeyd: opens Displays settings; with Accessibility drops only this firmware Cmd+P (a typed Cmd+P still prints) |
| Fn+F10 | 5A 6b | roadmap: touchpad on / off (see below) |
| Fn+F11 | 5A 6c | AsusWmi: sleep |
| Fn+F12 | report 03 | rogkeyd: airplane mode, Wi-Fi + Bluetooth off, then back as they were (code 0x88) |
| M1 / M2 | consumer Vol- / Vol+ (02 ea / 02 e9) | macOS |
| M3 | 5A 7c | rogkeyd: built-in mic mute |
| M4 | 5A 38 | rogkeyd: opens ROG Control |

Release is `5A 00`. Report 0x5A (usage page 0xFF31) needs no init: the keyboard sends it from power-on.

macOS's keyboard driver (the AppleUserHIDEventService dext) drops page 0xFF31, and the keyboard has to stay on that driver
(see the AsusNKey section below). So the keys are read next to it:

- **rogkeyd** (`macos/RogKeys`, LaunchAgent `com.itlmt7925.rogkeyd`, `scripts/build-rogkeys.sh --install`) opens the
  keyboard with IOHIDManager and reads reports 0x5A and 0x03. It does mic mute, M4 and Wi-Fi itself and passes every code
  to AsusWmi through user client selector `kAsusUcKey` (ABI 4). Reading a keyboard needs **Input Monitoring** for
  `~/Library/Application Support/RogControl/rogkeyd.app`, granted once; Fn+F9's event tap needs **Accessibility**. macOS
  ties both grants to the binary, so the install keeps an unchanged binary and a new build needs them again. Log:
  `~/Library/Logs/rogkeyd.log`.
- **AsusWmi 0.2.2** handles the keyboard light, Aura, profile and sleep, plus brightness. For brightness it sends the
  ACPI notification the firmware would send to the panel device, which BrightnessKeys already listens to. It counts every
  key in `sysctl debug.asuswmi.hotkey` (`<sequence> <code>`), and RogControl refreshes when that count moves.

Undo: `scripts/build-rogkeys.sh --uninstall`. The AsusWmi key selector does nothing without rogkeyd.

## Install and check

1. AsusWmi 0.2.2 in `EFI/OC/Kexts` (`scripts/macos-install-kext.sh AsusWmi`), reboot.
2. `bash scripts/build-rogkeys.sh --install` (or unzip `rogkeyd-1.2.app.zip` from the release into
   `~/Library/Application Support/RogControl/` and run the script's `--install`, which also writes the LaunchAgent).
3. ROG Control > Doctor. Under Fn keys, **Fix it** walks through the grants: it resets rogkeyd's stale entry
   (`tccutil reset ListenEvent com.itlmt7925.rogkeyd`) so macOS asks again, opens the Settings pane with `rogkeyd.app` shown
   in Finder, then restarts rogkeyd and checks again. The same steps exist for Accessibility.
4. Press Fn+F2: Doctor's "Keys reaching AsusWmi" counts up.

`RogControl --doctor` prints the same report in a terminal.

## Panic on Fn+F7 / F8 with AsusWmi 0.2.0 (2026-11-05 21:39)

Kernel trap 13 (general protection) in `AsusWmi::hotkey` from `keyDrain`, RAX 0x87 (brightness down), RDI
0x01c501c501c501c5: the `lcd` pointer had been overwritten with four queued Fn+F2 codes (0x1c5 = 0xc5 | keyboard bit).
The key ring wrapped with `% sizeof(keyQ)`, 32 (bytes), on a 16-entry `uint16_t` array, so entries 16 to 31 went past the
array into the head/tail indices and `lcd`. Any 16 keys since boot started the overwrite; the next F7/F8 called through
the bad pointer. Fixed in 0.2.1 (`kKeyQLen`); the brightness path itself is unchanged.

## Fn+F9

The firmware types Win+P in one keyboard report (GUI and P together) and holds GUI about 7 s. macOS turns it into Cmd+P,
the same event as a typed Cmd+P, so a filter on Cmd+P alone would break Print. rogkeyd reads the raw report (a typed Cmd+P
comes as two reports, Cmd first), marks it, and its event tap drops only the next Cmd+P within 300 ms of that mark, then
takes Cmd off keys until the firmware lets GUI go. Without the Accessibility grant Fn+F9 still opens Displays settings and
the Cmd+P goes through.

## Roadmap

- Fn+F10 (5A 6b): touchpad on / off. Needs a disable switch in VoodooI2CHID (or AsusWmi telling it to drop reports) and an
  on-screen state; Windows shows an OSD.
- Fn+F6 (Win+Shift+S, arrives as Cmd+Shift+S): left to the owner's own key mapping.

## Black screen with AsusNKey 0.1.0 (2026-11-05 17:37 and 17:39 boots, traced from Windows)

AsusNKey 0.1.0 was injected from the ESP (Kernel>Add) for the first time on the 17:37:57 boot. That boot and the 17:39:31 boot
stayed black. **WindowServer crash-loops** as soon as it enumerates HID devices.

- Crash: `WindowServer-2026-11-05-173821.ips` and `.000.ips` (same boot, uptime 13 s and 16 s): `EXC_BAD_ACCESS` at 0,
  `_platform_strlen` with `rdi = 0`, called from SkyLight `device_set_create_dictionary` → `announce_device_set` →
  `CGXHIDServicesAddCallback`. WindowServer reads a C string from a new HID service, and that string is NULL.
- Restarts: good boots have one WindowServer (pid 205). Each bad boot has 6-7 (launchd respawns it): 710, 966, 1175, 1475…
  in the first boot and 689, 915, 1098, 1375, 1720… in the second.
- Service: hidd's descriptions in the unified log (Persist tracev3, after LZ4-decompressing the chunks):
  - good boot: `IOHIDService name:AppleUserHIDEventDriver ... primaryUsagePage:0xff89 primaryUsage:0x10 transport:USB locationID:4194304`
  - bad boot: the same interface as `name:AsusNKey ... primaryUsagePage:0xff89 primaryUsage:0x10 transport:USB locationID:4194304`.
    It also shows up as `name:AsusNKey ... primaryUsagePage:0x0 primaryUsage:0x0 transport: locationID:(null)`, next to
    `KeyboardBacklightServiceFilter`. An Apple service never shows empty `transport` or `(null)` `locationID`.
- So the AsusNKey service is visible to clients before (or without) the string properties that Apple's dext has. The exact
  key WindowServer reads could not be confirmed from Windows: the E: volume is the Data volume, with no dyld shared cache to
  disassemble SkyLight.

**Result:** AsusNKey is removed (2026-11-05 18:11, kext kept in `~/efi-audit/AsusNKey.kext.disabled`). Replacing a dext-driven
keyboard with a kernel `IOHIDEventDriver` gives a service without the properties WindowServer needs, so that route is closed.
It was first disabled on the ESP (backup
`EFI/OC/config.plist.pre-asusnkey-off-20261105-180109`). Apple's dext keeps the keyboard; the 0x5A Fn keys do nothing.

### To trace on macOS (before turning AsusNKey back on)
1. Properties Apple's dext puts on the keyboard service (the list AsusNKey must match):
   `ioreg -rc AppleUserHIDEventDriver -l -w0 > ~/nkey-apple.txt` (the entry with `LocationID = 4194304`, `ProductID = 6582`).
   Note `Transport`, `Product`, `Manufacturer`, `SerialNumber`, `LocationID`, `CountryCode`, `PrimaryUsagePage`,
   `DeviceUsagePairs`, `HIDServiceSupport`, `HIDDefaultBehavior`, `KeyboardLanguage`.
2. The crash site: `otool -tvV` on SkyLight is not possible (shared cache). Use `lldb` on a copy:
   `dyld_info -disassemble -start device_set_create_dictionary /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`
   (or `ipsw dyld disass`), and find which `IOHIDServiceClientCopyProperty` key feeds the `strlen`.
3. Load test without a reboot loop: keep the Kernel>Add entry off and load a fixed build with `kextutil` from a terminal
   over SSH, so a WindowServer crash only costs a re-login. Watch `log stream --predicate 'process == "WindowServer"'`.

### Fix ideas for 0.1.1
- In `start()`, before `IOHIDEventDriver::start(provider)`, copy `Transport`, `Product`, `Manufacturer`, `SerialNumber`,
  `LocationID`, `VendorID`, `ProductID`, `CountryCode` from the `IOHIDInterface`/`IOHIDDevice` onto `this`, so the
  service is complete when `registerService()` publishes it.
- Match only the vendor interface that carries report 0x5A, not the whole keyboard, with a lower `IOProbeScore`.
- Alternative with no driver swap: leave the keyboard to Apple's dext and read report 0x5A from user space
  (IOHIDManager in rogaudiod/RogControl, which already worked in the key trace), then pass codes to AsusWmi through sysctl.

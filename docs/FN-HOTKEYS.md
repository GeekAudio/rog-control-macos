# GA403WM Fn keys

Traced 2026-11-05 on the GA403WM (macOS 26.7.1) with an IOHIDManager listener on the N-KEY keyboard (USB HID 0b05:19b6).

Every Fn key comes from the keyboard. None of them reach the ATKD WMI path: `Notify (ATKD, 0xFF)` and `_WED` stayed silent
for all keys. The keyboard sends them in two ways.

| Key | N-KEY report | Handled by |
|---|---|---|
| Fn+F1 | consumer Mute (02 e2) | macOS |
| Fn+F2 / F3 | 5A c5 / 5A c4 | AsusWmi: keyboard light down / up |
| Fn+F4 | 5A b3 | AsusWmi: Slash on / off |
| Fn+F5 | 5A ae | AsusWmi: next profile |
| Fn+F6 | keyboard Win+Shift+S | macOS (arrives as Cmd+Shift+S) |
| Fn+F7 / F8 | 5A 10 / 5A 20 | AsusNKey: Apple brightness down / up |
| Fn+F9 | keyboard Win+P | macOS (arrives as Cmd+P) |
| Fn+F10 | 5A 6b | nothing yet (no touchpad switch in VoodooI2C) |
| Fn+F11 | 5A 6c | AsusWmi: sleep |
| Fn+F12 | report 03 | RogControl: Wi-Fi on / off (code 0x88) |
| M1 / M2 | consumer Vol- / Vol+ (02 ea / 02 e9) | macOS |
| M3 | 5A 7c | RogControl: built-in mic mute |
| M4 | 5A 38 | RogControl: opens the window |

Release is `5A 00`. Report 0x5A (usage page 0xFF31) needs no init: the keyboard sends it from power-on.

macOS's keyboard driver (the AppleUserHIDEventService dext) drops page 0xFF31. AsusNKey.kext replaces that driver for this
one keyboard. It is Apple's kernel `IOHIDEventDriver` (the class behind the "HID Keyboard Driver" personality) and passes every
report on unchanged, but it reads report 0x5A first. It hands codes to AsusWmi with `callPlatformFunction("asusNKeyCode")`,
so neither kext links against the other. AsusWmi handles the codes and counts them in `sysctl debug.asuswmi.hotkey`
(`<sequence> <code>`); RogControl polls that for M3, M4 and Fn+F12.

Undo: boot-arg `-asusnkeyoff` (Apple's driver keeps the keyboard), or disable the AsusNKey Kernel>Add entry.
Check after boot: `ioreg -rc AsusNKey -d1`, then press a key and read `ioreg -rc AsusNKey -l | grep AsusNKeyLast` and
`sysctl debug.asuswmi.hotkey`.

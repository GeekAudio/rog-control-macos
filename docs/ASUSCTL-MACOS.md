# asusctl / ROG Control Center on macOS

[asusctl](https://github.com/opengamingcollective/asusctl) (formerly <https://gitlab.com/asus-linux/asusctl>, by Luke Jones
and the asus-linux contributors, **MPL-2.0**) is the Linux daemon (`asusd`), CLI (`asusctl`) and GUI (`rog-control-center`)
for ASUS ROG laptops. It does not talk to the hardware itself: it drives the Linux kernel drivers `asus-wmi` and
`asus-armoury` through sysfs, the keyboard LEDs through USB HID, and GPU switching through `supergfxctl`. A port to macOS
therefore has two halves: a kext that does what the Linux kernel drivers do, and a user-space tool/app that does what asusd
and rog-control-center do. Credits and license notes: [NOTICE.md](../NOTICE.md).

## Why it matters here

macOS has no driver for ASUS's ACPI WMI device (`ATKD`, `_UID "ATK"`, GUID `97845ED0-4E6D-11DE-8A39-0800200C9A66`). The
embedded controller keeps the profile and power limits it booted with, and nothing on macOS can change them. On this
laptop (2026-10-11, `sysctl debug.amdcppc.freq`) the four Zen 5 cores stay at exactly 2000 MHz in every mode (CPPC off or
on, AC or battery) and the Zen 5c cores at 1.4-3.3 GHz; boost is enabled in the CPU (`CpbDis=0`) and CPPC requests the
highest performance, so the limit sits in the platform. The profile and the PPT limits are the obvious suspects.

## Feature map

| asusctl feature | Linux path | macOS route | Status |
|---|---|---|---|
| Platform profile (balanced / turbo / silent) | `asus-wmi` throttle_thermal_policy, WMI dev `0x00120075` | `kexts/AsusWmi`: `sysctl debug.asuswmi.profile` | **done, untested** |
| CPU power limits SPL / SPPT / FPPT | `asus-armoury` ppt_*, dev `0x001200A3` / `0x001200A0` / `0x001200C1`; GA403WM: 15-80 / 25-80 / 35-80 W on AC, 35/35/65 W max on battery | `debug.asuswmi.ppt_spl`, `ppt_sppt`, `ppt_fppt` (AC ranges enforced) | **done, untested** |
| Battery charge limit | dev `0x00120057` | `debug.asuswmi.charge_limit` (20-100) | **done, untested** |
| NVIDIA dynamic boost / temp target / TGP | dev `0x001200C0` / `0x001200C2` / `0x00120099` | read in `debug.asuswmi.status`; writes later (NullMoth driver decides the GPU clocks anyway) | read only |
| GPU MUX, dGPU disable | dev `0x00090016` / `0x00090020` | read in `status`; **do not write** from macOS: the NVIDIA driver is running | read only |
| Fan curves | dev `0x00110024` / `0x00110025` (buffer result) | needs a buffer-returning WMNB call (`evaluateObject`) | todo |
| Keyboard LEDs (Aura) | USB HID, N-KEY device `0b05:19b6` (here: "ITE Device(8910)"); `aura_support.ron` lists GA403 boards as one zone, Static/Breathe/Pulse/Rainbow | user space, `IOHIDDeviceSetReport` feature reports, no kext needed; port of `rog-aura` (MPL-2.0 files keep their license) | todo |
| Panel overdrive, mini-LED | dev `0x00050019`, `0x0005001E` | WMI, same kext | todo |
| AniMe / Slash lid LEDs | USB HID | user space | not on this board |
| Profile on AC/battery change | asusd | small LaunchDaemon watching IOPowerSources | todo |
| GUI (rog-control-center) | Slint app over D-Bus | SwiftUI menu bar app (like ItlWiFi) talking to the sysctls through a privileged helper | todo |

## AsusWmi (phase 1)

`kexts/AsusWmi` matches `IOACPIPlatformDevice` `PNP0C14` with `_UID "ATK"` and calls `ATKD.WMNB(0, method, {arg0, arg1, 0})`
like `wmi_evaluate_method()` does for asus-wmi (`DSTS` 0x53545344 reads a device, `DEVS` 0x53564544 sets it; bit 16 of a
DSTS result means "present"; `_UID "ATK"` means DSTS rather than DCTS). At start it calls `INIT`, `SPEC` and `SFUN` as Linux
does and records them in the registry property `asus-log`.

```
sysctl debug.asuswmi.status                 # profile, ppt_*, charge_limit, gpu_mux ... as value(raw DSTS)
sudo sysctl debug.asuswmi.profile=1         # 0 balanced, 1 turbo, 2 silent
sudo sysctl debug.asuswmi.ppt_spl=65 debug.asuswmi.ppt_sppt=80 debug.asuswmi.ppt_fppt=80
sudo sysctl debug.asuswmi.charge_limit=80
sudo sysctl debug.asuswmi.probe=0x00120075; sysctl debug.asuswmi.probe   # raw DSTS of any device id
sudo sysctl debug.asuswmi.dumpacpi=1        # DSDT + SSDTs as registry properties acpi-DSDT, acpi-SSDT-<n>
```

The settings live in the EC; like on Linux they may be reset by the firmware at boot or on AC/battery changes, which is
what asusd's profile-on-power-change logic is for.

## Reading the ACPI tables

macOS does not publish them in the registry. `debug.asuswmi.dumpacpi=1` copies them into the kext's registry entry; save
them with `ioreg -a -rc AsusWmi -d 1` and decompile with `iasl` (MaciASL ships one). Needed for the fan-curve buffer format,
for checking what `WMNB` does with each device id on this BIOS, and for the EC fields if the profile alone does not lift the
2000 MHz cap.

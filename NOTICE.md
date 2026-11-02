# Third-party material

Everything under `kexts/`, `macos/`, `scripts/`, `test/`, `docs/` is licensed under the [Clear BSD License](LICENSE) unless the
table says otherwise. Nothing here is copied from the projects below; they are references for interface values and design.

## Design references (no code copied)

* **asusctl / rog-control-center** ([github.com/opengamingcollective/asusctl](https://github.com/opengamingcollective/asusctl),
  formerly <https://gitlab.com/asus-linux/asusctl>; <https://asus-linux.org>), by Luke Jones and the asus-linux contributors,
  MPL-2.0: the feature set and its organisation (platform profile, PPT power limits, charge limit, per-board limits) that
  `kexts/AsusWmi`, `macos/RogControl` and `docs/ASUSCTL-MACOS.md` follow. A later port of any of its files would keep them
  under MPL-2.0 with their notices.
* Linux **asus-wmi** (`drivers/platform/x86/asus-wmi.c`, `include/linux/platform_data/x86/asus-wmi.h`; Corentin Chary and
  contributors, GPL-2.0-or-later) and **asus-armoury** (`drivers/platform/x86/asus-armoury.[ch]`; Luke Jones, GPL-2.0): the
  WMI method and device ids, the DSTS/DEVS calling convention, the DSTS-vs-DCTS rule, the profile values and the GA403WM
  power-limit ranges used by `kexts/AsusWmi`. Interface values only.
* Linux **k10temp** / **amd_nb** (GPL-2.0): the SMN address of Tctl (0x59800) and the host-bridge index/data registers used by
  `kexts/AmdCppc`. Interface values only.
* [G-Helper](https://github.com/seerge/g-helper) (check its repository for the license): the HID report sequences for the keyboard light and the Slash
  display (`Aura.DirectBrightness`, `SlashDeviceAura`) that `kexts/AsusWmi` re-implements, and a UX reference for
  [docs/rog-control-design.md](docs/rog-control-design.md). The byte sequences are recorded in `docs/ASUSCTL-MACOS.md`; no
  G-Helper code is included.
* [asusctltray](https://github.com/Baldomo/asusctltray): a UX reference only.

## Build-time dependencies (not included)

* [acidanthera/MacKernelSDK](https://github.com/acidanthera/MacKernelSDK): kernel headers and libraries used by
  `scripts/build.sh`, downloaded at build time and not redistributed.

## Origin of this repository

The files were split out of [thanhnndev/ga403wm-hackintosh](https://github.com/thanhnndev/ga403wm-hackintosh) with
`git filter-repo`. Commits keep their original authors and dates. The kext bundle identifiers still read
`com.itlmt7925.*` because the kexts started in that project; they are kept so already installed copies keep matching.

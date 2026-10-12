// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
// User client ABI of AsusWmi (IOServiceOpen on the "AsusWmi" service, type 0). Used by macos/RogControl.
// Allowed for root, an administrator, or the user logged in at the console (as the itlmt7925 user client).
#ifndef ASUSWMI_ABI_H
#define ASUSWMI_ABI_H

#define ASUSWMI_ABI_VERSION 2

enum {
    kAsusUcGetState  = 0,   // out: struct, uint32_t[ASUS_ST_COUNT]
    kAsusUcSet       = 1,   // in: scalars { what (ASUS_SET_*), value }
    kAsusUcFanRead   = 2,   // in: scalars { fan (0 cpu, 1 gpu), profile (0 balanced, 1 turbo, 2 silent) }; out: struct 16 bytes
                            //     (8 temperatures in °C, then 8 fan duties in %): the firmware's curve for that profile
    kAsusUcFanWrite  = 3,   // in: scalars { fan }, struct 16 bytes (same layout): custom curve, makes the fans "manual"
    kAsusUcFanReset  = 4,   // re-applies the current profile: firmware fan curves, power limits back to the profile's
};

enum {                      // kAsusUcSet "what"
    ASUS_SET_PROFILE = 1,   // 0 balanced (Armoury Crate "Performance"), 1 turbo, 2 silent
    ASUS_SET_SPL     = 2,   // W, PL1 sustained; needs a custom fan curve first (asus-armoury: requires_fan_curve on GA403WM)
    ASUS_SET_SPPT    = 3,   // W, PL2 slow
    ASUS_SET_FPPT    = 4,   // W, PL3 fast
    ASUS_SET_CHARGE  = 5,   // %, battery charge end 20..100
    ASUS_SET_BACKLIGHT = 6, // panel brightness 0..ASUS_ST_BACKLIGHT_MAX (EC, through the NVIDIA WMI-EC method AWMI.WMAA)
};

enum {                      // kAsusUcGetState words
    ASUS_ST_ABI = 0,
    ASUS_ST_FLAGS,          // ASUS_FL_*
    ASUS_ST_PROFILE,        // 0..2 as last set since boot (the BIOS's DSTS does not report it), 0xFFFFFFFF unknown
    ASUS_ST_CHARGE,         // %, as last set since boot (DSTS reads 0 on this BIOS), 0xFFFFFFFF unknown
    ASUS_ST_CPU_FAN_RPM,
    ASUS_ST_GPU_FAN_RPM,
    ASUS_ST_SPL,            // W last set through AsusWmi since boot / the last profile change; 0 = the profile's own
    ASUS_ST_SPPT,
    ASUS_ST_FPPT,
    ASUS_ST_SPL_MIN, ASUS_ST_SPL_MAX,     // ranges for the current power source (asus-armoury, GA403WM)
    ASUS_ST_SPPT_MIN, ASUS_ST_SPPT_MAX,
    ASUS_ST_FPPT_MIN, ASUS_ST_FPPT_MAX,
    ASUS_ST_GPU_MUX,        // raw DSTS
    ASUS_ST_DGPU_DISABLE,   // raw DSTS
    ASUS_ST_NV_BASE_TGP,    // W
    ASUS_ST_BACKLIGHT,      // current level, 0xFFFFFFFF unknown
    ASUS_ST_BACKLIGHT_MAX,  // 0 = no EC backlight control
    ASUS_ST_BAT_DESIGN,     // mAh, design capacity (_BIF); 0 unknown
    ASUS_ST_BAT_FULL,       // mAh, last full charge capacity
    ASUS_ST_BAT_NOW,        // mAh, remaining
    ASUS_ST_BAT_STATE,      // bits 0-7: _BST state (1 discharging, 2 charging), bits 8-31: rate in mA
    ASUS_ST_COUNT = 24
};

#define ASUS_FL_AC         0x1u    // on AC power (ACPI0003 _PSR)
#define ASUS_FL_FAN_CUSTOM 0x2u    // a custom fan curve is active (written since the last profile change)

#endif

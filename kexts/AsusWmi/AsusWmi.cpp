// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
// AsusWmi: the platform half of asusctl / ROG Control Center for macOS, on the GA403WM (ROG Zephyrus G14 2025).
//
// macOS has no driver for ASUS's ACPI WMI device (ATKD, _UID "ATK", GUID 97845ED0-4E6D-11DE-8A39-0800200C9A66), so the
// firmware stays in whatever performance profile and power limits it booted with, and nothing can change them. This kext
// calls the device's WMNB method the way Linux does (asus-wmi: method id + a 12-byte argument buffer; DSTS reads a device,
// DEVS sets it) and exposes the settings asusctl manages as sysctls.
//
// Credits (see NOTICE.md): device ids, the DSTS/DEVS convention, the profile values and the GA403WM power-limit ranges come
// from the Linux drivers asus-wmi (Corentin Chary and contributors, GPL-2.0-or-later) and asus-armoury (Luke Jones, GPL-2.0),
// and the feature set from asusctl / rog-control-center (asus-linux.org, Luke Jones and contributors, MPL-2.0). No code is
// copied from them; this file only uses those documented interface values.
//
//   sysctl debug.asuswmi.status            (read) profile, power limits, charge limit, raw DSTS of the known devices
//   sysctl debug.asuswmi.profile=<0|1|2>   0 balanced, 1 turbo (overboost), 2 silent   (throttle_thermal_policy 0x00120075)
//   sysctl debug.asuswmi.ppt_spl=<W>       PL1 sustained   15..80 W   (0x001200A3)
//   sysctl debug.asuswmi.ppt_sppt=<W>      PL2 slow        25..80 W   (0x001200A0)
//   sysctl debug.asuswmi.ppt_fppt=<W>      PL3 fast        35..80 W   (0x001200C1)
//   sysctl debug.asuswmi.charge_limit=<%>  battery charge end 20..100 (0x00120057)
//   sysctl debug.asuswmi.probe=<dev id>    then read debug.asuswmi.probe: raw DSTS of any device id (exploration)
//   sysctl debug.asuswmi.dumpacpi=1        publishes the DSDT and SSDTs as registry properties acpi-DSDT, acpi-SSDT-<n>
// Writes need root and only touch the device ids above, within the ranges asus-armoury allows for this board on AC.
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/acpi/IOACPIPlatformExpert.h>
#include <sys/sysctl.h>
#include <stdarg.h>
#include <string.h>

#define M_INIT 0x54494E49
#define M_SPEC 0x43455053
#define M_SFUN 0x4E554653
#define M_DSTS 0x53545344
#define M_DEVS 0x53564544
#define WMI_UNSUPPORTED 0xFFFFFFFEu
#define DSTS_PRESENT 0x00010000u

#define DEV_PROFILE   0x00120075
#define DEV_PPT_SPPT  0x001200A0
#define DEV_PPT_SPL   0x001200A3
#define DEV_PPT_APU   0x001200B0
#define DEV_PPT_PLAT  0x001200B1
#define DEV_PPT_FPPT  0x001200C1
#define DEV_NV_BOOST  0x001200C0
#define DEV_NV_TEMP   0x001200C2
#define DEV_RSOC      0x00120057
#define DEV_GPU_MUX   0x00090016
#define DEV_DGPU      0x00090020
#define DEV_CPU_FAN   0x00110013
#define DEV_GPU_FAN   0x00110014
#define DEV_PANEL_OD  0x00050019

struct Known { uint32_t id; const char *name; };
static const Known kKnown[] = {
    { DEV_PROFILE, "profile" }, { DEV_PPT_SPL, "ppt_spl" }, { DEV_PPT_SPPT, "ppt_sppt" }, { DEV_PPT_FPPT, "ppt_fppt" },
    { DEV_PPT_APU, "ppt_apu_sppt" }, { DEV_PPT_PLAT, "ppt_platform_sppt" }, { DEV_NV_BOOST, "nv_dynamic_boost" },
    { DEV_NV_TEMP, "nv_temp_target" }, { DEV_RSOC, "charge_limit" }, { DEV_GPU_MUX, "gpu_mux" }, { DEV_DGPU, "dgpu_disable" },
    { DEV_CPU_FAN, "cpu_fan" }, { DEV_GPU_FAN, "gpu_fan" }, { DEV_PANEL_OD, "panel_overdrive" },
};

class AsusWmi : public IOService {
    OSDeclareDefaultStructors(AsusWmi)
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOACPIPlatformDevice *atk = nullptr;
    IOLock *lock = nullptr;
    char log[600] = {0};
    size_t loglen = 0;
    void say(const char *fmt, ...) __attribute__((format(printf, 2, 3)));
    bool wmi(uint32_t method, uint32_t a0, uint32_t a1, uint32_t *ret);
    bool dsts(uint32_t dev, uint32_t *ret) { return wmi(M_DSTS, dev, 0, ret) && *ret != WMI_UNSUPPORTED && *ret != ~0u; }
    bool devs(uint32_t dev, uint32_t val, uint32_t *ret) { return wmi(M_DEVS, dev, val, ret) && *ret != WMI_UNSUPPORTED; }
    void dumpAcpi();
};
OSDefineMetaClassAndStructors(AsusWmi, IOService)

static AsusWmi *gSelf;
static char gStatus[1024];
static uint32_t gProbeDev, gProbeVal;
static bool gProbeOk;

void AsusWmi::say(const char *fmt, ...)
{
    char line[128];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    IOLog("AsusWmi: %s\n", line);
    size_t n = strlen(line);
    if (loglen + n + 2 >= sizeof(log)) return;
    memcpy(log + loglen, line, n);
    loglen += n;
    log[loglen++] = ';';
    log[loglen] = 0;
    setProperty("asus-log", log);
}

// ATKD.WMNB(instance 0, method id, buffer { arg0, arg1, arg2 }) -> integer, as wmi_evaluate_method() with the asus-wmi args
bool AsusWmi::wmi(uint32_t method, uint32_t a0, uint32_t a1, uint32_t *ret)
{
    uint32_t args[3] = { a0, a1, 0 };
    OSNumber *inst = OSNumber::withNumber(0ull, 32), *mid = OSNumber::withNumber((unsigned long long)method, 32);
    OSData *buf = OSData::withBytes(args, sizeof(args));
    bool ok = false;
    if (inst && mid && buf) {
        OSObject *params[3] = { inst, mid, buf };
        UInt32 r = 0;
        ok = atk->evaluateInteger("WMNB", &r, params, 3) == kIOReturnSuccess;
        *ret = r;
    }
    if (inst) inst->release();
    if (mid) mid->release();
    if (buf) buf->release();
    return ok;
}

// getACPITableData() is protected; this type is never instantiated, it only makes the (virtual) call reachable.
class AcpiTables : public IOACPIPlatformExpert {
public:
    const OSData *table(const char *sig, UInt32 n) { return getACPITableData(sig, n); }
};

void AsusWmi::dumpAcpi()
{
    AcpiTables *pe = (AcpiTables *)OSDynamicCast(IOACPIPlatformExpert, getPlatform());
    if (!pe) { say("no ACPI platform expert"); return; }
    const OSData *d = pe->table("DSDT", 0);
    if (d) setProperty("acpi-DSDT", (OSObject *)d);
    int n = 0;
    for (uint32_t i = 0; i < 64; i++) {
        const OSData *s = pe->table("SSDT", i);
        if (!s) break;
        char key[24];
        snprintf(key, sizeof(key), "acpi-SSDT-%u", i);
        setProperty(key, (OSObject *)s);
        n++;
    }
    say("acpi dump: DSDT %u bytes, %d SSDTs", d ? d->getLength() : 0, n);
}

static void buildStatus()
{
    size_t n = 0;
    gStatus[0] = 0;
    for (const Known &k : kKnown) {
        uint32_t v = 0;
        if (!gSelf->dsts(k.id, &v)) { n += (size_t)snprintf(gStatus + n, sizeof(gStatus) - n, "%s%s=-", n ? " " : "", k.name); continue; }
        if (!(v & DSTS_PRESENT)) { n += (size_t)snprintf(gStatus + n, sizeof(gStatus) - n, "%s%s=absent", n ? " " : "", k.name); continue; }
        n += (size_t)snprintf(gStatus + n, sizeof(gStatus) - n, "%s%s=%u(%08x)", n ? " " : "", k.name, v & 0xffff, v);
        if (n >= sizeof(gStatus) - 48) break;
    }
}

static int status_sysctl SYSCTL_HANDLER_ARGS
{
    if (!gSelf) return ENODEV;
    IOLockLock(gSelf->lock);
    buildStatus();
    int e = SYSCTL_OUT(req, gStatus, strlen(gStatus) + 1);
    IOLockUnlock(gSelf->lock);
    return e;
}

enum { W_PROFILE = 1, W_SPL, W_SPPT, W_FPPT, W_CHARGE, W_DUMP };
struct Limit { uint32_t dev; int lo, hi; };
static const Limit kLimits[] = {
    { 0, 0, 0 }, { DEV_PROFILE, 0, 2 }, { DEV_PPT_SPL, 15, 80 }, { DEV_PPT_SPPT, 25, 80 }, { DEV_PPT_FPPT, 35, 80 },
    { DEV_RSOC, 20, 100 }, { 0, 1, 1 },
};

static int write_sysctl SYSCTL_HANDLER_ARGS
{
    if (!gSelf) return ENODEV;
    int what = (int)arg2, v = -1;
    uint32_t cur = 0;
    if (what != W_DUMP) {
        IOLockLock(gSelf->lock);
        bool ok = gSelf->dsts(kLimits[what].dev, &cur) && (cur & DSTS_PRESENT);
        IOLockUnlock(gSelf->lock);
        v = ok ? (int)(cur & 0xffff) : -1;
    }
    int e = sysctl_handle_int(oidp, &v, 0, req);
    if (e || !req->newptr) return e;
    if (v < kLimits[what].lo || v > kLimits[what].hi) return EINVAL;
    IOLockLock(gSelf->lock);
    if (what == W_DUMP) {
        gSelf->dumpAcpi();
        IOLockUnlock(gSelf->lock);
        return 0;
    }
    uint32_t ret = 0;
    bool ok = gSelf->devs(kLimits[what].dev, (uint32_t)v, &ret);
    gSelf->say("%s=%d -> %s ret %08x", oidp->oid_name, v, ok ? "ok" : "failed", ret);
    IOLockUnlock(gSelf->lock);
    return ok ? 0 : EIO;
}

static int probe_sysctl SYSCTL_HANDLER_ARGS
{
    if (!gSelf) return ENODEV;
    if (req->newptr) {                                       // write: a device id
        int dev = 0;
        int e = SYSCTL_IN(req, &dev, sizeof(dev));
        if (e) return e;
        IOLockLock(gSelf->lock);
        gProbeDev = (uint32_t)dev;
        gProbeOk = gSelf->wmi(M_DSTS, gProbeDev, 0, &gProbeVal);
        IOLockUnlock(gSelf->lock);
        return 0;
    }
    char s[64];
    snprintf(s, sizeof(s), "dev %08x: %s %08x", gProbeDev, gProbeOk ? "dsts" : "call failed", gProbeVal);
    return SYSCTL_OUT(req, s, strlen(s) + 1);
}

SYSCTL_NODE(_debug, OID_AUTO, asuswmi, CTLFLAG_RW | CTLFLAG_LOCKED, 0, "AsusWmi");
SYSCTL_PROC(_debug_asuswmi, OID_AUTO, status, CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, status_sysctl, "A", "");
SYSCTL_PROC(_debug_asuswmi, OID_AUTO, profile, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_PROFILE, write_sysctl, "I", "");
SYSCTL_PROC(_debug_asuswmi, OID_AUTO, ppt_spl, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_SPL, write_sysctl, "I", "");
SYSCTL_PROC(_debug_asuswmi, OID_AUTO, ppt_sppt, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_SPPT, write_sysctl, "I", "");
SYSCTL_PROC(_debug_asuswmi, OID_AUTO, ppt_fppt, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_FPPT, write_sysctl, "I", "");
SYSCTL_PROC(_debug_asuswmi, OID_AUTO, charge_limit, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_CHARGE, write_sysctl, "I", "");
SYSCTL_PROC(_debug_asuswmi, OID_AUTO, dumpacpi, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_DUMP, write_sysctl, "I", "");
SYSCTL_PROC(_debug_asuswmi, OID_AUTO, probe, CTLTYPE_STRING | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, 0, probe_sysctl, "A", "");

static struct sysctl_oid *const kOids[] = {
    &sysctl__debug_asuswmi, &sysctl__debug_asuswmi_status, &sysctl__debug_asuswmi_profile, &sysctl__debug_asuswmi_ppt_spl,
    &sysctl__debug_asuswmi_ppt_sppt, &sysctl__debug_asuswmi_ppt_fppt, &sysctl__debug_asuswmi_charge_limit,
    &sysctl__debug_asuswmi_dumpacpi, &sysctl__debug_asuswmi_probe,
};

bool AsusWmi::start(IOService *provider)
{
    if (!IOService::start(provider)) return false;
    atk = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!atk || gSelf) return false;
    if (atk->validateObject("WMNB") != kIOReturnSuccess) { IOLog("AsusWmi: no WMNB on %s\n", atk->getName()); return false; }
    lock = IOLockAlloc();
    if (!lock) return false;
    gSelf = this;
    uint32_t r = 0;
    if (wmi(M_INIT, 0, 0, &r)) say("INIT %08x", r);
    if (wmi(M_SPEC, 0, 9, &r)) say("BIOS WMI spec %u.%u", r >> 16, r & 0xff);
    if (wmi(M_SFUN, 0, 0, &r)) say("SFUN %08x", r);
    buildStatus();
    say("%s", gStatus);
    for (sysctl_oid *o : kOids) sysctl_register_oid(o);
    registerService();
    return true;
}

void AsusWmi::stop(IOService *provider)
{
    for (int i = (int)(sizeof(kOids) / sizeof(kOids[0])) - 1; i >= 0; i--) sysctl_unregister_oid(kOids[i]);
    gSelf = nullptr;
    if (lock) { IOLockFree(lock); lock = nullptr; }
    IOService::stop(provider);
}

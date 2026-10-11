// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
// AmdCppc: CPU performance control for AMD Zen on macOS, which has no driver for it (no P-state requests, no CPPC).
// Measured on the GA403WM (Ryzen AI 9 HX 370, boost 5.1 GHz), one busy thread, on AC: 1.4-3.3 GHz (tools/cpuclock.c).
//
// At start it only READS, on every CPU: HWCR (boost disable bit), the legacy P-state control/status, the CPPC enable, caps and
// request registers, and APERF/MPERF. The result is the registry property "report" and sysctl debug.amdcppc.report.
// Changes are made only when root writes a sysctl, so they can be tried without a reboot and are gone after one:
//   sysctl debug.amdcppc.pstate=0      request P-state 0 (the boostable one) on every CPU through PStateCtl (legacy path)
//   sysctl debug.amdcppc.boost=1       clear HWCR.CpbDis on every CPU (0 sets it: no boost)
//   sysctl debug.amdcppc.cppc=1        enable CPPC on every CPU (cannot be turned off until reset; what Linux amd-pstate does)
//   sysctl debug.amdcppc.epp=<0..255>  CPPC request on every CPU: max = highest perf, min = lowest non-linear, desired = 0
//                                      (autonomous), EPP = value (0 performance .. 128 balanced .. 255 power save). Only when
//                                      CPPC is enabled.
// Every MSR access goes through rdmsr_carefully / a #GP-safe write path only for registers that were read successfully first.
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <sys/sysctl.h>
#include <i386/proc_reg.h>
#include <string.h>

extern "C" {
int rdmsr_carefully(uint32_t msr, uint32_t *lo, uint32_t *hi);
void mp_rendezvous_no_intrs(void (*action)(void *), void *arg);
int cpu_number(void);
}

#define MSR_APERF          0xE8
#define MSR_MPERF          0xE7
#define MSR_HWCR           0xC0010015
#define MSR_PSTATE_CTL     0xC0010062
#define MSR_PSTATE_STAT    0xC0010063
#define MSR_PSTATE_DEF0    0xC0010064
#define MSR_CPPC_CAP1      0xC00102B0
#define MSR_CPPC_ENABLE    0xC00102B1
#define MSR_CPPC_REQ       0xC00102B3
#define HWCR_CPB_DIS       (1ull << 25)

static const int kMaxCpu = 64;
struct CpuRegs { bool ok[8]; uint64_t hwcr, pctl, pstat, pdef0, cap1, en, req, aperf, mperf; };
static CpuRegs gRegs[kMaxCpu];
static int gNcpu;
static char gReport[1536];

static bool rd(uint32_t m, uint64_t *v)
{
    uint32_t lo = 0, hi = 0;
    if (rdmsr_carefully(m, &lo, &hi)) return false;
    *v = ((uint64_t)hi << 32) | lo;
    return true;
}

static void readAll(void *)
{
    int c = cpu_number();
    if (c < 0 || c >= kMaxCpu) return;
    CpuRegs &r = gRegs[c];
    r.ok[0] = rd(MSR_HWCR, &r.hwcr);
    r.ok[1] = rd(MSR_PSTATE_CTL, &r.pctl);
    r.ok[2] = rd(MSR_PSTATE_STAT, &r.pstat);
    r.ok[3] = rd(MSR_PSTATE_DEF0, &r.pdef0);
    r.ok[4] = rd(MSR_CPPC_CAP1, &r.cap1);
    r.ok[5] = rd(MSR_CPPC_ENABLE, &r.en);
    r.ok[6] = rd(MSR_CPPC_REQ, &r.req);
    r.ok[7] = rd(MSR_APERF, &r.aperf) && rd(MSR_MPERF, &r.mperf);
    if (c + 1 > gNcpu) gNcpu = c + 1;
}

// Writes: each action only touches a register this CPU could read (so it exists), and only the documented fields.
struct WriteReq { int what; uint64_t val; };
enum { W_PSTATE = 1, W_BOOST, W_CPPC_EN, W_EPP };
static void writeAll(void *arg)
{
    const WriteReq *w = (const WriteReq *)arg;
    int c = cpu_number();
    if (c < 0 || c >= kMaxCpu) return;
    const CpuRegs &r = gRegs[c];
    switch (w->what) {
    case W_PSTATE:
        if (r.ok[1]) wrmsr64(MSR_PSTATE_CTL, (r.pctl & ~7ull) | (w->val & 7));
        break;
    case W_BOOST:
        if (r.ok[0]) wrmsr64(MSR_HWCR, w->val ? (r.hwcr & ~HWCR_CPB_DIS) : (r.hwcr | HWCR_CPB_DIS));
        break;
    case W_CPPC_EN:
        if (r.ok[5] && !(r.en & 1)) wrmsr64(MSR_CPPC_ENABLE, 1);
        break;
    case W_EPP:
        if (r.ok[4] && r.ok[6] && (r.en & 1)) {
            uint64_t highest = (r.cap1 >> 24) & 0xff, lownl = (r.cap1 >> 8) & 0xff;
            uint64_t req = (r.req & ~0xffffffffull) | highest | (lownl << 8) | (0ull << 16) | ((w->val & 0xff) << 24);
            wrmsr64(MSR_CPPC_REQ, req);
        }
        break;
    }
}

static void buildReport()
{
    // one line per distinct register set, so 24 identical CPUs give one line
    size_t n = 0;
    gReport[0] = 0;
    bool done[kMaxCpu] = {};
    for (int c = 0; c < gNcpu && n + 200 < sizeof(gReport); c++) {
        if (done[c]) continue;
        const CpuRegs &r = gRegs[c];
        int same = 0;
        for (int k = c; k < gNcpu; k++) {
            const CpuRegs &o = gRegs[k];
            if (o.hwcr == r.hwcr && o.pctl == r.pctl && o.pdef0 == r.pdef0 && o.cap1 == r.cap1 && o.en == r.en && o.req == r.req) {
                done[k] = true; same++;
            }
        }
        unsigned mhz0 = r.ok[3] ? (unsigned)(r.pdef0 & 0xfff) * 5 : 0;      // Zen 4/5 PStateDef: CpuFid[11:0] x 5 MHz
        n += (size_t)snprintf(gReport + n, sizeof(gReport) - n,
            "%scpu%d(x%d): CpbDis=%d PStateCtl=%llu PStateStat=%llu P0=%uMHz(def %s) CPPC_EN=%s CAP1=high %llu nom %llu lownl %llu low %llu "
            "REQ=max %llu min %llu des %llu epp %llu",
            n ? " | " : "", c, same, r.ok[0] ? (int)((r.hwcr >> 25) & 1) : -1, r.ok[1] ? r.pctl & 7 : 99ull,
            r.ok[2] ? r.pstat & 7 : 99ull, mhz0, r.ok[3] ? ((r.pdef0 >> 63) ? "on" : "off") : "?",
            r.ok[5] ? ((r.en & 1) ? "1" : "0") : "?",
            (r.cap1 >> 24) & 0xff, (r.cap1 >> 16) & 0xff, (r.cap1 >> 8) & 0xff, r.cap1 & 0xff,
            r.req & 0xff, (r.req >> 8) & 0xff, (r.req >> 16) & 0xff, (r.req >> 24) & 0xff);
    }
}

static IOService *gSelf;
static IOLock *gLock;
static void refresh()
{
    mp_rendezvous_no_intrs(readAll, nullptr);
    buildReport();
    if (gSelf) gSelf->setProperty("report", gReport);
}

static int report_sysctl SYSCTL_HANDLER_ARGS
{
    if (gLock) IOLockLock(gLock);
    refresh();
    int e = SYSCTL_OUT(req, gReport, strlen(gReport) + 1);
    if (gLock) IOLockUnlock(gLock);
    return e;
}
static int write_sysctl SYSCTL_HANDLER_ARGS
{
    int what = (int)arg2, v = -1;
    int e = sysctl_handle_int(oidp, &v, 0, req);
    if (e || !req->newptr) return e;
    if (what == W_PSTATE && (v < 0 || v > 7)) return EINVAL;
    if (what == W_EPP && (v < 0 || v > 255)) return EINVAL;
    if (gLock) IOLockLock(gLock);
    mp_rendezvous_no_intrs(readAll, nullptr);                // fresh copies: writes only modify current values
    WriteReq w = { what, (uint64_t)v };
    mp_rendezvous_no_intrs(writeAll, &w);
    refresh();
    IOLog("AmdCppc: %s=%d -> %s\n", oidp->oid_name, v, gReport);
    if (gLock) IOLockUnlock(gLock);
    return 0;
}

SYSCTL_NODE(_debug, OID_AUTO, amdcppc, CTLFLAG_RW | CTLFLAG_LOCKED, 0, "AmdCppc");
SYSCTL_PROC(_debug_amdcppc, OID_AUTO, report, CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, report_sysctl, "A", "registers");
SYSCTL_PROC(_debug_amdcppc, OID_AUTO, pstate, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_PSTATE, write_sysctl, "I", "request P-state");
SYSCTL_PROC(_debug_amdcppc, OID_AUTO, boost, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_BOOST, write_sysctl, "I", "1 = boost allowed");
SYSCTL_PROC(_debug_amdcppc, OID_AUTO, cppc, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_CPPC_EN, write_sysctl, "I", "1 = enable CPPC");
SYSCTL_PROC(_debug_amdcppc, OID_AUTO, epp, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, W_EPP, write_sysctl, "I", "CPPC EPP");

class AmdCppc : public IOService {
    OSDeclareDefaultStructors(AmdCppc)
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
};
OSDefineMetaClassAndStructors(AmdCppc, IOService)

bool AmdCppc::start(IOService *provider)
{
    if (!IOService::start(provider)) return false;
    gSelf = this;
    gLock = IOLockAlloc();
    refresh();
    IOLog("AmdCppc: %d CPUs: %s\n", gNcpu, gReport);
    sysctl_register_oid(&sysctl__debug_amdcppc);
    sysctl_register_oid(&sysctl__debug_amdcppc_report);
    sysctl_register_oid(&sysctl__debug_amdcppc_pstate);
    sysctl_register_oid(&sysctl__debug_amdcppc_boost);
    sysctl_register_oid(&sysctl__debug_amdcppc_cppc);
    sysctl_register_oid(&sysctl__debug_amdcppc_epp);
    registerService();
    return true;
}

void AmdCppc::stop(IOService *provider)
{
    sysctl_unregister_oid(&sysctl__debug_amdcppc_epp);
    sysctl_unregister_oid(&sysctl__debug_amdcppc_cppc);
    sysctl_unregister_oid(&sysctl__debug_amdcppc_boost);
    sysctl_unregister_oid(&sysctl__debug_amdcppc_pstate);
    sysctl_unregister_oid(&sysctl__debug_amdcppc_report);
    sysctl_unregister_oid(&sysctl__debug_amdcppc);
    gSelf = nullptr;
    IOService::stop(provider);
}

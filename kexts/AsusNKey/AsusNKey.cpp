// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
//
// AsusNKey: keyboard driver for the ASUS N-KEY keyboard of the GA403WM (USB HID 0b05:19b6, "ITE Device(8910)").
//
// The keyboard sends its Fn keys as vendor input report 0x5A (usage page 0xFF31): one byte with the key code, then 0x00
// on release. macOS's own keyboard driver ignores that page, so none of these keys did anything. This driver is Apple's
// kernel IOHIDEventDriver (the class behind the "HID Keyboard Driver" personality) with one change: it reads report 0x5A
// before passing every report on unchanged, so typing, the consumer keys (Fn+F1 mute, M1 / M2 volume) and the keyboard
// shortcuts the firmware sends (Fn+F6, Fn+F9) work as before.
//
//   0x10 / 0x20 (Fn+F7 / F8)   brightness down / up, as Apple top-case brightness keys (the slider and HUD follow)
//   any other code             handed to AsusWmi (callPlatformFunction "asusNKeyCode"): keyboard light, Slash, profile,
//                              sleep, and the sequence that RogControl reads for mic mute, M4, touchpad
//   report 0x03 (Fn+F12)       radio key, handed over as 0x88 (asus-wmi's rfkill code)
//
// Boot-arg -asusnkeyoff: do not attach; Apple's driver keeps the keyboard.
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/hid/IOHIDEventDriver.h>
#include <IOKit/hid/AppleHIDUsageTables.h>
#include <pexpert/pexpert.h>

class AsusNKey : public IOHIDEventDriver {
    OSDeclareDefaultStructors(AsusNKey)
    IOService *wmi = nullptr;
    const OSSymbol *fn = nullptr;
    uint32_t heldBrightness = 0;            // top-case usage of a brightness key still down
    uint32_t count = 0;
    void toWmi(uint32_t code);
public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
protected:
    void handleInterruptReport(AbsoluteTime timeStamp, IOMemoryDescriptor *report, IOHIDReportType reportType,
                               UInt32 reportID) override;
};
OSDefineMetaClassAndStructors(AsusNKey, IOHIDEventDriver)

IOService *AsusNKey::probe(IOService *provider, SInt32 *score)
{
    char arg[8];
    if (PE_parse_boot_argn("-asusnkeyoff", arg, sizeof(arg))) { IOLog("AsusNKey: -asusnkeyoff, not attaching\n"); return nullptr; }
    return IOHIDEventDriver::probe(provider, score);
}

bool AsusNKey::start(IOService *provider)
{
    fn = OSSymbol::withCString("asusNKeyCode");
    if (!IOHIDEventDriver::start(provider)) { OSSafeReleaseNULL(fn); return false; }
    IOLog("AsusNKey: driving %s, Fn keys from report 0x5A\n", provider->getName());
    setProperty("AsusNKey", true);
    return true;
}

void AsusNKey::stop(IOService *provider)
{
    OSSafeReleaseNULL(wmi);
    OSSafeReleaseNULL(fn);
    IOHIDEventDriver::stop(provider);
}

// AsusWmi starts after this driver on some boots, so look it up on first use
void AsusNKey::toWmi(uint32_t code)
{
    if (!wmi) {
        OSDictionary *m = IOService::serviceMatching("AsusWmi");
        if (m) { wmi = IOService::copyMatchingService(m); m->release(); }
    }
    if (wmi && fn) wmi->callPlatformFunction(fn, false, (void *)(uintptr_t)code, nullptr, nullptr, nullptr);
    else IOLog("AsusNKey: key %02x, AsusWmi not loaded\n", code);
}

void AsusNKey::handleInterruptReport(AbsoluteTime ts, IOMemoryDescriptor *report, IOHIDReportType type, UInt32 reportID)
{
    if (type == kIOHIDReportTypeInput && report && (reportID == 0x5A || reportID == 0x03)) {
        uint8_t b[2] = { 0, 0 };
        report->readBytes(0, b, report->getLength() < 2 ? report->getLength() : 2);
        if (reportID == 0x03) {
            toWmi(0x88);
        } else if (b[1] == 0x10 || b[1] == 0x20) {
            heldBrightness = b[1] == 0x20 ? kHIDUsage_AV_TopCase_BrightnessUp : kHIDUsage_AV_TopCase_BrightnessDown;
            dispatchKeyboardEvent(ts, kHIDPage_AppleVendorTopCase, heldBrightness, 1);
        } else if (b[1] == 0x00) {
            if (heldBrightness) dispatchKeyboardEvent(ts, kHIDPage_AppleVendorTopCase, heldBrightness, 0);
            heldBrightness = 0;
        } else {
            toWmi(b[1]);
        }
        if (b[1] || reportID == 0x03) setProperty("AsusNKeyLast", (unsigned long long)((++count << 8) | (reportID == 0x03 ? 0x88 : b[1])), 32);
    }
    IOHIDEventDriver::handleInterruptReport(ts, report, type, reportID);
}

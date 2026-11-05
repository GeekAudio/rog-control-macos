// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
//
// rogkeyd: the GA403WM Fn keys. The N-KEY keyboard (USB HID 0b05:19b6) sends them as vendor input report 0x5A (one code
// byte, then 0x00 on release) and Fn+F12 as report 0x03. macOS's keyboard driver drops both. This agent reads them with
// IOHIDManager, next to Apple's driver, which keeps the keyboard; reading a keyboard needs Input Monitoring for this app.
//
//   0x7C  M3      built-in microphone mute on / off (CoreAudio)
//   0x38  M4      opens ROG Control
//   0x88  Fn+F12  Wi-Fi on / off (report 0x03)
//   every code also goes to AsusWmi (user client selector kAsusUcKey, ABI 4), which does the keyboard light (C4 / C5), Slash
//   (B3), profile (AE), brightness (10 / 20) and sleep (6C), and counts the keys for RogControl.
//
// Runs as a LaunchAgent (com.itlmt7925.rogkeyd). Log: ~/Library/Logs/rogkeyd.log.
import AppKit
import CoreAudio
import CoreWLAN
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) \(s)")
}

// ---- AsusWmi ------------------------------------------------------------------------------------------------------------
var wmi: io_connect_t = 0
func toWmi(_ code: UInt8) {
    if wmi == 0 {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AsusWmi"))
        guard svc != 0 else { log("AsusWmi not loaded, key \(String(format: "%02x", code)) dropped"); return }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &wmi) == KERN_SUCCESS else { wmi = 0; log("AsusWmi: open failed"); return }
    }
    var input: [UInt64] = [UInt64(code)]
    let r = IOConnectCallScalarMethod(wmi, 5, &input, 1, nil, nil)
    if r == kIOReturnUnsupported { log("AsusWmi has no key selector (ABI < 4): reboot with the new AsusWmi") }
    else if r != kIOReturnSuccess { log(String(format: "AsusWmi key %02x: 0x%08x", code, r)); IOServiceClose(wmi); wmi = 0 }
}

// ---- local actions ------------------------------------------------------------------------------------------------------
func builtinMic() -> AudioObjectID? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return nil }
    return ids.first { d in
        var t = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0, n: UInt32 = 4
        guard AudioObjectGetPropertyData(d, &t, 0, nil, &n, &v) == noErr, v == kAudioDeviceTransportTypeBuiltIn else { return false }
        var s = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var ss: UInt32 = 0
        return AudioObjectGetPropertyDataSize(d, &s, 0, nil, &ss) == noErr && ss > 0
    }
}
func toggleMic() {
    guard let mic = builtinMic() else { log("M3: no built-in microphone"); return }
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput,
                                       mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0, n: UInt32 = 4
    guard AudioObjectGetPropertyData(mic, &a, 0, nil, &n, &v) == noErr else { log("M3: mic has no mute"); return }
    v = v == 0 ? 1 : 0
    let r = AudioObjectSetPropertyData(mic, &a, 0, nil, 4, &v)
    log(r == noErr ? "M3: microphone \(v == 1 ? "muted" : "on")" : "M3: mute failed \(r)")
}
func openRogControl() {
    let url = URL(fileURLWithPath: "/Applications/RogControl.app")
    let c = NSWorkspace.OpenConfiguration(); c.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: c) { _, e in if let e { log("M4: \(e.localizedDescription)") } }
}
func toggleWiFi() {
    guard let w = CWWiFiClient.shared().interface() else { log("Fn+F12: no Wi-Fi interface"); return }
    let on = !w.powerOn()
    do { try w.setPower(on); log("Fn+F12: Wi-Fi \(on ? "on" : "off")") } catch { log("Fn+F12: \(error.localizedDescription)") }
}

func key(_ code: UInt8) {
    log(String(format: "key %02x", code))
    switch code {
    case 0x7C: toggleMic()
    case 0x38: openRogControl()
    case 0x88: toggleWiFi()
    default: break
    }
    toWmi(code)
}

// ---- keyboard -----------------------------------------------------------------------------------------------------------
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x0B05, kIOHIDProductIDKey: 0x19B6] as CFDictionary)
let onReport: IOHIDReportCallback = { _, _, _, type, id, report, len in
    guard type == kIOHIDReportTypeInput else { return }
    if id == 0x5A, len >= 2, report[1] != 0 { key(report[1]) }
    else if id == 0x03 { key(0x88) }
}
IOHIDManagerRegisterInputReportCallback(mgr, onReport, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

var opened = false
func tryOpen() {
    let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    if r == kIOReturnSuccess { opened = true; log("reading the N-KEY keyboard"); return }
    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log("no Input Monitoring access: allow rogkeyd in System Settings > Privacy & Security > Input Monitoring")
    } else {
        log(String(format: "keyboard open failed 0x%08x", r))
    }
}
tryOpen()
let retry = Timer(timeInterval: 10, repeats: true) { t in
    if opened { t.invalidate() } else { tryOpen() }
}
RunLoop.main.add(retry, forMode: .default)
CFRunLoopRun()

// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
//
// rogkeyd: the GA403WM Fn keys. The N-KEY keyboard (USB HID 0b05:19b6) sends them as vendor input report 0x5A (one code
// byte, then 0x00 on release) and Fn+F12 as report 0x03. macOS's keyboard driver drops both. This agent reads them with
// IOHIDManager, next to Apple's driver, which keeps the keyboard; reading a keyboard needs Input Monitoring for this app.
//
//   0x7C  M3      built-in microphone mute on / off (CoreAudio)
//   0x38  M4      opens ROG Control
//   0x88  Fn+F12  airplane mode: Wi-Fi and Bluetooth off, then back on as they were (report 0x03)
//         Fn+F9   the firmware types Win+P (one keyboard report with GUI and P together, GUI then held about 7 s), which
//                 macOS sees as Cmd+P. rogkeyd opens Displays settings (Win+P is Windows' display switcher) and, with the
//                 Accessibility grant, drops that Cmd+P and the stuck Cmd so apps do not open a Print dialog.
//   every code also goes to AsusWmi (user client selector kAsusUcKey, ABI 4), which does the keyboard light (C4 / C5), Slash
//   (B3), profile (AE), brightness (10 / 20) and sleep (6C), and counts the keys for RogControl.
//
// Runs as a LaunchAgent (com.itlmt7925.rogkeyd). Log: ~/Library/Logs/rogkeyd.log.
// One codesign identifier for every build; still, macOS ties an ad-hoc grant to the binary, so a new build needs the grant again.
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
// Bluetooth power: IOBluetooth's preference calls (what blueutil uses), looked up at run time.
let bt = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
typealias BtGet = @convention(c) () -> Int32
typealias BtSet = @convention(c) (Int32) -> Void
let btGet = dlsym(bt, "IOBluetoothPreferenceGetControllerPowerState").map { unsafeBitCast($0, to: BtGet.self) }
let btSet = dlsym(bt, "IOBluetoothPreferenceSetControllerPowerState").map { unsafeBitCast($0, to: BtSet.self) }

// Airplane mode: if any radio is on, remember which and turn both off; otherwise turn the remembered ones back on.
var restoreWiFi = true, restoreBT = true
func airplane() {
    let w = CWWiFiClient.shared().interface()
    let wifiOn = w?.powerOn() ?? false, btOn = (btGet?() ?? 0) != 0
    func wifi(_ on: Bool) { do { try w?.setPower(on) } catch { log("Fn+F12: Wi-Fi: \(error.localizedDescription)") } }
    if wifiOn || btOn {
        restoreWiFi = wifiOn; restoreBT = btOn
        if wifiOn { wifi(false) }
        if btOn { btSet?(0) }
        log("Fn+F12: airplane mode on (Wi-Fi was \(wifiOn ? "on" : "off"), Bluetooth was \(btOn ? "on" : "off"))")
    } else {
        if restoreWiFi { wifi(true) }
        if restoreBT { btSet?(1) }
        log("Fn+F12: airplane mode off (Wi-Fi \(restoreWiFi ? "on" : "off"), Bluetooth \(restoreBT ? "on" : "off"))")
    }
}
func openDisplays() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    log("Fn+F9: Displays settings")
}

// ---- Fn+F9's Cmd+P ------------------------------------------------------------------------------------------------------
// A session event tap (needs Accessibility). Only the Cmd+P that the N-KEY firmware typed for Fn+F9 is dropped: the raw
// HID report (GUI and P in one report, read below) marks it first, and the tap drops the next Cmd+P only within 300 ms of
// that mark. A Cmd+P typed by hand (Cmd, then P, in two reports) or on another keyboard never gets the mark, so Print
// keeps working. After a dropped one, Cmd is taken off the events that follow until the firmware lets Cmd go (about 7 s),
// since a key typed meanwhile would be a Cmd shortcut otherwise.
var f9Mark: UInt64 = 0                          // DispatchTime ns of the last firmware Win+P
var dropP = false, stripCmd = false
var tap: CFMachPort?
var tapAsked = false
let tapCallback: CGEventTapCallBack = { _, type, e, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(e) }
    let cmd = e.flags.contains(.maskCommand)
    switch type {
    case .flagsChanged:
        if !cmd { stripCmd = false }
    case .keyDown:
        let kc = e.getIntegerValueField(.keyboardEventKeycode)
        if kc == 35, cmd, f9Mark != 0, DispatchTime.now().uptimeNanoseconds &- f9Mark < 300_000_000 {
            f9Mark = 0; dropP = true; stripCmd = true
            return nil
        }
        if stripCmd { e.flags.remove(.maskCommand) }
    case .keyUp:
        if dropP, e.getIntegerValueField(.keyboardEventKeycode) == 35 { dropP = false; return nil }
        if stripCmd { e.flags.remove(.maskCommand) }
    default: break
    }
    return Unmanaged.passUnretained(e)
}
func startTap() {
    guard tap == nil else { return }
    let ask = !tapAsked; tapAsked = true                   // the system prompt once; the 10 s timer only checks
    guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): ask] as CFDictionary) else {
        if ask { log("no Accessibility access: Fn+F9 still opens Displays, but its Cmd+P reaches apps; allow rogkeyd in Privacy & Security > Accessibility") }
        return
    }
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { log("event tap: create failed"); return }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    tap = t
    log("event tap on: Fn+F9's Cmd+P is dropped")
}

func key(_ code: UInt8) {
    log(String(format: "key %02x", code))
    switch code {
    case 0x7C: toggleMic()
    case 0x38: openRogControl()
    case 0x88: airplane()
    default: break
    }
    toWmi(code)
}

// ---- keyboard -----------------------------------------------------------------------------------------------------------
// An open made while the login session is still coming up, or before the Input Monitoring grant, can succeed and still
// deliver no reports, and a reopen of the same manager does not fix that. So the manager is rebuilt: until an open works,
// once 30 s after start (the login race), and after every wake or session switch.
let onReport: IOHIDReportCallback = { _, _, _, type, id, report, len in
    guard type == kIOHIDReportTypeInput else { return }
    if id == 0x5A, len >= 2, report[1] != 0 { key(report[1]) }
    else if id == 0x03 { key(0x88) }
    else if id == 0x01, len >= 6 { keyboardReport(report[1], report[5] & 0x08 != 0) }   // byte 1 modifiers, P = usage 0x13
}
// Fn+F9 = GUI (left or right) and P appearing in the same report.
var lastGui = false, lastP = false
func keyboardReport(_ mods: UInt8, _ p: Bool) {
    let gui = mods & 0x88 != 0
    if gui && p && !lastGui && !lastP && mods & 0x77 == 0 { f9Mark = DispatchTime.now().uptimeNanoseconds; log("key f9 (Win+P)"); openDisplays() }
    lastGui = gui; lastP = p
}
var mgr: IOHIDManager?
var opened = false
func start(_ why: String) {
    if let m = mgr {
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x0B05, kIOHIDProductIDKey: 0x19B6] as CFDictionary)
    IOHIDManagerRegisterInputReportCallback(m, onReport, nil)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    mgr = m
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    let devices = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.count ?? 0
    opened = r == kIOReturnSuccess && access == kIOHIDAccessTypeGranted && devices > 0
    log(String(format: "%@: open 0x%08x, access %u, %d device(s)%@", why, r, access.rawValue, devices,
               opened ? ", reading the N-KEY keyboard" : ""))
    if access != kIOHIDAccessTypeGranted {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log("no Input Monitoring access: allow rogkeyd in System Settings > Privacy & Security > Input Monitoring")
    }
}
start("start")
startTap()
RunLoop.main.add(Timer(timeInterval: 10, repeats: true) { _ in if !opened { start("retry") }; startTap() }, forMode: .default)
RunLoop.main.add(Timer(timeInterval: 30, repeats: false) { _ in start("after login") }, forMode: .default)
let ws = NSWorkspace.shared.notificationCenter
for n in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
    ws.addObserver(forName: n, object: nil, queue: .main) { note in
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { start(note.name == NSWorkspace.didWakeNotification ? "wake" : "session") }
    }
}
CFRunLoopRun()

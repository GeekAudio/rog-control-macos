// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
//
// rogkeyd：GA403WM 的 Fn 功能键。N-KEY 键盘（USB HID 0b05:19b6）以厂商输入报告 0x5A 发送（一个码字节，松开时为
// 0x00），Fn+F12 走报告 0x03。macOS 的键盘驱动会把这两种都丢掉。本守护进程用 IOHIDManager 与 Apple 的驱动并行读取，
// 键盘仍归 Apple 的驱动管；读取键盘需要为本程序开启「输入监控」权限。
//
//   0x7C  M3      内置麦克风静音开 / 关（CoreAudio）
//   0x38  M4      打开 ROG 控制中心
//   0x88  Fn+F12  airplane mode: Wi-Fi and Bluetooth off, then back on as they were (report 0x03)
//         Fn+F9   the firmware types Win+P (one keyboard report with GUI and P together, GUI then held about 7 s), which
//                 macOS sees as Cmd+P. rogkeyd opens Displays settings (Win+P is Windows' display switcher) and, with the
//                 Accessibility grant, drops that Cmd+P and the stuck Cmd so apps do not open a Print dialog.
//   每个键码同时转发给 AsusWmi（user client 选择子 kAsusUcKey，ABI 4），由它处理键盘背光（C4 / C5）、Slash（B3）、
//   性能模式（AE）、亮度（10 / 20）与睡眠（6C），并为 RogControl 统计按键次数。
//
// 以 LaunchAgent（com.itlmt7925.rogkeyd）运行。日志：~/Library/Logs/rogkeyd.log。
// 所有构建共用同一个 codesign 标识；但 macOS 把 ad-hoc 授权绑定到二进制本身，因此重新编译后需要重新授权。
//
// 注意：下面这些日志文本是 Doctor 用来解析状态的标记，翻译时必须原样保留：
//   " start: " / ": open 0x" / ", reading the N-KEY keyboard" / "event tap on" / "no Accessibility access"
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
        guard svc != 0 else { log("AsusWmi 未加载，按键 \(String(format: "%02x", code)) 已丢弃"); return }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &wmi) == KERN_SUCCESS else { wmi = 0; log("AsusWmi：打开失败"); return }
    }
    var input: [UInt64] = [UInt64(code)]
    let r = IOConnectCallScalarMethod(wmi, 5, &input, 1, nil, nil)
    if r == kIOReturnUnsupported { log("AsusWmi 没有按键选择器（ABI < 4）：请换用新版 AsusWmi 后重启") }
    else if r != kIOReturnSuccess { log(String(format: "AsusWmi 按键 %02x：0x%08x", code, r)); IOServiceClose(wmi); wmi = 0 }
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
    guard let mic = builtinMic() else { log("M3：未找到内置麦克风"); return }
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput,
                                       mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0, n: UInt32 = 4
    guard AudioObjectGetPropertyData(mic, &a, 0, nil, &n, &v) == noErr else { log("M3：麦克风没有静音属性"); return }
    v = v == 0 ? 1 : 0
    let r = AudioObjectSetPropertyData(mic, &a, 0, nil, 4, &v)
    log(r == noErr ? "M3：麦克风\(v == 1 ? "已静音" : "已开启")" : "M3：静音失败 \(r)")
}
func openRogControl() {
    let url = URL(fileURLWithPath: "/Applications/RogControl.app")
    let c = NSWorkspace.OpenConfiguration(); c.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: c) { _, e in if let e { log("M4：\(e.localizedDescription)") } }
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
    func wifi(_ on: Bool) { do { try w?.setPower(on) } catch { log("Fn+F12：Wi-Fi：\(error.localizedDescription)") } }
    if wifiOn || btOn {
        restoreWiFi = wifiOn; restoreBT = btOn
        if wifiOn { wifi(false) }
        if btOn { btSet?(0) }
        log("Fn+F12：飞行模式已开启（Wi-Fi 原为\(wifiOn ? "开" : "关")，蓝牙原为\(btOn ? "开" : "关")）")
    } else {
        if restoreWiFi { wifi(true) }
        if restoreBT { btSet?(1) }
        log("Fn+F12：飞行模式已关闭（Wi-Fi \(restoreWiFi ? "开" : "关")，蓝牙 \(restoreBT ? "开" : "关")）")
    }
}
func openDisplays() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    log("Fn+F9：显示器设置")
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
        if ask { log("no Accessibility access：Fn+F9 仍会打开显示器设置，但其 Cmd+P 会传给应用；请在「隐私与安全性 › 辅助功能」中允许 rogkeyd") }
        return
    }
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { log("事件监听创建失败"); return }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    tap = t
    log("event tap on：Fn+F9 的 Cmd+P 将被拦截")
}

func key(_ code: UInt8) {
    log(String(format: "按键 %02x", code))
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
    if gui && p && !lastGui && !lastP && mods & 0x77 == 0 { f9Mark = DispatchTime.now().uptimeNanoseconds; log("按键 f9（Win+P）"); openDisplays() }
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
        log("没有「输入监控」权限：请在系统设置 › 隐私与安全性 › 输入监控中允许 rogkeyd")
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

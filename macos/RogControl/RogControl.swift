// SPDX-License-Identifier: BSD-3-Clause-Clear
// Copyright (c) 2026 thanhnndev and contributors
// RogControl: a small ROG Control Center for macOS on the GA403WM (ROG Zephyrus G14 2025): performance mode (Silent,
// Performance, Turbo, Manual power limits), battery charge limit, CPU temperature / package power / fan speeds, GPU MUX
// state. Settings are kept per power source (AC / battery) and applied again when the source changes and at login, as asusd
// does. Native app window and menu bar popover, SwiftUI, SF Symbols only.
//
// Inspired by asusctl / rog-control-center (asus-linux.org, Luke Jones and contributors, MPL-2.0); no code is taken from it.
// Talks to kexts/AsusWmi through its user client (ABI: kexts/AsusWmi/asuswmi_abi.h, no sudo) and reads the sysctl
// debug.amdcppc.sensors of kexts/AmdCppc.
//
// Command line (same binary):
//   RogControl --bench [seconds]   runs Silent, Performance and Turbo in turn under full load on every CPU and prints package
//                                  power, Tctl, fan speeds and clocks per mode; puts the previous mode back afterwards
// Build: scripts/build-rogcontrol.sh
import AppKit
import SwiftUI
import Charts
import IOKit
import IOKit.ps

// ---- driver access (asuswmi_abi.h) -----------------------------------------------------------------------------------------
struct AsusState {
    var present = false, ac = true, fanCustom = false
    var profile: Int? = nil, charge: Int? = nil
    var cpuFan = 0, gpuFan = 0
    var ppt = [0, 0, 0]
    var ranges = [(15, 80), (25, 80), (35, 80)]
    var gpuMux: UInt32 = ~0, dgpu: UInt32 = ~0, baseTgp = 0
    var backlight: Int? = nil, backlightMax = 0
    var batDesign = 0, batFull = 0, batNow = 0, batState = 0, batRate = 0   // mAh, mAh, mAh, _BST state, mA
    var kbd: Int? = nil, slash: Int? = nil, hid = false                   // ABI 3: keyboard light 0..3, Slash (packed), N-KEY seen
    var lighting = false                                                    // the kext has the keyboard / Slash settings
}

// Slash lighting (asuswmi_abi.h ASUS_SLASH_*): mode index, brightness 0..3 (0 = off), interval 0..5
struct Slash: Equatable {
    static let modes = ["Static", "Bounce", "Slash", "Loading", "Bit Stream", "Transmission", "Flow", "Flux",
                        "Phantom", "Spectrum", "Hazard", "Interfacing", "Ramp", "Game Over", "Start", "Buzzer"]
    var mode = 2, bright = 2, interval = 0
    var packed: Int { mode | (bright << 8) | (interval << 12) }
    init(mode: Int = 2, bright: Int = 2, interval: Int = 0) { self.mode = mode; self.bright = bright; self.interval = interval }
    init(packed v: Int) { mode = v & 0xff; bright = (v >> 8) & 0xf; interval = (v >> 12) & 0xf }
}

enum Asus {
    static let abi: UInt32 = 3
    enum Sel: UInt32 { case state = 0, set = 1, fanRead = 2, fanWrite = 3, fanReset = 4 }
    enum What: UInt64 { case profile = 1, spl = 2, sppt = 3, fppt = 4, charge = 5, backlight = 6, kbd = 7, slash = 8 }

    static func open() -> io_connect_t? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AsusWmi"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        return IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS ? conn : nil
    }

    static func call(_ sel: Sel, scalars: [UInt64] = [], input: [UInt8]? = nil, outCount: Int = 0) -> (kern_return_t, [UInt8]) {
        guard let c = open() else { return (kIOReturnNotFound, []) }
        defer { IOServiceClose(c) }
        var out = [UInt8](repeating: 0, count: outCount)
        var outSize = outCount
        var sc = scalars
        let inp = input ?? []
        let kr: kern_return_t = sc.withUnsafeMutableBufferPointer { sb in
            inp.withUnsafeBytes { ib in
                out.withUnsafeMutableBytes { ob in
                    IOConnectCallMethod(c, sel.rawValue, sb.baseAddress, UInt32(sb.count), inp.isEmpty ? nil : ib.baseAddress, ib.count,
                                        nil, nil, outCount > 0 ? ob.baseAddress : nil, &outSize)
                }
            }
        }
        return (kr, Array(out.prefix(outSize)))
    }

    static func state() -> AsusState {
        var s = AsusState()
        let (kr, b) = call(.state, outCount: 27 * 4)
        guard kr == KERN_SUCCESS, b.count >= 24 * 4 else { return s }
        func w(_ i: Int) -> UInt32 { b.withUnsafeBytes { $0.load(fromByteOffset: i * 4, as: UInt32.self) } }
        guard w(0) >= 1, w(0) <= abi else { return s }          // ABI 1 / 2 (fewer words) still work
        s.present = true
        s.ac = w(1) & 1 != 0; s.fanCustom = w(1) & 2 != 0
        s.profile = w(2) == ~0 ? nil : Int(w(2)); s.charge = w(3) == ~0 ? nil : Int(w(3))
        s.cpuFan = Int(w(4)); s.gpuFan = Int(w(5))
        s.ppt = [Int(w(6)), Int(w(7)), Int(w(8))]
        s.ranges = [(Int(w(9)), Int(w(10))), (Int(w(11)), Int(w(12))), (Int(w(13)), Int(w(14)))]
        s.gpuMux = w(15); s.dgpu = w(16); s.baseTgp = Int(w(17))
        guard w(0) >= 2 else { return s }
        s.backlight = w(18) == ~0 ? nil : Int(w(18)); s.backlightMax = Int(w(19))
        s.batDesign = Int(w(20)); s.batFull = Int(w(21)); s.batNow = Int(w(22))
        s.batState = Int(w(23) & 0xff); s.batRate = Int(w(23) >> 8)
        guard w(0) >= 3, b.count >= 27 * 4 else { return s }
        s.lighting = true
        s.kbd = w(24) == ~0 ? nil : Int(w(24)); s.slash = w(25) == ~0 ? nil : Int(w(25)); s.hid = w(26) != 0
        return s
    }

    @discardableResult static func set(_ what: What, _ v: Int) -> kern_return_t { call(.set, scalars: [what.rawValue, UInt64(v)]).0 }
    static func fanCurve(fan: Int, profile: Int) -> [UInt8]? {
        let (kr, b) = call(.fanRead, scalars: [UInt64(fan), UInt64(profile)], outCount: 16)
        return kr == KERN_SUCCESS && b.count == 16 ? b : nil
    }
    @discardableResult static func setFanCurve(fan: Int, _ c: [UInt8]) -> kern_return_t { call(.fanWrite, scalars: [UInt64(fan)], input: c).0 }
    @discardableResult static func fanReset() -> kern_return_t { call(.fanReset).0 }
}

// AmdCppc: "tctl=<m°C> pkg_mw=<mW>" (power averaged since the previous read) and the per-CPU clock report
enum Sensors {
    static func string(_ name: String) -> String? {
        var len = 0
        guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len + 1)
        guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func read() -> (tctl: Double?, watts: Double?) {
        guard let s = string("debug.amdcppc.sensors") else { return (nil, nil) }
        var t: Double?, w: Double?
        for kv in s.split(separator: " ") {
            let p = kv.split(separator: "="); guard p.count == 2, let v = Double(p[1]) else { continue }
            if p[0] == "tctl", v > -1 { t = v / 1000 }
            if p[0] == "pkg_mw", v > 0 { w = v / 1000 }
        }
        return (t, w)
    }
    // average effective MHz of the busy CPUs 0-7 (Zen 5) and 8-23 (Zen 5c) from debug.amdcppc.freq
    static func clocks() -> (big: Int, little: Int)? {
        guard let s = string("debug.amdcppc.freq") else { return nil }
        var big: [Int] = [], little: [Int] = []
        for part in s.split(separator: "|").dropFirst() {
            let f = part.split(separator: " ")
            guard f.count >= 2, let cpu = Int(f[0]) else { continue }
            let v = f[1].split(separator: "/")
            guard v.count >= 2, let mhz = Int(v[0]), let busy = Int(v[1].dropLast()), busy >= 50 else { continue }
            if cpu < 8 { big.append(mhz) } else { little.append(mhz) }
        }
        func avg(_ a: [Int]) -> Int { a.isEmpty ? 0 : a.reduce(0, +) / a.count }
        return (avg(big), avg(little))
    }
}

// ---- modes and settings ------------------------------------------------------------------------------------------------------
enum Mode: String, CaseIterable, Identifiable {
    case silent, performance, turbo, manual
    var id: String { rawValue }
    var title: String { ["silent": "Silent", "performance": "Performance", "turbo": "Turbo", "manual": "Custom"][rawValue]! }   // manual is shown as Custom
    var symbol: String {
        // one family: filled glyphs at one weight, drawn in the same chamfered badge (ModeBadge)
        ["silent": "leaf.fill", "performance": "gauge.with.needle.fill", "turbo": "flame.fill", "manual": "dial.low.fill"][rawValue]!
    }
    var firmwareProfile: Int { self == .silent ? 2 : self == .turbo ? 1 : 0 }   // asus-wmi: 0 balanced, 1 overboost, 2 silent
    static func from(profile: Int?) -> Mode? { profile == 2 ? .silent : profile == 1 ? .turbo : profile == 0 ? .performance : nil }
}

// One setting set per power source, in UserDefaults ("ac.mode", "battery.spl", ...)
struct SourceSettings {
    var mode: Mode
    var spl: Int, sppt: Int, fppt: Int
    var fanBase: Mode            // whose firmware fan curve Manual uses (silent / performance / turbo)
    static func load(ac: Bool) -> SourceSettings {
        let d = UserDefaults.standard, k = ac ? "ac." : "battery."
        func i(_ n: String, _ def: Int) -> Int { d.object(forKey: k + n) == nil ? def : d.integer(forKey: k + n) }
        return SourceSettings(mode: Mode(rawValue: d.string(forKey: k + "mode") ?? "") ?? .performance,
                              spl: i("spl", ac ? 45 : 30), sppt: i("sppt", ac ? 65 : 35), fppt: i("fppt", ac ? 80 : 50),
                              fanBase: Mode(rawValue: d.string(forKey: k + "fanBase") ?? "") ?? .performance)
    }
    func save(ac: Bool) {
        let d = UserDefaults.standard, k = ac ? "ac." : "battery."
        d.set(mode.rawValue, forKey: k + "mode"); d.set(spl, forKey: k + "spl"); d.set(sppt, forKey: k + "sppt")
        d.set(fppt, forKey: k + "fppt"); d.set(fanBase.rawValue, forKey: k + "fanBase")
    }
}

// ---- login item (a user LaunchAgent; no signing needed) ------------------------------------------------------------------
enum LoginItem {
    static let label = "com.itlmt7925.RogControl"
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }
    static func set(_ on: Bool) {
        if !on { try? FileManager.default.removeItem(at: plist); return }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let d: [String: Any] = ["Label": label, "ProgramArguments": [exe, "--background"], "RunAtLoad": true, "ProcessType": "Interactive",
                                "LimitLoadToSessionType": "Aqua"]
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        (d as NSDictionary).write(to: plist, atomically: true)
    }
}

// ---- apply ---------------------------------------------------------------------------------------------------------------
enum Apply {
    // Returns an error text or nil. Manual: profile first (fresh firmware state), then the chosen firmware fan curves as custom
    // curves (needed for power limits on this board), then the limits, kept in order SPL <= SPPT <= FPPT and in range.
    static func mode(_ s: SourceSettings, state st: AsusState) -> String? {
        var m = s.mode
        if m == .turbo && !st.ac { m = .performance }               // as Armoury Crate: no Turbo on battery
        if m != .manual {
            return Asus.set(.profile, m.firmwareProfile) == KERN_SUCCESS ? nil : "could not set the profile"
        }
        guard Asus.set(.profile, Mode.performance.firmwareProfile) == KERN_SUCCESS else { return "could not set the profile" }
        let base = s.fanBase == .turbo && !st.ac ? Mode.performance : s.fanBase
        for fan in 0..<2 {
            guard let c = Asus.fanCurve(fan: fan, profile: base.firmwareProfile) else { return "could not read the fan curve" }
            guard Asus.setFanCurve(fan: fan, c) == KERN_SUCCESS else { return "the fan curve was refused" }
        }
        let r = st.ranges
        let spl = min(max(s.spl, r[0].0), r[0].1)
        let sppt = min(max(max(s.sppt, spl), r[1].0), r[1].1)
        let fppt = min(max(max(s.fppt, sppt), r[2].0), r[2].1)
        for (w, v) in [(Asus.What.spl, spl), (.sppt, sppt), (.fppt, fppt)] where Asus.set(w, v) != KERN_SUCCESS {
            return "power limit \(v) W was refused"
        }
        return nil
    }
}

// ---- model -------------------------------------------------------------------------------------------------------------------
@MainActor
final class RogModel: ObservableObject {
    @Published var st = AsusState()
    @Published var tctl: Double?
    @Published var watts: Double?
    @Published var settings = SourceSettings.load(ac: true)
    @Published var charge = UserDefaults.standard.object(forKey: "charge") == nil ? 100 : UserDefaults.standard.integer(forKey: "charge")
    @Published var kbd = UserDefaults.standard.object(forKey: "kbd") == nil ? 2 : UserDefaults.standard.integer(forKey: "kbd")
    @Published var slash = UserDefaults.standard.object(forKey: "slash") == nil ? Slash() : Slash(packed: UserDefaults.standard.integer(forKey: "slash"))
    @Published var message = ""
    @Published var loginEnabled = LoginItem.enabled
    @Published var curve: [UInt8]? = nil
    @Published var gpuCurve: [UInt8]? = nil
    @Published var curveMode: Mode = .performance
    @Published var profileError = ""
    @Published var chargeError = ""
    @Published var lightingError = ""
    struct Sample: Identifiable { let id: Int; let date: Date; let temp: Double; let watts: Double? }
    @Published var history: [Sample] = []
    private var sampleID = 0
    var activeMode: Mode? { st.present ? (st.fanCustom ? .manual : Mode.from(profile: st.profile)) : nil }
    var modeLabel: String { activeMode?.title ?? "Unavailable" }
    var currentSlash: Slash { st.slash.map { Slash(packed: $0) } ?? slash }
    var manualDirty: Bool {
        let saved = SourceSettings.load(ac: st.ac)
        return settings.spl != saved.spl || settings.sppt != saved.sppt || settings.fppt != saved.fppt || settings.fanBase != saved.fanBase
    }
    var onChange: (() -> Void)?
    // window navigation, so the popover can open a given page
    @Published var page: RogPage = .performance
    @Published var advanced = false
    // what ROG Control did on its own (power source change); shown for a few minutes
    @Published var autoNote = ""
    var autoNoteAt: Date?
    var recentAutoNote: String? {
        guard let at = autoNoteAt, Date().timeIntervalSince(at) < 600, !autoNote.isEmpty else { return nil }
        return autoNote
    }
    // Custom (manual) is "set up" once its limits were saved from Advanced, or it was already in use
    var customReady: Bool { UserDefaults.standard.bool(forKey: "custom.saved") || settings.mode == .manual }
    private var timer: Timer?
    private var lastAC: Bool?
    var visible = false { didSet { schedule() } }

    // Snapshot / preview: fixed state, never touches the driver (no reads, no writes, no timer)
    init(preview st: AsusState, tctl: Double?, watts: Double?, curve: [UInt8]?, gpuCurve: [UInt8]?) {
        self.st = st; self.tctl = tctl; self.watts = watts; self.curve = curve; self.gpuCurve = gpuCurve
        settings = SourceSettings(mode: Mode.from(profile: st.profile) ?? .performance, spl: 45, sppt: 65, fppt: 80, fanBase: .performance)
        charge = st.charge ?? 80; kbd = st.kbd ?? 2; slash = st.slash.map { Slash(packed: $0) } ?? Slash()
        curveMode = settings.mode; preview = true
    }
    var preview = false

    init() {
        refresh()
        // first run: keep what the firmware is doing now instead of imposing a default
        let d = UserDefaults.standard
        if st.present, d.string(forKey: st.ac ? "ac.mode" : "battery.mode") == nil, let m = Mode.from(profile: st.profile) {
            var s = SourceSettings.load(ac: st.ac); s.mode = m; s.save(ac: st.ac)
        }
        if st.present, d.object(forKey: "charge") == nil, let c = st.charge, (20...100).contains(c) { charge = c; d.set(c, forKey: "charge") }
        settings = SourceSettings.load(ac: st.ac)
        applyAll(reason: "start")
        applyLighting()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // the keyboard comes back from sleep with its own defaults: give it a moment, then send ours again
            // bind self once (a `self?` inside the delayed closure is a captured weak var, which older toolchains reject there)
            guard let model = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { model.applyLighting() } }
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<RogModel>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { m.powerChanged() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        schedule()
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: visible ? 2 : 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let previousMode = activeMode
        st = Asus.state()
        let s = Sensors.read()
        tctl = s.tctl; watts = s.watts
        if let t = s.tctl {
            sampleID += 1
            history.append(Sample(id: sampleID, date: Date(), temp: t, watts: s.watts))
            if history.count > 180 { history.removeFirst(history.count - 180) }   // 6 min at the 2 s visible rate
        }
        if st.present, lastAC != nil, lastAC != st.ac { powerChanged() }
        lastAC = st.ac
        if previousMode != activeMode { loadCurve() }
        onChange?()
    }

    func powerChanged() {
        let now = Asus.state()
        guard now.present, now.ac != lastAC else { return }
        st = now; lastAC = now.ac
        settings = SourceSettings.load(ac: now.ac)
        applyAll(reason: now.ac ? "on AC" : "on battery")
        autoNote = "Switched to \(settings.mode.title) when the charger was \(now.ac ? "plugged in" : "unplugged")"
        autoNoteAt = Date()
    }

    func applyAll(reason: String) {
        guard st.present else { message = "AsusWmi is not loaded"; return }
        profileError = Apply.mode(settings, state: st) ?? ""
        chargeError = ""
        if st.charge != charge, Asus.set(.charge, charge) != KERN_SUCCESS { chargeError = "Charge limit was not applied." }
        st = Asus.state()
        loadCurve()
        let errs = [profileError, chargeError].filter { !$0.isEmpty }
        message = errs.isEmpty ? "\(settings.mode.title) applied (\(reason))" : errs.joined(separator: "; ")
        onChange?()
    }

    func choose(_ m: Mode) {
        settings.mode = m
        settings.save(ac: st.ac)
        applyAll(reason: st.ac ? "AC" : "battery")
    }
    func saveManual() { settings.save(ac: st.ac); applyAll(reason: "manual limits") }
    func setCharge(_ v: Int) {
        charge = v; UserDefaults.standard.set(v, forKey: "charge")
        chargeError = Asus.set(.charge, v) == KERN_SUCCESS ? "" : "Charge limit was not applied."
        message = chargeError.isEmpty ? "charge limit \(v) %" : chargeError
        st = Asus.state()
    }
    func applyLighting() {
        guard st.lighting else { return }
        var errs: [String] = []
        if Asus.set(.kbd, kbd) != KERN_SUCCESS { errs.append("keyboard light refused") }
        if Asus.set(.slash, slash.packed) != KERN_SUCCESS { errs.append("Slash refused") }
        st = Asus.state()
        lightingError = errs.joined(separator: "; ")
        if !errs.isEmpty { message = lightingError }
    }
    func setKbd(_ v: Int) {
        kbd = v; UserDefaults.standard.set(v, forKey: "kbd")
        lightingError = Asus.set(.kbd, v) == KERN_SUCCESS ? "" : "Keyboard light was not applied. Check the keyboard connection."
        message = lightingError.isEmpty ? "keyboard light \(v)" : lightingError
        st = Asus.state()
    }
    func setSlash(_ s: Slash) {
        slash = s; UserDefaults.standard.set(s.packed, forKey: "slash")
        lightingError = Asus.set(.slash, s.packed) == KERN_SUCCESS ? "" : "Slash lighting was not applied. Check the keyboard connection."
        message = lightingError.isEmpty ? (s.bright == 0 ? "Slash off" : "Slash \(Slash.modes[s.mode])") : lightingError
        st = Asus.state()
    }
    var batteryLine: String {
        guard st.batDesign > 5 else { return "battery data not available from the firmware" }
        var s = ""
        if st.batFull > 0 { s += String(format: "health %.0f %% (%d / %d mAh)", 100.0 * Double(st.batFull) / Double(st.batDesign), st.batFull, st.batDesign) }
        if st.batFull > 0, st.batNow > 0 { s += String(format: " · %.0f %%", 100.0 * Double(st.batNow) / Double(st.batFull)) }
        if st.batState & 2 != 0 { s += " · charging \(st.batRate) mA" } else if st.batState & 1 != 0 { s += " · \(st.batRate) mA" }
        return s
    }
    func loadCurve() {
        // Manual shows the selected firmware reference, not an editable or measured RPM curve.
        curveMode = settings.mode == .manual ? settings.fanBase : (Mode.from(profile: st.profile) ?? .performance)
        if curveMode == .turbo && !st.ac { curveMode = .performance }
        curve = st.present ? Asus.fanCurve(fan: 0, profile: curveMode.firmwareProfile) : nil
        gpuCurve = st.present ? Asus.fanCurve(fan: 1, profile: curveMode.firmwareProfile) : nil
    }
    func setLogin(_ on: Bool) { LoginItem.set(on); loginEnabled = LoginItem.enabled }
    // the mode each power source uses; the current one is applied, the other is only saved
    func mode(forAC ac: Bool) -> Mode { ac == st.ac ? settings.mode : SourceSettings.load(ac: ac).mode }
    func setMode(_ mode: Mode, forAC ac: Bool) {
        if ac == st.ac { choose(mode); return }
        var s = SourceSettings.load(ac: ac); s.mode = mode; s.save(ac: ac)
        objectWillChange.send()
    }
    func saveCustom() {
        UserDefaults.standard.set(true, forKey: "custom.saved")
        settings.mode = .manual
        settings.save(ac: st.ac)
        applyAll(reason: "custom limits")
    }
    func resetCustom() {
        let saved = SourceSettings.load(ac: st.ac)
        settings.spl = saved.spl; settings.sppt = saved.sppt; settings.fppt = saved.fppt; settings.fanBase = saved.fanBase
        loadCurve()
    }
    func seedHistory() {
        let now = Date()
        history = (0..<120).map { i in
            let x = Double(i)
            let t: Double = 70 + 5 * sin(x / 11) + 2 * sin(x / 3)
            let w: Double = 36 + 9 * sin(x / 7 + 1) + 3 * sin(x / 2)
            return Sample(id: i, date: now.addingTimeInterval(Double(i - 120) * 2), temp: t, watts: w)
        }
    }
}

// ---- views ---------------------------------------------------------------------------------------------------------------------
// Two surfaces. The menu bar panel is native (system materials and accent) and holds only what is used daily: the mode, why the
// machine is hot or loud, the charge limit and the keyboard light. The window is the ROG side: dark, one red accent, chamfered
// cards and the Slash bar's slanted segments as its graphic language; it holds setup (power sources, Custom limits, fan curves,
// battery, lighting).

enum RogPage: String, CaseIterable, Identifiable {
    case performance = "Performance", battery = "Battery", lighting = "Lighting", general = "General"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .performance: return "gauge.with.dots.needle.67percent"
        case .battery: return "battery.75percent"
        case .lighting: return "keyboard"
        case .general: return "gearshape"
        }
    }
}

extension Mode {
    var short: String {
        switch self {
        case .silent: return "Quiet"
        case .performance: return "Balanced"
        case .turbo: return "Max power"
        case .manual: return "Your limits"
        }
    }
    var detail: String {
        switch self {
        case .silent: return "Quiet fans, cool and long battery"
        case .performance: return "Balanced for work and play"
        case .turbo: return "Full power on the charger"
        case .manual: return "Your own power limits"
        }
    }
    var level: Int { self == .silent ? 1 : self == .performance ? 2 : self == .turbo ? 4 : 3 }   // relative power, 4 segments
}

extension View {
    // numbers that refresh every 2 s roll instead of jumping (macOS 14+; plain text before)
    @ViewBuilder func rollingNumber(_ v: Double) -> some View {
        if #available(macOS 14.0, *) { self.contentTransition(.numericText(value: v)) } else { self }
    }
}

enum Fmt {
    static func temp(_ t: Double?) -> String { t.map { String(format: "%.0f°", $0) } ?? "–" }
    static func watts(_ w: Double?) -> String { w.map { String(format: "%.1f W", $0) } ?? "–" }
}

struct ErrorLine: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// ---- menu bar panel ------------------------------------------------------------------------------------------------------------
// Same language as the window (dark, chamfered, one red), sized for a glance: temperature leads, then the mode, then the two
// settings people change by hand (charge limit, keyboard light). Setup lives in the window.
// The mode glyph in a small chamfered plate: red with a white glyph when active, raised grey otherwise.
struct ModeBadge: View {
    let mode: Mode, active: Bool, size: CGFloat
    var body: some View {
        Image(systemName: mode.symbol).font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(active ? Color.white : T.dim)
            .frame(width: size, height: size)
            .background(active ? T.red : T.raised, in: Chamfer(cut: size * 0.25))
            .accessibilityHidden(true)
    }
}

struct PopoverTile: View {
    let mode: Mode, selected: Bool, unavailable: Bool, subtitle: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    ModeBadge(mode: mode, active: selected, size: 20)
                    Text(mode.title).font(T.num(11.5)).foregroundStyle(T.text).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                HStack {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(T.dim).lineLimit(1)
                    Spacer(minLength: 4)
                    Segments(lit: mode.level, total: 4, height: 4, color: selected ? T.red : Color.white.opacity(0.4)).frame(width: 34)
                }
            }
            .padding(.horizontal, 10).frame(height: 54)
            .background(selected ? T.red.opacity(0.12) : hover ? T.raised : T.surface, in: Chamfer(cut: 9))
            .overlay(Chamfer(cut: 9).stroke(selected ? T.red : T.line, lineWidth: 1))
            .contentShape(Chamfer(cut: 9))
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .onHover { hover = $0 }
        .accessibilityLabel(mode.title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(unavailable ? "Turbo needs the charger" : mode.detail)
    }
}

struct ContentView: View {
    @ObservedObject var m: RogModel
    let openWindow: (RogPage, Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !m.st.present {
                Label("AsusWmi is not loaded. Controls are off until the kext loads.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true)
            }
            header
            modes
            VStack(spacing: 0) {
                row("Charge limit") {
                    let opts = [60, 80, 100]
                    Pills(items: opts.map { "\($0)%" }, selected: m.st.charge.flatMap { opts.firstIndex(of: $0) }, minWidth: 30, pad: 7, label: "Charge limit") {
                        m.setCharge(opts[$0])
                    }
                    .disabled(m.st.charge == nil)
                }
                if m.st.lighting {
                    Rectangle().fill(T.line).frame(height: 1)
                    row("Keyboard") {
                        Pills(items: ["Off", "Low", "Med", "High"], selected: m.st.kbd, minWidth: 30, pad: 7, label: "Keyboard") { m.setKbd($0) }
                            .disabled(m.st.kbd == nil)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(T.surface, in: Chamfer(cut: 10))
            .overlay(Chamfer(cut: 10).stroke(T.line))
            .disabled(!m.st.present)
            ErrorLine(text: m.chargeError)
            ErrorLine(text: m.lightingError)
            footer
        }
        .padding(12).frame(width: 320)
        .background(T.bg)
        .environment(\.colorScheme, .dark)
        .tint(T.red)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(m.tctl.map { String(format: "%.0f", $0) } ?? "–").font(T.num(40)).monospacedDigit()
                        .foregroundStyle((m.tctl ?? 0) >= 90 ? T.red : T.text)
                        .rollingNumber(m.tctl ?? 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: m.tctl)
                    Text("°C").font(T.num(14, .medium)).foregroundStyle(T.dim)
                }
                Caps((m.tctl ?? 0) >= 90 ? "CPU · hot" : "CPU")
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Caps("Power"); Spacer()
                    Text(m.watts.map { String(format: "%.1f", $0) } ?? "–").font(T.num(12)).monospacedDigit().foregroundStyle(T.text)
                    Text("W").font(.system(size: 9.5)).foregroundStyle(T.dim)
                }
                fan("CPU fan", m.st.cpuFan)
                fan("GPU fan", m.st.gpuFan)
            }
            .frame(width: 136)
        }
        .padding(12)
        .background(T.surface, in: Chamfer(cut: 12))
        .overlay(Chamfer(cut: 12).stroke(T.line))
        .accessibilityElement(children: .combine)
    }

    func fan(_ name: String, _ rpm: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Caps(name); Spacer()
                Text(verbatim: !m.st.present ? "–" : rpm == 0 ? "Off" : String(rpm)).font(T.num(10.5, .medium)).monospacedDigit().foregroundStyle(T.text)
            }
            Segments(lit: m.st.present ? min(12, rpm * 12 / 6500) : 0, total: 12, height: 4)
        }
    }

    var modes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Caps("Mode"); Spacer()
                Image(systemName: m.st.ac ? "powerplug.fill" : "battery.75percent").font(.system(size: 9.5)).foregroundStyle(T.dim)
                Text(m.st.ac ? "On charger" : "On battery").font(.system(size: 10.5)).foregroundStyle(T.dim)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Mode.allCases) { mode in
                    let unavailable = mode == .turbo && !m.st.ac
                    let sub = unavailable ? "Needs charger" : (mode == .manual && !m.customReady) ? "Set up…" : mode.short
                    PopoverTile(mode: mode, selected: m.activeMode == mode, unavailable: unavailable, subtitle: sub) {
                        if mode == .manual && !m.customReady { openWindow(.performance, true) } else { m.choose(mode) }
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: m.activeMode)
            .disabled(!m.st.present)
            if let note = m.recentAutoNote {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(T.red)
                    Text(note).font(.system(size: 10.5)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            ErrorLine(text: m.profileError)
        }
    }

    var footer: some View {
        HStack {
            Button { openWindow(m.page, false) } label: {
                HStack(spacing: 6) {
                    Text("Open ROG Control").font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.dim)
                }
                .padding(.horizontal, 10).frame(height: 26)
            }
            .buttonStyle(RogButtonStyle(cut: 6))
            Spacer()
            Menu {
                Toggle("Open at Login", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) }))
                Divider()
                Button("Created by thanhnndev (GitHub)") { NSWorkspace.shared.open(URL(string: "https://github.com/thanhnndev")!) }
                Button("Quit ROG Control") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(T.dim)
                    .frame(width: 26, height: 26).background(T.raised, in: Chamfer(cut: 6))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack { Text(title).font(.system(size: 11.5)).foregroundStyle(T.text); Spacer(minLength: 8); control() }.frame(height: 40)
    }
}

// ---- window: ROG look ----------------------------------------------------------------------------------------------------------
// Dark-first, one brand accent (red), amber for warnings, a status color never carries meaning alone.
enum T {
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let side = Color(red: 0.063, green: 0.067, blue: 0.078)
    static let surface = Color(red: 0.086, green: 0.094, blue: 0.110)
    static let raised = Color(red: 0.118, green: 0.125, blue: 0.145)
    static let hover = Color(red: 0.150, green: 0.158, blue: 0.180)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.93, green: 0.93, blue: 0.94)
    static let dim = Color(red: 0.55, green: 0.57, blue: 0.60)
    static let faint = Color(red: 0.40, green: 0.42, blue: 0.45)
    static let red = Color(red: 1.0, green: 0.13, blue: 0.24)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.20)
    static let nsBG = NSColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1)
    static func num(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w).width(.expanded) }
}
struct Caps: View {      // small tracked label, the HUD voice of the window
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(T.faint) }
}

// Sharp card with the top-right corner cut
struct Chamfer: Shape {
    var cut: CGFloat = 14
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cut)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p
    }
}
struct Card<C: View>: View {
    var cut: CGFloat = 14, pad: CGFloat = 18, active = false, stretch = false
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(pad).frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
            .background(active ? T.red.opacity(0.10) : T.surface, in: Chamfer(cut: cut))
            .overlay(Chamfer(cut: cut).stroke(active ? T.red : T.line, lineWidth: 1))
    }
}

// The Slash bar's slanted LED segments
struct Slant: Shape {
    func path(in r: CGRect) -> Path {
        let k = min(r.height * 0.45, r.width * 0.35)   // tall cells keep a gentle slant
        var p = Path(); p.move(to: CGPoint(x: r.minX + k, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p
    }
}
struct Segments: View {
    let lit: Int, total: Int
    var height: CGFloat = 10, color: Color = T.red
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { i in Slant().fill(i < lit ? color : Color.white.opacity(0.08)).frame(height: height) }
        }
        .animation(.easeOut(duration: 0.25), value: lit)
    }
}

struct Gauge: View {
    let value: Double, maximum: Double, text: String, unit: String, caption: String, size: CGFloat
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: size * 0.045))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * min(1, max(0, value / maximum))).stroke(T.red, style: StrokeStyle(lineWidth: size * 0.045))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.6), value: value)
            ForEach(0..<16, id: \.self) { i in
                Rectangle().fill(Color.white.opacity(i % 5 == 0 ? 0.30 : 0.12)).frame(width: 1, height: i % 5 == 0 ? 7 : 4)
                    .offset(y: -size / 2 + size * 0.09).rotationEffect(.degrees(-135 + Double(i) * 18))
            }
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(text).font(T.num(size * 0.24)).monospacedDigit().foregroundStyle(T.text).rollingNumber(value)
                        .animation(.easeOut(duration: 0.3), value: value)
                    Text(unit).font(T.num(size * 0.09, .medium)).foregroundStyle(T.dim)
                }
                Caps(caption)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption).accessibilityValue("\(text) \(unit)")
    }
}

// Chamfered button: pills, preset cards and the menu triggers share it
struct RogButtonStyle: ButtonStyle {
    var selected = false, prominent = false, cut: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View { Chip(configuration: configuration, selected: selected, prominent: prominent, cut: cut) }
    struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool, prominent: Bool, cut: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let filled = selected || prominent
            configuration.label
                .foregroundStyle(filled ? Color.white : (enabled ? T.text : T.faint))
                .background(filled ? T.red.opacity(configuration.isPressed ? 0.8 : 1) : (configuration.isPressed ? T.hover : hover && enabled ? T.hover : T.raised),
                            in: Chamfer(cut: cut))
                .contentShape(Chamfer(cut: cut))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

struct Pills: View {
    let items: [String]
    let selected: Int?
    var minWidth: CGFloat = 34
    var pad: CGFloat = 8
    var label = ""
    let pick: (Int) -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    Text(items[i]).font(.system(size: 11.5, weight: i == selected ? .semibold : .regular))
                        .fixedSize().frame(minWidth: minWidth).padding(.horizontal, pad).frame(height: 26)
                }
                .buttonStyle(RogButtonStyle(selected: i == selected, cut: 5))
                .accessibilityLabel("\(label) \(items[i])").accessibilityAddTraits(i == selected ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

struct RogMenu: View {
    let title: String
    let items: [String]
    let pick: (Int) -> Void
    var body: some View {
        Menu {
            ForEach(items.indices, id: \.self) { i in Button(items[i]) { pick(i) } }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(T.text).padding(.horizontal, 10).frame(height: 26)
            .background(T.raised, in: Chamfer(cut: 6))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct RogSlider: View {
    let name: String
    @Binding var value: Int
    let range: (Int, Int)
    var body: some View {
        let lo = range.0, hi = max(range.1, range.0 + 1)
        GeometryReader { g in
            let f = CGFloat(min(max(value, lo), hi) - lo) / CGFloat(hi - lo)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 3)
                Rectangle().fill(T.red).frame(width: g.size.width * f, height: 3)
                Rectangle().fill(T.text).frame(width: 4, height: 16).offset(x: max(0, g.size.width * f - 2))
            }
            .frame(height: 20).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let x = min(max(0, v.location.x), g.size.width)
                value = lo + Int((x / max(1, g.size.width) * CGFloat(hi - lo)).rounded())
            })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel(name).accessibilityValue("\(value) watts")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(hi, value + 1)
            case .decrement: value = max(lo, value - 1)
            @unknown default: break
            }
        }
    }
}

struct FanCurvePoint: Identifiable {
    let id: Int
    let temperature: Int
    let duty: Int
    let segment: Int
}
struct FanCurveData {
    let points: [FanCurvePoint]
    let omitted: Int
    init(_ bytes: [UInt8]) {
        guard bytes.count == 16 else { points = []; omitted = bytes.count == 0 ? 0 : 8; return }
        var valid: [FanCurvePoint] = []
        var skipped = 0, segment = 0
        var previous: Int?
        for i in 0..<8 {
            let temperature = Int(bytes[i]), duty = Int(bytes[8 + i])
            guard (20...105).contains(temperature), (0...100).contains(duty),
                  previous == nil || temperature >= previous! else {
                skipped += 1; segment += 1; continue
            }
            valid.append(FanCurvePoint(id: i, temperature: temperature, duty: duty, segment: segment))
            previous = temperature
        }
        points = valid; omitted = skipped
    }
}

// Firmware fan curve, drawn in the window's style. Hover reads a point.
struct CurveChart: View {
    let c: [UInt8]
    @State private var hovered: Int?
    private var data: FanCurveData { FanCurveData(c) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if data.points.isEmpty {
                Text("The firmware did not return a usable fan curve.").font(.system(size: 12)).foregroundStyle(T.dim).frame(height: 120)
            } else {
                Chart(data.points) { p in
                    AreaMark(x: .value("Temperature", p.temperature), y: .value("Fan duty", p.duty), series: .value("Segment", p.segment))
                        .foregroundStyle(LinearGradient(colors: [T.red.opacity(0.22), T.red.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Temperature", p.temperature), y: .value("Fan duty", p.duty), series: .value("Segment", p.segment))
                        .foregroundStyle(T.red).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Temperature", p.temperature), y: .value("Fan duty", p.duty))
                        .symbolSize(p.id == hovered ? 70 : 26).foregroundStyle(T.text)
                }
                .chartXScale(domain: 20...105).chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: [20, 40, 60, 80, 100]) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)°").foregroundStyle(T.faint) } } } }
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").foregroundStyle(T.faint) } } } }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let origin = geometry[proxy.plotAreaFrame].origin
                                    let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
                                    hovered = data.points.min { distance($0, local, proxy) < distance($1, local, proxy) }?.id
                                case .ended: hovered = nil
                                }
                            }
                    }
                }
                .frame(height: 180)
            }
            HStack {
                if data.omitted > 0 {
                    Text("\(data.omitted) firmware point(s) outside the valid range are not drawn.").font(.system(size: 11)).foregroundStyle(T.dim)
                }
                Spacer()
                if let p = data.points.first(where: { $0.id == hovered }) {
                    Text("\(p.temperature)°C · \(p.duty)%").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(T.text)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fan duty by temperature")
        .accessibilityValue(data.points.map { "\($0.temperature) degrees, \($0.duty) percent" }.joined(separator: "; "))
    }
    private func distance(_ p: FanCurvePoint, _ pos: CGPoint, _ proxy: ChartProxy) -> CGFloat {
        guard let x = proxy.position(forX: p.temperature), let y = proxy.position(forY: p.duty) else { return .infinity }
        return pow(x - pos.x, 2) + pow(y - pos.y, 2)
    }
}

struct LiveChart: View {
    let samples: [RogModel.Sample]
    var body: some View {
        if samples.count < 2 {
            Text("Collecting readings…").font(.system(size: 11)).foregroundStyle(T.dim).frame(maxWidth: .infinity, minHeight: 96)
        } else {
            Chart {
                ForEach(samples) { s in
                    AreaMark(x: .value("Time", s.date), yStart: .value("Base", 30), yEnd: .value("CPU", s.temp))
                        .foregroundStyle(LinearGradient(colors: [T.red.opacity(0.28), T.red.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.date), y: .value("CPU", s.temp), series: .value("Series", "temp"))
                        .foregroundStyle(T.red).lineStyle(StrokeStyle(lineWidth: 1.6)).interpolationMethod(.monotone)
                }
                ForEach(samples.filter { $0.watts != nil }) { s in
                    // power on the same axis: 0..70 W drawn as 30..100
                    LineMark(x: .value("Time", s.date), y: .value("Power", min(100, 30 + (s.watts ?? 0))), series: .value("Series", "watts"))
                        .foregroundStyle(Color.white.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: 30...100).chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: [40, 70, 100]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)°").font(.system(size: 10)).foregroundStyle(T.faint) } } } }
            .frame(height: 96)
            .accessibilityLabel("CPU temperature and package power, last minutes")
        }
    }
}

struct RogWindowView: View {
    @ObservedObject var m: RogModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !m.st.present { offline }
                        switch m.page {
                        case .performance: if m.advanced { AdvancedPage(m: m) } else { DashboardPage(m: m) }
                        case .battery: BatteryPage(m: m)
                        case .lighting: LightingPage(m: m)
                        case .general: GeneralPage(m: m)
                        }
                    }
                    .disabled(!m.st.present && m.page != .general)
                    .padding(.horizontal, 28).padding(.bottom, 28)
                    .frame(maxWidth: 1100, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading).background(T.bg)
        }
        .frame(minWidth: 960, minHeight: 660)
        .environment(\.colorScheme, .dark)
        .tint(T.red)
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ROG CONTROL").font(T.num(14, .bold)).foregroundStyle(T.text)
                Caps("Zephyrus G14 · GA403WM")
            }
            .padding(.horizontal, 8).padding(.top, 52).padding(.bottom, 22)
            ForEach(RogPage.allCases) { p in
                let on = p == m.page
                Button { m.page = p; m.advanced = false } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.symbol).font(.system(size: 13, weight: .medium)).frame(width: 18).foregroundStyle(on ? T.red : T.dim)
                        Text(p.rawValue).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? T.text : T.dim)
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(on ? T.raised : Color.clear, in: Chamfer(cut: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(m.st.present ? Color.green : T.amber).frame(width: 6, height: 6)
                Text(m.st.present ? "AsusWmi connected" : "AsusWmi not loaded").font(.system(size: 11)).foregroundStyle(T.dim)
            }
            .padding(.horizontal, 10).padding(.bottom, 16)
        }
        .padding(.horizontal, 10).frame(width: 220).background(T.side)
        .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }
    }

    var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            if m.page == .performance && m.advanced {
                Button { m.advanced = false } label: { Text("Performance").font(T.num(20)).foregroundStyle(T.dim) }.buttonStyle(.plain)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(T.faint)
                Text("Advanced").font(T.num(20)).foregroundStyle(T.text)
            } else {
                Text(m.page.rawValue).font(T.num(20)).foregroundStyle(T.text)
            }
            Spacer()
            if m.page == .performance && m.st.present {
                Label(m.st.ac ? "On charger" : "On battery", systemImage: m.st.ac ? "powerplug.fill" : "battery.75percent")
                    .font(.system(size: 11)).foregroundStyle(T.dim)
            }
        }
        .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 18)
    }

    var offline: some View {
        Card(pad: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AsusWmi is not loaded").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text)
                    Text("Hardware controls are off until the kext loads through OpenCore.").font(.system(size: 11)).foregroundStyle(T.dim)
                }
            }
        }
    }
}

// ---- Performance -----------------------------------------------------------------------------------------------------------------
struct DashboardPage: View {
    @ObservedObject var m: RogModel
    var limitNow: Int { m.st.ppt[2] > 0 ? m.st.ppt[2] : 0 }
    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 28) {
                Gauge(value: m.tctl ?? 0, maximum: 100, text: m.tctl.map { String(format: "%.0f", $0) } ?? "–", unit: "°C", caption: "CPU", size: 170)
                Gauge(value: m.watts ?? 0, maximum: Double(limitNow > 0 ? limitNow : 80),
                      text: m.watts.map { String(format: "%.0f", $0) } ?? "–", unit: "W", caption: "Package", size: 124)
                VStack(alignment: .leading, spacing: 16) {
                    fan("CPU fan", m.st.cpuFan)
                    fan("GPU fan", m.st.gpuFan)
                    HStack(spacing: 18) {
                        stat("Power limit", limitNow > 0 ? "\(limitNow) W" : "–")
                        stat("GPU", gpuMode)
                        stat("TGP", m.st.baseTgp > 0 ? "\(m.st.baseTgp) W" : "–")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if (m.tctl ?? 0) >= 90 {
                Label("Running hot. Silent lowers power and heat.", systemImage: "thermometer.high").font(.system(size: 11)).foregroundStyle(T.amber)
                    .padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Caps(historyCaption)
                    Spacer()
                    legend(T.red, "Temperature", dashed: false)
                    legend(Color.white.opacity(0.55), "Power", dashed: true)
                }
                LiveChart(samples: m.history)
            }
            .padding(.top, 14)
        }
        HStack(spacing: 10) {
            ForEach(Mode.allCases) { mode in modeCard(mode) }
        }
        .fixedSize(horizontal: false, vertical: true)
        ErrorLine(text: m.profileError)
        HStack(alignment: .top, spacing: 10) {
            Card(pad: 16, stretch: true) {
                Caps("Switch automatically")
                VStack(spacing: 10) {
                    sourceRow(ac: true)
                    sourceRow(ac: false)
                }
                .padding(.top, 10)
            }
            Button { m.advanced = true } label: {
                Card(pad: 16, stretch: true) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Caps("Advanced")
                            Text("Custom power limits and fan curves").font(.system(size: 13, weight: .medium)).foregroundStyle(T.text)
                            Text("Set how much power the CPU may draw, and for how long.").font(.system(size: 11)).foregroundStyle(T.dim)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.dim).padding(.top, 18)
                    }
                }
                .contentShape(Chamfer())
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var historyCaption: String {
        guard let first = m.history.first?.date else { return "Live" }
        let minutes = max(1, Int(Date().timeIntervalSince(first) / 60))
        return "Last \(minutes) minute\(minutes == 1 ? "" : "s")"
    }
    var gpuMode: String {
        let mux = m.st.gpuMux
        if mux == ~0 { return "–" }
        var s = mux & 1 == 0 ? "dGPU only" : "Hybrid"
        if m.st.dgpu != ~0 && m.st.dgpu & 1 != 0 { s += ", off" }
        return s
    }
    func fan(_ name: String, _ rpm: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Caps(name); Spacer()
                Text(verbatim: m.st.present ? String(rpm) : "–").font(T.num(15)).monospacedDigit().foregroundStyle(T.text)
                    .rollingNumber(Double(rpm)).animation(.easeOut(duration: 0.3), value: rpm)
                Text("rpm").font(.system(size: 10)).foregroundStyle(T.dim)
            }
            Segments(lit: m.st.present ? min(20, rpm * 20 / 6500) : 0, total: 20, height: 9)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(name).accessibilityValue("\(rpm) rpm")
    }
    func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Caps(k); Text(v).font(T.num(13, .medium)).foregroundStyle(T.text).lineLimit(1) }
    }
    func legend(_ c: Color, _ s: String, dashed: Bool) -> some View {
        HStack(spacing: 6) { Rectangle().fill(c).frame(width: 14, height: dashed ? 1 : 2); Text(s).font(.system(size: 10)).foregroundStyle(T.dim) }
    }
    func modeCard(_ mode: Mode) -> some View {
        let active = m.activeMode == mode
        let unavailable = mode == .turbo && !m.st.ac
        let desc = unavailable ? "Needs the charger" :
            mode == .manual ? (m.customReady ? "\(m.settings.spl) / \(m.settings.sppt) / \(m.settings.fppt) W, your limits" : "Set up your own limits")
            : mode.detail
        return Button {
            if mode == .manual && !m.customReady { m.advanced = true } else { m.choose(mode) }
        } label: {
            Card(cut: 12, pad: 14, active: active, stretch: true) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ModeBadge(mode: mode, active: active, size: 26)
                        Spacer()
                        if active { Text("ACTIVE").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(T.red) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mode.title).font(T.num(14)).foregroundStyle(T.text)
                        Text(desc).font(.system(size: 11)).foregroundStyle(T.dim).lineLimit(1)
                    }
                    Segments(lit: mode.level, total: 4, height: 6, color: active ? T.red : Color.white.opacity(0.45))
                }
            }
            .contentShape(Chamfer(cut: 12))
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .opacity(unavailable ? 0.45 : 1)
        .animation(.easeOut(duration: 0.18), value: active)
        .accessibilityLabel(mode.title).accessibilityHint(desc).accessibilityAddTraits(active ? .isSelected : [])
    }
    func sourceRow(ac: Bool) -> some View {
        let current = m.st.ac == ac
        let choices: [Mode] = ac ? Mode.allCases : [.silent, .performance, .manual]
        return HStack(spacing: 10) {
            Image(systemName: ac ? "powerplug.fill" : "battery.75percent").font(.system(size: 12)).foregroundStyle(current ? T.text : T.dim).frame(width: 18)
            Text(ac ? "On charger" : "On battery").font(.system(size: 13)).foregroundStyle(current ? T.text : T.dim)
            if current { Text("NOW").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(T.red) }
            Spacer()
            RogMenu(title: m.mode(forAC: ac).title, items: choices.map(\.title)) { m.setMode(choices[$0], forAC: ac) }
        }
    }
}

struct AdvancedPage: View {
    @ObservedObject var m: RogModel
    @State private var fan = 0
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    Caps("Custom mode limits, \(m.st.ac ? "on charger" : "on battery")")
                    limit("Burst", "A few seconds when a load starts", "FPPT", $m.settings.fppt, m.st.ranges[2])
                    limit("Short boost", "The first few minutes", "SPPT", $m.settings.sppt, m.st.ranges[1])
                    limit("Sustained", "As long as the load lasts", "SPL", $m.settings.spl, m.st.ranges[0])
                    HStack(spacing: 10) {
                        Caps("Fans follow")
                        Spacer()
                        let bases: [Mode] = [.silent, .performance, .turbo]
                        RogMenu(title: m.settings.fanBase.title + " curve", items: bases.map { $0.title + " curve" }) {
                            m.settings.fanBase = bases[$0]; m.loadCurve()
                        }
                    }
                }
                .frame(width: 380)
                VStack(alignment: .leading, spacing: 10) {
                    Caps("How the CPU uses them")
                    envelope
                    Text("Higher limits are faster but louder and hotter. ROG Control keeps them in order and within the firmware range for this power source.")
                        .font(.system(size: 11)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if m.manualDirty {
                    Image(systemName: "circle.dashed").font(.system(size: 11, weight: .bold)).foregroundStyle(T.amber)
                    Text("Not saved").font(.system(size: 12)).foregroundStyle(T.amber)
                } else {
                    Image(systemName: m.customReady ? "checkmark" : "circle").font(.system(size: 11, weight: .bold)).foregroundStyle(T.dim)
                    Text(m.activeMode == .manual ? "Saved and in use" : m.customReady ? "Saved. Choose Custom to use it." : "Not set up yet")
                        .font(.system(size: 12)).foregroundStyle(T.dim)
                }
                Spacer()
                Button { m.resetCustom() } label: { Text("Reset").font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).frame(height: 30) }
                    .buttonStyle(RogButtonStyle(cut: 7)).disabled(!m.manualDirty)
                Button { m.saveCustom() } label: { Text("Save to Custom").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 16).frame(height: 30) }
                    .buttonStyle(RogButtonStyle(prominent: true, cut: 7)).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
            ErrorLine(text: m.profileError).padding(.top, 8)
        }
        Card {
            HStack {
                Caps("Fan curve · \(m.curveMode.title)")
                Spacer()
                Pills(items: ["CPU", "GPU"], selected: fan, minWidth: 40, label: "Fan") { fan = $0 }
            }
            Group {
                if let bytes = fan == 0 ? m.curve : m.gpuCurve { CurveChart(c: bytes) }
                else { Text("The firmware did not return a fan curve.").font(.system(size: 12)).foregroundStyle(T.dim).frame(height: 120) }
            }
            .padding(.top, 10)
            Text("Read from the firmware: fan speed by temperature. A reference, not live fan speed.")
                .font(.system(size: 11)).foregroundStyle(T.dim).padding(.top, 6)
        }
    }
    func limit(_ name: String, _ desc: String, _ code: String, _ v: Binding<Int>, _ range: (Int, Int)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(T.text)
                Text(code).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(T.faint)
                Spacer()
                Text(verbatim: String(v.wrappedValue)).font(T.num(18)).monospacedDigit().foregroundStyle(T.text)
                Text("W").font(.system(size: 11)).foregroundStyle(T.dim)
            }
            RogSlider(name: name, value: v, range: range)
            Text("\(desc) · \(range.0) to \(range.1) W").font(.system(size: 11)).foregroundStyle(T.dim)
        }
    }
    // Burst, short boost and sustained as one picture: height is the limit, width is roughly how long it lasts
    var envelope: some View {
        let top = Double(max(m.settings.fppt, m.settings.sppt, m.settings.spl, 1))
        let blocks: [(String, String, Int, CGFloat, Double)] = [("Burst", "seconds", m.settings.fppt, 0.16, 0.95),
                                                                ("Short boost", "minutes", m.settings.sppt, 0.32, 0.65),
                                                                ("Sustained", "as long as needed", m.settings.spl, 0.52, 0.40)]
        return GeometryReader { g in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(blocks.indices, id: \.self) { i in
                    let b = blocks[i]
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(b.2) W").font(T.num(12)).foregroundStyle(T.text)
                        Rectangle().fill(T.red.opacity(b.4)).frame(height: max(4, (g.size.height - 46) * CGFloat(Double(b.2) / top)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.0).font(.system(size: 11, weight: .medium)).foregroundStyle(T.text)
                            Text(b.1).font(.system(size: 10)).foregroundStyle(T.dim)
                        }
                        .frame(height: 26, alignment: .topLeading)
                    }
                    .frame(width: (g.size.width - 4) * b.3)
                }
            }
            .animation(.easeOut(duration: 0.15), value: m.settings.fppt + m.settings.sppt * 100 + m.settings.spl * 10000)
        }
        .frame(height: 210).padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Burst \(m.settings.fppt) watts for seconds, short boost \(m.settings.sppt) watts for minutes, sustained \(m.settings.spl) watts")
    }
}

// ---- Battery ---------------------------------------------------------------------------------------------------------------------
struct BatteryPage: View {
    @ObservedObject var m: RogModel
    var level: Int? { m.st.batFull > 0 ? min(100, max(0, m.st.batNow * 100 / m.st.batFull)) : nil }
    var state: String {
        let limit = m.st.charge.map { " at \($0)%" } ?? ""
        if m.st.batState & 2 != 0 { return "Charging" + (m.st.batRate > 0 ? ", \(m.st.batRate) mA" : "") }
        if m.st.batState & 1 != 0 { return "On battery" + (m.st.batRate > 0 ? ", \(m.st.batRate) mA" : "") }
        return m.st.ac ? "On charger · holding\(limit)" : "On battery"
    }
    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: level.map(String.init) ?? "–").font(T.num(56)).monospacedDigit().foregroundStyle(T.text)
                        Text("%").font(T.num(20, .medium)).foregroundStyle(T.dim)
                    }
                    Text(state).font(.system(size: 12)).foregroundStyle(T.dim)
                }
                .frame(width: 220, alignment: .leading)
                cell.frame(height: 110)
            }
        }
        HStack(spacing: 10) {
            preset(60, "Desk", "Plugged in most of the day. Kindest to the battery.")
            preset(80, "Everyday", "Good balance of runtime and battery life.")
            preset(100, "Travel", "Full charge for a long day away from a socket.")
        }
        .fixedSize(horizontal: false, vertical: true)
        ErrorLine(text: m.chargeError)
        HStack(spacing: 10) {
            Card(pad: 16, stretch: true) {
                Caps("Health")
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: m.st.batDesign > 5 && m.st.batFull > 0 ? String(format: "%.0f", 100.0 * Double(m.st.batFull) / Double(m.st.batDesign)) : "–")
                        .font(T.num(26)).foregroundStyle(T.text)
                    Text("%").font(T.num(13)).foregroundStyle(T.dim)
                }
                .padding(.top, 6)
                Text(m.st.batFull > 0 ? "\(String(m.st.batFull)) of \(String(m.st.batDesign)) mAh design capacity" : "Not reported by the firmware")
                    .font(.system(size: 11)).foregroundStyle(T.dim)
            }
            Card(pad: 16, stretch: true) {
                Caps("Now")
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: String(m.st.batRate)).font(T.num(26)).foregroundStyle(T.text)
                    Text("mA").font(T.num(13)).foregroundStyle(T.dim)
                }
                .padding(.top, 6)
                Text(m.st.batState & 2 != 0 ? "Charging" : m.st.batState & 1 != 0 ? "Discharging" : "Not charging, held at the limit")
                    .font(.system(size: 11)).foregroundStyle(T.dim)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    // the battery as 20 slanted cells, with the charge limit drawn on it
    var cell: some View {
        GeometryReader { g in
            let w = g.size.width - 10
            let lit = (level ?? 0) * 20 / 100
            let limitCell = (m.st.charge ?? 100) * 20 / 100
            let limitX = 6 + (w - 12) * CGFloat(m.st.charge ?? 100) / 100
            ZStack(alignment: .leading) {
                Rectangle().stroke(Color.white.opacity(0.25), lineWidth: 1.5).frame(width: w, height: 56)
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 5, height: 22).offset(x: w + 2)
                HStack(spacing: 3) {
                    ForEach(0..<20, id: \.self) { i in
                        Slant().fill(i < lit ? T.red : (i < limitCell ? Color.white.opacity(0.10) : Color.white.opacity(0.03)))
                    }
                }
                .frame(width: w - 12, height: 44).offset(x: 6)
                .animation(.easeOut(duration: 0.3), value: lit)
                if let c = m.st.charge, c < 100 {
                    Rectangle().fill(T.text).frame(width: 2, height: 74).offset(x: limitX)
                    Text("LIMIT \(c)%").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(T.text).fixedSize()
                        .offset(x: limitX - 26, y: -48)
                }
            }
            .frame(height: g.size.height)
            .animation(.easeOut(duration: 0.3), value: m.st.charge)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery").accessibilityValue("\(level ?? 0) percent, limit \(m.st.charge ?? 100) percent")
    }
    func preset(_ v: Int, _ name: String, _ desc: String) -> some View {
        let active = m.st.charge == v
        return Button { m.setCharge(v) } label: {
            Card(cut: 12, pad: 16, active: active, stretch: true) {
                HStack {
                    Text("\(v)%").font(T.num(22)).foregroundStyle(active ? T.red : T.text)
                    Spacer()
                    if active { Text("ACTIVE").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(T.red) }
                }
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text).padding(.top, 8)
                Text(desc).font(.system(size: 11)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            .contentShape(Chamfer(cut: 12))
        }
        .buttonStyle(.plain)
        .disabled(m.st.charge == nil)
        .animation(.easeOut(duration: 0.18), value: active)
        .accessibilityLabel("\(name), \(v) percent").accessibilityAddTraits(active ? .isSelected : [])
    }
}

// ---- Lighting --------------------------------------------------------------------------------------------------------------------
struct SlashPreview: View {
    let on: Bool, bright: Int
    var body: some View {
        ZStack {
            Rectangle().fill(Color(red: 0.13, green: 0.14, blue: 0.16)).frame(width: 300, height: 190)
                .overlay(Rectangle().stroke(Color.white.opacity(0.10)))
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { i in
                    let base = [0.25, 0.45, 0.75, 1.0, 0.75, 0.45, 0.25][i]
                    let a = on ? base * (0.45 + 0.55 * Double(bright) / 3) : 0.06
                    Capsule().fill(Color.white.opacity(a)).frame(width: 26, height: 7)
                        .shadow(color: Color.white.opacity(on ? a * 0.6 : 0), radius: i == 3 ? 6 : 3)
                }
            }
            .rotationEffect(.degrees(-35))
            .animation(.easeOut(duration: 0.25), value: on)
            .animation(.easeOut(duration: 0.25), value: bright)
        }
        .accessibilityHidden(true)
    }
}

struct LightingPage: View {
    @ObservedObject var m: RogModel
    var slash: Slash { m.currentSlash }
    var body: some View {
        if !m.st.lighting {
            Card {
                Text("Lighting is not available").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text)
                Text("It needs AsusWmi ABI 3 and the N-KEY keyboard.").font(.system(size: 11)).foregroundStyle(T.dim).padding(.top, 2)
            }
        } else {
            Card {
                HStack(alignment: .center, spacing: 28) {
                    SlashPreview(on: slash.bright > 0, bright: max(1, slash.bright))
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Caps("Slash lighting")
                                Text(slash.bright > 0 ? Slash.modes[min(slash.mode, Slash.modes.count - 1)] : "Off").font(T.num(22)).foregroundStyle(T.text)
                            }
                            Spacer()
                            Toggle("Slash", isOn: slashOn).toggleStyle(.switch).labelsHidden().tint(T.red)
                        }
                        Group {
                            HStack {
                                Text("Brightness").font(.system(size: 12)).foregroundStyle(T.dim); Spacer()
                                Pills(items: ["Low", "Med", "High"], selected: max(1, slash.bright) - 1, label: "Brightness") {
                                    var s = slash; s.bright = $0 + 1; m.setSlash(s)
                                }
                            }
                            HStack {
                                Text("Pause between runs").font(.system(size: 12)).foregroundStyle(T.dim); Spacer()
                                Pills(items: (0...5).map(String.init), selected: slash.interval, minWidth: 24, label: "Pause") {
                                    var s = slash; s.interval = $0; m.setSlash(s)
                                }
                            }
                        }
                        .disabled(slash.bright == 0).opacity(slash.bright == 0 ? 0.5 : 1)
                        Text("Fn+F4 turns it on and off.").font(.system(size: 11)).foregroundStyle(T.dim)
                    }
                }
            }
            Card {
                Caps("Animation")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Slash.modes.indices, id: \.self) { i in
                        let on = slash.bright > 0 && slash.mode == i
                        Button {
                            var s = slash; s.mode = i; if s.bright == 0 { s.bright = 2 }; m.setSlash(s)
                        } label: {
                            Text(Slash.modes[i]).font(.system(size: 12, weight: on ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 34)
                        }
                        .buttonStyle(RogButtonStyle(selected: on, cut: 8))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.top, 12)
            }
            Card(pad: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Caps("Keyboard backlight")
                        Text("Fn+F2 and Fn+F3 change it too.").font(.system(size: 11)).foregroundStyle(T.dim)
                    }
                    Spacer()
                    Pills(items: ["Off", "Low", "Med", "High"], selected: m.st.kbd, minWidth: 44, label: "Keyboard") { m.setKbd($0) }
                        .disabled(m.st.kbd == nil)
                }
            }
            ErrorLine(text: m.lightingError)
        }
    }
    // a brightness of 0 is "off"; the last brightness is kept so switching back on restores it
    var slashOn: Binding<Bool> {
        Binding(get: { m.currentSlash.bright > 0 }, set: { on in
            var s = m.currentSlash
            s.bright = on ? (UserDefaults.standard.object(forKey: "slash.on.bright") as? Int ?? 2) : 0
            if !on { UserDefaults.standard.set(m.currentSlash.bright, forKey: "slash.on.bright") }
            m.setSlash(s)
        })
    }
}

// ---- General ---------------------------------------------------------------------------------------------------------------------
struct GeneralPage: View {
    @ObservedObject var m: RogModel
    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Caps("Startup")
                    Text("Open at login").font(.system(size: 13, weight: .medium)).foregroundStyle(T.text)
                    Text("Runs in the menu bar. Closing this window keeps hardware control active.").font(.system(size: 11)).foregroundStyle(T.dim)
                }
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) })).toggleStyle(.switch).labelsHidden().tint(T.red)
            }
        }
        Card {
            Caps("About")
            VStack(spacing: 0) {
                row("Model") { Text("ROG Zephyrus G14 · GA403WM").foregroundStyle(T.dim) }
                row("Version") { Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev").foregroundStyle(T.dim) }
                row("Created by") { Link("thanhnndev", destination: URL(string: "https://github.com/thanhnndev")!).foregroundStyle(T.red) }
                row("Inspired by", last: true) { Link("asusctl and asus-linux", destination: URL(string: "https://asus-linux.org")!).foregroundStyle(T.red) }
            }
            .padding(.top, 8)
            Text("Settings are saved separately for the charger and the battery, and restored when the power source changes.")
                .font(.system(size: 11)).foregroundStyle(T.dim).padding(.top, 10)
        }
    }
    func row<C: View>(_ k: String, last: Bool = false, @ViewBuilder _ v: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack { Text(k).font(.system(size: 13)).foregroundStyle(T.text); Spacer(); v().font(.system(size: 12)) }.frame(height: 38)
            if !last { Rectangle().fill(T.line).frame(height: 1) }
        }
    }
}

// ---- status item -------------------------------------------------------------------------------------------------------------
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    var popoverHost: NSHostingController<ContentView>!
    // The popover hangs from this 1 pt window at the menu bar's bottom edge, under the icon. Anchoring to the status button
    // itself puts the popover over the bar when the menu bar auto-hides: the button's window then sits above the screen.
    let anchor: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.level = .statusBar; w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return w
    }()
    var model: RogModel!
    var window: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        model = RogModel()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)   // the panel uses the window's dark ROG look
        popoverHost = NSHostingController(rootView: ContentView(m: model, openWindow: { [weak self] page, adv in self?.open(page, advanced: adv) }))
        popoverHost.sizingOptions = .preferredContentSize   // follow SwiftUI's size, so a new line grows the panel downward
        popover.contentViewController = popoverHost
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        setupMenus()
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        model.refresh()
        model.loadCurve()
        model.visible = true
        popover.contentSize = popoverHost.view.fittingSize   // size before showing; a later resize would grow it upward off screen
        if let bw = b.window {
            let r = bw.convertToScreen(b.convert(b.bounds, to: nil))
            let screen = NSScreen.screens.first { $0.frame.minX <= r.midX && r.midX < $0.frame.maxX } ?? NSScreen.main
            let bottom = (screen?.frame.maxY ?? r.minY + bw.frame.height) - bw.frame.height
            anchor.setFrame(NSRect(x: r.minX, y: bottom, width: r.width, height: 1), display: false)
            anchor.orderFront(nil)
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ n: Notification) { anchor.orderOut(nil); updateVisibility() }
    func updateVisibility() { model.visible = popover.isShown || window?.isVisible == true }
    func windowWillClose(_ n: Notification) {
        model.visible = popover.isShown
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func open(_ page: RogPage, advanced: Bool) {
        model.page = page; model.advanced = advanced
        showWindow()
    }
    @objc func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "ROG Control"
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 960, height: 680)
            w.appearance = NSAppearance(named: .darkAqua)   // the window is the ROG side: always dark
            w.backgroundColor = T.nsBG
            w.contentViewController = NSHostingController(rootView: RogWindowView(m: model))
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("RogControl.MainWindow")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refresh(); model.loadCurve(); updateVisibility()
    }
    @objc func refreshNow() { model.refresh(); model.loadCurve() }
    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: "Created by thanhnndev\ngithub.com/thanhnndev\n\nInspired by asusctl and the asus-linux community.",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.addAttribute(.link, value: URL(string: "https://github.com/thanhnndev")!, range: (credits.string as NSString).range(of: "github.com/thanhnndev"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    func setupMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About ROG Control", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ROG Control", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ROG Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        let open = windowMenu.addItem(withTitle: "Open ROG Control", action: #selector(showWindow), keyEquivalent: "0"); open.target = self
        let refresh = windowMenu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r"); refresh.target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    func updateIcon() {
        guard let b = item.button else { return }
        let mode = model.activeMode ?? .performance
        let img = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: "ROG: \(mode.title)")
        img?.isTemplate = true
        b.image = img
        var tip = "ROG: \(model.modeLabel)"
        if let t = model.tctl { tip += String(format: " · CPU %.0f°C", t) }
        if let w = model.watts { tip += String(format: " · %.1f W", w) }
        b.toolTip = tip
    }
}

// ---- command line: offscreen snapshots (layout review without hardware) -------------------------------------------------------
@MainActor
enum Snapshot {
    static func mock(manual: Bool, offline: Bool) -> RogModel {
        var st = AsusState()
        st.present = !offline; st.ac = true; st.fanCustom = manual
        st.profile = manual ? 0 : 1; st.charge = 80; st.cpuFan = 5000; st.gpuFan = 5400; st.ppt = [45, 65, 80]
        st.gpuMux = 1; st.dgpu = 0; st.baseTgp = 55
        st.batDesign = 4580; st.batFull = 4132; st.batNow = 2440; st.batState = 0; st.batRate = 0
        st.lighting = true; st.kbd = 2; st.slash = Slash(mode: 7, bright: 2, interval: 1).packed; st.hid = true
        let m = RogModel(preview: st, tctl: offline ? nil : 78, watts: offline ? nil : 46.8,
                         curve: [43, 68, 70, 72, 74, 76, 78, 255, 1, 6, 8, 13, 18, 22, 32, 32],
                         gpuCurve: [43, 67, 68, 70, 70, 70, 70, 255, 1, 6, 8, 13, 18, 22, 32, 32])
        if manual { m.settings.mode = .manual }
        m.seedHistory()
        return m
    }
    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let Charts and AppKit controls draw
        let fit = host.fittingSize
        if size.height == 0 { host.frame.size.height = fit.height; w.setContentSize(host.frame.size); host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    static func run(dir: String, manual: Bool, offline: Bool) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: dir); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let m = mock(manual: manual, offline: offline)
        let tag = offline ? "-offline" : manual ? "-manual" : ""
        render(ContentView(m: m, openWindow: { _, _ in }), size: NSSize(width: 320, height: 0), dark: true,
               to: out.appendingPathComponent("popover\(tag).png"))
        // the window is always dark; each page at the default window size, full height
        let pages: [(String, RogPage, Bool)] = [("1-dashboard", .performance, false), ("2-advanced", .performance, true),
                                                ("3-battery", .battery, false), ("4-lighting", .lighting, false), ("5-general", .general, false)]
        for (name, page, adv) in pages {
            m.page = page; m.advanced = adv
            render(RogWindowView(m: m).frame(width: 1120, height: 1000), size: NSSize(width: 1120, height: 1000), dark: true,
                   to: out.appendingPathComponent("window-\(name)\(tag).png"))
        }
        print("snapshots in \(out.path)")
    }
}

// ---- command line: profile bench -------------------------------------------------------------------------------------------------
final class Load {
    private var running = true
    private let lock = NSLock()
    func start(_ n: Int) {
        for _ in 0..<n {
            Thread.detachNewThread { [self] in
                var x: UInt64 = 88172645463325252
                while lock.withLock({ running }) {
                    for _ in 0..<200_000 { x ^= x << 13; x ^= x >> 7; x ^= x << 17 }
                }
                if x == 42 { print("") }
            }
        }
    }
    func stop() { lock.withLock { running = false } }
}

func bench(seconds: Int) -> Int32 {
    let st0 = Asus.state()
    guard st0.present else { print("AsusWmi is not loaded"); return 1 }
    let ncpu = ProcessInfo.processInfo.activeProcessorCount
    print("RogControl bench: \(ncpu) busy threads, \(seconds) s per mode, \(st0.ac ? "on AC" : "on battery"); previous profile \(st0.profile.map(String.init) ?? "?")")
    print("mode         avg W   max W   Tctl max   CPU fan   GPU fan   Zen5 MHz   Zen5c MHz")
    var modes: [Mode] = [.silent, .performance]
    if st0.ac { modes.append(.turbo) }
    for mode in modes {
        guard Asus.set(.profile, mode.firmwareProfile) == KERN_SUCCESS else { print("\(mode.title): profile refused"); continue }
        Thread.sleep(forTimeInterval: 3)                       // let the firmware settle, fans spin down/up a little
        let load = Load(); load.start(ncpu)
        _ = Sensors.read()
        var ws: [Double] = [], tmax = 0.0, cf = 0, gf = 0
        for i in 0..<seconds {
            Thread.sleep(forTimeInterval: 1)
            let s = Sensors.read()
            if i >= 2, let w = s.watts { ws.append(w) }       // skip the first seconds of the fast boost
            tmax = max(tmax, s.tctl ?? 0)
            let st = Asus.state(); cf = max(cf, st.cpuFan); gf = max(gf, st.gpuFan)
        }
        let clk = Sensors.clocks()
        load.stop()
        let avg = ws.isEmpty ? 0 : ws.reduce(0, +) / Double(ws.count)
        print(String(format: "%-11@ %6.1f  %6.1f   %6.1f°C   %7d   %7d   %8d   %9d", mode.title as NSString, avg, ws.max() ?? 0, tmax, cf, gf,
                     clk?.big ?? 0, clk?.little ?? 0))
        Thread.sleep(forTimeInterval: 5)                       // cool down between modes
    }
    if let p = st0.profile { Asus.set(.profile, p) }
    print("previous profile restored (custom fan curves and power limits, if any, are reset; RogControl re-applies its mode at the next power change or start)")
    return 0
}

let args = CommandLine.arguments
if args.count >= 3 && args[1] == "--snapshot" {
    MainActor.assumeIsolated { Snapshot.run(dir: args[2], manual: args.contains("--manual"), offline: args.contains("--offline")) }
    exit(0)
}
if args.count >= 2 && args[1] == "--bench" {
    exit(bench(seconds: args.count >= 3 ? max(5, Int(args[2]) ?? 20) : 20))
}

MainActor.assumeIsolated {                     // top-level code runs on the main thread
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

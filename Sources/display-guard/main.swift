// display-guard: keeps macOS from treating a display that is not really in
// use as alive (the "zombie screen" windows wander onto).
//
//   1. None of the listed USB devices (the keyboards) is on the Mac -> switch the
//      main monitor to the other input over DDC, then disconnect it. One is back
//      -> reconnect the monitor, then switch it to the Mac's input. (The Mac cannot
//      read which input the monitor shows, so the keyboards are the cue.)
//   2. The Mac is locked                    -> disconnect all but the main monitor.
//   3. A Sunshine session is running        -> disconnect all but the main monitor.
//   Back to normal                          -> reconnect.
//
// 2 and 3 can be switched off in the settings. "Disconnect" is
// CGSConfigureDisplayEnabled (private API, same as BetterDisplay's paid feature).
// The input is switched over DDC/CI (VCP 0x60 write) through IOAVService (Apple
// Silicon). Reading the input back is not reliable, so it is not used. Never
// leaves the Mac with zero active displays.
//
// Usage: display-guard [run|status|restore|setup]
//   setup   asks a few questions and writes ~/.config/display-guard/config.toml

import Foundation
import CoreGraphics
import IOKit

// MARK: - Settings

/// Loaded from the settings file in `run` and `status` (see Config.swift).
var cfg: Config!
let confirmDisconnect = 1                // polls in a row (plus the short re-check) before acting
let confirmReconnect = 1

func hex2(_ v: Int) -> String { "0x" + String(format: "%02X", v) }

// MARK: - Private APIs

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ c: CGDisplayConfigRef?, _ id: CGDirectDisplayID, _ enabled: Bool) -> CGError
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ a: CFAllocator?, _ s: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ s: CFTypeRef, _ chip: UInt32, _ off: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> Int32
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ s: CFTypeRef, _ chip: UInt32, _ off: UInt32, _ buf: UnsafeRawPointer, _ size: UInt32) -> Int32

// MARK: - Logging / test hook

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

/// Test hook: DG_FAKE_FILE=path with lines like `input=0x12`, `locked=1`, `sunshine=1`.
func fake(_ key: String) -> String? {
    guard let path = ProcessInfo.processInfo.environment["DG_FAKE_FILE"],
          let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2, kv[0] == key { return kv[1] }
    }
    return nil
}

// MARK: - Displays

func displayList(active: Bool) -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    _ = active ? CGGetActiveDisplayList(32, &ids, &n) : CGGetOnlineDisplayList(32, &ids, &n)
    return Array(ids.prefix(Int(n)))
}

func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
    guard CGSConfigureDisplayEnabled(cfg, id, on) == .success else {
        CGCancelDisplayConfiguration(cfg)
        return false
    }
    return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
}

// Disabled displays vanish from the online list, so remember them (also on
// disk, so a crash or restart can bring them back).
let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/display-guard/disabled.json")

func loadDisabled() -> Set<CGDirectDisplayID> {
    guard let data = try? Data(contentsOf: stateURL),
          let ids = try? JSONDecoder().decode([UInt32].self, from: data) else { return [] }
    return Set(ids)
}

func saveDisabled(_ ids: Set<CGDirectDisplayID>) {
    try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(Array(ids).sorted()).write(to: stateURL)
}

var disabled = loadDisabled()
var known: [CGDirectDisplayID: String] = [:]   // id -> "vendor:model" for every display seen

func isMain(_ id: CGDirectDisplayID) -> Bool {
    guard let c = cfg else { return false }
    return known[id] == "\(c.monitor.vendor):\(c.monitor.model)"
}

func refreshKnown() {
    let online = displayList(active: false)
    for id in online { known[id] = "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id))" }
    // Forget displays that were unplugged (not online and not disabled by us).
    for id in known.keys where !online.contains(id) && !disabled.contains(id) { known[id] = nil }
}

func restoreAll() {
    for id in disabled {
        if setEnabled(id, true) { log("restored display \(id)") } else { log("FAILED to restore display \(id)") }
    }
    disabled = disabled.filter { !displayList(active: true).contains($0) }
    saveDisabled(disabled)
}

// MARK: - DDC (main monitor input)

func avServices() -> [CFTypeRef] {
    var it: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)
    var out: [CFTypeRef] = []
    while case let s = IOIteratorNext(it), s != 0 {
        if let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, s)?.takeRetainedValue() { out.append(svc) }
        IOObjectRelease(s)
    }
    IOObjectRelease(it)
    return out
}

func edidIDs(_ s: CFTypeRef) -> (UInt32, UInt32)? {
    var e = [UInt8](repeating: 0, count: 128)
    guard IOAVServiceReadI2C(s, 0x50, 0, &e, 128) == 0 else { return nil }
    // EDID vendor id (compressed ASCII); the same number CoreGraphics reports, e.g. "DEL" = 0x10AC.
    let vendor = (UInt32(e[8]) << 8) | UInt32(e[9])
    return (vendor, UInt32(e[11]) << 8 | UInt32(e[10]))
}

func getVCP(_ s: CFTypeRef, _ code: UInt8) -> Int? {
    var req: [UInt8] = [0x82, 0x01, code]
    var ck: UInt8 = 0x6E ^ 0x51
    for b in req { ck ^= b }
    req.append(ck)
    for _ in 0..<3 {
        if IOAVServiceWriteI2C(s, 0x37, 0x51, req, UInt32(req.count)) != 0 { usleep(20_000); continue }
        usleep(50_000)
        var rep = [UInt8](repeating: 0, count: 12)
        if IOAVServiceReadI2C(s, 0x37, 0x51, &rep, 12) == 0, rep[2] == 0x02, rep[3] == 0, rep[4] == code {
            return Int(rep[8]) << 8 | Int(rep[9])
        }
        usleep(20_000)
    }
    return nil
}

/// Sets the main monitor's input source (VCP 0x60) over DDC/CI. The monitor
/// accepts this from the cable even while showing another input, but not while
/// the display is disabled by us -- so call it only while it is connected.
func setMonitorInput(_ value: Int) -> Bool {
    if fake("keyboards") != nil { log("(test) would set the monitor input to \(hex2(value))"); return true }
    for s in avServices() {
        guard let (vendor, model) = edidIDs(s), Int(vendor) == cfg.monitor.vendor, Int(model) == cfg.monitor.model else { continue }
        var req: [UInt8] = [0x84, 0x03, 0x60, UInt8(value >> 8), UInt8(value & 255)]
        var ck: UInt8 = 0x6E ^ 0x51
        for b in req { ck ^= b }
        req.append(ck)
        return IOAVServiceWriteI2C(s, 0x37, 0x51, req, UInt32(req.count)) == 0
    }
    return false
}

// MARK: - USB devices (the keyboards)

struct USBDevice {
    let vendor: Int
    let product: Int
    let name: String
}

/// Every USB device the Mac can see.
func usbDevices() -> [USBDevice] {
    guard let match = IOServiceMatching("IOUSBHostDevice") else { return [] }
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == 0 else { return [] }
    var out: [USBDevice] = []
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == 0,
              let d = props?.takeRetainedValue() as? [String: Any],
              let vendor = (d["idVendor"] as? NSNumber)?.intValue,
              let product = (d["idProduct"] as? NSNumber)?.intValue else { continue }
        let name = (d["USB Product Name"] as? String) ?? (d["kUSBProductString"] as? String) ?? "USB device"
        out.append(USBDevice(vendor: vendor, product: product, name: name))
    }
    IOObjectRelease(it)
    return out
}

/// Number of the listed USB devices the Mac can see. The Mac cannot tell which
/// input the monitor shows, so the keyboards are the cue: they go away from the
/// Mac when the desk is switched to the other computer.
func keyboardCount() -> Int {
    if let f = fake("keyboards"), let n = Int(f) { return n }
    return usbDevices().filter { d in
        cfg.keyboards.contains { $0.vendor == d.vendor && ($0.product == nil || $0.product == d.product) }
    }.count
}

/// React to the listed USB devices appearing or vanishing at once instead of
/// waiting for the next poll.
var usbNotifyPort: IONotificationPortRef?

func startUSBWatch() {
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
    usbNotifyPort = port
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    let callback: IOServiceMatchingCallback = { _, iterator in
        while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
        DispatchQueue.main.async { reconcile() }
    }
    for vendor in Set(cfg.keyboards.map(\.vendor)) {
        for type in [kIOTerminatedNotification, kIOFirstMatchNotification] {
            guard let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { continue }
            match[kIOPropertyMatchKey] = ["idVendor": NSNumber(value: vendor)] as NSDictionary
            var it: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, match as CFDictionary, callback, nil, &it) == 0 {
                while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }   // arms the notification
            }
        }
    }
}

// MARK: - Lock / Sunshine

func isLocked() -> Bool {
    if let f = fake("locked") { return f == "1" }
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
}

/// This Mac's own non-loopback IPv4 addresses. Sunshine is queried on these and
/// never on 127.0.0.1: a port forwarder (OpenRemoteURLReceiver) can own
/// 127.0.0.1:47989 and answer with ANOTHER machine's Sunshine.
func localIPv4s() -> [String] {
    var out: [String] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    var cur = head
    while let node = cur {
        let ifa = node.pointee
        if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") { out.append(ip) }
            }
        }
        cur = ifa.ifa_next
    }
    freeifaddrs(head)
    return out
}

/// "auto" = this Mac's own addresses; otherwise the one host (or host:port) of the settings.
func sunshineHosts() -> [String] {
    let a = cfg.sunshineAddress.trimmingCharacters(in: .whitespaces)
    return a.isEmpty || a == "auto" ? localIPv4s() : [a]
}

func serverInfo(at host: String) -> String? {
    let hostPort = host.contains(":") ? host : "\(host):47989"
    guard let url = URL(string: "http://\(hostPort)/serverinfo") else { return nil }
    var req = URLRequest(url: url); req.timeoutInterval = 1
    let sem = DispatchSemaphore(value: 0)
    var text: String?
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data { text = String(data: data, encoding: .utf8) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 2)
    return text
}

func sunshineBusy() -> Bool {
    if let f = fake("sunshine") { return f == "1" }
    for host in sunshineHosts() {
        if let text = serverInfo(at: host), text.contains("<state>") { return text.contains("SUNSHINE_SERVER_BUSY") }
    }
    return false
}

// MARK: - Decision

var mainWanted = true
var needMacInput = 0               // polls left to (re)send "input = HDMI 1" after reconnecting
var pendingMain: Bool? = nil
var pendingCount = 0

func updateMainWanted() {
    let want = keyboardCount() > 0
    guard want != mainWanted else { pendingMain = nil; pendingCount = 0; return }
    if pendingMain == want { pendingCount += 1 } else { pendingMain = want; pendingCount = 1 }
    guard pendingCount >= (want ? confirmReconnect : confirmDisconnect) else { return }
    if !want {                                // gone: look once more to ride out a re-enumeration
        usleep(cfg.recheckDelay)
        if keyboardCount() > 0 { pendingMain = nil; pendingCount = 0; return }
    }
    pendingMain = nil; pendingCount = 0
    mainWanted = want
    if want {
        log("a keyboard is back: reconnecting the monitor, then switching it to \(hex2(cfg.monitor.mac_input))")
        needMacInput = 6
    } else {
        log("no keyboard on the Mac: switching the monitor to \(hex2(cfg.monitor.other_input)), then disconnecting it")
        needMacInput = 0
        for _ in 0..<3 { if setMonitorInput(cfg.monitor.other_input) { break }; usleep(300_000) }
        usleep(500_000)                       // let the monitor leave HDMI before the display is removed
    }
}

var lastReason = ""

func reconcile() {
    refreshKnown()
    updateMainWanted()
    let locked = cfg.othersEnabled && cfg.whenLocked && isLocked()
    let busy = cfg.othersEnabled && cfg.whenSunshine && sunshineBusy()
    let othersWanted = !(locked || busy)

    let all = Set(known.keys)
    var wanted = all.filter { isMain($0) ? mainWanted : othersWanted }
    if wanted.isEmpty {                       // never leave the Mac with no display
        let others = all.filter { !isMain($0) }
        wanted = others.isEmpty ? all : others
    }

    let reason = "monitor=\(mainWanted ? "on" : "off") others=\(othersWanted ? "on" : "off") (locked=\(locked) sunshine=\(busy))"
    if reason != lastReason { log(reason); lastReason = reason }

    let active = Set(displayList(active: true))
    for id in all.sorted() {
        let should = wanted.contains(id), isOn = active.contains(id)
        if should && !isOn {
            if setEnabled(id, true) { disabled.remove(id); saveDisabled(disabled); log("connected display \(id)") }
            else { log("FAILED to connect display \(id)") }
        } else if !should && isOn {
            disabled.insert(id); saveDisabled(disabled)           // record first: crash-safe
            if setEnabled(id, false) { log("disconnected display \(id)") }
            else { disabled.remove(id); saveDisabled(disabled); log("FAILED to disconnect display \(id)") }
        }
    }

    // After reconnecting the main monitor, tell it to show the Mac's input. The link needs a
    // moment to come up, so the (idempotent) command is repeated for a few polls.
    if needMacInput > 0, Set(displayList(active: true)).contains(where: isMain) {
        needMacInput -= 1
        if setMonitorInput(cfg.monitor.mac_input) && needMacInput == 0 { log("monitor input -> \(hex2(cfg.monitor.mac_input)) sent") }
    }
}

// MARK: - Main

func loadConfigOrExit() {
    do { cfg = try Config.load() }
    catch { print("display-guard: \(error)"); exit(1) }
}

let command = CommandLine.arguments.dropFirst().first ?? "run"
switch command {
case "restore":
    restoreAll()
case "status":
    cfg = try? Config.load()
    refreshKnown()
    log("displays: \(known.map { "\($0.key)=\($0.value)\(isMain($0.key) ? "(main)" : "")" }.sorted())")
    log("active: \(displayList(active: true))  disabled-by-us: \(disabled.sorted())")
    if cfg == nil {
        log("no settings file (\(Config.path.path)): run `display-guard setup`")
    } else {
        log("listed USB devices: \(keyboardCount())  locked: \(isLocked())  sunshine busy: \(sunshineBusy())")
    }
case "setup":
    runSetup()
case "run":
    loadConfigOrExit()
    restoreAll()                              // recover from a previous crash
    for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_IGN) }
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { log("signal \(sig): restoring displays"); restoreAll(); exit(0) }
        src.resume()
        sources.append(src)
    }
    log("display-guard started")
    startUSBWatch()
    let timer = Timer(timeInterval: cfg.pollInterval, repeats: true) { _ in reconcile() }
    RunLoop.main.add(timer, forMode: .common)
    reconcile()
    RunLoop.main.run()
default:
    print("usage: display-guard [run|status|restore|setup]")
    exit(2)
}

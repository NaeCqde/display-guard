import Foundation
import AppKit
import Noora

// `display-guard setup`: asks a few questions (like the `init` command of a web
// framework) and writes the settings file. The prompts come from Noora:
// arrows move, space selects, return goes to the next step.

private func tr(_ ja: String, _ en: String) -> String {
    let env = ProcessInfo.processInfo.environment
    let lang = env["LC_ALL"] ?? env["LC_MESSAGES"] ?? env["LANG"] ?? ""
    return lang.hasPrefix("ja") ? ja : en
}

private func tt(_ s: String) -> TerminalText { "\(s)" }

private struct MonitorChoice: Equatable, CustomStringConvertible {
    let vendor: Int
    let model: Int
    let label: String
    var description: String { label }
}

private struct USBChoice: Equatable, CustomStringConvertible {
    let vendor: Int
    let product: Int
    let label: String
    var description: String { label }
}

private enum Condition: CaseIterable, Equatable, CustomStringConvertible {
    case locked, sunshine
    var description: String {
        switch self {
        case .locked: return tr("Macがロック中", "while the Mac is locked")
        case .sunshine: return tr("Sunshineのセッション中", "while a Sunshine session runs")
        }
    }
}

private func hex4(_ v: Int) -> String { "0x" + String(format: "%04X", v) }

private func monitorChoices() -> [MonitorChoice] {
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[CGDirectDisplayID(n.uint32Value)] = screen.localizedName
        }
    }
    return displayList(active: false).map { id in
        let vendor = Int(CGDisplayVendorNumber(id)), model = Int(CGDisplayModelNumber(id))
        let name = names[id] ?? tr("ディスプレイ", "Display")
        let builtin = CGDisplayIsBuiltin(id) != 0 ? tr(" (内蔵)", " (built-in)") : ""
        return MonitorChoice(vendor: vendor, model: model,
                             label: "\(name)\(builtin)  [\(hex4(vendor)):\(hex4(model))]")
    }
}

/// Asks until the answer is a number ("0x11" or "17"), or accepted by `parse`.
private func ask<T>(_ noora: Noora, title: String, prompt: String, description: String, defaultValue: String,
                    parse: (String) -> T?) -> T {
    while true {
        let answer = noora.textPrompt(
            title: tt(title), prompt: tt(prompt), description: tt(description),
            defaultValue: defaultValue, collapseOnAnswer: true, validationRules: []
        ).trimmingCharacters(in: .whitespaces)
        if let v = parse(answer.isEmpty ? defaultValue : answer) { return v }
        print(tr("  読み取れませんでした。もう一度入力してください。", "  Could not read that. Try again."))
    }
}

private func parseInt(_ s: String) -> Int? {
    let t = s.lowercased()
    if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
    return Int(t)
}

func runSetup() {
    guard isatty(STDIN_FILENO) != 0 else {
        print("display-guard setup needs a terminal"); exit(1)
    }
    let noora = Noora()
    let path = Config.path

    print(tr("display-guard の設定を作ります。矢印キーで移動、スペースで選択、Enterで次へ進みます。",
             "Let's set up display-guard. Arrows move, space selects, return goes to the next step."))
    print("")

    if FileManager.default.fileExists(atPath: path.path) {
        let overwrite = noora.yesOrNoChoicePrompt(
            title: tt(tr("設定ファイル", "Settings file")),
            question: tt(tr("\(path.path) は既にあります。上書きしますか?", "\(path.path) exists. Overwrite it?")),
            defaultAnswer: false, description: nil, collapseOnSelection: true)
        if !overwrite { print(tr("中止しました。", "Cancelled.")); return }
    }

    // 1. main monitor
    let monitors = monitorChoices()
    guard !monitors.isEmpty else { print(tr("ディスプレイが見つかりません。", "No display found.")); exit(1) }
    let monitor = noora.singleChoicePrompt(
        title: tt(tr("1. メインモニター", "1. Main monitor")),
        question: tt(tr("USB機器が無いときに切断するモニターを選んでください", "Which monitor should be disconnected when no USB device is on this Mac?")),
        options: monitors,
        description: tt(tr("USB機器が無いとき切断・再接続する対象です。現在つながっているものだけが出ます。入力の切り替えは次の質問で選びます。",
                           "It is disconnected / reconnected. Only the connected displays are listed. Input switching is chosen in the next question.")),
        collapseOnSelection: true, filterMode: .disabled, autoselectSingleChoice: false)

    // Input switching: any number of monitors, only those that answer DDC/CI (asked now), main or not.
    var currents: [String: Int] = [:]
    for m in monitors { if let v = readMonitorInput(vendor: m.vendor, model: m.model) { currents["\(m.vendor):\(m.model)"] = v } }
    let ddcMonitors = monitors.filter { currents["\($0.vendor):\($0.model)"] != nil }
    var switches: [Config.InputSwitch] = []
    if ddcMonitors.isEmpty {
        print(tr("  DDCに応答するモニターがないので、入力の自動切り替えは設定しません。",
                 "  No monitor answers DDC, so input switching is not set up."))
    } else {
        let picked = noora.multipleChoicePrompt(
            title: tt(tr("1. 入力の自動切り替え", "1. Input switching")),
            question: tt(tr("入力を自動で切り替えるモニターを選んでください(なければ何も選ばずEnter)",
                            "Which monitors should have their input switched? (none: just press return)")),
            options: ddcMonitors,
            description: tt(tr("DDCに応答するモニターだけが出ます。メインモニターを選ばなくても構いません。USB機器がMacから外れると、選んだモニターはもう1台の入力に切り替えてから切断され、戻ると再接続してMacの入力に切り替えます。",
                               "Only monitors that answer DDC are listed. The main monitor need not be among them. When the USB devices leave the Mac, each chosen monitor is switched to the other input and then disconnected; when they are back it is connected and switched to the Mac's input.")),
            collapseOnSelection: true, filterMode: .disabled,
            maxLimit: .unlimited, minLimit: .unlimited)
        for m in picked {
            let cur = currents["\(m.vendor):\(m.model)"] ?? 0x11
            let curHex = "0x" + String(cur, radix: 16, uppercase: true)
            print(tr("  \(m.label) の現在の入力: \(curHex)", "  \(m.label) shows input \(curHex) now"))
            let mac: Int = ask(noora, title: tr("1. 入力 — \(m.label)", "1. Inputs — \(m.label)"),
                prompt: tr("このMacを映す入力の値(VCP 0x60)", "Input value that shows this Mac (VCP 0x60)"),
                description: tr("HDMI 1 = 0x11, HDMI 2 = 0x12, DP 1 = 0x0F, DP 2 = 0x10, USB-C = 0x1B(モニターにより異なります)。いまMacが映っているなら、現在の値がそのまま使えます。",
                                "HDMI 1 = 0x11, HDMI 2 = 0x12, DP 1 = 0x0F, DP 2 = 0x10, USB-C = 0x1B (it depends on the monitor). If the Mac is shown now, the current value is the one."),
                defaultValue: curHex) { v in parseInt(v).flatMap { (0...0xFFFF).contains($0) ? $0 : nil } }
            let other: Int = ask(noora, title: tr("1. 入力 — \(m.label)", "1. Inputs — \(m.label)"),
                prompt: tr("もう1台のコンピューターを映す入力の値", "Input value that shows the other computer"),
                description: tr("USB機器がMacから外れたときに、このモニターをこの入力に切り替えてから切断します。",
                                "When the USB devices leave the Mac, this monitor is switched to this input before it is disconnected."),
                defaultValue: mac == 0x0F ? "0x11" : "0x0F") { v in parseInt(v).flatMap { (0...0xFFFF).contains($0) ? $0 : nil } }
            switches.append(.init(vendor: m.vendor, model: m.model, mac_input: mac, other_input: other))
        }
    }

    // 2. USB devices
    var devices: [USBChoice] = []
    for d in usbDevices() where !devices.contains(where: { $0.vendor == d.vendor && $0.product == d.product }) {
        devices.append(USBChoice(vendor: d.vendor, product: d.product,
                                 label: "\(d.name)  [\(hex4(d.vendor)):\(hex4(d.product))]"))
    }
    devices.sort { $0.label.localizedCompare($1.label) == .orderedAscending }
    guard !devices.isEmpty else { print(tr("USB機器が見つかりません。", "No USB device found.")); exit(1) }
    let chosen = noora.multipleChoicePrompt(
        title: tt(tr("2. USB機器", "2. USB devices")),
        question: tt(tr("このMacにつながっている間だけモニターを使う機器を選んでください", "Which USB devices tell that the desk is on this Mac?")),
        options: devices,
        description: tt(tr("キーボードなど。どれか1つでもMacに見えていればモニターを使います。すべて外れると切断します。",
                           "Keyboards and the like. The monitor is used while any of them is seen; it is disconnected when all are gone.")),
        collapseOnSelection: true, filterMode: .disabled,
        maxLimit: .unlimited,
        minLimit: .limited(count: 1, errorMessage: tr("1つ以上選んでください。", "Select at least one.")))

    // 3. others
    let othersEnabled = noora.yesOrNoChoicePrompt(
        title: tt(tr("3. その他のディスプレイ", "3. Other displays")),
        question: tt(tr("メインモニター以外のディスプレイも切断しますか?", "Also disconnect the displays other than the main monitor?")),
        defaultAnswer: true,
        description: tt(tr("条件はこの次に選びます。", "You pick the conditions next.")),
        collapseOnSelection: true)

    var conditions: [Condition] = []
    var sunshineAddress = Config.defaultSunshineAddress
    if othersEnabled {
        conditions = noora.multipleChoicePrompt(
            title: tt(tr("3. 条件", "3. Conditions")),
            question: tt(tr("どの間、切断しますか?", "When should they be disconnected?")),
            options: Condition.allCases,
            description: tt(tr("元に戻ると自動で再接続します。", "They are reconnected when the condition ends.")),
            collapseOnSelection: true, filterMode: .disabled,
            maxLimit: .unlimited, minLimit: .unlimited)
        if conditions.contains(.sunshine) {
            sunshineAddress = ask(noora, title: tr("3. Sunshine", "3. Sunshine"),
                prompt: tr("SunshineのアドレスまたはAddress:ポート", "Sunshine address (host or host:port)"),
                description: tr("auto = このMacのLAN / Tailscaleアドレス(127.0.0.1は見ません。ポート転送が別のマシンの応答を返すことがあるため)。ポートの既定値は47989です。",
                                "auto = this Mac's own LAN / Tailscale addresses (never 127.0.0.1: a port forwarder may answer with another machine's Sunshine). The port defaults to 47989."),
                defaultValue: Config.defaultSunshineAddress) { v in
                    v.isEmpty || v.contains(" ") || v.contains("\"") ? nil : v
                }
        }
    }

    // 4. displays to refresh after the unlock
    var refresh: [MonitorChoice] = []
    refresh = noora.multipleChoicePrompt(
        title: tt(tr("4. 解除時の再接続", "4. Refresh on unlock")),
        question: tt(tr("ロック解除後に暗いままになるモニターを選んでください(なければ何も選ばずEnter)",
                        "Which monitors stay dark after the unlock? (none: just press return)")),
        options: monitors,
        description: tt(tr("選んだモニターは、ロック解除の直後に一度切断してもう一度接続します。",
                           "Each chosen monitor is disconnected and connected again right after the unlock.")),
        collapseOnSelection: true, filterMode: .disabled,
        maxLimit: .unlimited, minLimit: .unlimited)
    var refreshDelay = Config.defaultRefreshDelayMs, refreshOff = Config.defaultRefreshOffMs
    if !refresh.isEmpty {
        refreshDelay = ask(noora, title: tr("4. 解除時の再接続", "4. Refresh on unlock"),
            prompt: tr("ロック解除から再接続までの待ち時間(ミリ秒)", "Milliseconds from the unlock to the refresh"),
            description: tr("通常の再接続が終わるのを待ちます。", "It waits for the normal reconnect to finish."),
            defaultValue: "\(Config.defaultRefreshDelayMs)") { v in Int(v).flatMap { (0...30000).contains($0) ? $0 : nil } }
        refreshOff = ask(noora, title: tr("4. 解除時の再接続", "4. Refresh on unlock"),
            prompt: tr("切断したままにする時間(ミリ秒)", "Milliseconds to keep it disconnected"),
            description: tr("短すぎるとモニターが切断に気づきません。", "Too short and the monitor does not notice."),
            defaultValue: "\(Config.defaultRefreshOffMs)") { v in Int(v).flatMap { (0...30000).contains($0) ? $0 : nil } }
    }

    // 5. timing
    let poll: Double = ask(noora, title: tr("5. タイミング", "5. Timing"),
        prompt: tr("ロックとSunshineを確認する間隔(秒)", "Seconds between the lock / Sunshine checks"),
        description: tr("USBの抜き差しは通知で即座に反応するので、この間隔の影響は受けません。",
                        "USB changes are reacted to at once by notification, so they do not wait for this."),
        defaultValue: "\(Config.defaultPollInterval)") { v in Double(v).flatMap { $0 >= 0.2 && $0 <= 60 ? $0 : nil } }
    let recheck: Int = ask(noora, title: tr("5. タイミング", "5. Timing"),
        prompt: tr("切断する前に再確認するまでの待ち時間(ミリ秒)", "Milliseconds to wait before looking again, prior to disconnecting"),
        description: tr("USBの再列挙で一瞬見えなくなる場合に誤って切断しないための待ち時間です。",
                        "It keeps a short USB re-enumeration from disconnecting the monitor by mistake."),
        defaultValue: "\(Config.defaultRecheckDelayMs)") { v in Int(v).flatMap { (0...5000).contains($0) ? $0 : nil } }

    // 6. start at login
    let customPath = ProcessInfo.processInfo.environment["DISPLAY_GUARD_CONFIG"].map { !$0.isEmpty } ?? false
    var autostart = false
    if customPath {
        print(tr("DISPLAY_GUARD_CONFIG で別の場所を指定しているので、自動起動の登録は聞きません(`display-guard install` は標準の場所の設定を読みます)。",
                 "DISPLAY_GUARD_CONFIG points elsewhere, so the start-at-login step is skipped (`display-guard install` reads the settings in the standard place)."))
    } else {
        autostart = noora.yesOrNoChoicePrompt(
            title: tt(tr("6. 自動起動", "6. Start at login")),
            question: tt(tr("ログイン時に自動で起動しますか?", "Start display-guard automatically at login?")),
            defaultAnswer: true,
            description: tt(tr("「はい」なら、設定を書いたあとに ~/.local/bin へコピーして launchd に登録し、すぐ起動します。",
                               "If yes, after the settings are written it is copied to ~/.local/bin, registered with launchd and started at once.")),
            collapseOnSelection: true)
    }

    let text = Config.render(
        monitor: .init(vendor: monitor.vendor, model: monitor.model),
        switches: switches,
        keyboards: chosen.map { .init(vendor: $0.vendor, product: $0.product) },
        othersEnabled: othersEnabled && !conditions.isEmpty,
        whenLocked: conditions.contains(.locked),
        whenSunshine: conditions.contains(.sunshine),
        sunshineAddress: sunshineAddress,
        refreshOnUnlock: refresh.map { .init(vendor: $0.vendor, model: $0.model) },
        pollInterval: poll, recheckDelayMs: recheck, refreshDelayMs: refreshDelay, refreshOffMs: refreshOff,
        pcPower: (try? Config.load())?.pcPower)   // keeps a hand-written [pc_power]

    do {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
    } catch {
        print("display-guard: cannot write \(path.path): \(error)"); exit(1)
    }
    print("")
    print(tr("\(path.path) に書きました。", "Wrote \(path.path)."))
    if autostart {
        print("")
        runInstall()
    } else {
        print(tr("確認: display-guard status    起動: display-guard install(ログイン時に自動起動)または display-guard run",
                 "Check: display-guard status    Start: display-guard install (at login) or display-guard run"))
    }
}

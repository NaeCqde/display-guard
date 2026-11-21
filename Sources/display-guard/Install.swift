import Foundation

// `display-guard install` / `uninstall`: puts the program in ~/.local/bin and registers it with
// launchd (a LaunchAgent that starts at login and is restarted if it stops). The template is the
// same as com.local.display-guard.plist.template in the repository.

private let label = "com.local.display-guard"

private func tr(_ ja: String, _ en: String) -> String {
    let env = ProcessInfo.processInfo.environment
    let lang = env["LC_ALL"] ?? env["LC_MESSAGES"] ?? env["LANG"] ?? ""
    return lang.hasPrefix("ja") ? ja : en
}

private let plistTemplate = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.local.display-guard</string>
    <key>ProgramArguments</key><array><string>__PROGRAM__</string><string>run</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/display-guard.log</string>
    <key>StandardErrorPath</key><string>/tmp/display-guard.log</string>
</dict>
</plist>

"""

private let home = FileManager.default.homeDirectoryForCurrentUser
private let programURL = home.appendingPathComponent(".local/bin/display-guard")
private let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")

@discardableResult
private func launchctl(_ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

private var domain: String { "gui/\(getuid())" }

private func isLoaded() -> Bool { launchctl(["print", "\(domain)/\(label)"]).status == 0 }

func runInstall() {
    // `run` stops at once without settings, and launchd would restart it again and again.
    do { _ = try Config.load() }
    catch {
        print("display-guard: \(error)")
        print(tr("先に `display-guard setup` を実行してください。", "Run `display-guard setup` first."))
        exit(1)
    }

    let fm = FileManager.default
    let here = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    let there = programURL.resolvingSymlinksInPath()

    // Stop the running copy first: its file is about to be replaced.
    if isLoaded() { launchctl(["bootout", "\(domain)/\(label)"]) }

    do {
        // A binary on an external volume can hang when launchd starts it, so it lives in ~/.local/bin.
        if here.path != there.path {
            try fm.createDirectory(at: programURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = programURL.deletingLastPathComponent().appendingPathComponent(".display-guard.new")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: here, to: tmp)           // keeps the signature of a signed binary
            _ = try fm.replaceItemAt(programURL, withItemAt: tmp)
            print(tr("\(programURL.path) にコピーしました。", "Copied to \(programURL.path)."))
        }
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plistTemplate.replacingOccurrences(of: "__PROGRAM__", with: programURL.path)
            .write(to: plistURL, atomically: true, encoding: .utf8)
    } catch {
        print("display-guard: \(error)"); exit(1)
    }

    let r = launchctl(["bootstrap", domain, plistURL.path])
    guard r.status == 0 else {
        print("display-guard: launchctl bootstrap failed (\(r.status)): \(r.output)"); exit(1)
    }
    print(tr("登録しました(\(plistURL.path))。ログイン時に起動し、止まっても再起動します。ログ: /tmp/display-guard.log",
             "Registered (\(plistURL.path)). It starts at login and is restarted if it stops. Log: /tmp/display-guard.log"))
}

func runUninstall() {
    if isLoaded() {
        let r = launchctl(["bootout", "\(domain)/\(label)"])
        if r.status != 0 { print("display-guard: launchctl bootout failed (\(r.status)): \(r.output)") }
    }
    if FileManager.default.fileExists(atPath: plistURL.path) {
        try? FileManager.default.removeItem(at: plistURL)
        print(tr("\(plistURL.path) を削除しました。", "Removed \(plistURL.path)."))
    } else {
        print(tr("登録されていません。", "It was not registered."))
    }
    restoreAll()                                  // bring back any display this program disconnected
    print(tr("\(programURL.path) と設定ファイルは残してあります。", "\(programURL.path) and the settings file are kept."))
}

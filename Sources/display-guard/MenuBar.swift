import AppKit

// The menu bar item: display-guard stays in the menu bar, and a display that stayed dark can be
// disconnected and connected again by hand from its menu.

private func ja() -> Bool { Locale.preferredLanguages.first?.hasPrefix("ja") ?? false }
private func t(_ j: String, _ e: String) -> String { ja() ? j : e }

final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var names: [CGDirectDisplayID: String] = [:]

    func start() {
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "display", accessibilityDescription: "display-guard")
            b.image?.isTemplate = true
            if b.image == nil { b.title = "DG" }
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    private func label(_ id: CGDirectDisplayID) -> String {
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[CGDirectDisplayID(n.uint32Value)] = s.localizedName
            }
        }
        let key = known[id] ?? "?"
        return "\(names[id] ?? key)  (\(id))"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshKnown()
        let head = NSMenuItem(title: "display-guard", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        let listed = known.keys.sorted().filter { id in
            guard let d = known[id] else { return false }
            return cfg.refreshOnUnlock.contains { d == "\($0.vendor):\($0.model)" }
        }
        let all = NSMenuItem(title: t("対象のモニターを再接続", "Reconnect the listed monitors"), action: #selector(reconnectListed), keyEquivalent: "")
        all.target = self; all.isEnabled = !listed.isEmpty
        menu.addItem(all)
        menu.addItem(.separator())
        for id in known.keys.sorted() {
            let m = NSMenuItem(title: t("再接続: ", "Reconnect: ") + label(id), action: #selector(reconnectOne(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = NSNumber(value: id)
            menu.addItem(m)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: t("終了(ディスプレイを元に戻す)", "Quit (restore the displays)"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func reconnectListed() {
        log("menu: reconnect the listed monitors")
        for id in known.keys.sorted() {
            if let d = known[id], cfg.refreshOnUnlock.contains(where: { d == "\($0.vendor):\($0.model)" }) { refreshDisplay(id) }
        }
    }

    @objc private func reconnectOne(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        log("menu: reconnect display \(n)")
        refreshDisplay(CGDirectDisplayID(n.uint32Value))
    }

    @objc private func quit() {
        log("menu: quit, restoring displays")
        restoreAll()
        exit(0)
    }
}

var menuBar: MenuBarController?

func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)          // no Dock icon
    menuBar = MenuBarController()
    menuBar?.start()
    app.run()
    exit(0)
}

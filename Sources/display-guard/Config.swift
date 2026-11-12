import Foundation
import TOMLDecoder

/// The settings file: `~/.config/display-guard/config.toml` (or the path in
/// `DISPLAY_GUARD_CONFIG`). `display-guard setup` writes it.
struct Config {
    struct Monitor: Codable {
        var vendor: Int          // EDID vendor id as CoreGraphics reports it (Dell = 0x10AC)
        var model: Int           // EDID product code (G2725D = 0x2014)
        var mac_input: Int       // VCP 0x60 value that shows this Mac (HDMI 1 = 0x11)
        var other_input: Int     // VCP 0x60 value for the other computer (DP 1 = 0x0F)
    }

    struct Keyboard: Codable {
        var vendor: Int          // USB vendor id
        var product: Int?        // USB product id; omitted = every device of the vendor
    }

    struct Others: Codable {
        var enabled: Bool?
        var when_locked: Bool?
        var when_sunshine: Bool?
        var sunshine_address: String?
    }

    struct Display: Codable {
        var vendor: Int          // EDID vendor id
        var model: Int           // EDID product code
    }

    struct Timing: Codable {
        var poll_interval: Double?
        var recheck_delay_ms: Int?
        var refresh_delay_ms: Int?
        var refresh_off_ms: Int?
    }

    private struct File: Codable {
        var monitor: Monitor
        var keyboard: [Keyboard]
        var others: Others?
        var refresh_on_unlock: [Display]?
        var timing: Timing?
    }

    // The values the program works with, after the defaults are applied.
    var monitor: Monitor
    var keyboards: [Keyboard]
    var othersEnabled: Bool
    var whenLocked: Bool
    var whenSunshine: Bool
    var sunshineAddress: String
    var pollInterval: TimeInterval
    var recheckDelay: useconds_t
    var refreshOnUnlock: [Display]
    var refreshDelayMs: Int
    var refreshOffMs: Int

    static let defaultSunshineAddress = "auto"
    static let defaultPollInterval = 1.5
    static let defaultRecheckDelayMs = 300
    static let defaultRefreshDelayMs = 1000
    static let defaultRefreshOffMs = 2000

    static var path: URL {
        if let p = ProcessInfo.processInfo.environment["DISPLAY_GUARD_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/display-guard/config.toml")
    }

    static func load() throws -> Config {
        let text: String
        do { text = try String(contentsOf: path, encoding: .utf8) }
        catch { throw ConfigError("cannot read \(path.path): run `display-guard setup` first") }
        let f: File
        do { f = try TOMLDecoder().decode(File.self, from: text) }
        catch { throw ConfigError("cannot parse \(path.path): \(error)") }
        guard !f.keyboard.isEmpty else {
            throw ConfigError("\(path.path): at least one [[keyboard]] is needed (without one the monitor would always be disconnected)")
        }
        let o = f.others, t = f.timing
        return Config(
            monitor: f.monitor,
            keyboards: f.keyboard,
            othersEnabled: o?.enabled ?? true,
            whenLocked: o?.when_locked ?? true,
            whenSunshine: o?.when_sunshine ?? true,
            sunshineAddress: o?.sunshine_address ?? defaultSunshineAddress,
            pollInterval: t?.poll_interval ?? defaultPollInterval,
            recheckDelay: useconds_t((t?.recheck_delay_ms ?? defaultRecheckDelayMs) * 1000),
            refreshOnUnlock: f.refresh_on_unlock ?? [],
            refreshDelayMs: t?.refresh_delay_ms ?? defaultRefreshDelayMs,
            refreshOffMs: t?.refresh_off_ms ?? defaultRefreshOffMs
        )
    }

    /// The text `setup` writes. Hex numbers keep the USB / EDID ids readable.
    static func render(monitor: Monitor, keyboards: [Keyboard], othersEnabled: Bool, whenLocked: Bool,
                       whenSunshine: Bool, sunshineAddress: String, refreshOnUnlock: [Display],
                       pollInterval: Double, recheckDelayMs: Int, refreshDelayMs: Int, refreshOffMs: Int) -> String {
        func hex(_ v: Int, _ width: Int = 4) -> String {
            "0x" + String(format: "%0\(width)X", v)
        }
        func bool(_ b: Bool) -> String { b ? "true" : "false" }
        var s = """
        # display-guard settings (written by `display-guard setup`)

        # The main monitor: disconnected while no listed USB device is on this Mac,
        # and switched between the two inputs over DDC/CI.
        [monitor]
        vendor      = \(hex(monitor.vendor))   # EDID vendor id
        model       = \(hex(monitor.model))   # EDID product code
        mac_input   = \(hex(monitor.mac_input, 2))     # VCP 0x60 value that shows this Mac (HDMI 1 = 0x11)
        other_input = \(hex(monitor.other_input, 2))     # VCP 0x60 value for the other computer (DP 1 = 0x0F)

        # USB devices that tell "the desk is on this Mac": the monitor is used while any of them is seen.
        # Leave `product` out to match every device of the vendor.

        """
        for k in keyboards {
            s += "[[keyboard]]\nvendor  = \(hex(k.vendor))\n"
            if let p = k.product { s += "product = \(hex(p))\n" }
            s += "\n"
        }
        s += """
        # Other displays: disconnected while the Mac is locked and / or a Sunshine session runs.
        [others]
        enabled       = \(bool(othersEnabled))
        when_locked   = \(bool(whenLocked))
        when_sunshine = \(bool(whenSunshine))
        # "auto" = this Mac's own LAN / Tailscale addresses (never 127.0.0.1: a port forwarder may answer there).
        # Or one host, "100.64.0.1" or "host:47989" (the port defaults to 47989).
        sunshine_address = "\(sunshineAddress)"

        # Displays that stay dark after the Mac is unlocked: right after the unlock each one is disconnected
        # and connected again (see refresh_* in [timing]). One [[refresh_on_unlock]] per display; none = off.

        """
        for d in refreshOnUnlock { s += "[[refresh_on_unlock]]\nvendor = \(hex(d.vendor))\nmodel  = \(hex(d.model))\n\n" }
        s += """
        [timing]
        poll_interval    = \(pollInterval)   # seconds between lock / Sunshine checks
        recheck_delay_ms = \(recheckDelayMs)   # look again before disconnecting, to ride out a USB re-enumeration
        refresh_delay_ms = \(refreshDelayMs)   # wait after the unlock before the refresh
        refresh_off_ms   = \(refreshOffMs)   # how long the display stays disconnected during the refresh

        """
        return s
    }
}

struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

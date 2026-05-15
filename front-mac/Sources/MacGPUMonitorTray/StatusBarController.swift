import AppKit
import Foundation

private let repoURL = URL(string: "https://github.com/maximofn/mac_gpu_monitor")!
private let coffeeURL = URL(string: "https://www.buymeacoffee.com/maximofn")!

enum TrayState: Sendable {
    case connecting
    case connected(Snapshot)
    case disconnected(String)
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let renderer: IconRenderer
    private let backendURL: String
    private var state: TrayState = .connecting
    private var lastAppearance: IconAppearance = .dark
    private var lastRenderedKey: String = ""
    private let compactModeDefaultsKey = "MacGPUMonitorTray.compactMode"
    private var compactMode: Bool

    init(renderer: IconRenderer, backendURL: String) {
        self.renderer = renderer
        self.backendURL = backendURL
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.compactMode = UserDefaults.standard.bool(forKey: compactModeDefaultsKey)
        super.init()
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.toolTip = "Mac GPU Monitor — connecting to \(backendURL)"
        }
        // Don't KVO `effectiveAppearance` on the button — AppKit re-evaluates
        // that during repaints and any reaction there feeds back into
        // refreshIcon → set image → repaint → KVO loop.
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        lastAppearance = currentAppearance
        applyState(.connecting)
    }

    deinit {
        DistributedNotificationCenter.default.removeObserver(self)
    }

    @objc private func appearanceChanged() {
        Task { @MainActor in
            self.lastAppearance = self.currentAppearance
            self.lastRenderedKey = ""
            self.refreshIcon()
        }
    }

    func applyState(_ new: TrayState) {
        state = new
        refreshIcon()
        refreshMenu()
        refreshTooltip()
    }

    private var currentAppearance: IconAppearance {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        switch match {
        case .darkAqua, .vibrantDark: return .dark
        default: return .light
        }
    }

    private func refreshIcon() {
        let (gpu, connected): (GPU?, Bool) = {
            switch state {
            case .connected(let snap): return (snap.gpus.first, snap.gpus.first != nil)
            default: return (nil, false)
            }
        }()
        // Dedupe identical renders — at 1 Hz most ticks have identical visible state.
        let key = renderKey(gpu: gpu, connected: connected, appearance: lastAppearance)
        if key == lastRenderedKey { return }
        lastRenderedKey = key
        if let img = renderer.renderImage(gpu: gpu, connected: connected, appearance: lastAppearance, compact: compactMode) {
            statusItem.button?.image = img
        }
    }

    private func renderKey(gpu: GPU?, connected: Bool, appearance: IconAppearance) -> String {
        var parts: [String] = ["\(connected)", "\(appearance)", "compact=\(compactMode)"]
        if let g = gpu {
            let pct = g.utilization.gpuPercent
            let temp = g.temperatureC.map { Int($0) } ?? -999
            let memPct = g.utilization.memoryPercent
            parts.append("\(pct):\(temp):\(memPct)")
        }
        return parts.joined(separator: "|")
    }

    private func refreshTooltip() {
        guard let button = statusItem.button else { return }
        switch state {
        case .connecting:
            button.toolTip = "Mac GPU Monitor — connecting to \(backendURL)"
        case .connected(let snap):
            guard let g = snap.gpus.first else {
                button.toolTip = "Mac GPU Monitor — no GPU reported"
                return
            }
            let tempStr = g.temperatureC.map { "\($0)°C" } ?? "—"
            let header = "\(g.name) — \(g.utilization.gpuPercent)% (\(tempStr))"
            var lines: [String] = [header]
            if let p = g.powerDrawW {
                lines.append(String(format: "Power: %.1f W", p))
            }
            lines.append(String(format: "Memory: %@ / %@ (%d%%)",
                                formatBytes(g.memory.usedBytes),
                                formatBytes(g.memory.totalBytes),
                                g.utilization.memoryPercent))
            button.toolTip = lines.joined(separator: "\n")
        case .disconnected(let err):
            button.toolTip = "Backend offline: \(err)"
        }
    }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch state {
        case .connecting:
            menu.addItem(disabledItem("Connecting to \(backendURL)…"))
            menu.addItem(.separator())
        case .disconnected(let err):
            menu.addItem(disabledItem("Backend offline: \(err)"))
            menu.addItem(disabledItem("Backend: \(backendURL)"))
            menu.addItem(.separator())
        case .connected(let snap):
            if snap.gpus.isEmpty {
                menu.addItem(disabledItem("No GPUs reported"))
            } else {
                for g in snap.gpus {
                    let item = NSMenuItem(title: g.name, action: nil, keyEquivalent: "")
                    item.submenu = gpuSubmenu(for: g)
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())
            menu.addItem(disabledItem("Backend: \(backendURL)"))
            if let driver = snap.driverVersion {
                menu.addItem(disabledItem("Driver: \(driver)"))
            }
            menu.addItem(disabledItem("Updated: \(shortTime(snap.timestamp))"))
            menu.addItem(.separator())
        }

        let toggleTitle = compactMode ? "Cambiar a extendido" : "Cambiar a compacto"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleCompactMode), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let repo = NSMenuItem(title: "Repository", action: #selector(openRepo), keyEquivalent: "")
        repo.target = self
        menu.addItem(repo)
        let coffee = NSMenuItem(title: "Buy me a coffee", action: #selector(openCoffee), keyEquivalent: "")
        coffee.target = self
        menu.addItem(coffee)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func gpuSubmenu(for gpu: GPU) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(disabledItem("Index: \(gpu.index)"))
        if !gpu.uuid.isEmpty {
            m.addItem(disabledItem("UUID: \(gpu.uuid)"))
        }
        m.addItem(disabledItem("Utilization: \(gpu.utilization.gpuPercent)%"))
        if let t = gpu.temperatureC {
            m.addItem(disabledItem("Temperature: \(t)°C"))
        }
        if let p = gpu.powerDrawW {
            let limit = gpu.powerLimitW.map { String(format: " / %.1f W", $0) } ?? ""
            m.addItem(disabledItem(String(format: "Power: %.2f W%@", p, limit)))
        }
        if let f = gpu.fanSpeedPercent {
            m.addItem(disabledItem("Fan: \(f)%"))
        }

        m.addItem(.separator())
        m.addItem(disabledItem(String(format: "Memory: %@ / %@",
                                       formatBytes(gpu.memory.usedBytes),
                                       formatBytes(gpu.memory.totalBytes))))
        m.addItem(disabledItem("Memory used: \(gpu.utilization.memoryPercent)%"))
        m.addItem(disabledItem("Memory free: \(formatBytes(gpu.memory.freeBytes))"))

        m.addItem(.separator())
        if gpu.processes.isEmpty {
            m.addItem(disabledItem("No GPU processes"))
        } else {
            m.addItem(disabledItem("Top processes (\(gpu.processes.count))"))
            for proc in gpu.processes {
                let line = String(
                    format: "  %6d %@  %@ (%@)",
                    proc.pid,
                    proc.kind as NSString,
                    proc.name as NSString,
                    formatBytes(proc.usedMemoryBytes) as NSString
                )
                m.addItem(disabledItem(line))
            }
        }
        return m
    }

    @objc private func openRepo() { NSWorkspace.shared.open(repoURL) }
    @objc private func openCoffee() { NSWorkspace.shared.open(coffeeURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleCompactMode() {
        compactMode.toggle()
        UserDefaults.standard.set(compactMode, forKey: compactModeDefaultsKey)
        lastRenderedKey = ""
        refreshIcon()
        refreshMenu()
    }
}

// MARK: - Helpers

private func disabledItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
}

private func formatBytes(_ bytes: UInt64) -> String {
    let gib: Double = 1024 * 1024 * 1024
    let mib: Double = 1024 * 1024
    let b = Double(bytes)
    if b >= gib { return String(format: "%.2f GiB", b / gib) }
    if b >= mib { return String(format: "%.0f MiB", b / mib) }
    return "\(bytes) B"
}

/// "2026-05-06T10:11:12.345Z" → "10:11:12".
private func shortTime(_ rfc3339: String) -> String {
    guard let tIdx = rfc3339.firstIndex(of: "T") else { return rfc3339 }
    let after = rfc3339[rfc3339.index(after: tIdx)...]
    if let dot = after.firstIndex(of: ".") {
        return String(after[..<dot])
    }
    if let plus = after.firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" }) {
        return String(after[..<plus])
    }
    return String(after)
}

import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let manager = WindowManager()
    private var toggleHotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() { return }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        manager.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }
        rebuildMenu()
        registerToggleHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if manager.isTiling { manager.stopAndRestore() }
        if let m = toggleHotkeyMonitor { NSEvent.removeMonitor(m); toggleHotkeyMonitor = nil }
    }

    private func ensureSingleInstance() -> Bool {
        let myId = Bundle.main.bundleIdentifier ?? "com.youngharold.terminal-tiler"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: myId)
            .filter { $0.processIdentifier != myPID }
        if others.isEmpty { return true }
        let alert = NSAlert()
        alert.messageText = "Terminal Tiler is already running"
        alert.informativeText = "Quit the existing instance from the menu bar before launching another."
        alert.runModal()
        NSApp.terminate(nil)
        return false
    }

    private func registerToggleHotkey() {
        // Cmd+Option+T to toggle tiling. Match by character (layout-independent) and
        // explicitly allow only the two modifiers we want — Caps Lock is fine.
        toggleHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags
            guard mods.contains(.command), mods.contains(.option),
                  !mods.contains(.shift), !mods.contains(.control),
                  event.charactersIgnoringModifiers?.lowercased() == "t" else { return }
            DispatchQueue.main.async { self?.manager.toggle() }
        }
    }

    private func rebuildMenu() {
        if let button = statusItem.button {
            let symbol = manager.isTiling ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Terminal Tiler")
        }

        let menu = NSMenu()

        if !manager.isTiling {
            let tile = NSMenuItem(title: "Tile Terminal Windows", action: #selector(toggleTiling), keyEquivalent: "t")
            tile.keyEquivalentModifierMask = [.command, .option]
            tile.target = self
            menu.addItem(tile)
        } else {
            let stopRoot = NSMenuItem(title: "Stop Tiling", action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()

            let restore = NSMenuItem(title: "Stop & Restore Originals", action: #selector(stopAndRestore), keyEquivalent: "t")
            restore.keyEquivalentModifierMask = [.command, .option]
            restore.target = self
            stopMenu.addItem(restore)

            let leave = NSMenuItem(title: "Stop & Leave Where They Are", action: #selector(stopAndLeave), keyEquivalent: "")
            leave.target = self
            stopMenu.addItem(leave)

            stopRoot.submenu = stopMenu
            menu.addItem(stopRoot)
        }

        let retile = NSMenuItem(title: "Re-tile Now", action: #selector(retileNow), keyEquivalent: "r")
        retile.target = self
        retile.isEnabled = manager.isTiling
        menu.addItem(retile)

        let refresh = NSMenuItem(title: "Refresh Window List", action: #selector(refreshWindows), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = manager.isTiling
        menu.addItem(refresh)

        menu.addItem(.separator())

        let zoomItem = NSMenuItem(title: "Zoom Style", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        let sideStrip = NSMenuItem(title: "Side Strip (focused + thumbnails)", action: #selector(setSideStrip), keyEquivalent: "")
        sideStrip.target = self
        sideStrip.state = manager.zoomMode == .sideStrip ? .on : .off
        zoomMenu.addItem(sideStrip)
        let fullScreen = NSMenuItem(title: "Full Screen (focused fills, others hidden)", action: #selector(setFullScreen), keyEquivalent: "")
        fullScreen.target = self
        fullScreen.state = manager.zoomMode == .fullScreen ? .on : .off
        zoomMenu.addItem(fullScreen)
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: manager.isTiling ? "Tiling \(manager.windowCount) windows" : "Idle",
            action: nil, keyEquivalent: ""
        )
        about.isEnabled = false
        menu.addItem(about)

        let hint = NSMenuItem(title: "Esc returns to grid · ⌘⌥T toggles", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let version = NSMenuItem(title: "v\(short) (\(build))", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggleTiling() { manager.toggle() }
    @objc private func stopAndRestore() { manager.stopAndRestore() }
    @objc private func stopAndLeave() { manager.stopAndLeaveInPlace() }
    @objc private func retileNow() { manager.retile() }
    @objc private func refreshWindows() { manager.refreshWindows() }
    @objc private func setSideStrip() { manager.zoomMode = .sideStrip }
    @objc private func setFullScreen() { manager.zoomMode = .fullScreen }
}

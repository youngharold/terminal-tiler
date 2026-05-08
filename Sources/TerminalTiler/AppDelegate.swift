import AppKit
import ApplicationServices
import ServiceManagement
import TerminalTilerCore

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
        // AX writes are async-ish; spin the runloop briefly so restored frames actually land
        // before the process exits. Without this, quitting mid-tile can leave windows half-restored.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
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
        // Global key monitoring is gated by Accessibility (same TCC permission). If trust isn't
        // granted yet, addGlobalMonitor returns silently with no events ever firing. We retry
        // on a short timer until trust flips on, so users who grant later don't need to restart.
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.registerToggleHotkey()
            }
            return
        }
        // ⌘⌥T  — toggle tiling (start, or Stop & Restore if tiling)
        // ⌘⌥⇧T — Stop & Leave Where They Are (only meaningful while tiling)
        // ⌘⌥G  — return to grid (replaces Esc, which conflicts with vim/REPLs in Terminal)
        toggleHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags
            guard mods.contains(.command), mods.contains(.option), !mods.contains(.control) else { return }
            let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
            // Early-bail on irrelevant chars so we don't dispatch every ⌘⌥<key> press.
            guard char == "t" || char == "g" else { return }
            let shift = mods.contains(.shift)
            DispatchQueue.main.async { [weak self] in
                guard let m = self?.manager else { return }
                switch (char, shift) {
                case ("t", false): m.toggle()
                case ("t", true):  if m.isTiling { m.stopAndLeaveInPlace() }
                case ("g", false): if m.isTiling { m.retile() }
                default: break
                }
            }
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

            let leave = NSMenuItem(title: "Stop & Leave Where They Are", action: #selector(stopAndLeave), keyEquivalent: "T")
            leave.keyEquivalentModifierMask = [.command, .option, .shift]
            leave.target = self
            stopMenu.addItem(leave)

            stopRoot.submenu = stopMenu
            menu.addItem(stopRoot)
        }

        let retile = NSMenuItem(title: "Return to Grid", action: #selector(retileNow), keyEquivalent: "g")
        retile.keyEquivalentModifierMask = [.command, .option]
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

        let hint = NSMenuItem(title: "⌘⌥T toggle · ⌘⌥G return to grid · ⌘⌥⇧T stop & leave", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let version = NSMenuItem(title: "v\(short) (\(build))", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login setting"
            alert.informativeText = "\(error.localizedDescription)\n\nMake sure Terminal Tiler is in /Applications and is allowed in System Settings → General → Login Items."
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func toggleTiling() { manager.toggle() }
    @objc private func stopAndRestore() { manager.stopAndRestore() }
    @objc private func stopAndLeave() { manager.stopAndLeaveInPlace() }
    @objc private func retileNow() { manager.retile() }
    @objc private func refreshWindows() { manager.refreshWindows() }
    @objc private func setSideStrip() { manager.zoomMode = .sideStrip }
    @objc private func setFullScreen() { manager.zoomMode = .fullScreen }
}

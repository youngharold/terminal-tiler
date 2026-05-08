import AppKit
import ApplicationServices
import ServiceManagement
import TerminalTilerCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let manager = WindowManager()
    private var toggleHotkeyMonitor: Any?

    /// True if this binary is running from a real `.app` bundle. Launch at Login via
    /// SMAppService.mainApp is meaningless when run from `.build/release/`.
    private var isInsideAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Update only items whose state can change OUTSIDE our control (e.g. user toggled
        // Login Items in System Settings). Don't rebuild the whole menu here — that would
        // replace `statusItem.menu` while we're inside this menu's own delegate callback.
        if let loginItem = menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) }) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

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
        // Idempotent: tear down any prior monitor before re-installing.
        if let m = toggleHotkeyMonitor { NSEvent.removeMonitor(m); toggleHotkeyMonitor = nil }
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

        // Tiling-only items: hide entirely when idle so the menu stays clean.
        if manager.isTiling {
            let retile = NSMenuItem(title: "Return to Grid", action: #selector(retileNow), keyEquivalent: "g")
            retile.keyEquivalentModifierMask = [.command, .option]
            retile.target = self
            menu.addItem(retile)

            let refresh = NSMenuItem(title: "Refresh Window List", action: #selector(refreshWindows), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            let exclude = NSMenuItem(title: "Exclude Focused Window", action: #selector(excludeFocused), keyEquivalent: "")
            exclude.target = self
            exclude.toolTip = "Drop the focused Terminal window from tiling and snap it back to where it was. Useful for long-running monitors that shouldn't move."
            menu.addItem(exclude)
        }

        menu.addItem(.separator())

        let zoomItem = NSMenuItem(title: "Zoom Style", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        for mode in ZoomMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setZoomMode(_:)), keyEquivalent: "")
            item.target = self
            item.state = manager.zoomMode == mode ? .on : .off
            item.representedObject = mode.rawValue
            zoomMenu.addItem(item)
        }
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        let autoReturnItem = NSMenuItem(title: "Auto Return to Grid", action: nil, keyEquivalent: "")
        let autoMenu = NSMenu()
        let idleItem = NSMenuItem(title: "After 5 min idle", action: #selector(toggleIdleReturn), keyEquivalent: "")
        idleItem.target = self
        idleItem.state = manager.autoReturnIdleEnabled ? .on : .off
        autoMenu.addItem(idleItem)
        let hoverItem = NSMenuItem(title: "On hover at top edge", action: #selector(toggleHoverReturn), keyEquivalent: "")
        hoverItem.target = self
        hoverItem.state = manager.autoReturnHoverEnabled ? .on : .off
        autoMenu.addItem(hoverItem)
        let sendItem = NSMenuItem(title: "After ⏎ + 3s idle (Claude-CLI style)", action: #selector(toggleSendReturn), keyEquivalent: "")
        sendItem.target = self
        sendItem.state = manager.autoReturnAfterSendEnabled ? .on : .off
        autoMenu.addItem(sendItem)
        autoReturnItem.submenu = autoMenu
        menu.addItem(autoReturnItem)

        menu.addItem(.separator())

        let status = NSMenuItem(
            title: manager.isTiling ? "Tiling \(manager.windowCount) windows" : "Idle",
            action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

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

        // Only offer Launch at Login when running from a real .app bundle — SMAppService
        // can't register the bare `.build/release/TerminalTiler` binary.
        if isInsideAppBundle {
            let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(loginItem)
        }

        let about = NSMenuItem(title: "About Terminal Tiler", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "https://github.com/youngharold/terminal-tiler",
                attributes: [
                    .foregroundColor: NSColor.linkColor,
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                ]
            ),
        ])
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
            rebuildMenu()
            return
        }
        // .requiresApproval: registration was accepted but the user must enable Terminal Tiler
        // in System Settings → General → Login Items. Surface that explicitly so they don't
        // think the toggle is broken.
        if service.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Approval needed in System Settings"
            alert.informativeText = "Terminal Tiler is registered as a login item but needs your approval. Open System Settings → General → Login Items and toggle Terminal Tiler on."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        rebuildMenu()
    }

    @objc private func toggleTiling() { manager.toggle() }
    @objc private func stopAndRestore() { manager.stopAndRestore() }
    @objc private func stopAndLeave() { manager.stopAndLeaveInPlace() }
    @objc private func retileNow() { manager.retile() }
    @objc private func refreshWindows() { manager.refreshWindows() }
    @objc private func excludeFocused() { manager.excludeFocused() }
    @objc private func setZoomMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ZoomMode(rawValue: raw) else { return }
        manager.zoomMode = mode
    }

    @objc private func toggleIdleReturn() { manager.autoReturnIdleEnabled.toggle() }
    @objc private func toggleHoverReturn() { manager.autoReturnHoverEnabled.toggle() }
    @objc private func toggleSendReturn() { manager.autoReturnAfterSendEnabled.toggle() }
}

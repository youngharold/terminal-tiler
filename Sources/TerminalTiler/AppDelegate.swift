import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let manager = WindowManager()
    private var toggleHotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        if let m = toggleHotkeyMonitor { NSEvent.removeMonitor(m); toggleHotkeyMonitor = nil }
    }

    private func registerToggleHotkey() {
        // Cmd+Option+T to toggle tiling from anywhere.
        toggleHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let want: NSEvent.ModifierFlags = [.command, .option]
            let active = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if active == want, event.keyCode == 17 {
                DispatchQueue.main.async { self?.manager.toggle() }
            }
        }
    }

    private func rebuildMenu() {
        if let button = statusItem.button {
            let symbol = manager.isTiling ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Terminal Tiler")
        }

        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: manager.isTiling ? "Stop Tiling" : "Tile Terminal Windows",
            action: #selector(toggleTiling),
            keyEquivalent: "t"
        )
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        menu.addItem(toggle)

        let retile = NSMenuItem(title: "Re-tile Now", action: #selector(retileNow), keyEquivalent: "r")
        retile.target = self
        retile.isEnabled = manager.isTiling
        menu.addItem(retile)

        let refresh = NSMenuItem(title: "Refresh Window List", action: #selector(refreshWindows), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = manager.isTiling
        menu.addItem(refresh)

        menu.addItem(.separator())

        // Zoom style submenu
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
            action: nil,
            keyEquivalent: ""
        )
        about.isEnabled = false
        menu.addItem(about)

        let hint = NSMenuItem(title: "Esc returns to grid · ⌘⌥T toggles", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc private func toggleTiling() { manager.toggle() }
    @objc private func retileNow() { manager.retile() }
    @objc private func refreshWindows() { manager.refreshWindows() }
    @objc private func setSideStrip() { manager.zoomMode = .sideStrip }
    @objc private func setFullScreen() { manager.zoomMode = .fullScreen }
}

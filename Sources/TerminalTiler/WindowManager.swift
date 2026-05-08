import AppKit
import ApplicationServices

enum ZoomMode: String {
    case sideStrip
    case fullScreen
}

final class WindowManager {
    private(set) var isTiling = false
    var onStateChange: (() -> Void)?

    var windowCount: Int { managed.count }

    var zoomMode: ZoomMode {
        get { _zoomMode }
        set {
            _zoomMode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "zoomMode")
            onStateChange?()
            guard isTiling else { return }
            if let last = lastFocused {
                zoom(last)
            } else {
                layoutGrid()
            }
        }
    }
    private var _zoomMode: ZoomMode = ZoomMode(rawValue: UserDefaults.standard.string(forKey: "zoomMode") ?? "") ?? .sideStrip

    private final class Managed {
        let window: AXUIElement
        var original: CGRect
        var slot: CGRect = .zero
        var animationGeneration: Int = 0
        init(window: AXUIElement, original: CGRect) {
            self.window = window
            self.original = original
        }
    }

    private var pid: pid_t = 0
    private var terminalApp: AXUIElement?
    private var managed: [Managed] = []
    private var subscribedWindows: [AXUIElement] = []
    private var observer: AXObserver?
    private var keyMonitorGlobal: Any?
    private var keyMonitorLocal: Any?
    private var ignoreFocusCounter: Int = 0
    private var lastFocused: AXUIElement?

    private var isFocusIgnored: Bool { ignoreFocusCounter > 0 }

    private func suspendFocus(for duration: TimeInterval) {
        ignoreFocusCounter += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self else { return }
            self.ignoreFocusCounter = max(0, self.ignoreFocusCounter - 1)
        }
    }

    // MARK: - Public API

    func toggle() {
        if isTiling { stopAndRestore() } else { start() }
    }

    func stopAndRestore() { stop(restore: true) }
    func stopAndLeaveInPlace() { stop(restore: false) }

    func retile() {
        guard isTiling else { return }
        layoutGrid()
        lastFocused = nil
    }

    func refreshWindows() {
        guard isTiling, let axApp = terminalApp else { return }
        var winsRef: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)
        guard let wins = winsRef as? [AXUIElement] else { return }

        let valid = wins.filter { isManageable($0) }
        managed.removeAll { m in !valid.contains(where: { CFEqual($0, m.window) }) }
        for w in valid where !managed.contains(where: { CFEqual($0.window, w) }) {
            // Capture original BEFORE laying out so Stop & Restore is sane.
            let mw = Managed(window: w, original: getFrame(w))
            managed.append(mw)
            subscribeDestroy(w)
        }
        if managed.isEmpty { stop(restore: false); return }
        layoutGrid()
    }

    // MARK: - Lifecycle

    private func start() {
        guard AXIsProcessTrusted() else {
            showAccessibilityAlert()
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            showAlert(
                title: "Terminal isn't running",
                body: "Open Terminal.app with at least two windows, then try again."
            )
            return
        }
        pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        terminalApp = axApp

        var winsRef: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)
        let wins = (winsRef as? [AXUIElement]) ?? []
        let valid = wins.filter { isManageable($0) }

        guard valid.count >= 2 else {
            let body = valid.isEmpty
                ? "Open at least two Terminal windows first."
                : "You have only one Terminal window — open another to tile."
            showAlert(title: "Not enough Terminal windows", body: body)
            terminalApp = nil
            pid = 0
            return
        }

        managed = valid.map { Managed(window: $0, original: getFrame($0)) }

        var obs: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &obs)
        guard result == .success, let observer = obs else {
            NSLog("AXObserverCreate failed: \(result.rawValue)")
            showAlert(
                title: "Couldn't observe Terminal",
                body: "AXObserverCreate failed (\(result.rawValue)). Try restarting Terminal.app and Terminal Tiler."
            )
            for m in managed { setFrame(m.window, to: m.original) }
            managed = []
            terminalApp = nil
            pid = 0
            return
        }
        self.observer = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, context)
        AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, context)
        for m in managed { subscribeDestroy(m.window) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)

        // Esc returns to grid — only when Terminal is the frontmost app, so we don't hijack Esc elsewhere.
        keyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" {
                self?.retile()
            }
        }
        keyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.retile() }
            return event
        }

        isTiling = true
        layoutGrid()
        onStateChange?()
    }

    private func stop(restore: Bool) {
        if restore {
            for m in managed { setFrame(m.window, to: m.original) }
        }
        managed = []

        if let observer = observer, let app = terminalApp {
            AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, app, kAXWindowCreatedNotification as CFString)
            for w in subscribedWindows {
                AXObserverRemoveNotification(observer, w, kAXUIElementDestroyedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        terminalApp = nil
        subscribedWindows = []
        pid = 0

        if let m = keyMonitorGlobal { NSEvent.removeMonitor(m); keyMonitorGlobal = nil }
        if let m = keyMonitorLocal { NSEvent.removeMonitor(m); keyMonitorLocal = nil }

        lastFocused = nil
        ignoreFocusCounter = 0
        isTiling = false
        onStateChange?()
    }

    private func subscribeDestroy(_ window: AXUIElement) {
        guard let observer = observer else { return }
        if subscribedWindows.contains(where: { CFEqual($0, window) }) { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, context)
        subscribedWindows.append(window)
    }

    // MARK: - Layout

    private func layoutGrid() {
        let groups = Dictionary(grouping: managed, by: { screenIndex(forAX: $0.original) })
        suspendFocus(for: 0.4)
        for (idx, group) in groups {
            let screen = axVisibleFrame(for: idx)
            let frames = computeGrid(count: group.count, in: screen)
            for (i, m) in group.enumerated() {
                m.slot = frames[i]
                animateFrame(m, to: frames[i])
            }
        }
    }

    fileprivate func handleFocusChange(_ window: AXUIElement) {
        guard isTiling, !isFocusIgnored else { return }
        guard managed.contains(where: { CFEqual($0.window, window) }) else { return }
        if let last = lastFocused, CFEqual(last, window) { return }
        lastFocused = window
        suspendFocus(for: 0.45)
        zoom(window)
    }

    fileprivate func handleWindowCreated(_ window: AXUIElement) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshWindows()
        }
    }

    fileprivate func handleWindowDestroyed(_ window: AXUIElement) {
        guard isTiling else { return }
        DispatchQueue.main.async { [weak self] in
            self?.refreshWindows()
        }
    }

    private func zoom(_ focused: AXUIElement) {
        guard let focusedManaged = managed.first(where: { CFEqual($0.window, focused) }) else { return }
        // Use the focused window's LIVE frame (not the cached slot) to find its current screen —
        // handles the case where the user manually dragged a tile to another display.
        let liveFocused = getFrame(focused)
        let idx = screenIndex(forAX: liveFocused)
        let screen = axVisibleFrame(for: idx)
        let onScreen = managed.filter { screenIndex(forAX: getFrame($0.window)) == idx }

        switch _zoomMode {
        case .sideStrip:
            let mainW = floor(screen.width * 0.78)
            animateFrame(focusedManaged, to: CGRect(x: screen.minX, y: screen.minY, width: mainW, height: screen.height))
            let others = onScreen.filter { !CFEqual($0.window, focused) }
            guard !others.isEmpty else { return }
            let stripX = screen.minX + mainW
            let stripW = screen.width - mainW
            let h = screen.height / CGFloat(others.count)
            for (i, m) in others.enumerated() {
                animateFrame(m, to: CGRect(x: stripX, y: screen.minY + CGFloat(i) * h, width: stripW, height: h))
            }
        case .fullScreen:
            animateFrame(focusedManaged, to: screen)
        }
    }

    // MARK: - Alerts

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility access required"
        alert.informativeText = "Terminal Tiler needs Accessibility permission to read and move Terminal windows. Grant access in System Settings → Privacy & Security → Accessibility, then click Tile again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }

    // MARK: - AX helpers

    private func isManageable(_ win: AXUIElement) -> Bool {
        var subRef: AnyObject?
        let r1 = AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subRef)
        guard r1 == .success, let subrole = subRef as? String, subrole == (kAXStandardWindowSubrole as String) else {
            return false
        }
        var minRef: AnyObject?
        AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef)
        let minimized = (minRef as? Bool) ?? false
        return !minimized
    }

    private func getFrame(_ win: AXUIElement) -> CGRect {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        let r1 = AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        let r2 = AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)

        var pos = CGPoint.zero
        var size = CGSize.zero
        if r1 == .success, let p = posRef, CFGetTypeID(p) == AXValueGetTypeID() {
            AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        }
        if r2 == .success, let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() {
            AXValueGetValue(s as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    private func setFrame(_ win: AXUIElement, to frame: CGRect) {
        let cur = getFrame(win)
        let growing = frame.width > cur.width || frame.height > cur.height
        var pos = frame.origin
        var size = frame.size

        // Set the dimension that grows first; otherwise Terminal can clamp the second write.
        if growing {
            if let v = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
            }
            if let v = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
            }
        } else {
            if let v = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
            }
            if let v = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
            }
        }
    }

    private func animateFrame(_ m: Managed, to target: CGRect, duration: TimeInterval = 0.18) {
        m.animationGeneration += 1
        let myGen = m.animationGeneration
        let start = getFrame(m.window)
        let steps = 10
        let dt = duration / Double(steps)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + dt * Double(i)) { [weak m, weak self] in
                guard let self = self, let m = m, m.animationGeneration == myGen else { return }
                let f = CGRect(
                    x: start.minX + (target.minX - start.minX) * eased,
                    y: start.minY + (target.minY - start.minY) * eased,
                    width: start.width + (target.width - start.width) * eased,
                    height: start.height + (target.height - start.height) * eased
                )
                self.setFrame(m.window, to: f)
            }
        }
    }

    private func computeGrid(count: Int, in screen: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellW = screen.width / CGFloat(cols)
        let cellH = screen.height / CGFloat(rows)
        var frames: [CGRect] = []
        for i in 0..<count {
            let r = i / cols
            let c = i % cols
            frames.append(CGRect(
                x: screen.minX + CGFloat(c) * cellW,
                y: screen.minY + CGFloat(r) * cellH,
                width: cellW,
                height: cellH
            ))
        }
        return frames
    }

    // MARK: - Coordinates
    //
    // AX uses origin at the TOP-LEFT of the primary display, y growing downward, in a
    // coordinate space that spans every connected display. NSScreen uses a BOTTOM-LEFT
    // origin (also primary-anchored) with y growing upward. The conversion is:
    //
    //     ax_y = primary.frame.height - ns_maxY
    //     ax_x = ns_x  (no change)
    //
    // This is correct for displays in any arrangement — above, below, left, or right of
    // primary — because it converts each screen's NS-coords frame into the same AX space.

    private func axFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        let primaryHeight = primary.frame.height
        let ns = screen.frame
        return CGRect(x: ns.minX, y: primaryHeight - ns.maxY, width: ns.width, height: ns.height)
    }

    private func axVisibleFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.visibleFrame }
        let primaryHeight = primary.frame.height
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
    }

    private func screenIndex(forAX axRect: CGRect) -> Int {
        guard !NSScreen.screens.isEmpty else { return 0 }
        let center = CGPoint(x: axRect.midX, y: axRect.midY)
        for (i, screen) in NSScreen.screens.enumerated() {
            if axFrame(of: screen).contains(center) { return i }
        }
        return 0
    }

    private func axVisibleFrame(for screenIndex: Int) -> CGRect {
        guard screenIndex < NSScreen.screens.count else { return .zero }
        return axVisibleFrame(of: NSScreen.screens[screenIndex])
    }
}

private func axCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    let note = notification as String

    DispatchQueue.main.async {
        switch note {
        case kAXFocusedWindowChangedNotification:
            manager.handleFocusChange(element)
        case kAXWindowCreatedNotification:
            manager.handleWindowCreated(element)
        case kAXUIElementDestroyedNotification:
            manager.handleWindowDestroyed(element)
        default:
            break
        }
    }
}

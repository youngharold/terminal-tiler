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
        get { ZoomMode(rawValue: UserDefaults.standard.string(forKey: "zoomMode") ?? "") ?? .sideStrip }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "zoomMode")
            onStateChange?()
            if isTiling { layoutGrid() }
        }
    }

    private final class Managed {
        let window: AXUIElement
        let original: CGRect
        var slot: CGRect = .zero
        init(window: AXUIElement, original: CGRect) {
            self.window = window
            self.original = original
        }
    }

    private var pid: pid_t = 0
    private var terminalApp: AXUIElement?
    private var managed: [Managed] = []
    private var observer: AXObserver?
    private var keyMonitorGlobal: Any?
    private var keyMonitorLocal: Any?
    private var ignoreFocus = false
    private var lastFocused: AXUIElement?

    // MARK: - Public API

    func toggle() {
        if isTiling { stop() } else { start() }
    }

    func retile() {
        guard isTiling else { return }
        layoutGrid()
        lastFocused = nil
    }

    /// Re-scan Terminal windows; add new ones, drop closed ones, then re-tile.
    func refreshWindows() {
        guard isTiling, let axApp = terminalApp else { return }
        var winsRef: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)
        guard let wins = winsRef as? [AXUIElement] else { return }

        let valid = wins.filter { isManageable($0) }
        // Remove closed
        managed.removeAll { m in !valid.contains(where: { CFEqual($0, m.window) }) }
        // Add new
        for w in valid where !managed.contains(where: { CFEqual($0.window, w) }) {
            let mw = Managed(window: w, original: getFrame(w))
            managed.append(mw)
            subscribeDestroy(w)
        }
        if managed.isEmpty { stop(); return }
        layoutGrid()
    }

    // MARK: - Lifecycle

    private func start() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            NSSound.beep()
            return
        }
        pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        terminalApp = axApp

        var winsRef: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)
        guard let wins = winsRef as? [AXUIElement] else { NSSound.beep(); return }
        let valid = wins.filter { isManageable($0) }
        guard !valid.isEmpty else { NSSound.beep(); return }

        managed = valid.map { Managed(window: $0, original: getFrame($0)) }

        var obs: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &obs)
        guard result == .success, let observer = obs else {
            NSLog("AXObserverCreate failed: \(result.rawValue)")
            isTiling = true
            layoutGrid()
            onStateChange?()
            return
        }
        self.observer = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, context)
        AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, context)
        for m in managed { subscribeDestroy(m.window) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)

        // Esc returns to grid; Cmd+Opt+T toggle is registered globally in AppDelegate.
        // Local Esc handler so our own menu/window doesn't swallow it.
        keyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.retile() }
        }
        keyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.retile() }
            return event
        }

        isTiling = true
        layoutGrid()
        onStateChange?()
    }

    private func stop() {
        for m in managed { setFrame(m.window, to: m.original) }
        managed = []

        if let observer = observer, let app = terminalApp {
            AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, app, kAXWindowCreatedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        terminalApp = nil

        if let m = keyMonitorGlobal { NSEvent.removeMonitor(m); keyMonitorGlobal = nil }
        if let m = keyMonitorLocal { NSEvent.removeMonitor(m); keyMonitorLocal = nil }

        lastFocused = nil
        isTiling = false
        onStateChange?()
    }

    private func subscribeDestroy(_ window: AXUIElement) {
        guard let observer = observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, context)
    }

    // MARK: - Layout

    private func layoutGrid() {
        let groups = Dictionary(grouping: managed, by: { screenIndex(for: $0.original) })
        ignoreFocus = true
        for (idx, group) in groups {
            let screen = axVisibleFrame(for: idx)
            let frames = computeGrid(count: group.count, in: screen)
            for (i, m) in group.enumerated() {
                m.slot = frames[i]
                animateFrame(m.window, to: frames[i])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.ignoreFocus = false }
    }

    fileprivate func handleFocusChange(_ window: AXUIElement) {
        guard isTiling, !ignoreFocus else { return }
        guard managed.contains(where: { CFEqual($0.window, window) }) else { return }
        if let last = lastFocused, CFEqual(last, window) { return }
        lastFocused = window

        ignoreFocus = true
        zoom(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.ignoreFocus = false }
    }

    fileprivate func handleWindowCreated(_ window: AXUIElement) {
        // Brief delay so the new window has a real subrole/size by the time we check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshWindows()
        }
    }

    fileprivate func handleWindowDestroyed(_ window: AXUIElement) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshWindows()
        }
    }

    private func zoom(_ focused: AXUIElement) {
        let idx = screenIndex(for: getFrame(focused))
        let screen = axVisibleFrame(for: idx)
        let onScreen = managed.filter { screenIndex(for: $0.slot) == idx }

        switch zoomMode {
        case .sideStrip:
            let mainW = floor(screen.width * 0.78)
            animateFrame(focused, to: CGRect(x: screen.minX, y: screen.minY, width: mainW, height: screen.height))
            let others = onScreen.filter { !CFEqual($0.window, focused) }
            guard !others.isEmpty else { return }
            let stripX = screen.minX + mainW
            let stripW = screen.width - mainW
            let h = screen.height / CGFloat(others.count)
            for (i, m) in others.enumerated() {
                animateFrame(m.window, to: CGRect(x: stripX, y: screen.minY + CGFloat(i) * h, width: stripW, height: h))
            }
        case .fullScreen:
            animateFrame(focused, to: screen)
            // Other windows stay in their grid slots, just behind the focused one.
        }
    }

    // MARK: - AX helpers

    private func isManageable(_ win: AXUIElement) -> Bool {
        var subRef: AnyObject?
        AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subRef)
        let subrole = subRef as? String ?? ""
        guard subrole == (kAXStandardWindowSubrole as String) else { return false }

        var minRef: AnyObject?
        AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef)
        let minimized = (minRef as? Bool) ?? false
        return !minimized
    }

    private func getFrame(_ win: AXUIElement) -> CGRect {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGRect(origin: pos, size: size)
    }

    private func setFrame(_ win: AXUIElement, to frame: CGRect) {
        var pos = frame.origin
        var size = frame.size
        if let v = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
        }
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
        }
    }

    private func animateFrame(_ win: AXUIElement, to target: CGRect, duration: TimeInterval = 0.18) {
        let start = getFrame(win)
        let steps = 10
        let dt = duration / Double(steps)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + dt * Double(i)) { [weak self] in
                let f = CGRect(
                    x: start.minX + (target.minX - start.minX) * eased,
                    y: start.minY + (target.minY - start.minY) * eased,
                    width: start.width + (target.width - start.width) * eased,
                    height: start.height + (target.height - start.height) * eased
                )
                self?.setFrame(win, to: f)
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

    // MARK: - Screen / coordinates

    /// Returns the index in `NSScreen.screens` for the screen that contains the given AX-coords frame.
    private func screenIndex(for axFrame: CGRect) -> Int {
        guard !NSScreen.screens.isEmpty else { return 0 }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: axFrame.midX, y: primaryHeight - axFrame.midY)
        for (i, screen) in NSScreen.screens.enumerated() where screen.frame.contains(center) {
            return i
        }
        return 0
    }

    /// AX-coords visible frame (excludes menu bar / dock) for a given screen index.
    private func axVisibleFrame(for screenIndex: Int) -> CGRect {
        guard screenIndex < NSScreen.screens.count else { return .zero }
        let screen = NSScreen.screens[screenIndex]
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: visible.minX,
            y: primaryHeight - visible.maxY,
            width: visible.width,
            height: visible.height
        )
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

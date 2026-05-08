import AppKit
import ApplicationServices

public enum ZoomMode: String {
    case sideStrip
    case fullScreen
}

public final class WindowManager {
    public private(set) var isTiling = false
    public var onStateChange: (() -> Void)?

    public var windowCount: Int { managed.count }

    public init() {}

    public var zoomMode: ZoomMode {
        get { _zoomMode }
        set {
            _zoomMode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.zoomModeKey)
            onStateChange?()
            guard isTiling else { return }
            if let last = lastFocused {
                zoom(last)
            } else {
                layoutGrid()
            }
        }
    }
    private static let zoomModeKey = "TerminalTiler.zoomMode"
    private var _zoomMode: ZoomMode = ZoomMode(rawValue: UserDefaults.standard.string(forKey: WindowManager.zoomModeKey) ?? "") ?? .sideStrip

    private final class Managed {
        let window: AXUIElement
        var original: CGRect
        var slot: CGRect = .zero
        var screenIdx: Int = 0
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
    private var refreshScheduled = false
    private var ignoreFocusCounter: Int = 0
    private var lastFocused: AXUIElement?
    /// Bumped on every start()/stop() so deferred suspendFocus decrements from a previous
    /// session can't leak across into the next one (would otherwise race with new ops).
    private var sessionEpoch: Int = 0

    private var isFocusIgnored: Bool { ignoreFocusCounter > 0 }

    private func suspendFocus(for duration: TimeInterval) {
        let myEpoch = sessionEpoch
        ignoreFocusCounter += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.sessionEpoch == myEpoch else { return }
            self.ignoreFocusCounter = max(0, self.ignoreFocusCounter - 1)
        }
    }

    // MARK: - Public API

    public func toggle() {
        if isTiling { stopAndRestore() } else { start() }
    }

    public func stopAndRestore() { stop(restore: true) }
    public func stopAndLeaveInPlace() { stop(restore: false) }

    public func retile() {
        guard isTiling else { return }
        layoutGrid()
        lastFocused = nil
    }

    /// Drop the most-recently-focused window from tiling and snap it back to its `original`
    /// frame. The window stays open and can be re-tiled by stopping and re-starting tiling.
    /// If fewer than 2 windows would remain, tiling stops with a restore.
    public func excludeFocused() {
        guard isTiling else { return }
        guard let last = lastFocused else {
            showAlert(
                title: "Click a tile first",
                body: "Click the tile you want to exclude (so it zooms), then choose Exclude Focused Window from the menu."
            )
            return
        }
        guard let m = managed.first(where: { CFEqual($0.window, last) }) else { return }
        // Bumped to 0.5s: covers Terminal's post-restore settle window which can re-raise
        // sibling tabs on cross-display moves.
        suspendFocus(for: 0.5)
        // Remove from `managed` BEFORE the AX write so an in-flight focus event can't find
        // the window in our list while we're mid-restore.
        managed.removeAll { CFEqual($0.window, last) }
        if let observer = observer, let dead = subscribedWindows.first(where: { CFEqual($0, last) }) {
            AXObserverRemoveNotification(observer, dead, kAXUIElementDestroyedNotification as CFString)
            subscribedWindows.removeAll { CFEqual($0, dead) }
        }
        setFrame(last, to: m.original)
        lastFocused = nil
        if managed.count < 2 { stop(restore: true); return }
        layoutGrid()
        onStateChange?()
    }

    public func refreshWindows() {
        guard isTiling, let axApp = terminalApp else { return }
        var winsRef: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)
        guard let wins = winsRef as? [AXUIElement] else { return }

        let valid = wins.filter { isManageable($0) }
        managed.removeAll { m in !valid.contains(where: { CFEqual($0, m.window) }) }
        // Prune destroy-notification subscriptions for windows that no longer exist; left
        // unpruned, the list grows unboundedly across long sessions with churn.
        let dead = subscribedWindows.filter { sub in !valid.contains(where: { CFEqual($0, sub) }) }
        if let observer = observer {
            for w in dead {
                AXObserverRemoveNotification(observer, w, kAXUIElementDestroyedNotification as CFString)
            }
        }
        subscribedWindows.removeAll { sub in dead.contains(where: { CFEqual($0, sub) }) }
        for w in valid where !managed.contains(where: { CFEqual($0.window, w) }) {
            // Capture original BEFORE laying out so Stop & Restore is sane.
            let mw = Managed(window: w, original: getFrame(w))
            managed.append(mw)
            subscribeDestroy(w)
        }
        // Same minimum as start(): tiling a single window is meaningless. Restore so the
        // surviving window leaves the now-pointless tiled layout cleanly.
        if managed.count < 2 { stop(restore: true); return }
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

        // Refuse layouts that would produce unreadably small Terminal cells.
        if let primary = NSScreen.main {
            let visible = Layout.axVisibleFrame(of: primary)
            if Layout.gridWouldBeUnreadable(count: valid.count, in: visible) {
                showAlert(
                    title: "Too many Terminal windows",
                    body: "\(valid.count) windows on this display would produce cells smaller than \(Int(Layout.minReadableCellSize.width))×\(Int(Layout.minReadableCellSize.height)) pt. Close some windows or move them to another display."
                )
                terminalApp = nil
                pid = 0
                return
            }
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

        sessionEpoch &+= 1
        isTiling = true
        layoutGrid()
        onStateChange?()
    }

    private func stop(restore: Bool) {
        sessionEpoch &+= 1
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
        refreshScheduled = false

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
        // Bail if the screen graph is transiently empty (e.g., display sleep / lock).
        guard !NSScreen.screens.isEmpty else { return }
        let groups = Dictionary(grouping: managed, by: { Layout.screenIndex(forAX: $0.original) })
        suspendFocus(for: 0.4)
        for (idx, group) in groups {
            let screen = Layout.axVisibleFrame(forIndex: idx)
            let frames = Layout.grid(count: group.count, in: screen)
            for (i, m) in group.enumerated() {
                m.slot = frames[i]
                m.screenIdx = idx
                animateFrame(m, to: frames[i])
            }
        }
    }

    fileprivate func handleFocusChange(_ window: AXUIElement) {
        guard isTiling else { return }
        guard managed.contains(where: { CFEqual($0.window, window) }) else { return }
        // Always remember the user's most recent intent — even if we're suspending right
        // now. This way post-suspend operations (zoomMode toggle, retile + re-zoom) target
        // the user's actual focus, not the one we last animated.
        let isNew = !(lastFocused.map { CFEqual($0, window) } ?? false)
        lastFocused = window
        guard !isFocusIgnored, isNew else { return }
        suspendFocus(for: 0.45)
        zoom(window)
    }

    fileprivate func handleWindowCreated(_ window: AXUIElement) {
        scheduleRefresh()
    }

    fileprivate func handleWindowDestroyed(_ window: AXUIElement) {
        scheduleRefresh()
    }

    /// Coalesce rapid window create/destroy bursts into one refresh. The 0.15s wait also
    /// lets a brand-new Terminal window settle into its default frame before we capture it
    /// as `original`. Epoch-gated so a pending refresh from a previous session can't run
    /// inside a new one if the user toggles stop/start within the window.
    private func scheduleRefresh() {
        guard isTiling, !refreshScheduled else { return }
        refreshScheduled = true
        let myEpoch = sessionEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.sessionEpoch == myEpoch else { return }
            self.refreshScheduled = false
            self.refreshWindows()
        }
    }

    private func zoom(_ focused: AXUIElement) {
        guard let focusedManaged = managed.first(where: { CFEqual($0.window, focused) }) else { return }
        // Suspend focus events around our own setFrame writes — Terminal can sometimes raise
        // a sibling tab during a resize, which would re-enter handleFocusChange.
        suspendFocus(for: 0.4)
        // Probe the focused window's live frame ONCE (handles a manual drag to another display);
        // every other window uses its cached screenIdx from layoutGrid to avoid N AX reads.
        let liveFocused = getFrame(focused)
        let idx = Layout.screenIndex(forAX: liveFocused)
        focusedManaged.screenIdx = idx
        let screen = Layout.axVisibleFrame(forIndex: idx)
        let onScreen = managed.filter { $0.screenIdx == idx }

        switch _zoomMode {
        case .sideStrip:
            let others = onScreen.filter { !CFEqual($0.window, focused) }
            // Fall back to fullScreen when strip cells would be unreadably thin
            // (e.g. focusing one of 20 windows on a single display).
            let stripRowMin: CGFloat = 90
            if !others.isEmpty, screen.height / CGFloat(others.count) < stripRowMin {
                animateFrame(focusedManaged, to: screen)
                return
            }
            let mainW = floor(screen.width * 0.78)
            animateFrame(focusedManaged, to: CGRect(x: screen.minX, y: screen.minY, width: mainW, height: screen.height))
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
            let v = p as! AXValue
            if AXValueGetType(v) == .cgPoint { AXValueGetValue(v, .cgPoint, &pos) }
        }
        if r2 == .success, let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() {
            let v = s as! AXValue
            if AXValueGetType(v) == .cgSize { AXValueGetValue(v, .cgSize, &size) }
        }
        return CGRect(origin: pos, size: size)
    }

    private func setFrame(_ win: AXUIElement, to frame: CGRect, settle: Bool = true) {
        var pos = frame.origin
        var size = frame.size
        let posVal = AXValueCreate(.cgPoint, &pos)
        let sizeVal = AXValueCreate(.cgSize, &size)
        // Intermediate animation steps: pos + size (2 writes). Final/settle step: pos → size →
        // pos (3 writes) so cross-display moves and Terminal min-size clamps land cleanly.
        if let posVal = posVal {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = sizeVal {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        }
        if settle, let posVal = posVal {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        }
    }

    private func animateFrame(_ m: Managed, to target: CGRect, duration: TimeInterval = 0.18) {
        m.animationGeneration += 1
        let myGen = m.animationGeneration
        let start = getFrame(m.window)
        // If start ≈ target, skip animation entirely (saves ~30 AX writes per no-op step).
        let dx = abs(target.minX - start.minX), dy = abs(target.minY - start.minY)
        let dw = abs(target.width - start.width), dh = abs(target.height - start.height)
        if dx + dy + dw + dh < 2 {
            setFrame(m.window, to: target, settle: true)
            return
        }
        let steps = 10
        let dt = duration / Double(steps)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)
            let isFinal = (i == steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + dt * Double(i)) { [weak m, weak self] in
                guard let self = self, let m = m, m.animationGeneration == myGen else { return }
                let f = CGRect(
                    x: start.minX + (target.minX - start.minX) * eased,
                    y: start.minY + (target.minY - start.minY) * eased,
                    width: start.width + (target.width - start.width) * eased,
                    height: start.height + (target.height - start.height) * eased
                )
                self.setFrame(m.window, to: f, settle: isFinal)
            }
        }
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

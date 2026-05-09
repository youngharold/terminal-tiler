import AppKit
import ApplicationServices

public enum ZoomMode: String, CaseIterable {
    /// Focused fills 78% width; others stack on right strip.
    case sideStrip
    /// Focused fills the screen entirely.
    case fullScreen
    /// Focused expands to its column's full screen height (1/N width × full height).
    case fullColumn
    /// Click does nothing — windows stay in the static grid.
    case disabled

    public var displayName: String {
        switch self {
        case .sideStrip:  return "Side Strip (focused + thumbnails)"
        case .fullScreen: return "Full Screen (focused fills)"
        case .fullColumn: return "Full Column (focused expands vertically)"
        case .disabled:   return "Disabled (no zoom on click)"
        }
    }
}

public final class WindowManager {
    public private(set) var isTiling = false
    public var onStateChange: (() -> Void)?

    public var windowCount: Int { managed.count }

    public init() {
        // One-time migration of the pre-namespaced UserDefaults key (v0.2.6 and earlier
        // wrote to plain "zoomMode"). Move it into the namespaced key on first launch
        // after upgrade so users don't silently lose their preference.
        let defaults = UserDefaults.standard
        let legacyKey = "zoomMode"
        if let legacy = defaults.string(forKey: legacyKey),
           defaults.string(forKey: Self.zoomModeKey) == nil {
            defaults.set(legacy, forKey: Self.zoomModeKey)
            defaults.removeObject(forKey: legacyKey)
        }
        _zoomMode = ZoomMode(rawValue: defaults.string(forKey: Self.zoomModeKey) ?? "") ?? .sideStrip
    }

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
    private static let zoomModeKey = "TermUsher.zoomMode"
    private static let idleReturnKey = "TermUsher.autoReturnIdleEnabled"
    private static let idleReturnSecondsKey = "TermUsher.autoReturnIdleSeconds"
    private static let hoverReturnKey = "TermUsher.autoReturnHoverEnabled"
    private static let sendReturnKey = "TermUsher.autoReturnAfterSendEnabled"
    private static let sendReturnSecondsKey = "TermUsher.autoReturnAfterSendSeconds"

    private var _zoomMode: ZoomMode = .sideStrip

    // MARK: - Auto-return settings (persisted)

    public var autoReturnIdleEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.idleReturnKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.idleReturnKey); onStateChange?() }
    }
    /// Default 5 minutes if unset.
    public var autoReturnIdleSeconds: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: Self.idleReturnSecondsKey)
            return v > 0 ? v : 300
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.idleReturnSecondsKey) }
    }
    public var autoReturnHoverEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hoverReturnKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hoverReturnKey); onStateChange?() }
    }
    public var autoReturnAfterSendEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.sendReturnKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.sendReturnKey); onStateChange?() }
    }
    public var autoReturnAfterSendSeconds: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: Self.sendReturnSecondsKey)
            return v > 0 ? v : 3
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.sendReturnSecondsKey) }
    }

    private final class Managed {
        let window: AXUIElement
        var original: CGRect
        var slot: CGRect = .zero
        var screenIdx: Int = 0
        var animationGeneration: Int = 0
        /// Debounce timer for user-drag detection: kAXMovedNotification fires for every
        /// pixel of a drag; we only act after 0.3s of no further moves (drop).
        var dragSettleTimer: Timer?
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
    /// Wall-clock timestamp of the most recent zoom; used to know whether auto-return
    /// triggers (idle/hover/send) should fire at all.
    private var zoomedAt: Date?
    /// Polls user idle every 30s; if zoomed and idle > threshold, returns to grid.
    private var idleTimer: Timer?
    /// Tracks how long the mouse has been at the top edge while zoomed.
    private var hoverEdgeEnteredAt: Date?
    /// Watches for the user pressing Return inside Terminal; on idle-after-Enter, returns.
    private var sendReturnTimer: Timer?
    /// Local + global mouse moved monitor (for hover detection).
    private var mouseMonitorGlobal: Any?
    private var mouseMonitorLocal: Any?
    /// Local + global key monitor for the auto-return-after-send trigger.
    private var sendKeyMonitorGlobal: Any?
    private var sendKeyMonitorLocal: Any?
    private var ignoreFocusCounter: Int = 0
    private var lastFocused: AXUIElement?
    /// Bumped on every start()/stop() so deferred suspendFocus decrements from a previous
    /// session can't leak across into the next one (would otherwise race with new ops).
    private var sessionEpoch: Int = 0

    private var isFocusIgnored: Bool { ignoreFocusCounter > 0 }

    /// Mark that we're now in a zoomed state, and reset any drift the auto-return triggers
    /// were tracking (so a fresh 5-min countdown begins).
    private func markZoomed() {
        zoomedAt = Date()
        hoverEdgeEnteredAt = nil
        sendReturnTimer?.invalidate(); sendReturnTimer = nil
    }

    /// True if we just zoomed a window and triggers should consider auto-returning.
    private var isZoomed: Bool {
        return zoomedAt != nil && lastFocused != nil
    }

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
        zoomedAt = nil
        hoverEdgeEnteredAt = nil
        sendReturnTimer?.invalidate(); sendReturnTimer = nil
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
                AXObserverRemoveNotification(observer, w, kAXMovedNotification as CFString)
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
                body: "AXObserverCreate failed (\(result.rawValue)). Try restarting Terminal.app and TermUsher."
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
        installAutoReturnMonitors()
        onStateChange?()
    }

    private func installAutoReturnMonitors() {
        // Idle poll runs every 30s; cheap; kicks retile when threshold crossed.
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkIdleAutoReturn()
        }

        // Mouse monitor for top-edge hover. Both global and local so it fires regardless
        // of which app is frontmost.
        let mouseHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleMouseMoved(event)
        }
        mouseMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { event in
            mouseHandler(event)
        }
        mouseMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            mouseHandler(event)
            return event
        }

        // Key monitor for "user pressed Return → start send-idle countdown".
        let keyHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleSendKey(event)
        }
        sendKeyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            keyHandler(event)
        }
        sendKeyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyHandler(event)
            return event
        }
    }

    private func removeAutoReturnMonitors() {
        idleTimer?.invalidate(); idleTimer = nil
        sendReturnTimer?.invalidate(); sendReturnTimer = nil
        if let m = mouseMonitorGlobal { NSEvent.removeMonitor(m); mouseMonitorGlobal = nil }
        if let m = mouseMonitorLocal { NSEvent.removeMonitor(m); mouseMonitorLocal = nil }
        if let m = sendKeyMonitorGlobal { NSEvent.removeMonitor(m); sendKeyMonitorGlobal = nil }
        if let m = sendKeyMonitorLocal { NSEvent.removeMonitor(m); sendKeyMonitorLocal = nil }
        hoverEdgeEnteredAt = nil
    }

    private func checkIdleAutoReturn() {
        guard isTiling, isZoomed, autoReturnIdleEnabled else { return }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0) ?? .null
        )
        if idle >= autoReturnIdleSeconds {
            retile()
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard isTiling, isZoomed, autoReturnHoverEnabled else { hoverEdgeEnteredAt = nil; return }
        // NSEvent.mouseLocation is screen coords with origin at the bottom-left of the
        // primary display. We want "is the mouse at the very top of any screen?"
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return }
        let isAtTop = p.y >= screen.frame.maxY - 2
        if isAtTop {
            if let entered = hoverEdgeEnteredAt {
                if Date().timeIntervalSince(entered) >= 0.3 {
                    hoverEdgeEnteredAt = nil
                    retile()
                }
            } else {
                hoverEdgeEnteredAt = Date()
            }
        } else {
            hoverEdgeEnteredAt = nil
        }
    }

    private func handleSendKey(_ event: NSEvent) {
        guard isTiling, isZoomed, autoReturnAfterSendEnabled else { return }
        // We only count Return/Enter (keyCode 36) and the keypad Enter (76). After Return,
        // start an idle timer; if any further keystroke fires, push the countdown out so a
        // continuous typist doesn't get yanked back to grid mid-sentence.
        if event.keyCode == 36 || event.keyCode == 76 {
            sendReturnTimer?.invalidate()
            sendReturnTimer = Timer.scheduledTimer(withTimeInterval: autoReturnAfterSendSeconds, repeats: false) { [weak self] _ in
                guard let self = self, self.isTiling, self.isZoomed else { return }
                self.retile()
            }
        } else if sendReturnTimer != nil {
            // User started typing again — reset the countdown.
            sendReturnTimer?.invalidate()
            sendReturnTimer = Timer.scheduledTimer(withTimeInterval: autoReturnAfterSendSeconds, repeats: false) { [weak self] _ in
                guard let self = self, self.isTiling, self.isZoomed else { return }
                self.retile()
            }
        }
    }

    private func stop(restore: Bool) {
        sessionEpoch &+= 1
        removeAutoReturnMonitors()
        if restore {
            for m in managed { setFrame(m.window, to: m.original) }
        }
        managed = []

        // Cancel any in-flight drag-settle timers before tearing down.
        for m in managed { m.dragSettleTimer?.invalidate(); m.dragSettleTimer = nil }
        if let observer = observer, let app = terminalApp {
            AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, app, kAXWindowCreatedNotification as CFString)
            for w in subscribedWindows {
                AXObserverRemoveNotification(observer, w, kAXUIElementDestroyedNotification as CFString)
                AXObserverRemoveNotification(observer, w, kAXMovedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        terminalApp = nil
        subscribedWindows = []
        pid = 0
        refreshScheduled = false

        lastFocused = nil
        zoomedAt = nil
        ignoreFocusCounter = 0
        isTiling = false
        onStateChange?()
    }

    private func subscribeDestroy(_ window: AXUIElement) {
        guard let observer = observer else { return }
        if subscribedWindows.contains(where: { CFEqual($0, window) }) { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, context)
        // Drag-to-reorder: AX kAXMovedNotification fires on every frame change. We rely on
        // the per-Managed dragSettleTimer + isFocusIgnored gate to ignore our own writes.
        AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, context)
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
        // .disabled mode: the grid is static. Skip zoom entirely (and skip suspendFocus,
        // since we won't be writing frames).
        guard _zoomMode != .disabled else { return }
        guard !isFocusIgnored, isNew else { return }
        suspendFocus(for: 0.45)
        zoom(window)
        markZoomed()
    }

    fileprivate func handleWindowCreated(_ window: AXUIElement) {
        scheduleRefresh()
    }

    fileprivate func handleWindowDestroyed(_ window: AXUIElement) {
        scheduleRefresh()
    }

    /// AX move notification fires on every pixel of a drag AND on every step of our own
    /// animations. `isFocusIgnored` is true while we're mid-write, so we ignore those.
    /// Otherwise the move was user-initiated; debounce 0.3s for the drop, then swap with
    /// whichever grid slot the dropped center is closest to.
    fileprivate func handleWindowMoved(_ window: AXUIElement) {
        guard isTiling, !isFocusIgnored else { return }
        guard let m = managed.first(where: { CFEqual($0.window, window) }) else { return }
        m.dragSettleTimer?.invalidate()
        m.dragSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self, weak m] _ in
            guard let self = self, let m = m, self.isTiling else { return }
            m.dragSettleTimer = nil
            self.handleUserDragSettled(m)
        }
    }

    private func handleUserDragSettled(_ dragged: Managed) {
        let live = getFrame(dragged.window)
        let liveCenter = CGPoint(x: live.midX, y: live.midY)
        var bestIdx = -1
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (idx, candidate) in managed.enumerated() {
            let c = CGPoint(x: candidate.slot.midX, y: candidate.slot.midY)
            let dx = c.x - liveCenter.x, dy = c.y - liveCenter.y
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; bestIdx = idx }
        }
        guard bestIdx >= 0,
              let myIdx = managed.firstIndex(where: { CFEqual($0.window, dragged.window) }) else { return }
        if bestIdx != myIdx {
            managed.swapAt(myIdx, bestIdx)
        }
        // Re-tile to land everyone in their new slot. layoutGrid suspends focus so the
        // resulting writes don't fire move-notifications back at us.
        layoutGrid()
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
        case .disabled:
            return
        case .fullColumn:
            // Expand the focused window to its column width × full screen height.
            // Other windows stay where they are; the focused one covers its column-mates
            // visually but they remain at their grid positions.
            let slot = focusedManaged.slot
            animateFrame(focusedManaged, to: CGRect(x: slot.minX, y: screen.minY, width: slot.width, height: screen.height))
            return
        case .sideStrip:
            let others = onScreen.filter { !CFEqual($0.window, focused) }
            // Fall back to fullScreen when strip cells would be unreadably thin
            // (e.g. focusing one of 20 windows on a single display).
            if Layout.sideStripWouldBeTooThin(otherCount: others.count, in: screen) {
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
        alert.informativeText = "TermUsher needs Accessibility permission to read and move Terminal windows. Grant access in System Settings → Privacy & Security → Accessibility, then click Tile again."
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
        case kAXMovedNotification:
            manager.handleWindowMoved(element)
        default:
            break
        }
    }
}

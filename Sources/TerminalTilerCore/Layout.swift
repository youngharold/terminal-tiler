import AppKit

/// Pure layout math — testable without any AX or live-window state.
enum Layout {
    /// Minimum readable Terminal cell size; layouts with cells below this should warn.
    static let minReadableCellSize = CGSize(width: 320, height: 200)

    /// Side-strip rows below this height are unreadable thumbnails — zoom should fall back
    /// to fullScreen mode rather than producing a 50-pt strip cell.
    static let minSideStripRowHeight: CGFloat = 90

    /// True if a side-strip layout with `otherCount` rows would produce rows shorter than
    /// `minSideStripRowHeight`. Caller falls back to fullScreen zoom when this returns true.
    static func sideStripWouldBeTooThin(otherCount: Int, in screen: CGRect) -> Bool {
        guard otherCount > 0 else { return false }
        return screen.height / CGFloat(otherCount) < minSideStripRowHeight
    }

    /// True if a grid of `count` cells over `screen` would produce cells smaller than the
    /// readable threshold — an unusable layout. `screen` is expected to be the AX *visible*
    /// frame (menu bar / Dock excluded), not the full display rect.
    static func gridWouldBeUnreadable(count: Int, in screen: CGRect) -> Bool {
        guard count > 0 else { return false }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellW = screen.width / CGFloat(cols)
        let cellH = screen.height / CGFloat(rows)
        return cellW < minReadableCellSize.width || cellH < minReadableCellSize.height
    }

    /// Tile `count` rectangles into a square-ish grid that covers `screen`.
    /// Result order: row-major, top-left first.
    static func grid(count: Int, in screen: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellW = screen.width / CGFloat(cols)
        let cellH = screen.height / CGFloat(rows)
        var frames: [CGRect] = []
        frames.reserveCapacity(count)
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

    /// Convert an NS-coords rect (origin bottom-left of primary) to AX-coords
    /// (origin top-left of primary). Works for displays in any arrangement.
    static func axFromNS(_ nsFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        return CGRect(
            x: nsFrame.minX,
            y: primaryHeight - nsFrame.maxY,
            width: nsFrame.width,
            height: nsFrame.height
        )
    }

    /// Index of the screen whose AX-coords frame contains the center of `axRect`.
    /// Falls back to nearest screen by center distance if no screen contains it
    /// (handles the case of a window centered in a multi-display gap).
    static func screenIndex(forAX axRect: CGRect, nsScreens: [CGRect]) -> Int {
        guard !nsScreens.isEmpty else { return 0 }
        let primaryHeight = nsScreens[0].height
        let center = CGPoint(x: axRect.midX, y: axRect.midY)
        for (i, ns) in nsScreens.enumerated() {
            let ax = axFromNS(ns, primaryHeight: primaryHeight)
            if ax.contains(center) { return i }
        }
        // Fallback: nearest screen center.
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, ns) in nsScreens.enumerated() {
            let ax = axFromNS(ns, primaryHeight: primaryHeight)
            let dx = ax.midX - center.x
            let dy = ax.midY - center.y
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    // MARK: - NSScreen-based wrappers

    static func axFrame(of screen: NSScreen) -> CGRect {
        let primary = NSScreen.screens.first?.frame ?? screen.frame
        return axFromNS(screen.frame, primaryHeight: primary.height)
    }

    static func axVisibleFrame(of screen: NSScreen) -> CGRect {
        let primary = NSScreen.screens.first?.frame ?? screen.frame
        return axFromNS(screen.visibleFrame, primaryHeight: primary.height)
    }

    static func screenIndex(forAX axRect: CGRect) -> Int {
        return screenIndex(forAX: axRect, nsScreens: NSScreen.screens.map { $0.frame })
    }

    static func axVisibleFrame(forIndex idx: Int) -> CGRect {
        let screens = NSScreen.screens
        guard idx < screens.count else { return .zero }
        return axVisibleFrame(of: screens[idx])
    }
}

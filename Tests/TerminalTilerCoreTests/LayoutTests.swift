import XCTest
@testable import TerminalTilerCore

final class LayoutTests: XCTestCase {

    // MARK: - grid()

    func testGrid_zero() {
        XCTAssertTrue(Layout.grid(count: 0, in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }

    func testGrid_one_fillsScreen() {
        let s = CGRect(x: 10, y: 20, width: 800, height: 600)
        let frames = Layout.grid(count: 1, in: s)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], s)
    }

    func testGrid_two_squareIsh() {
        // count=2 → cols=ceil(sqrt(2))=2, rows=1. Two side-by-side cells.
        let s = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = Layout.grid(count: 2, in: s)
        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 500, height: 800),
            CGRect(x: 500, y: 0, width: 500, height: 800),
        ])
    }

    func testGrid_four_2x2() {
        let s = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = Layout.grid(count: 4, in: s)
        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 500, height: 400),
            CGRect(x: 500, y: 0, width: 500, height: 400),
            CGRect(x: 0, y: 400, width: 500, height: 400),
            CGRect(x: 500, y: 400, width: 500, height: 400),
        ])
    }

    func testGrid_five_3x2_lastCellEmpty() {
        // count=5 → cols=ceil(sqrt(5))=3, rows=ceil(5/3)=2. 6 cells, 5 used.
        let s = CGRect(x: 0, y: 0, width: 900, height: 600)
        let frames = Layout.grid(count: 5, in: s)
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames[0].size, CGSize(width: 300, height: 300))
        XCTAssertEqual(frames[4].origin, CGPoint(x: 300, y: 300))
    }

    func testGrid_nine_3x3() {
        let s = CGRect(x: 0, y: 0, width: 900, height: 900)
        let frames = Layout.grid(count: 9, in: s)
        XCTAssertEqual(frames.count, 9)
        XCTAssertEqual(frames[8], CGRect(x: 600, y: 600, width: 300, height: 300))
    }

    func testGrid_respectsScreenOrigin() {
        // Used for secondary displays whose AX origin is non-zero.
        let s = CGRect(x: 1920, y: -420, width: 1440, height: 900)
        let frames = Layout.grid(count: 4, in: s)
        XCTAssertEqual(frames[0].origin, CGPoint(x: 1920, y: -420))
        XCTAssertEqual(frames[3].origin, CGPoint(x: 1920 + 720, y: -420 + 450))
    }

    // MARK: - axFromNS()

    func testAxFromNS_primaryIdentity() {
        // Primary screen with origin (0,0) — AX-coords identical.
        let ns = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(Layout.axFromNS(ns, primaryHeight: 1080), ns)
    }

    func testAxFromNS_secondaryAbovePrimary() {
        // Secondary above primary: NSScreen y > 0. AX y must be negative.
        let primaryH: CGFloat = 1080
        let secondary = CGRect(x: 0, y: 1080, width: 1920, height: 1080)  // sits at +1080 in NS
        let ax = Layout.axFromNS(secondary, primaryHeight: primaryH)
        XCTAssertEqual(ax, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    func testAxFromNS_secondaryBelowPrimary() {
        // Secondary below primary: NS y < 0. AX y > primaryH.
        let primaryH: CGFloat = 1080
        let secondary = CGRect(x: 0, y: -900, width: 1440, height: 900)  // below primary
        let ax = Layout.axFromNS(secondary, primaryHeight: primaryH)
        XCTAssertEqual(ax, CGRect(x: 0, y: 1080, width: 1440, height: 900))
    }

    func testAxFromNS_secondaryRightOfPrimary() {
        let primaryH: CGFloat = 1080
        let secondary = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        let ax = Layout.axFromNS(secondary, primaryHeight: primaryH)
        XCTAssertEqual(ax, CGRect(x: 1920, y: 180, width: 1440, height: 900))
    }

    // MARK: - screenIndex()

    func testScreenIndex_singleDisplay() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let win = CGRect(x: 100, y: 100, width: 400, height: 300)  // in AX coords
        XCTAssertEqual(Layout.screenIndex(forAX: win, nsScreens: screens), 0)
    }

    func testScreenIndex_dualHorizontalRight() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),       // primary
            CGRect(x: 1920, y: 0, width: 1440, height: 900),     // right of primary
        ]
        // AX y for secondary right-of: ax y range [180, 1080]
        let onPrimary = CGRect(x: 100, y: 100, width: 400, height: 300)
        let onSecondary = CGRect(x: 2200, y: 400, width: 400, height: 300)
        XCTAssertEqual(Layout.screenIndex(forAX: onPrimary, nsScreens: screens), 0)
        XCTAssertEqual(Layout.screenIndex(forAX: onSecondary, nsScreens: screens), 1)
    }

    func testScreenIndex_dualVerticalAbove() {
        // Secondary stacked ABOVE primary in NS coords → AX y of secondary is negative.
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),  // above primary in NS
        ]
        let onPrimary = CGRect(x: 100, y: 100, width: 400, height: 300)
        let onAbove = CGRect(x: 100, y: -500, width: 400, height: 300)  // negative AX y
        XCTAssertEqual(Layout.screenIndex(forAX: onPrimary, nsScreens: screens), 0)
        XCTAssertEqual(Layout.screenIndex(forAX: onAbove, nsScreens: screens), 1,
                       "Window with negative AX y should map to the screen above primary")
    }

    func testScreenIndex_emptyScreens() {
        XCTAssertEqual(Layout.screenIndex(forAX: .zero, nsScreens: []), 0)
    }

    // MARK: - gridWouldBeUnreadable()

    func testUnreadable_belowThreshold() {
        // 25 windows on 1920×1080 → 5×5 → 384×216 cells → height 216 < 200 = unreadable
        let s = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(Layout.gridWouldBeUnreadable(count: 25, in: s))
    }

    func testUnreadable_aboveThreshold() {
        // 4 windows on 1920×1080 → 2×2 → 960×540 cells → readable
        let s = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(Layout.gridWouldBeUnreadable(count: 4, in: s))
    }

    func testUnreadable_zeroIsNotUnreadable() {
        XCTAssertFalse(Layout.gridWouldBeUnreadable(count: 0, in: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    func testScreenIndex_nearestFallbackForGap() {
        // Two displays with a gap. Window center sits in the gap — should pick the nearest.
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 2000, y: 0, width: 1000, height: 800),
        ]
        // Window center at AX (1500, 400) — midway between screens, equally distant. Either
        // is acceptable, but we should never crash and never return out-of-range.
        let mid = CGRect(x: 1300, y: 200, width: 400, height: 400)
        let idx = Layout.screenIndex(forAX: mid, nsScreens: screens)
        XCTAssertTrue(idx == 0 || idx == 1)
    }
}

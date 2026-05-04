// NotchDetectorTests.swift
// Smoke coverage for NotchDetector. We can't synthesise a fake NSScreen with
// a non-zero safeAreaInsets in a unit test (NSScreen is owned by the window
// server), so the deepest test we can do here is "given the actual host
// screen, the detector returns either nil or a self-consistent NotchInfo".
//
// For richer geometry checks, see manual QA notes in v2.0 release.
import XCTest
import AppKit
@testable import ClaudeNotch

@MainActor
final class NotchDetectorTests: XCTestCase {

    /// `detect()` should never throw, never crash, and (when it does return a
    /// NotchInfo) the frame must sit at the very top of its screen.
    func test_detect_returnsNilOrTopAlignedFrame() {
        let info = NotchDetector.detect()
        guard let info else {
            // No notch on this host — that's fine, the test still passes.
            return
        }
        let screen = info.screen
        XCTAssertEqual(info.frame.maxY, screen.frame.maxY,
                       "Notch frame must touch the top of the screen.")
        XCTAssertGreaterThan(info.frame.height, 0,
                             "Notch height must be positive.")
        XCTAssertGreaterThanOrEqual(info.frame.width, 140,
                                    "Notch width should be at least the documented floor.")
        XCTAssertLessThanOrEqual(info.frame.width, screen.frame.width,
                                 "Notch can't be wider than the screen.")
    }

    /// `notchInfo(for:)` is consistent with `detect()` when the main screen IS
    /// the one being queried.
    func test_notchInfoForMainScreen_matchesDetect() {
        guard let main = NSScreen.main else {
            // No screens available (CI?). Accept and return.
            return
        }
        let viaMain = NotchDetector.notchInfo(for: main)
        let viaDetect = NotchDetector.detect()
        XCTAssertEqual(viaMain, viaDetect,
                       "detect() should match notchInfo(for: NSScreen.main).")
    }

    /// When the detector reports a frame, that frame must be horizontally
    /// centred on the screen (Apple positions notches dead-center).
    func test_detectedNotch_isHorizontallyCentered() {
        guard let info = NotchDetector.detect() else { return }
        let screenMidX = info.screen.frame.midX
        let frameMidX = info.frame.midX
        XCTAssertEqual(frameMidX, screenMidX, accuracy: 1.0,
                       "Notch must be horizontally centered on its screen (within 1pt).")
    }
}

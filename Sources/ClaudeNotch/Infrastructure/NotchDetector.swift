// NotchDetector.swift
// Detects whether the current screen has a hardware notch (MacBook Pro 14"/16"
// post-2021, M-series MacBook Air post-2022) and computes the notch's frame in
// global screen coordinates (macOS y-up).
//
// macOS 12+ exposes:
//   - NSScreen.safeAreaInsets.top         → notch height when > 0
//   - NSScreen.auxiliaryTopLeftArea       → free rect to the LEFT of the notch
//   - NSScreen.auxiliaryTopRightArea      → free rect to the RIGHT of the notch
//
// Notch width is therefore `screen.frame.width - leftAux - rightAux`. When the
// auxiliary areas are unavailable (sandbox/permission edge cases) we fall back
// to a conservative 200pt approximation centered horizontally.
import AppKit

/// Snapshot of a notch's geometry on a particular screen. All measurements are
/// in points using global screen coordinates (origin bottom-left, y axis up).
struct NotchInfo: Equatable {
    /// Notch frame in global screen coordinates (y-up). `frame.minY == screen.frame.maxY - notchHeight`.
    let frame: CGRect
    /// The screen this notch belongs to. Kept around for re-detection on screen-parameter changes.
    let screen: NSScreen

    static func == (lhs: NotchInfo, rhs: NotchInfo) -> Bool {
        lhs.frame == rhs.frame && lhs.screen === rhs.screen
    }
}

@MainActor
enum NotchDetector {
    /// Conservative fallback width when `auxiliaryTopLeftArea` /
    /// `auxiliaryTopRightArea` are unavailable. Real-world notches measure
    /// roughly 180–220pt across M-series MacBooks.
    private static let fallbackNotchWidth: CGFloat = 200
    /// Floor on the computed width to avoid zero/negative frames when the
    /// auxiliary-area math returns nonsense.
    private static let minNotchWidth: CGFloat = 140

    /// Returns notch info for the main screen, or `nil` if there is none.
    static func detect() -> NotchInfo? {
        guard let screen = NSScreen.main else { return nil }
        return notchInfo(for: screen)
    }

    /// Returns notch info for an arbitrary screen, or `nil` if that screen has no notch.
    static func notchInfo(for screen: NSScreen) -> NotchInfo? {
        guard #available(macOS 12.0, *) else { return nil }
        let notchHeight = screen.safeAreaInsets.top
        guard notchHeight > 0 else { return nil }

        let leftAux = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightAux = screen.auxiliaryTopRightArea?.width ?? 0
        let totalAux = leftAux + rightAux

        let computedWidth: CGFloat
        if totalAux > 0 {
            computedWidth = max(minNotchWidth, screen.frame.width - totalAux)
        } else {
            computedWidth = fallbackNotchWidth
        }

        let x = screen.frame.midX - computedWidth / 2
        // In macOS coordinates y goes UP, so the top of the screen is `maxY`.
        // The notch sits at the very top, height `notchHeight`.
        let y = screen.frame.maxY - notchHeight

        let frame = CGRect(x: x, y: y, width: computedWidth, height: notchHeight)
        return NotchInfo(frame: frame, screen: screen)
    }
}

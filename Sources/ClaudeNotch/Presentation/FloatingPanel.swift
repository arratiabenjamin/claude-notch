// FloatingPanel.swift
// Borderless, non-activating, floating NSPanel that hosts our SwiftUI content.
// Configured to:
//   - never become key/main (never steals focus)
//   - join all spaces (visible regardless of which Mission Control space is up)
//   - be draggable by its background ONLY in free-floating mode (the orchestrator
//     toggles `isMovableByWindowBackground` per mode — Dynamic Island modes are pinned).
//
// v2.0 adds frame helpers + animated frame changes to support the
// compact↔expanded "Dynamic Island" transition driven by AppController.
import AppKit

final class FloatingPanel: NSPanel {
    /// macOS window level used when the panel is sitting on the notch.
    /// We need a level ABOVE the menu bar (which renders at `.mainMenu`/24)
    /// so the pill paints over the system-rendered notch background.
    /// `.popUpMenu` (101) sits comfortably above the menu bar but below
    /// modal alerts and screen savers — exactly what we want.
    static let notchLevel: NSWindow.Level = .popUpMenu

    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true

        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Notch-aware frame helpers

    /// Frame the panel should occupy when sitting ON the notch.
    /// Exact 1:1 match with the hardware cutout — no margin, no offset.
    func compactFrame(notch: NotchInfo) -> CGRect {
        notch.frame
    }

    /// Frame the panel should occupy when expanded BELOW the notch.
    /// Centered horizontally on the notch midpoint; small vertical gap so the
    /// shadow doesn't visually fuse into the menu-bar.
    func expandedFrame(notch: NotchInfo, contentSize: NSSize = NSSize(width: 360, height: 460)) -> CGRect {
        let x = notch.frame.midX - contentSize.width / 2
        // y is below the notch — in macOS coords, that's `notch.minY - height`.
        let y = notch.frame.minY - contentSize.height - 4

        // Clamp X to keep the panel fully on-screen if the user has a narrow
        // display or the notch sits near the screen edge (defensive).
        let screenFrame = notch.screen.frame
        let clampedX = min(max(x, screenFrame.minX + 4), screenFrame.maxX - contentSize.width - 4)

        return CGRect(x: clampedX, y: y, width: contentSize.width, height: contentSize.height)
    }

    /// Animate to a new frame using the standard `easeOut` curve. Designed to
    /// feel like the iPhone Dynamic Island morph.
    func animateFrame(to frame: CGRect, duration: TimeInterval = 0.32) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(frame, display: true)
        }
    }

    /// Configure window chrome for compact (notch-pinned) mode.
    /// In compact mode any shadow leaks pixels outside the hardware notch
    /// silhouette, breaking the "extension of the cutout" illusion. We also
    /// invalidate the existing shadow so AppKit recomputes it from the
    /// transparent regions of the new content view.
    func setCompactChrome() {
        self.hasShadow = false
        self.invalidateShadow()
    }

    /// Configure window chrome for expanded / free-floating modes — the
    /// glass panel benefits from a soft drop shadow to lift it off the wallpaper.
    func setFloatingChrome() {
        self.hasShadow = true
        self.invalidateShadow()
    }
}

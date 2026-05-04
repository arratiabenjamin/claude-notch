// TrackedHostingView.swift
// NSHostingView subclass with a built-in NSTrackingArea, so we can detect
// mouse-enter/exit on the panel content without injecting AppKit views into
// the SwiftUI tree.
//
// Used by AppController to drive compact↔expanded transitions on hover and
// to cancel the auto-collapse timer while the cursor lingers over the panel.
import AppKit
import SwiftUI

final class TrackedHostingView<Content: View>: NSHostingView<Content> {
    /// Fired when the cursor enters the view's bounds. Always invoked on the main thread.
    var onMouseEntered: (() -> Void)?
    /// Fired when the cursor leaves the view's bounds. Always invoked on the main thread.
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Wipe stale tracking areas before installing a fresh one — the bounds
        // change between compact (notch-sized) and expanded (full panel) and
        // we want the area to follow the new bounds exactly.
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

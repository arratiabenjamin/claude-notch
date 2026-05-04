// FloatingPanel.swift
// Borderless, non-activating, floating NSPanel that hosts our SwiftUI content.
// Configured to:
//   - never become key/main (never steals focus)
//   - join all spaces (visible regardless of which Mission Control space is up)
//   - be draggable by its background (entire window is the drag handle)
import AppKit

final class FloatingPanel: NSPanel {
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
}

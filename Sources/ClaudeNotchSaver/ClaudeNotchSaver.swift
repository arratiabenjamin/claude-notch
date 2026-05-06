// ClaudeNotchSaver.swift
// Entry point of the .saver bundle. macOS instantiates this class via the
// Info.plist key NSPrincipalClass, then drives its lifecycle through
// startAnimation / stopAnimation as the user idles in / out of the lock.
//
// We keep the AppKit shell minimal — the visual is a SwiftUI tree hosted
// inside an NSHostingView. The hosting view auto-layouts to the saver's
// bounds so the orb rescales correctly when the system uses the saver in
// preview (small) and fullscreen (huge) without separate codepaths.
import ScreenSaver
import SwiftUI
import AppKit

@objc(ClaudeNotchSaver)
final class ClaudeNotchSaver: ScreenSaverView {
    private var hostingView: NSHostingView<OrbScreenSaverView>?
    private let poller = SaverSessionPoller()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        // SwiftUI's TimelineView drives its own redraw cadence, so we don't
        // rely on animateOneFrame. We still set a sensible interval so the
        // ScreenSaver framework's bookkeeping is happy.
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        installHostingView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        installHostingView()
    }

    private func installHostingView() {
        let root = OrbScreenSaverView(poller: poller)
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        self.hostingView = host
    }

    override func startAnimation() {
        super.startAnimation()
        Task { @MainActor in self.poller.start() }
    }

    override func stopAnimation() {
        super.stopAnimation()
        Task { @MainActor in self.poller.stop() }
    }

    /// SwiftUI's TimelineView pushes redraws on its own — we deliberately do
    /// nothing here so we don't double-tick.
    override func animateOneFrame() {}

    override var hasConfigureSheet: Bool { false }
}

// AppController.swift
// NSApplicationDelegate that owns the panel + status item + watcher + store.
// MainActor-isolated. Wires the FSEvents publisher from the watcher into the
// store via Combine, on the main queue.
import AppKit
import SwiftUI
import Combine

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    // MARK: - Owned state

    private let store = SessionStore()
    private lazy var watcher: StateFileWatcher = {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude")
        return StateFileWatcher(directory: dir)
    }()
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    // Persistence keys
    private enum Keys {
        static let panelOriginX = "panelOriginX"
        static let panelOriginY = "panelOriginY"
        static let panelVisible = "panelVisible"
    }

    private static let defaultPanelSize = NSSize(width: 320, height: 240)
    private static let defaultMargin: CGFloat = 16

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildPanel()
        wireWatcher()

        // Ask for notification permission on first launch. Best-effort —
        // if the user denies, the app keeps working without notifications.
        Task { await NotificationService.shared.requestAuthorizationIfNeeded() }

        // Restore visibility (default = visible).
        let visible = UserDefaults.standard.object(forKey: Keys.panelVisible) as? Bool ?? true
        if visible {
            showPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePanelOrigin()
        watcher.stop()
        cancellables.removeAll()
        panel?.orderOut(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // We live in the menu bar; the panel closing should not exit the app.
        false
    }

    // MARK: - Panel

    private func buildPanel() {
        let panel = FloatingPanel(contentSize: Self.defaultPanelSize)

        let hosting = NSHostingView(
            rootView: SessionListView().environmentObject(store)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultPanelSize))
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        panel.contentView = container
        panel.setFrame(
            NSRect(origin: restoredOrigin(), size: Self.defaultPanelSize),
            display: false
        )
        // Persist position on move.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelMoved(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )
        self.panel = panel
    }

    private func restoredOrigin() -> NSPoint {
        let defaults = UserDefaults.standard
        if let xObj = defaults.object(forKey: Keys.panelOriginX) as? Double,
           let yObj = defaults.object(forKey: Keys.panelOriginY) as? Double {
            let candidate = NSPoint(x: xObj, y: yObj)
            // Validate against current screens (multi-screen safety).
            if Self.originIsOnScreen(candidate, size: Self.defaultPanelSize) {
                return candidate
            }
        }
        return Self.defaultTopRightOrigin()
    }

    private static func originIsOnScreen(_ origin: NSPoint, size: NSSize) -> Bool {
        let candidateFrame = NSRect(origin: origin, size: size)
        for screen in NSScreen.screens {
            if screen.visibleFrame.intersects(candidateFrame) {
                return true
            }
        }
        return false
    }

    private static func defaultTopRightOrigin() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else {
            return NSPoint(x: 100, y: 100)
        }
        let x = frame.maxX - defaultPanelSize.width - defaultMargin
        let y = frame.maxY - defaultPanelSize.height - defaultMargin
        return NSPoint(x: x, y: y)
    }

    @objc private func handlePanelMoved(_ note: Notification) {
        savePanelOrigin()
    }

    private func savePanelOrigin() {
        guard let panel else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: Keys.panelOriginX)
        UserDefaults.standard.set(Double(origin.y), forKey: Keys.panelOriginY)
    }

    private func showPanel() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Keys.panelVisible)
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Keys.panelVisible)
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // ◆ glyph keeps with the panel header chrome.
            button.title = "◆"
            button.toolTip = "Claude Notch"
        }
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: "Show / Hide",
            action: #selector(togglePanelMenu(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let about = NSMenuItem(
            title: "About Claude Notch",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit Claude Notch",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func togglePanelMenu(_ sender: Any?) {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - Watcher wiring

    private func wireWatcher() {
        watcher.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .data(let data):
                    self.store.ingest(data, error: nil)
                case .error(let err):
                    self.store.ingest(nil, error: err)
                }
            }
            .store(in: &cancellables)

        watcher.start()
    }
}

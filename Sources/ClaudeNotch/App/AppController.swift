// AppController.swift
// NSApplicationDelegate that owns the panel + status item + watcher + store.
// MainActor-isolated. Wires the FSEvents publisher from the watcher into the
// store via Combine, on the main queue.
//
// v2.0 — Notch Dynamic Island
// ---------------------------
// On launch we ask NotchDetector whether the main screen has a hardware notch.
//   - Yes → default to `.compact` mode: the panel sits ON the notch, showing
//           only the logo + counter. Hover or click promotes to `.expanded`,
//           which morphs the same NSPanel down BELOW the notch with the full
//           session list. 3s of no interaction collapses back to `.compact`.
//           A click outside the expanded panel also collapses.
//   - No  → fallback to `.freeFloating` — the legacy v1.x pill in the user's
//           preferred corner.
//
// The user can override the default via Settings (`use_notch_mode`). Toggling
// it posts `.claudeNotchModeDidChange`, which we listen for and re-setup.
import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
import Sparkle

extension Notification.Name {
    /// Posted by SettingsView when the user flips the "Use notch as Dynamic Island"
    /// toggle. AppController re-evaluates the active mode in response.
    static let claudeNotchModeDidChange = Notification.Name("com.velion.claude-notch.notchModeDidChange")
    /// Posted by SettingsView when the user flips the "Modo proyector
    /// holográfico" toggle. AppController starts/stops HologramServer.
    static let claudeHologramServerToggle = Notification.Name("com.velion.claude-notch.hologramServerToggle")
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    // MARK: - Owned state

    private let store = SessionStore()
    private let speaker = AvatarSpeaker()
    private lazy var watcher: StateFileWatcher = {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude")
        return StateFileWatcher(directory: dir)
    }()
    /// Watches `~/.claude/sessions/` for `/rename` updates so the panel can
    /// re-decode the cached active-sessions.json with fresh names without
    /// waiting for active-sessions.json itself to tick.
    private lazy var sessionNamesWatcher: DirectoryWatcher = {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/sessions")
        return DirectoryWatcher(directory: dir)
    }()
    private var panel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let hotKeys = HotKeyManager()
    /// Sparkle 2 auto-updater. Reads SUFeedURL + SUPublicEDKey from the
    /// app's Info.plist (configured in project.yml). Drives the menu item
    /// "Check for updates…" and the background scheduled-check loop.
    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()

    /// Local HTTP server that serves the Pepper's ghost pyramid page.
    /// Started/stopped via the Settings toggle (`hologram_projector_enabled`).
    let hologramServer = HologramServer()

    // Notch / Dynamic Island state
    private var mode: PanelMode = .hidden
    private var notchInfo: NotchInfo?
    private var collapseTimer: Timer?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    /// Global mouse-moved monitor installed only while expanded. Watches whether
    /// the cursor is in the hot zone (notch ∪ panel ∪ bridge between them) and
    /// drives the auto-collapse timer. NSTrackingArea alone is not sufficient
    /// because the cursor can leave the panel through the gap to the notch and
    /// we still want to keep the panel open in that case.
    private var globalMouseMoveMonitor: Any?

    // Persistence keys
    private enum Keys {
        static let panelOriginX = "panelOriginX"
        static let panelOriginY = "panelOriginY"
        static let panelVisible = "panelVisible"
        /// Default panel corner when no saved origin exists. Mirrors the same
        /// key SettingsView writes via @AppStorage.
        static let defaultPosition = "default_position"
        /// User's explicit preference for notch mode (Settings toggle).
        static let useNotchMode = "use_notch_mode"
        /// Whether the user has explicitly set `useNotchMode`. If false, we
        /// auto-default based on hardware (notch present → on).
        static let useNotchModeExplicitlySet = "use_notch_mode_explicitly_set"
        /// Whether the local hologram HTTP server is running. Toggled from
        /// Settings; observed via `.claudeHologramServerToggle`.
        static let hologramEnabled = "hologram_projector_enabled"
    }

    private static let defaultPanelSize = NSSize(width: 320, height: 320)
    private static let defaultMargin: CGFloat = 16
    /// Expanded "Dynamic Island" content size. Square stage so the orb sits
    /// centered with consistent orbit radius regardless of session count.
    private static let expandedContentSize = NSSize(width: 320, height: 320)
    /// How long after the cursor leaves an expanded panel before collapsing back.
    private static let autoCollapseInterval: TimeInterval = 3.0

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Avatar voice is opt-in. Register defaults so first-launch users
        // start muted, regardless of whether they ever visit Settings.
        UserDefaults.standard.register(defaults: [
            "avatar_muted": true,
            "avatar_voice_lang": "es-ES"
        ])
        store.speaker = speaker
        buildStatusItem()
        buildPanel()
        wireWatcher()
        observeScreenChanges()
        observeSettingsChanges()
        installGlobalClickMonitor()
        registerGlobalHotKey()

        // Notification authorization is LAZY (v1.3) — we ask the OS only
        // when we're about to post a real notification. See
        // NotificationService.ensureAuthorizedLazily.

        // Restore visibility (default = visible).
        let visible = UserDefaults.standard.object(forKey: Keys.panelVisible) as? Bool ?? true
        if visible {
            applyDefaultMode()
        } else {
            mode = .hidden
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePanelOrigin()
        cancelCollapseTimer()
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        uninstallMouseMoveMonitor()
        watcher.stop()
        sessionNamesWatcher.stop()
        cancellables.removeAll()
        panel?.orderOut(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // We live in the menu bar; the panel closing should not exit the app.
        false
    }

    // MARK: - Panel

    private func buildPanel() {
        // Initial size doesn't really matter — the very first transitionTo*
        // will re-frame the panel correctly. We pick a sane default for cases
        // where the user is on hidden mode and later toggles visible.
        let panel = FloatingPanel(contentSize: Self.defaultPanelSize)
        // Persist position on move (only meaningful in free-floating mode).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelMoved(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )
        self.panel = panel
    }

    /// Pick the appropriate mode for the current hardware/preference combo and
    /// transition into it. Called on launch and whenever screens or settings change.
    private func applyDefaultMode() {
        notchInfo = NotchDetector.detect()

        if shouldUseNotchMode(), let notch = notchInfo {
            transitionToCompact(notch: notch, animated: false)
        } else {
            transitionToFreeFloating(animated: false)
        }
    }

    /// True when the user wants notch mode AND there is actually a notch.
    /// If they have explicitly set the preference we honor it; otherwise we
    /// default to on iff the hardware has a notch.
    private func shouldUseNotchMode() -> Bool {
        let defaults = UserDefaults.standard
        let explicit = defaults.bool(forKey: Keys.useNotchModeExplicitlySet)
        let preferOn: Bool
        if explicit {
            preferOn = defaults.bool(forKey: Keys.useNotchMode)
        } else {
            preferOn = (notchInfo != nil)
        }
        // Even if the user wants notch mode, we can't honor it without a notch.
        return preferOn && notchInfo != nil
    }

    // MARK: - Mode transitions

    private func transitionToCompact(notch: NotchInfo, animated: Bool = true) {
        guard let panel else { return }
        cancelCollapseTimer()
        uninstallMouseMoveMonitor()

        let view = OrbCompactView(notchHeight: notch.frame.height, notchWidth: notch.frame.width)
            .environmentObject(store)
            .environmentObject(speaker)
        installContent(view, on: panel)

        // The compact pill is pinned exactly on the notch. Disable drag.
        panel.isMovableByWindowBackground = false
        panel.level = FloatingPanel.notchLevel
        // No shadow on compact — any shadow leaks outside the notch silhouette.
        panel.setCompactChrome()

        let frame = panel.compactFrame(notch: notch)
        if animated && mode == .expanded {
            panel.animateFrame(to: frame)
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Keys.panelVisible)
        mode = .compact
    }

    private func transitionToExpanded(notch: NotchInfo, animated: Bool = true) {
        guard let panel else { return }

        let view = OrbView()
            .environmentObject(store)
            .environmentObject(speaker)
        installContent(view, on: panel)

        panel.isMovableByWindowBackground = false
        panel.level = FloatingPanel.notchLevel
        // Glass panel earns its drop shadow back.
        panel.setFloatingChrome()

        let frame = panel.expandedFrame(notch: notch, contentSize: Self.expandedContentSize)
        if animated {
            panel.animateFrame(to: frame)
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Keys.panelVisible)
        mode = .expanded
        // Watch the cursor globally so we can collapse when the user simply
        // moves the mouse away — no clicks required.
        installMouseMoveMonitor()
        scheduleCollapseTimer()
    }

    private func transitionToFreeFloating(animated: Bool = false) {
        guard let panel else { return }
        cancelCollapseTimer()
        uninstallMouseMoveMonitor()

        let view = OrbView()
            .environmentObject(store)
            .environmentObject(speaker)
        installContent(view, on: panel)

        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.setFloatingChrome()

        let origin = restoredOrigin()
        let frame = NSRect(origin: origin, size: Self.defaultPanelSize)
        if animated {
            panel.animateFrame(to: frame)
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Keys.panelVisible)
        mode = .freeFloating
    }

    private func transitionToHidden() {
        guard let panel else { return }
        cancelCollapseTimer()
        uninstallMouseMoveMonitor()
        panel.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Keys.panelVisible)
        mode = .hidden
    }

    /// Replace the panel's contentView with a fresh `TrackedHostingView` for the
    /// given SwiftUI content. We rebuild from scratch on every transition so
    /// the mouse-tracking area gets re-installed with the new bounds.
    private func installContent<Content: View>(_ rootView: Content, on panel: FloatingPanel) {
        let host = TrackedHostingView(rootView: AnyView(rootView))
        host.onMouseEntered = { [weak self] in
            Task { @MainActor in self?.handlePanelHover(entering: true) }
        }
        host.onMouseExited = { [weak self] in
            Task { @MainActor in self?.handlePanelHover(entering: false) }
        }
        panel.contentView = host
    }

    // MARK: - Hover / timer / click handlers

    private func handlePanelHover(entering: Bool) {
        if entering {
            cancelCollapseTimer()
            if mode == .compact, let notch = notchInfo {
                transitionToExpanded(notch: notch)
            }
        } else {
            // Cursor left the SwiftUI hosting view. The global mouse-moved
            // monitor (installed in expanded mode) will keep deciding whether
            // to keep the timer alive based on the broader hot zone.
            if mode == .expanded, collapseTimer == nil {
                scheduleCollapseTimer()
            }
        }
    }

    private func scheduleCollapseTimer() {
        cancelCollapseTimer()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: Self.autoCollapseInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleCollapseTimeout()
            }
        }
    }

    private func cancelCollapseTimer() {
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    private func handleCollapseTimeout() {
        guard mode == .expanded, let notch = notchInfo else { return }
        // Final guard: if the cursor is back inside the hot zone right now
        // (came in too fast for mouseMoved to register), reschedule.
        if isMouseInHotZone() {
            scheduleCollapseTimer()
            return
        }
        transitionToCompact(notch: notch)
    }

    /// Hot zone = compact pill area ∪ expanded panel area ∪ a vertical bridge
    /// between them at the panel's horizontal range. The bridge keeps the
    /// panel open while the user travels with the mouse from the notch down
    /// into the panel (or back), even though those are separated by a few pt.
    private func isMouseInHotZone() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let panel, panel.frame.contains(mouse) { return true }
        if let notch = notchInfo, notch.frame.contains(mouse) { return true }
        if let panel, let notch = notchInfo {
            let bridge = CGRect(
                x: panel.frame.minX,
                y: panel.frame.maxY,
                width: panel.frame.width,
                height: max(0, notch.frame.minY - panel.frame.maxY)
            )
            if bridge.contains(mouse) { return true }
        }
        return false
    }

    private func installMouseMoveMonitor() {
        if globalMouseMoveMonitor != nil { return }
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMove()
            }
        }
    }

    private func uninstallMouseMoveMonitor() {
        if let monitor = globalMouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMoveMonitor = nil
        }
    }

    private func handleMouseMove() {
        guard mode == .expanded else { return }
        if isMouseInHotZone() {
            cancelCollapseTimer()
        } else if collapseTimer == nil {
            scheduleCollapseTimer()
        }
    }

    /// Clicks ANYWHERE outside the expanded panel collapse it back to compact.
    /// The compact pill itself swallows clicks via the local monitor (we
    /// handle them as "expand" requests), and the menu bar is fine to leak through.
    private func installGlobalClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleGlobalClick(event)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            // Local monitor only fires when WE are key/active, but our panels
            // don't become key. So this is mostly a no-op safety net for
            // settings/about windows; we still return the event unchanged.
            Task { @MainActor in
                self?.handleLocalClick(event)
            }
            return event
        }
    }

    private func handleGlobalClick(_ event: NSEvent) {
        let mouseLocation = NSEvent.mouseLocation

        switch mode {
        case .compact:
            // Click landed on the notch pill → expand.
            if let panel, panel.frame.contains(mouseLocation), let notch = notchInfo {
                transitionToExpanded(notch: notch)
            }
        case .expanded:
            // Click landed OUTSIDE the expanded panel → collapse.
            if let panel, !panel.frame.contains(mouseLocation), let notch = notchInfo {
                transitionToCompact(notch: notch)
            }
        case .freeFloating, .hidden:
            break
        }
    }

    private func handleLocalClick(_ event: NSEvent) {
        // Reserved for future per-row click handling in expanded mode if it
        // ever needs to bypass SwiftUI's hit-testing. Today it's intentionally
        // a no-op — SwiftUI buttons inside SessionListView already work.
    }

    // MARK: - Screen / settings observers

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChanged(_ note: Notification) {
        // Display configuration changed (clamshell open/close, external monitor
        // hot-plug, resolution change). Re-detect notch and re-apply mode.
        let visible = UserDefaults.standard.object(forKey: Keys.panelVisible) as? Bool ?? true
        if visible {
            applyDefaultMode()
        }
    }

    private func observeSettingsChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNotchModeDidChange(_:)),
            name: .claudeNotchModeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHologramToggle(_:)),
            name: .claudeHologramServerToggle,
            object: nil
        )
        // Apply persisted preference on launch (default: off).
        if UserDefaults.standard.bool(forKey: Keys.hologramEnabled) {
            hologramServer.start()
        }
    }

    @objc private func handleHologramToggle(_ note: Notification) {
        let enabled = UserDefaults.standard.bool(forKey: Keys.hologramEnabled)
        if enabled { hologramServer.start() } else { hologramServer.stop() }
    }

    @objc private func handleNotchModeDidChange(_ note: Notification) {
        applyDefaultMode()
    }

    // MARK: - Free-floating origin restoration (v1.x legacy path)

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
        return Self.defaultOriginForUserCorner()
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

    /// Resolve the user's preferred corner from UserDefaults (Settings UI),
    /// then map it to a screen-local origin. Falls back to top-right.
    private static func defaultOriginForUserCorner() -> NSPoint {
        let raw = UserDefaults.standard.string(forKey: Keys.defaultPosition)
        let corner = PanelCorner(rawValue: raw ?? "") ?? .topRight
        return defaultOrigin(for: corner)
    }

    private static func defaultOrigin(for corner: PanelCorner) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else {
            return NSPoint(x: 100, y: 100)
        }
        let w = defaultPanelSize.width
        let h = defaultPanelSize.height
        let m = defaultMargin
        switch corner {
        case .topRight:
            return NSPoint(x: frame.maxX - w - m, y: frame.maxY - h - m)
        case .topLeft:
            return NSPoint(x: frame.minX + m, y: frame.maxY - h - m)
        case .bottomRight:
            return NSPoint(x: frame.maxX - w - m, y: frame.minY + m)
        case .bottomLeft:
            return NSPoint(x: frame.minX + m, y: frame.minY + m)
        }
    }

    @objc private func handlePanelMoved(_ note: Notification) {
        // Only persist drags in free-floating mode. Notch positions are
        // hardware-driven and would clobber the user's saved corner.
        guard mode == .freeFloating else { return }
        savePanelOrigin()
    }

    private func savePanelOrigin() {
        guard let panel, mode == .freeFloating else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: Keys.panelOriginX)
        UserDefaults.standard.set(Double(origin.y), forKey: Keys.panelOriginY)
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            // Symbol + tint are refreshed live by `updateStatusBadge(for:)` on
            // every store state change.
            button.image = NSImage(
                systemSymbolName: "circle",
                accessibilityDescription: "Claude Notch"
            )
            button.image?.isTemplate = true
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

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        // Sparkle: standard "Check for Updates…" item. Wired to the
        // updaterController's checkForUpdates: action so Sparkle handles
        // the whole UI flow (alerts, download, install on relaunch).
        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updates.target = updaterController
        menu.addItem(updates)

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

    /// Repaint the menu-bar item to reflect the current session pool:
    /// • cyan filled = sessions present, all idle
    /// • amber filled (and a warmer halo) = at least one session running
    /// • outline / secondary tint = no sessions / loading / error
    /// Called from a Combine sink on `store.$state`.
    private func updateStatusBadge(for state: UIState) {
        guard let button = statusItem?.button else { return }

        let symbol: String
        let tint: NSColor?
        let tooltip: String

        switch state {
        case .populated(let active) where active.contains(where: { $0.status == .running }):
            symbol = "circle.fill"
            tint = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.30, alpha: 1.0)
            let n = active.count
            tooltip = "Claude Notch — \(n) " + (n == 1 ? "sesión, trabajando" : "sesiones, alguna trabajando")
        case .populated(let active) where !active.isEmpty:
            symbol = "circle.fill"
            tint = NSColor(srgbRed: 0.30, green: 0.85, blue: 1.00, alpha: 1.0)
            let n = active.count
            tooltip = "Claude Notch — \(n) " + (n == 1 ? "sesión en espera" : "sesiones en espera")
        default:
            symbol = "circle"
            tint = nil // fall back to default status-bar foreground
            tooltip = "Claude Notch — sin sesiones activas"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Notch")
        image?.isTemplate = (tint == nil) // template = follow system foreground
        button.image = image
        button.contentTintColor = tint
        button.toolTip = tooltip
    }

    @objc private func togglePanelMenu(_ sender: Any?) {
        if mode == .hidden {
            applyDefaultMode()
        } else {
            transitionToHidden()
        }
    }

    /// Register ⌥⌘Space as the global show/hide toggle. Failure is silent —
    /// the user always has the menu-bar item as a fallback. We log via NSLog
    /// so the diagnostic shows up under the app's process even without the
    /// os.Logger subsystem.
    private func registerGlobalHotKey() {
        let success = hotKeys.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.togglePanelMenu(nil)
        }
        if !success {
            NSLog("[claude-notch] Global hotkey ⌥⌘Space NOT registered (already claimed?). Menu-bar toggle still works.")
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showSettings(_ sender: Any?) {
        if let window = settingsWindow {
            // Reuse the same window across opens — closing just hides it.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(
            onResetPosition: { [weak self] in self?.resetPanelPosition() },
            onQuit: { NSApp.terminate(nil) },
            hologramServer: hologramServer
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Claude Notch Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        // Switch the app to a regular activation policy briefly so the
        // settings window can become key. This is a small, well-known dance
        // for menu-bar apps that need to show a real window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window

        // Drop back to accessory once the user closes it so we don't hold
        // a Dock icon for nothing.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func handleSettingsWillClose(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Clear the persisted origin AND move the panel to the user's currently
    /// selected default corner. Called from SettingsView. Only meaningful in
    /// free-floating mode; in notch mode it's a no-op (the notch pins us).
    private func resetPanelPosition() {
        UserDefaults.standard.removeObject(forKey: Keys.panelOriginX)
        UserDefaults.standard.removeObject(forKey: Keys.panelOriginY)
        guard mode == .freeFloating, let panel else { return }
        let origin = Self.defaultOriginForUserCorner()
        panel.setFrameOrigin(origin)
        savePanelOrigin()
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

        // Live `/rename` propagation: any change inside ~/.claude/sessions/
        // means a per-pid file was written/removed — re-decode the cached
        // bytes with refreshed customNames. No-op if we never ingested yet.
        sessionNamesWatcher.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.store.refreshNamesAndReingest()
            }
            .store(in: &cancellables)

        sessionNamesWatcher.start()

        // Live menu-bar badge: tint the status item based on aggregate state
        // (running / idle / empty). Fires once for the initial value too.
        store.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusBadge(for: state)
            }
            .store(in: &cancellables)

        // Live hologram-server state push. Combines the session pool and
        // the avatar amplitude into a single HologramState that's fanned
        // out over SSE to whichever phone/Pi/projector is connected.
        Publishers.CombineLatest(store.$state, speaker.$amplitude)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, amp in
                self?.pushHologramState(state: state, amplitude: amp)
            }
            .store(in: &cancellables)
    }

    /// Translate the in-app session/audio state into the simpler
    /// HologramState the projector page consumes, and broadcast.
    private func pushHologramState(state: UIState, amplitude: Double) {
        guard hologramServer.isRunning else { return }
        let mode: HologramState.Mode
        if amplitude > 0.01 {
            mode = .speaking
        } else if case .populated(let active) = state,
                  active.contains(where: { $0.status == .running }) {
            mode = .thinking
        } else {
            mode = .idle
        }
        let running: Int
        let idle: Int
        if case .populated(let active) = state {
            running = active.filter { $0.status == .running }.count
            idle = active.count - running
        } else {
            running = 0
            idle = 0
        }
        hologramServer.push(HologramState(
            mode: mode,
            amplitude: amplitude,
            runningCount: running,
            idleCount: idle
        ))
    }
}

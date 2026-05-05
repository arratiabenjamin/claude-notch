// OrbView.swift
// The expanded / free-floating root view, replacing the legacy SessionListView.
//
// Default state: a single Velion orb at the center, breathing.
// Click on the orb: the panel "blooms" — satellite orbs (one per active
// session) emerge from the center and arrange in a circular orbit around the
// shrunken central orb. Hover a satellite to see its session name; right-click
// (or two-finger tap) for Terminal / End session actions.
// Click on the central orb again or anywhere else: the satellites fade back
// into the center and the orb returns to its solo breathing state.
//
// The orb is the persistent identity of the app. It is never replaced by
// anything else — even with zero sessions, the orb still breathes (dimmer).
import SwiftUI
import AppKit
import os.log

private let log = Logger(subsystem: "com.velion.claude-notch", category: "orb-view")

struct OrbView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var speaker: AvatarSpeaker
    @AppStorage("use_notch_mode") private var useNotchMode: Bool = true
    @AppStorage("use_notch_mode_explicitly_set") private var useNotchModeExplicitlySet: Bool = false

    /// Whether the panel is showing satellites (true) or just the central orb (false).
    @State private var bloomed: Bool = false

    /// Currently hovered satellite session id, for the floating name label.
    @State private var hoveredId: String? = nil

    /// True if ANY connected screen has a hardware notch. We deliberately
    /// don't use `NSScreen.main` here — that returns the screen with the
    /// current keyboard focus, which jumps to whatever external monitor
    /// the user just clicked into. The result was the toggle button
    /// flickering off whenever focus moved off the MacBook display.
    private var hasNotchHardware: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    /// Pixel-space dimensions of the inner stage. Halo extends past these bounds
    /// but never gets clipped because the surrounding ZStack uses `.allowsHitTesting`
    /// only on the actual interactive elements.
    private let stageSize: CGFloat = 320
    private let centralOrbSizeCollapsed: CGFloat = 128
    private let centralOrbSizeBloomed: CGFloat = 78
    private let satelliteSize: CGFloat = 44
    private let orbitRadius: CGFloat = 100

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, cornerRadius: 22)

            // Subtle ambient gradient on top of vibrancy — keeps the surface
            // alive without burying it in noise.
            LinearGradient(
                colors: [
                    Color.white.opacity(0.10),
                    Color.white.opacity(0.02),
                    Color.black.opacity(0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            // Glass rim
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            // Stage with the orb + satellites
            ZStack {
                VelionOrb(
                    size: bloomed ? centralOrbSizeBloomed : centralOrbSizeCollapsed,
                    glowIntensity: aggregateGlow,
                    pulseAmplitude: speaker.amplitude,
                    accent: aggregateColor
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                        bloomed.toggle()
                    }
                }
                .accessibilityLabel(centralAccessibilityLabel)

                if bloomed {
                    ForEach(SpatialSlot.allCases, id: \.self) { slot in
                        let sessionsInSlot = sessionsIn(slot: slot)
                        let baseOffset = slotOffset(slot)
                        ForEach(Array(sessionsInSlot.enumerated()), id: \.element.id) { stackIndex, session in
                            SatelliteOrb(
                                session: session,
                                size: satelliteSize,
                                emphasized: hoveredId == session.id
                            )
                            .offset(stackedOffset(base: baseOffset, stackIndex: stackIndex, stackTotal: sessionsInSlot.count))
                            .onHover { hovering in
                                hoveredId = hovering ? session.id : nil
                            }
                            .onTapGesture {
                                if let cwd = session.cwd, !cwd.isEmpty {
                                    _ = TerminalLauncher.openOrFocus(cwd: cwd, pid: session.pid)
                                }
                            }
                            .contextMenu {
                                satelliteMenu(for: session)
                            }
                            .transition(
                                .scale(scale: 0.1, anchor: .center)
                                    .combined(with: .opacity)
                            )
                            .accessibilityLabel(session.displayName)
                        }
                    }
                }

                // Hovered session name label, anchored bottom-center.
                if let id = hoveredId,
                   let session = activeSessions.first(where: { $0.id == id }) {
                    VStack {
                        Spacer()
                        sessionLabel(session)
                    }
                    .frame(width: stageSize, height: stageSize)
                    .allowsHitTesting(false)
                }

                // Empty-state caption, centered below the orb.
                if activeSessions.isEmpty && !bloomed {
                    VStack {
                        Spacer()
                        Text(emptyCaption)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 28)
                    }
                    .frame(width: stageSize, height: stageSize)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: stageSize, height: stageSize)

            // Mode toggle (notch ↔ floating) in the top-right corner. Only on
            // hardware with a notch — without one there's no second mode.
            if hasNotchHardware {
                VStack {
                    HStack {
                        Spacer()
                        modeToggleButton
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(width: stageSize, height: stageSize)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onChange(of: store.state) { _, newValue in
            // If the active list shrinks while bloomed, gracefully collapse if
            // there is now nothing to show as satellites.
            if case .populated(let active) = newValue {
                if active.isEmpty && bloomed {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        bloomed = false
                    }
                }
            } else if bloomed {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    bloomed = false
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func satelliteMenu(for session: SessionState) -> some View {
        if let cwd = session.cwd, !cwd.isEmpty {
            Button("Open in Terminal") {
                _ = TerminalLauncher.openOrFocus(cwd: cwd, pid: session.pid)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: cwd)]
                )
            }
        }
        if let pid = session.pid, session.status != .ended {
            Divider()
            Button("End session", role: .destructive) {
                if case .success = SessionTerminator.endSession(pid: pid) {
                    store.markManuallyEnded(id: session.id)
                }
            }
        }
    }

    /// Toggle between notch mode (Dynamic Island core) and free-floating
    /// window. Same effect as the Settings toggle: flips `use_notch_mode`,
    /// stamps `use_notch_mode_explicitly_set`, and posts the notification
    /// AppController listens to.
    @ViewBuilder
    private var modeToggleButton: some View {
        Button {
            log.info("modeToggleButton tapped, currentNotchMode=\(self.useNotchMode, privacy: .public) → flipping")
            useNotchMode.toggle()
            useNotchModeExplicitlySet = true
            log.info("posting claudeNotchModeDidChange, newValue=\(self.useNotchMode, privacy: .public)")
            NotificationCenter.default.post(name: .claudeNotchModeDidChange, object: nil)
        } label: {
            Image(systemName: useNotchMode
                  ? "macwindow"
                  : "rectangle.center.inset.filled")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(useNotchMode ? "Sacar a ventana flotante" : "Anclar al notch")
    }

    private func sessionLabel(_ session: SessionState) -> some View {
        Text(session.displayName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .padding(.bottom, 18)
    }

    // MARK: - Derived state

    private var activeSessions: [SessionState] {
        if case .populated(let active) = store.state {
            return active
        }
        return []
    }

    /// Aggregate orb tint:
    /// - any running session  → warm amber (tool/work tone)
    /// - idle but populated   → electric cyan (default tech accent)
    /// - empty / loading      → cool desaturated cyan
    private var aggregateColor: Color {
        switch store.state {
        case .populated(let active) where active.contains(where: { $0.status == .running }):
            return Color(red: 1.00, green: 0.80, blue: 0.35)
        case .populated(let active) where !active.isEmpty:
            return Color(red: 0.30, green: 0.85, blue: 1.00)
        default:
            return Color(red: 0.45, green: 0.65, blue: 0.85)
        }
    }

    private var aggregateGlow: Double {
        switch store.state {
        case .populated(let active) where active.contains(where: { $0.status == .running }):
            return 0.95
        case .populated(let active) where !active.isEmpty:
            return 0.80
        default:
            return 0.40
        }
    }

    private var emptyCaption: String {
        switch store.state {
        case .empty:
            return "Sin sesiones activas"
        case .loading:
            return "Cargando…"
        case .fileMissing:
            return "Esperando state file"
        case .dirMissing:
            return "~/.claude/ no encontrado"
        case .schemaMismatch:
            return "Schema no soportado"
        case .sizeLimitExceeded:
            return "State file demasiado grande"
        case .decodeError:
            return "Reintentando lectura…"
        case .populated:
            return ""
        }
    }

    private var centralAccessibilityLabel: String {
        let count = activeSessions.count
        if count == 0 { return "Claude Notch. Sin sesiones activas." }
        return "Claude Notch. \(count) sesiones activas. Tocá para expandir."
    }

    /// Sessions assigned to `slot`, ordered deterministically (stable id sort).
    private func sessionsIn(slot: SpatialSlot) -> [SessionState] {
        let ids = Set(store.slots.ids(in: slot))
        return activeSessions
            .filter { ids.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    /// Anchor position of a slot around the central orb. Front sits above the
    /// orb, left and right sit on the horizontal axis.
    private func slotOffset(_ slot: SpatialSlot) -> CGSize {
        switch slot {
        case .front: return CGSize(width: 0,                   height: -orbitRadius)
        case .left:  return CGSize(width: -orbitRadius,        height: orbitRadius * 0.5)
        case .right: return CGSize(width:  orbitRadius,        height: orbitRadius * 0.5)
        }
    }

    /// When a slot holds more than one session, fan the satellites slightly
    /// so they don't paint on top of each other. We keep the stacking compact
    /// so the slot still reads as a single direction in audio space.
    private func stackedOffset(base: CGSize, stackIndex: Int, stackTotal: Int) -> CGSize {
        guard stackTotal > 1 else { return base }
        let spread: CGFloat = CGFloat(satelliteSize) * 0.55
        // Offset along a perpendicular axis so the stack lays sideways.
        // Distribute symmetrically: index 0 at -((n-1)/2)*spread, n-1 at +((n-1)/2)*spread.
        let centered = CGFloat(stackIndex) - CGFloat(stackTotal - 1) / 2
        let dx = centered * spread * 0.6
        let dy = centered * spread * -0.4
        return CGSize(width: base.width + dx, height: base.height + dy)
    }
}

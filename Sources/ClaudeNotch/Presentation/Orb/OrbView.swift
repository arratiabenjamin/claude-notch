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

struct OrbView: View {
    @EnvironmentObject var store: SessionStore

    /// Whether the panel is showing satellites (true) or just the central orb (false).
    @State private var bloomed: Bool = false

    /// Currently hovered satellite session id, for the floating name label.
    @State private var hoveredId: String? = nil

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
                    color: aggregateColor
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                        bloomed.toggle()
                    }
                }
                .accessibilityLabel(centralAccessibilityLabel)

                if bloomed {
                    ForEach(Array(activeSessions.enumerated()), id: \.element.id) { index, session in
                        SatelliteOrb(
                            session: session,
                            size: satelliteSize,
                            emphasized: hoveredId == session.id
                        )
                        .offset(satelliteOffset(for: index, total: activeSessions.count))
                        .onHover { hovering in
                            hoveredId = hovering ? session.id : nil
                        }
                        .onTapGesture {
                            // Single tap focuses the terminal (most common action).
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
    /// - any running session  → warm gold-silver
    /// - idle but populated   → bright silver
    /// - empty / loading      → dim silver
    private var aggregateColor: Color {
        switch store.state {
        case .populated(let active) where active.contains(where: { $0.status == .running }):
            return Color(red: 0.96, green: 0.88, blue: 0.62)
        case .populated(let active) where !active.isEmpty:
            return Color(white: 0.92)
        default:
            return Color(white: 0.70)
        }
    }

    private var aggregateGlow: Double {
        switch store.state {
        case .populated(let active) where active.contains(where: { $0.status == .running }):
            return 0.95
        case .populated(let active) where !active.isEmpty:
            return 0.75
        default:
            return 0.35
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

    /// Distribute `total` satellites evenly around a circle, starting at the top.
    private func satelliteOffset(for index: Int, total: Int) -> CGSize {
        guard total > 0 else { return .zero }
        let angle = (Double(index) / Double(total)) * 2 * .pi - (.pi / 2)
        return CGSize(
            width: cos(angle) * orbitRadius,
            height: sin(angle) * orbitRadius
        )
    }
}

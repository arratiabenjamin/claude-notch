// OrbCompactView.swift
// The view rendered ON the MacBook's hardware notch. Replaces the v2.x
// rectangular pill with a permanent mini Velion orb. Same height as the
// notch; the orb sits centered with a small counter to its right when there
// are active sessions.
//
// Visual goal: the notch reads as a glowing slot that *contains* the orb,
// not as a sticker pasted over it. We keep the solid black background +
// NotchPillShape clip from the previous pill so the silhouette still
// matches the hardware cutout, but the contents are purely the orb now.
import SwiftUI

struct OrbCompactView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var speaker: AvatarSpeaker

    /// Notch height in points (typically 32–37). Drives orb sizing.
    let notchHeight: CGFloat

    /// Notch width in points. The view matches the notch exactly.
    let notchWidth: CGFloat

    var body: some View {
        ZStack {
            // Solid black so the cutout silhouette stays believable.
            Color.black

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                VelionSatelliteHologram(
                    size: max(14, notchHeight - 16),
                    mode: compactMode
                )
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: notchWidth, height: notchHeight)
        .clipShape(NotchPillShape(bottomCornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Derived state

    private var activeCount: Int {
        if case .populated(let active) = store.state { return active.count }
        return 0
    }

    /// Compact orb mode. Same priority order as the expanded panel:
    /// speaking > thinking > idle. The compact orb is tiny on the notch
    /// so the difference between idle and thinking matters mostly via the
    /// pulsing scale, not via halo strength.
    private var compactMode: VelionMode {
        if speaker.amplitude > 0.01 {
            return .speaking(amplitude: speaker.amplitude)
        }
        if case .populated(let active) = store.state,
           active.contains(where: { $0.status == .running }) {
            return .thinking
        }
        return .idle
    }

    private var accessibilityDescription: String {
        switch store.state {
        case .populated(let active):
            return "Claude Notch. \(active.count) sesiones activas."
        case .empty:    return "Claude Notch. Sin sesiones."
        case .loading:  return "Claude Notch. Cargando."
        default:        return "Claude Notch."
        }
    }
}

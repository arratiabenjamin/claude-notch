// SatelliteOrb.swift
// Per-session mini-core, rendered around the central VelionOrb when the
// panel blooms. Same tech / arc-reactor language as the main orb but at
// a smaller scale: bright core with a thin rim and a halo. Color encodes
// session status.
import SwiftUI

struct SatelliteOrb: View {
    let session: SessionState
    var size: CGFloat = 44
    var emphasized: Bool = false

    /// Status → tech accent. Running pulses a warm amber, idle is electric
    /// cyan (matches the main orb), ended/unknown is dim slate.
    private var stateColor: Color {
        switch session.status {
        case .running:           return Color(red: 1.00, green: 0.78, blue: 0.30)
        case .idle:              return Color(red: 0.30, green: 0.85, blue: 1.00)
        case .ended, .unknown:   return Color(white: 0.55)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Running cores breathe quickly; idle/ended barely.
            let speed: Double = session.status == .running ? 1.5 : 0.6
            let breath = (sin(t * speed) + 1) / 2
            let coreScale = 1.0 + breath * (session.status == .running ? 0.06 : 0.02)
            let emphScale = emphasized ? 1.18 : 1.0

            ZStack {
                // Outer glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                stateColor.opacity(0.55),
                                stateColor.opacity(0.10),
                                stateColor.opacity(0)
                            ],
                            center: .center,
                            startRadius: size * 0.20,
                            endRadius: size * 0.80
                        )
                    )
                    .frame(width: size * 1.7, height: size * 1.7)
                    .blur(radius: 6)

                // Core fill
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                stateColor.opacity(0.92),
                                stateColor.opacity(0.55),
                                Color(red: 0.05, green: 0.10, blue: 0.18).opacity(0.95)
                            ],
                            center: UnitPoint(x: 0.40, y: 0.35),
                            startRadius: 0,
                            endRadius: size * 0.55
                        )
                    )
                    .frame(width: size, height: size)
                    .shadow(color: stateColor.opacity(0.55), radius: 5, x: 0, y: 0)

                // Crisp rim
                Circle()
                    .stroke(stateColor.opacity(0.85), lineWidth: 0.8)
                    .frame(width: size, height: size)
                    .blur(radius: 0.2)

                // Specular dot
                Circle()
                    .fill(Color.white.opacity(0.65))
                    .frame(width: size * 0.16, height: size * 0.16)
                    .offset(x: -size * 0.18, y: -size * 0.22)
                    .blur(radius: 1.2)
            }
            .scaleEffect(coreScale * emphScale)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: emphasized)
        }
    }
}

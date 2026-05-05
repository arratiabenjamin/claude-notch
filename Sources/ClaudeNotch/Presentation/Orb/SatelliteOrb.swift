// SatelliteOrb.swift
// One mini-orb per session, rendered around the central Velion orb when the
// user expands the panel ("Option C bloom"). The satellite carries the
// session's status as color and pulses subtly when its session is running.
import SwiftUI

struct SatelliteOrb: View {
    let session: SessionState
    var size: CGFloat = 44
    var emphasized: Bool = false

    private var stateColor: Color {
        switch session.status {
        case .running:           return Color(red: 1.00, green: 0.85, blue: 0.40)  // soft amber-gold
        case .idle:              return Color(red: 0.60, green: 0.95, blue: 0.70)  // soft green
        case .ended, .unknown:   return Color(white: 0.55)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Running sessions breathe quickly; idle sessions barely.
            let speed: Double = session.status == .running ? 1.4 : 0.5
            let breath = (sin(t * speed * .pi / 2) + 1) / 2
            let scale = 1.0 + breath * (session.status == .running ? 0.08 : 0.03)
            let emphScale = emphasized ? 1.15 : 1.0

            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.35))
                    .frame(width: size * 1.5, height: size * 1.5)
                    .blur(radius: 6)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.92),
                                stateColor.opacity(0.85),
                                stateColor.opacity(0.55)
                            ],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0,
                            endRadius: size * 0.6
                        )
                    )
                    .frame(width: size, height: size)
                    .shadow(color: stateColor.opacity(0.35), radius: 4, x: 0, y: 0)

                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: size * 0.18, height: size * 0.18)
                    .offset(x: -size * 0.18, y: -size * 0.22)
                    .blur(radius: 2)
            }
            .scaleEffect(scale * emphScale)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: emphasized)
        }
    }
}

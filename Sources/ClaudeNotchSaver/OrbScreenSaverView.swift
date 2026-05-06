// OrbScreenSaverView.swift
// Fullscreen SwiftUI canvas drawn by the .saver bundle.
//
// Layout:
//   - Single Velion orb at the screen center, sized to the smaller axis.
//   - One satellite per active session, in a slow circular orbit. Speed and
//     glow scale with how "alive" the aggregate session pool is.
//   - "Claude Notch" wordmark at the bottom — sutil; the orb is the show.
//
// Polling-driven: the SaverSessionPoller refreshes ~/.claude/active-sessions.json
// every 2.5s. We can't use FSEvents inside the legacyScreenSaver host process
// (different lifecycle and sandbox), so polling at human-perceptible cadence
// is the right call here.
import SwiftUI

struct OrbScreenSaverView: View {
    @ObservedObject var poller: SaverSessionPoller

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Pitch-black background — gives the orb maximum contrast on
                // OLED-ish displays and matches the lock-screen aesthetic.
                Color.black.ignoresSafeArea()

                let active = poller.sessions.filter { $0.status != .ended }
                let centralSize = min(geo.size.width, geo.size.height) * 0.22
                let orbitRadius = centralSize * 1.55
                let satelliteSize = centralSize * 0.36

                VelionOrb(
                    size: centralSize,
                    glowIntensity: aggregateGlow(active),
                    pulseAmplitude: 0.0,
                    accent: aggregateColor(active)
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                ForEach(Array(active.enumerated()), id: \.element.id) { index, session in
                    let startAngle = Double(index) * (2 * .pi / Double(max(active.count, 1)))
                    OrbitingSatellite(
                        session: session,
                        size: satelliteSize,
                        radius: orbitRadius,
                        startAngle: startAngle,
                        speed: 0.10
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }

                VStack(spacing: 6) {
                    Spacer()
                    if !active.isEmpty {
                        Text(activeCountLabel(active))
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .tracking(1.5)
                    }
                    Text("Claude Notch")
                        .font(.system(size: 16, weight: .light, design: .rounded))
                        .tracking(4)
                        .foregroundStyle(Color.white.opacity(0.30))
                        .padding(.bottom, 36)
                }
            }
        }
    }

    private func aggregateColor(_ active: [SessionState]) -> Color {
        if active.contains(where: { $0.status == .running }) {
            return Color(red: 1.00, green: 0.80, blue: 0.35) // ámbar — laburando
        }
        if !active.isEmpty {
            return Color(red: 0.30, green: 0.85, blue: 1.00) // cian — esperando
        }
        return Color(red: 0.45, green: 0.65, blue: 0.85)     // gris-cian — sin sesiones
    }

    private func aggregateGlow(_ active: [SessionState]) -> Double {
        if active.contains(where: { $0.status == .running }) { return 0.95 }
        if !active.isEmpty { return 0.70 }
        return 0.40
    }

    private func activeCountLabel(_ active: [SessionState]) -> String {
        let running = active.filter { $0.status == .running }.count
        let idle = active.count - running
        if running > 0 && idle > 0 {
            return "\(running) ACTIVAS · \(idle) EN ESPERA"
        }
        if running > 0 {
            return running == 1 ? "1 SESIÓN ACTIVA" : "\(running) SESIONES ACTIVAS"
        }
        return active.count == 1 ? "1 SESIÓN EN ESPERA" : "\(active.count) SESIONES EN ESPERA"
    }
}

/// A satellite orb on a circular orbit around the screen center. Wraps
/// SatelliteOrb in a TimelineView-driven offset so the orbit advances every
/// frame without us paying for AppKit-side animations.
private struct OrbitingSatellite: View {
    let session: SessionState
    let size: CGFloat
    let radius: CGFloat
    let startAngle: Double
    /// Radians per second. ~0.10 → one revolution every ~63s. Slow enough
    /// to feel ambient, not distracting.
    let speed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = startAngle + t * speed
            let dx = cos(angle) * radius
            let dy = sin(angle) * radius
            SatelliteOrb(session: session, size: size, emphasized: false)
                .offset(x: dx, y: dy)
        }
    }
}

// OrbScreenSaverView.swift
// Fullscreen SwiftUI canvas drawn by the .saver bundle.
//
// Layout:
//   - Central VelionHologram at the screen midpoint, sized to the smaller axis.
//   - One VelionSatelliteHologram per active session, in slow circular orbit.
//   - All session state is communicated by motion (idle / thinking modes),
//     never by color — palette stays silver/white-on-black throughout.
//   - Active count + "Claude Notch" wordmark anchored bottom-center.
//
// Polling-driven: SaverSessionPoller refreshes /tmp/com.velion.claude-notch...
// every 2.5s. We can't use FSEvents inside the legacyScreenSaver sandbox
// (different lifecycle, restricted FS access), so polling at human-perceptible
// cadence is the right call here.
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.velion.claude-notch.saver", category: "view")

struct OrbScreenSaverView: View {
    @ObservedObject var poller: SaverSessionPoller

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                let active = poller.sessions.filter { $0.status != .ended }
                let _ = {
                    log.info("render: total=\(poller.sessions.count, privacy: .public) active=\(active.count, privacy: .public) viewSize=\(Int(geo.size.width), privacy: .public)x\(Int(geo.size.height), privacy: .public)")
                }()
                let centralSize = min(geo.size.width, geo.size.height) * 0.22
                let orbitRadius = centralSize * 1.85
                let satelliteSize = centralSize * 0.40

                VelionHologram(
                    size: centralSize,
                    mode: aggregateMode(active)
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                ForEach(Array(active.enumerated()), id: \.element.id) { index, session in
                    let startAngle = Double(index) * (2 * .pi / Double(max(active.count, 1)))
                    OrbitingSatellite(
                        session: session,
                        size: satelliteSize,
                        radius: orbitRadius,
                        startAngle: startAngle,
                        speed: 0.10,
                        center: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    )
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

    /// Map aggregate session state → VelionMode for the central orb. State
    /// is communicated by motion only (the palette is fixed silver/white):
    ///   • any session running → .thinking (rhythmic scale pulse)
    ///   • only idle sessions  → .idle (subtle wiggle, faster flicker)
    ///   • no sessions         → .idle (same)
    private func aggregateMode(_ active: [SessionState]) -> VelionMode {
        if active.contains(where: { $0.status == .running }) { return .thinking }
        return .idle
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

/// A holographic satellite on a circular orbit around an absolute screen
/// center. Uses .position from inside the TimelineView so the satellite
/// lands at an absolute point in the parent's coordinate space, regardless
/// of how the parent stacks it.
private struct OrbitingSatellite: View {
    let session: SessionState
    let size: CGFloat
    let radius: CGFloat
    let startAngle: Double
    /// Radians per second. ~0.10 → one revolution every ~63s.
    let speed: Double
    let center: CGPoint

    /// Per-session mode. Running sessions get .thinking (pulsing scale) so
    /// you can tell at a glance which sessions are working — same language
    /// as the central orb, no color shift.
    private var mode: VelionMode {
        session.status == .running ? .thinking : .idle
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = startAngle + t * speed
            let dx = cos(angle) * radius
            let dy = sin(angle) * radius
            VelionSatelliteHologram(size: size, mode: mode)
                .position(x: center.x + dx, y: center.y + dy)
        }
    }
}

// VelionSatelliteHologram.swift
// Miniature, screen-saver-only Velion hologram for orbiting satellites.
// Uses the same visual language as VelionHologram (silver wireframe + V
// sigil) but stripped down — at ~80pt diameter the scan band, the
// micro-glyphs, and 6 meridians become visual noise. We keep the bare
// minimum that still reads as the same family:
//
//   • 3 parallels + 3 meridians (instead of 5+6)
//   • 1 centered ring (instead of 3)
//   • Tiny stroke V sigil
//   • Soft halo
//
// Motion mapping is identical to the central hologram (mode-based, no
// hue change). Each satellite represents one Claude session.
import SwiftUI

struct VelionSatelliteHologram: View {
    var size: CGFloat = 80
    var mode: VelionMode = .idle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let scale = scaleMultiplier(t: t)
            let flicker = flickerOpacity(t: t)

            ZStack {
                halo(t: t)
                wireSphereLite(t: t)
                centeredRingLite(t: t)
                miniSigil(t: t)
            }
            .frame(width: size * 1.7, height: size * 1.7)
            .scaleEffect(scale)
            .opacity(flicker)
        }
    }

    // MARK: - Mode → motion

    private func scaleMultiplier(t: Double) -> CGFloat {
        switch mode {
        case .idle:
            return 1.0 + CGFloat(sin(t * 0.55)) * 0.008
        case .thinking:
            return 1.0 + CGFloat(sin(t * Double.pi)) * 0.06
        case .speaking(let amp):
            let clamped = max(0, min(1, amp))
            return 1.0 + CGFloat(clamped) * 0.14
        }
    }

    private func flickerOpacity(t: Double) -> Double {
        let base = 0.94
        switch mode {
        case .idle:
            return base + sin(t * 8.7) * 0.025 + sin(t * 13.3 + 1.1) * 0.020
        case .thinking:
            return base + sin(t * 5.2) * 0.020
        case .speaking:
            return 0.97
        }
    }

    private func rotationSpeedFactor() -> Double {
        switch mode {
        case .idle:        return 1.0
        case .thinking:    return 1.7
        case .speaking:    return 1.0
        }
    }

    // MARK: - Layers

    private func halo(t: Double) -> some View {
        let breath = (sin(t * 0.7) + 1) / 2
        let baseAlpha: Double = {
            switch mode {
            case .idle:        return 0.22
            case .thinking:    return 0.40
            case .speaking(let amp): return 0.25 + amp * 0.20
            }
        }()
        let alpha = baseAlpha + breath * 0.06
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(alpha),
                        Color.white.opacity(alpha * 0.30),
                        Color.white.opacity(0)
                    ],
                    center: .center,
                    startRadius: size * 0.20,
                    endRadius: size * 0.85
                )
            )
            .frame(width: size * 1.7, height: size * 1.7)
            .blur(radius: 9)
    }

    private func wireSphereLite(t: Double) -> some View {
        let yawDeg = (t * (0.30 * rotationSpeedFactor())) * (180 / .pi)
        let lats: [Double] = [-35, 0, 35].map { $0 * .pi / 180 }
        return ZStack {
            // Parallels — only 3 to stay legible at small scale.
            ForEach(Array(lats.enumerated()), id: \.offset) { _, lat in
                let cosLat = cos(lat)
                let yOff = sin(lat) * size * 0.50
                Ellipse()
                    .stroke(silverStroke, lineWidth: 0.7)
                    .frame(width: size * cosLat, height: size * cosLat * 0.22)
                    .offset(y: yOff)
            }
            // 3 meridians instead of 6.
            ForEach(0..<3, id: \.self) { i in
                let baseDeg = Double(i) * 60.0
                Ellipse()
                    .stroke(silverStrokeSoft, lineWidth: 0.7)
                    .frame(width: size * 0.14, height: size)
                    .rotation3DEffect(
                        .degrees(baseDeg + yawDeg),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.55
                    )
            }
        }
    }

    private func centeredRingLite(t: Double) -> some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [
                        Color.white.opacity(0.85),
                        Color.white.opacity(0.20),
                        Color.white.opacity(0.85)
                    ],
                    center: .center
                ),
                lineWidth: 1.0
            )
            .frame(width: size * 0.62, height: size * 0.62)
            .rotation3DEffect(
                .degrees(72),
                axis: (x: 1, y: 0, z: 0)
            )
            .rotationEffect(.radians(t * 0.55 * rotationSpeedFactor()))
            .shadow(color: Color.white.opacity(0.40), radius: 2, x: 0, y: 0)
    }

    private func miniSigil(t: Double) -> some View {
        let rotDeg = (t * (0.10 + 0.10 * rotationSpeedFactor())) * (180 / .pi)
        return ZStack {
            VWingsShape()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color.white.opacity(0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 1.0, lineJoin: .round)
                )
                .frame(width: size * 0.40, height: size * 0.42)
                .shadow(color: Color.white.opacity(0.55), radius: 3, x: 0, y: 0)

            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(y: -size * 0.20)
                .shadow(color: Color.white.opacity(0.85), radius: 4, x: 0, y: 0)
        }
        .rotation3DEffect(
            .degrees(rotDeg),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.7
        )
    }

    // MARK: - Stroke palettes

    private var silverStroke: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.80),
                Color.white.opacity(0.25),
                Color.white.opacity(0.80)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var silverStrokeSoft: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.50),
                Color.white.opacity(0.10),
                Color.white.opacity(0.50)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

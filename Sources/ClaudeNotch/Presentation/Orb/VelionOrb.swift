// VelionOrb.swift
// The signature visual of the app. A breathing silver-white sphere whose
// aesthetic borrows from the Velion brand — a winged figure inside a circle,
// minimalist, ethereal, suggestive of "ascend".
//
// Composition:
//   1. Outer halo: blurred radial gradient that fades into transparency,
//      gives the ambient "presence" without a hard edge.
//   2. Body: radial gradient with the highlight off-center toward the upper
//      left, simulating a soft top-light specular.
//   3. Specular dot: a tighter highlight ring that catches the eye like a
//      beveled glass rim.
//   4. Wing rings: three concentric strokes at decreasing opacity that nod to
//      the V-wing inside the Velion logo without being literal.
//
// Animation:
//   - A slow breath driven by `TimelineView(.animation)` modulates the body
//     scale by ~4%. Continuous, does not require external state.
//   - `pulseAmplitude` is the hook for amplitude-driven lip-sync (Phase 4):
//     pass the audio RMS [0..1] and the orb hits an extra ~15% scale + the
//     wing rings visibly ripple outward.
//
// The orb is purely cosmetic — interactivity (click, hover) is handled by
// containers (OrbView, OrbCompactView). This view never decides anything.
import SwiftUI

struct VelionOrb: View {
    /// Visual diameter of the orb body in points. Halo extends ~1.6× this.
    var size: CGFloat = 140

    /// 0..1. Drives the outer halo opacity. Idle ≈ 0.3, alive ≈ 0.7,
    /// running session ≈ 0.9.
    var glowIntensity: Double = 0.7

    /// 0..1. Audio RMS for lip-sync. Wired in Phase 4. Zero when not speaking.
    var pulseAmplitude: Double = 0.0

    /// Body tint. Default Velion silver. Shifts toward gold-silver when a
    /// session is running, toward dim silver when idle/empty.
    var color: Color = Color(white: 0.88)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Slow breath — period ~4s. sin returns -1..1; remap to 0..1.
            let breath = (sin(t * 0.5 * .pi / 2) + 1) / 2
            let pulse = max(0, min(1, pulseAmplitude))
            let scale = 1.0 + (breath * 0.04) + (pulse * 0.15)

            ZStack {
                outerHalo(breath: breath, pulse: pulse)
                wingRings(breath: breath, pulse: pulse)
                body(scale: scale)
                specular(scale: scale)
            }
            .frame(width: size * 1.7, height: size * 1.7)
        }
    }

    // MARK: - Layers

    private func outerHalo(breath: Double, pulse: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity(0.30 * glowIntensity + pulse * 0.25),
                        color.opacity(0.10 * glowIntensity),
                        color.opacity(0)
                    ],
                    center: .center,
                    startRadius: size * 0.25,
                    endRadius: size * 0.85
                )
            )
            .frame(width: size * 1.7, height: size * 1.7)
            .blur(radius: 14)
            .scaleEffect(1.0 + breath * 0.03 + pulse * 0.05)
    }

    private func wingRings(breath: Double, pulse: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                wingRing(index: i, breath: breath, pulse: pulse)
            }
        }
    }

    private func wingRing(index i: Int, breath: Double, pulse: Double) -> some View {
        let baseOpacity = 0.18 - Double(i) * 0.05
        let ringScale = 1.0 + Double(i) * 0.07
        let stepAmount = Double(i + 1)
        let dynamicScale = 1.0 + breath * 0.02 * stepAmount + pulse * 0.04 * stepAmount
        return Circle()
            .stroke(color.opacity(baseOpacity + pulse * 0.15), lineWidth: 0.6)
            .frame(width: size * ringScale, height: size * ringScale)
            .scaleEffect(dynamicScale)
    }

    private func body(scale: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        color.opacity(0.95),
                        color.opacity(0.6)
                    ],
                    center: UnitPoint(x: 0.35, y: 0.30),
                    startRadius: 0,
                    endRadius: size * 0.55
                )
            )
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .shadow(color: color.opacity(0.4), radius: size * 0.06, x: 0, y: 0)
    }

    private func specular(scale: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.75),
                        Color.white.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.10
                )
            )
            .frame(width: size * 0.40, height: size * 0.40)
            .offset(x: -size * 0.18, y: -size * 0.22)
            .scaleEffect(scale)
            .blur(radius: 1.5)
    }
}

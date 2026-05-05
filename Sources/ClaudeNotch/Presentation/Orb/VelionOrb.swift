// VelionOrb.swift
// The signature visual of the app — a tech / futurist orb. Reads as a
// compact arc-reactor or holographic core rather than a soft glass marble.
//
// Composition (back to front):
//   1. Outer glow:   electric cyan halo, blurred. Pulses with audio.
//   2. Tilted rings: two geometric rings on perpendicular axes, slowly
//                    rotating in opposite directions. Suggests an orbital /
//                    atomic structure, not concentric ripples.
//   3. Core sphere:  deep navy → bright cyan radial gradient with a sharp
//                    inner highlight. Flat-ish on the edges so the silhouette
//                    reads as solid, not foggy.
//   4. Energy seams: two thin arcs (top + bottom) that scan around the core
//                    every few seconds, like a holographic interface tracing.
//   5. Specular dot: small, hot-white, top-left.
//
// Animation:
//   - Continuous rotation of the geometric rings (TimelineView, 60 fps).
//   - `pulseAmplitude` (0..1) blooms the glow and pushes the rings outward
//     when the avatar is speaking — wired in Phase 4.
//
// Coloring:
//   - `accent`: the dominant tone of the orb (default electric cyan-blue).
//     Phases 2+ will swap this per session/state (gold for running, etc).
import SwiftUI

struct VelionOrb: View {
    /// Visual diameter of the core sphere in points.
    var size: CGFloat = 140

    /// 0..1. Drives the outer halo intensity. Idle ≈ 0.4, alive ≈ 0.8.
    var glowIntensity: Double = 0.7

    /// 0..1. Audio RMS for lip-sync. Wired in Phase 4. Zero when not speaking.
    var pulseAmplitude: Double = 0.0

    /// Dominant accent. Default electric cyan; per-state colors overridden by callers.
    var accent: Color = Color(red: 0.30, green: 0.85, blue: 1.00)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = max(0, min(1, pulseAmplitude))
            // Core breathing — much subtler than v1 so it reads as machine, not lung.
            let breath = (sin(t * 0.6) + 1) / 2
            let coreScale = 1.0 + breath * 0.015 + pulse * 0.10

            ZStack {
                outerGlow(pulse: pulse, breath: breath)
                tiltedRing(rotationOffset: t * 0.6, axis: .horizontal, pulse: pulse)
                tiltedRing(rotationOffset: -t * 0.45, axis: .vertical, pulse: pulse)
                core(scale: coreScale)
                scanArcs(rotation: t * 1.2, pulse: pulse)
                specular(scale: coreScale)
            }
            .frame(width: size * 1.7, height: size * 1.7)
        }
    }

    // MARK: - Layers

    private func outerGlow(pulse: Double, breath: Double) -> some View {
        let opacity = 0.35 * glowIntensity + pulse * 0.40
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        accent.opacity(opacity),
                        accent.opacity(opacity * 0.4),
                        accent.opacity(0)
                    ],
                    center: .center,
                    startRadius: size * 0.30,
                    endRadius: size * 0.95
                )
            )
            .frame(width: size * 1.7, height: size * 1.7)
            .blur(radius: 16)
            .scaleEffect(1.0 + breath * 0.02 + pulse * 0.06)
    }

    private enum RingAxis { case horizontal, vertical }

    /// A geometric ring tilted on one axis to read as 3D orbit.
    /// `rotationOffset` rotates the ring around its tilted axis to suggest motion.
    private func tiltedRing(rotationOffset: Double, axis: RingAxis, pulse: Double) -> some View {
        let strokeOpacity = 0.55 + pulse * 0.30
        let radius = size * 0.62 + pulse * size * 0.05
        return Ellipse()
            .stroke(
                LinearGradient(
                    colors: [
                        accent.opacity(strokeOpacity),
                        accent.opacity(strokeOpacity * 0.20),
                        accent.opacity(strokeOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.2
            )
            .frame(
                width: axis == .horizontal ? radius * 2 : radius * 0.4,
                height: axis == .horizontal ? radius * 0.4 : radius * 2
            )
            .rotationEffect(.radians(rotationOffset))
            .blur(radius: 0.4)
    }

    private func core(scale: Double) -> some View {
        ZStack {
            // Core fill — deep navy at edges, bright cyan-white core.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            accent.opacity(0.95),
                            accent.opacity(0.55),
                            Color(red: 0.05, green: 0.10, blue: 0.20).opacity(0.95)
                        ],
                        center: UnitPoint(x: 0.40, y: 0.35),
                        startRadius: 0,
                        endRadius: size * 0.55
                    )
                )
                .frame(width: size, height: size)
                .scaleEffect(scale)
                .shadow(color: accent.opacity(0.55), radius: size * 0.10, x: 0, y: 0)

            // Crisp rim — gives the silhouette its tech-edge.
            Circle()
                .stroke(accent.opacity(0.90), lineWidth: 1.0)
                .frame(width: size, height: size)
                .scaleEffect(scale)
                .blur(radius: 0.3)
        }
    }

    /// Two thin arcs that scan around the core. They sit just outside the rim
    /// and rotate slowly, like a HUD readout circling the core.
    private func scanArcs(rotation: Double, pulse: Double) -> some View {
        let radius = size * 0.55
        return ZStack {
            ArcShape(startAngle: .degrees(20), endAngle: .degrees(70))
                .stroke(accent.opacity(0.85 + pulse * 0.10), lineWidth: 1.4)
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.radians(rotation))

            ArcShape(startAngle: .degrees(200), endAngle: .degrees(250))
                .stroke(accent.opacity(0.55 + pulse * 0.10), lineWidth: 1.0)
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.radians(rotation * 0.7))
        }
        .blur(radius: 0.3)
    }

    private func specular(scale: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.85),
                        Color.white.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.08
                )
            )
            .frame(width: size * 0.32, height: size * 0.32)
            .offset(x: -size * 0.20, y: -size * 0.22)
            .scaleEffect(scale)
            .blur(radius: 1.2)
    }
}

// MARK: - Arc shape helper

/// Open arc (no fill, no closing line). Used for the scan lines around the core.
private struct ArcShape: Shape {
    var startAngle: Angle
    var endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        p.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return p
    }
}

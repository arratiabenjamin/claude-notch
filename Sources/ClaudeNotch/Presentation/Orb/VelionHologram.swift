// VelionHologram.swift
// Holographic Velion orb — wireframe sphere + sigil suspended in air,
// surrounded by HUD-style scan lines and a thin flicker. Iron Man HUD
// reference, Velion palette (silver / white-neon / black, no saturated
// cyan).
//
// Where it lives today:
//   • Screen saver bundle (.saver) — renders fullscreen as ambient
//     awareness on lock.
//
// Reserved for tomorrow:
//   • Volumetric projection (Cheoptics360, Looking Glass, Pepper's
//     ghost rig). The layer stack is intentionally line-art + alpha —
//     no opaque sphere body, no fake shading — so it translates
//     cleanly to a real 3D display when the hardware lands.
//
// The app panel currently uses the classic VelionOrb (cyan/amber arc-
// reactor). When the projector is in place, we wire THIS view into the
// panel and/or an external display.
//
// State is communicated by MOTION, not color:
//   • .idle      → calm breathing + tiny lateral wiggle, faster flicker.
//                  Reads as "attentive but waiting".
//   • .thinking  → rhythmic scale pulse + faster rotation + more frequent
//                  scans. Reads as "working".
//   • .speaking  → scale tracks audio amplitude, lip-sync style.
//
// Layers (back → front):
//   1. Outer glow      — soft silver halo on the dark backdrop.
//   2. Wire sphere     — 5 parallels + 6 meridians; meridians use
//                        rotation3DEffect on Y so they foreshorten as they
//                        pivot.
//   3. Centered rings  — 3 thin silver rings INSIDE the sphere on three
//                        different planes, rotating each on its own axis.
//                        Crossing each other gives the gyroscope feel.
//   4. Velion sigil    — V wings + tiny core sphere + ring around it,
//                        all stroke, slowly rotating around Y.
//   5. HUD scan band   — horizontal bright band sweeping vertically.
//   6. Sweep beam      — vertical scanner crossing horizontally.
//
// All scaling/wiggle is applied as a single transform at the end so the
// whole hologram moves as one rigid body — no parallax artifacts between
// the wireframe and the sigil.
import SwiftUI

/// What the orb is currently doing. Drives motion, NOT color.
enum VelionMode: Equatable, Sendable {
    case idle
    case thinking
    case speaking(amplitude: Double)
}

struct VelionHologram: View {
    var size: CGFloat = 300
    var mode: VelionMode = .idle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let scale = scaleMultiplier(t: t)
            let xWiggle = lateralWiggle(t: t)
            let flicker = flickerOpacity(t: t)

            ZStack {
                outerGlow(t: t)
                wireSphere(t: t)
                centeredRings(t: t)
                sigilEnsemble(t: t)
                scanBand(t: t)
                sweepBeam(t: t)
            }
            .frame(width: size * 1.9, height: size * 1.9)
            .scaleEffect(scale)
            .offset(x: xWiggle)
            .opacity(flicker)
        }
    }

    // MARK: - Mode-driven motion

    private func scaleMultiplier(t: Double) -> CGFloat {
        switch mode {
        case .idle:
            return 1.0 + CGFloat(sin(t * 0.55)) * 0.006
        case .thinking:
            return 1.0 + CGFloat(sin(t * Double.pi)) * 0.05
        case .speaking(let amplitude):
            let clamped = max(0, min(1, amplitude))
            return 1.0 + CGFloat(clamped) * 0.12
        }
    }

    private func lateralWiggle(t: Double) -> CGFloat {
        switch mode {
        case .idle:
            return CGFloat(sin(t * 1.30)) * size * 0.008
        default:
            return 0
        }
    }

    private func flickerOpacity(t: Double) -> Double {
        let base = 0.94
        switch mode {
        case .idle:
            return base + sin(t * 8.7) * 0.025 + sin(t * 13.3 + 1.1) * 0.020
        case .thinking:
            return base + sin(t * 5.2) * 0.020 + sin(t * 11.1 + 0.7) * 0.015
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

    // MARK: - Outer glow

    private func outerGlow(t: Double) -> some View {
        let breath = (sin(t * 0.45) + 1) / 2
        let baseAlpha: Double = {
            switch mode {
            case .idle:        return 0.20
            case .thinking:    return 0.32
            case .speaking(let amp): return 0.22 + amp * 0.20
            }
        }()
        let alpha = baseAlpha + breath * 0.05
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(alpha),
                        Color.white.opacity(alpha * 0.30),
                        Color.white.opacity(0)
                    ],
                    center: .center,
                    startRadius: size * 0.30,
                    endRadius: size * 1.00
                )
            )
            .frame(width: size * 1.9, height: size * 1.9)
            .blur(radius: 26)
            .scaleEffect(1.0 + breath * 0.02)
    }

    // MARK: - Wire sphere (UNCHANGED — the "ball" that worked)

    private func wireSphere(t: Double) -> some View {
        let yawDeg = (t * (0.20 * rotationSpeedFactor())) * (180 / .pi)
        return ZStack {
            parallelsLayer()
            ForEach(0..<6, id: \.self) { i in
                let baseDeg = Double(i) * 30.0
                meridianLine()
                    .rotation3DEffect(
                        .degrees(baseDeg + yawDeg),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.55
                    )
            }
        }
    }

    private func parallelsLayer() -> some View {
        let lats: [Double] = [-50, -25, 0, 25, 50].map { $0 * .pi / 180 }
        return ZStack {
            ForEach(Array(lats.enumerated()), id: \.offset) { _, lat in
                let cosLat = cos(lat)
                let yOff = sin(lat) * size * 0.50
                Ellipse()
                    .stroke(silverStroke, lineWidth: 0.9)
                    .frame(width: size * cosLat, height: size * cosLat * 0.22)
                    .offset(y: yOff)
                    .blur(radius: 0.3)
            }
        }
    }

    private func meridianLine() -> some View {
        Ellipse()
            .stroke(silverStrokeSoft, lineWidth: 0.9)
            .frame(width: size * 0.12, height: size)
            .blur(radius: 0.3)
    }

    // MARK: - Centered rings (the actual added feature: more rings, centered)

    /// Three thin silver rings inside the wire sphere, each on a different
    /// plane and spinning on a different axis. They cross at the center,
    /// reading as a gyroscope or atomic-core structure suspended inside
    /// the wireframe ball — NOT as a single ring at the silhouette.
    private func centeredRings(t: Double) -> some View {
        let speed = rotationSpeedFactor()
        let r = size * 0.62

        return ZStack {
            // Ring A — equatorial-ish, tilted toward the viewer.
            ringPath(strokeWidth: 1.2, alpha: 0.85)
                .frame(width: r, height: r)
                .rotation3DEffect(
                    .degrees(72),
                    axis: (x: 1, y: 0, z: 0)
                )
                .rotationEffect(.radians(t * 0.55 * speed))
                .shadow(color: Color.white.opacity(0.35), radius: 3, x: 0, y: 0)

            // Ring B — almost frontal, spinning the opposite way.
            ringPath(strokeWidth: 1.0, alpha: 0.70)
                .frame(width: r, height: r)
                .rotation3DEffect(
                    .degrees(20),
                    axis: (x: 0, y: 1, z: 0)
                )
                .rotationEffect(.radians(-t * 0.40 * speed))
                .shadow(color: Color.white.opacity(0.30), radius: 3, x: 0, y: 0)

            // Ring C — diagonal axis, slowest, faintest.
            ringPath(strokeWidth: 0.9, alpha: 0.55)
                .frame(width: r, height: r)
                .rotation3DEffect(
                    .degrees(55),
                    axis: (x: 1, y: 1, z: 0)
                )
                .rotationEffect(.radians(t * 0.28 * speed))
                .shadow(color: Color.white.opacity(0.25), radius: 3, x: 0, y: 0)
        }
    }

    private func ringPath(strokeWidth: CGFloat, alpha: Double) -> some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [
                        Color.white.opacity(alpha),
                        Color.white.opacity(alpha * 0.20),
                        Color.white.opacity(alpha * 0.85),
                        Color.white.opacity(alpha * 0.20),
                        Color.white.opacity(alpha)
                    ],
                    center: .center
                ),
                lineWidth: strokeWidth
            )
            .blur(radius: 0.3)
    }

    // MARK: - Velion sigil (UNCHANGED — the original sigil with its own ring)

    private func sigilEnsemble(t: Double) -> some View {
        let rotDeg = (t * (0.10 + 0.10 * rotationSpeedFactor())) * (180 / .pi)
        return ZStack {
            // Static ring around the V — same as the original design that
            // worked. Smaller than the centered rings so it nests inside
            // them and gives the V a clear visual frame.
            Circle()
                .stroke(silverStroke, lineWidth: 1.1)
                .frame(width: size * 0.46, height: size * 0.46)
                .blur(radius: 0.3)
                .shadow(color: Color.white.opacity(0.45), radius: 4, x: 0, y: 0)

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
                    style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)
                )
                .frame(width: size * 0.32, height: size * 0.34)
                .shadow(color: Color.white.opacity(0.55), radius: 5, x: 0, y: 0)

            // Tiny core sphere above the V.
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.95), lineWidth: 1.0)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white,
                                Color.white.opacity(0.30),
                                Color.white.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.04
                        )
                    )
            }
            .frame(width: size * 0.07, height: size * 0.07)
            .offset(y: -size * 0.15)
            .shadow(color: Color.white.opacity(0.85), radius: 6, x: 0, y: 0)
        }
        .rotation3DEffect(
            .degrees(rotDeg),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.7
        )
    }

    // MARK: - HUD scans

    private func scanBand(t: Double) -> some View {
        let cycleSeconds: Double = {
            switch mode {
            case .idle:      return 3.5
            case .thinking:  return 1.8
            case .speaking:  return 2.5
            }
        }()
        let phase = t.truncatingRemainder(dividingBy: cycleSeconds) / cycleSeconds
        let yOffset = (phase - 0.5) * size * 1.3

        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.30),
                        Color.white.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size * 1.4, height: 6)
            .offset(y: yOffset)
            .blur(radius: 1.6)
            .blendMode(.plusLighter)
            .mask(Circle().frame(width: size * 1.05, height: size * 1.05))
    }

    private func sweepBeam(t: Double) -> some View {
        let cycleSeconds: Double = {
            switch mode {
            case .idle:      return 7.0
            case .thinking:  return 4.0
            case .speaking:  return 5.5
            }
        }()
        let phase = t.truncatingRemainder(dividingBy: cycleSeconds) / cycleSeconds
        let xOffset = (phase - 0.5) * size * 1.3

        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.45),
                        Color.white.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 4, height: size * 1.4)
            .offset(x: xOffset)
            .blur(radius: 1.2)
            .blendMode(.plusLighter)
            .mask(Circle().frame(width: size * 1.05, height: size * 1.05))
    }

    // MARK: - Stroke palettes

    private var silverStroke: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.85),
                Color.white.opacity(0.25),
                Color.white.opacity(0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var silverStrokeSoft: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.55),
                Color.white.opacity(0.15),
                Color.white.opacity(0.55)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - V wings shape

/// Approximation of the V/wings glyph from the VELION logo. Two symmetric
/// wing-shaped curves opening upward, sharing a bottom apex. Drawn as a
/// closed compound path so callers can either `fill` it (solid sigil) or
/// `stroke` it (holographic line art).
struct VWingsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let apexY = rect.maxY - h * 0.05
        let outerTopY = rect.minY + h * 0.10
        let innerTopY = rect.minY + h * 0.28

        // Right wing.
        path.move(to: CGPoint(x: cx, y: apexY))
        path.addCurve(
            to: CGPoint(x: cx + w * 0.45, y: outerTopY),
            control1: CGPoint(x: cx + w * 0.10, y: rect.midY - h * 0.10),
            control2: CGPoint(x: cx + w * 0.30, y: outerTopY + h * 0.10)
        )
        path.addCurve(
            to: CGPoint(x: cx + w * 0.18, y: innerTopY),
            control1: CGPoint(x: cx + w * 0.36, y: outerTopY - h * 0.04),
            control2: CGPoint(x: cx + w * 0.26, y: innerTopY - h * 0.05)
        )
        path.addCurve(
            to: CGPoint(x: cx, y: apexY),
            control1: CGPoint(x: cx + w * 0.10, y: rect.midY),
            control2: CGPoint(x: cx + w * 0.04, y: apexY - h * 0.10)
        )
        path.closeSubpath()

        // Left wing (mirror).
        path.move(to: CGPoint(x: cx, y: apexY))
        path.addCurve(
            to: CGPoint(x: cx - w * 0.45, y: outerTopY),
            control1: CGPoint(x: cx - w * 0.10, y: rect.midY - h * 0.10),
            control2: CGPoint(x: cx - w * 0.30, y: outerTopY + h * 0.10)
        )
        path.addCurve(
            to: CGPoint(x: cx - w * 0.18, y: innerTopY),
            control1: CGPoint(x: cx - w * 0.36, y: outerTopY - h * 0.04),
            control2: CGPoint(x: cx - w * 0.26, y: innerTopY - h * 0.05)
        )
        path.addCurve(
            to: CGPoint(x: cx, y: apexY),
            control1: CGPoint(x: cx - w * 0.10, y: rect.midY),
            control2: CGPoint(x: cx - w * 0.04, y: apexY - h * 0.10)
        )
        path.closeSubpath()

        return path
    }
}

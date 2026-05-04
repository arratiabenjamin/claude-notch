// CompactPanelView.swift
// The "Dynamic Island" pill rendered ON the MacBook's hardware notch.
// Shows only logo + counter; visual goal: looks like a seamless extension
// of the physical notch (solid black background, sharp clipping).
//
// Width and height are passed in from the live NotchInfo so we always match
// the real hardware measurements (no hardcoded magic numbers in the view).
import SwiftUI

struct CompactPanelView: View {
    @EnvironmentObject var store: SessionStore
    /// Notch height in points (typically 32-37). Drives logo sizing and overall frame.
    let notchHeight: CGFloat
    /// Notch width in points. The pill matches the notch exactly.
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Image("PanelLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: max(12, notchHeight - 14), height: max(12, notchHeight - 14))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(counter)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(width: notchWidth, height: notchHeight)
        // Solid black so the pill blends into the physical notch cutout.
        // Any translucency here would expose the menu-bar wallpaper and
        // break the "extension of the notch" illusion.
        .background(Color.black)
        // The hardware notch has rounded BOTTOM corners (the top is flush
        // against the bezel). Clip with matching radius so the pill silhouette
        // reads as one with the cutout.
        .clipShape(NotchPillShape(bottomCornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// "" when nothing to show, "<active>" when no recent sessions,
    /// "<active>·<recent>" otherwise. Tabular nums via `.monospacedDigit()`.
    private var counter: String {
        switch store.state {
        case .populated(let active, let recent):
            if active.isEmpty && recent.isEmpty { return "" }
            if recent.isEmpty { return "\(active.count)" }
            return "\(active.count)·\(recent.count)"
        default:
            return ""
        }
    }

    /// Yellow when something is `running`, green when there are idle actives,
    /// secondary otherwise. Mirrors the dot color logic in the expanded list.
    private var color: Color {
        switch store.state {
        case .populated(let active, _) where active.contains(where: { $0.status == .running }):
            return .yellow
        case .populated(let active, _) where !active.isEmpty:
            return .green
        case .populated(_, let recent) where !recent.isEmpty:
            return .secondary
        default:
            return .secondary
        }
    }

    private var accessibilityDescription: String {
        switch store.state {
        case .populated(let active, let recent):
            return "Claude Notch. \(active.count) active, \(recent.count) recent."
        case .empty:
            return "Claude Notch. No sessions."
        case .loading:
            return "Claude Notch. Loading."
        default:
            return "Claude Notch."
        }
    }
}

/// Shape that matches the silhouette of the MacBook hardware notch:
/// flat top edge (flush against the bezel) and rounded BOTTOM corners.
/// Without this, the panel renders sharp 90° corners at the bottom and
/// looks like a black brick taped onto the screen instead of an extension
/// of the cutout.
struct NotchPillShape: Shape {
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(bottomCornerRadius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

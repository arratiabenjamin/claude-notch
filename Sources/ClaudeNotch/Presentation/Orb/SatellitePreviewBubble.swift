// SatellitePreviewBubble.swift
// Floating glass card shown when the user hovers a satellite. Replaces
// the old single-line capsule that just said the session's display name.
//
// Layout:
//   - Title row: status dot + display name + duration (when known).
//   - "Tú:" line — last user prompt, 2 lines max.
//   - "Claude:" line — last assistant text reply, 3 lines max.
//
// The bubble is always anchored at the bottom-center of the orb stage, NOT
// at the satellite's screen position. Reasons:
//   • The satellite circles the orb at a constant orbit; the bubble would
//     otherwise jitter as the satellite drifts on its slot offset.
//   • A fixed slot keeps the layout calm and predictable.
import SwiftUI

struct SatellitePreviewBubble: View {
    let session: SessionState
    /// May be nil while the loader is in flight, or empty when the
    /// transcript yielded nothing useful.
    let preview: SessionPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow

            if let p = preview {
                if let user = p.lastUserPrompt, !user.isEmpty {
                    promptRow(label: "Tú", text: user, lineLimit: 2)
                }
                if let claude = p.lastAssistantText, !claude.isEmpty {
                    promptRow(label: "Claude", text: claude, lineLimit: 3)
                }
                if p.isEmpty {
                    placeholderText("Sin actividad reciente.")
                }
            } else {
                placeholderText("Cargando…")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.40), radius: 8, x: 0, y: 4)
    }

    // MARK: - Subviews

    private var titleRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusDotColor.opacity(0.7), radius: 3)
            Text(session.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let duration = formattedDuration {
                Text(duration)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func promptRow(label: String, text: String, lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func placeholderText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .italic()
    }

    // MARK: - Derived

    private var statusDotColor: Color {
        switch session.status {
        case .running:           return Color(red: 1.00, green: 0.78, blue: 0.30) // ámbar
        case .idle:              return Color(red: 0.30, green: 0.85, blue: 1.00) // cian
        case .ended, .unknown:   return Color(white: 0.55)
        }
    }

    /// Last turn duration as "Xs" or "Xm Ys" for the title row. Uses the
    /// payload's `lastTurnDurationS` so it matches the same number the
    /// notification + avatar see.
    private var formattedDuration: String? {
        guard let secs = session.lastTurnDurationS, secs > 0 else { return nil }
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        let rest = secs % 60
        return rest == 0 ? "\(mins)m" : "\(mins)m \(rest)s"
    }
}

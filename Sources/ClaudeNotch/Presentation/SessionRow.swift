// SessionRow.swift
// One row of the panel — status dot + project label + relative time meta.
// Wrapped in a TimelineView so the relative time refreshes every second
// without re-decoding the JSON.
import SwiftUI
import AppKit

struct SessionRow: View {
    let session: SessionState
    @EnvironmentObject var store: SessionStore
    @State private var hovering = false

    private var isExpanded: Bool { store.expandedSessionId == session.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                HStack(spacing: 8) {
                    StatusDot(status: session.status)
                    Text(session.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(metaText(at: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    chevron
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(rowFillOpacity))
                )
                .onHover { hovering = $0 }
                .onTapGesture {
                    store.expandedSessionId = isExpanded ? nil : session.id
                }
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.15), value: isExpanded)
                .contextMenu {
                    Button(isExpanded ? "Collapse" : "Expand") {
                        store.expandedSessionId = isExpanded ? nil : session.id
                    }
                    Divider()
                    Button("Copy session ID") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(session.id, forType: .string)
                    }
                    if let cwd = session.cwd, !cwd.isEmpty {
                        Button("Copy working directory") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(cwd, forType: .string)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel(at: context.date)))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text(isExpanded ? "Collapse details" : "Expand for transcript and actions"))
            }

            if isExpanded {
                ExpandedSessionView(session: session)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isExpanded)
    }

    private var rowFillOpacity: Double {
        if isExpanded { return 0.10 }
        if hovering { return 0.06 }
        return 0
    }

    @ViewBuilder
    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .opacity(hovering || isExpanded ? 1 : 0.55)
    }

    // MARK: - Meta text

    private func metaText(at now: Date) -> String {
        switch session.status {
        case .running:
            if let started = session.promptStartedAt ?? session.startedAt {
                return "running · " + Self.relative(from: started, to: now)
            }
            return "running"
        case .idle:
            if let finished = session.lastTurnFinishedAt {
                let ago = Self.relative(from: finished, to: now)
                if let dur = session.lastTurnDurationS {
                    return "\(dur)s · \(ago)"
                }
                return ago
            }
            return "idle"
        case .ended:
            if let endedAt = session.endedAt {
                return Self.relative(from: endedAt, to: now)
            }
            return "ended"
        case .unknown:
            return "—"
        }
    }

    private func accessibilityLabel(at now: Date) -> String {
        let statusText: String = {
            switch session.status {
            case .running: return "running"
            case .idle:    return "idle"
            case .ended:   return "ended"
            case .unknown: return "unknown status"
            }
        }()
        return "Session \(session.displayName), \(statusText), \(metaText(at: now))"
    }

    private static func relative(from date: Date, to now: Date) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        if delta < 60 {
            return "\(Int(delta))s"
        }
        if delta < 3600 {
            return "\(Int(delta / 60))m"
        }
        if delta < 86_400 {
            return "\(Int(delta / 3600))h"
        }
        return "\(Int(delta / 86_400))d"
    }
}

// MARK: - StatusDot

struct StatusDot: View {
    let status: SessionState.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: glowColor, radius: 3)
    }

    private var color: Color {
        switch status {
        case .running: return .yellow
        case .idle:    return .green
        case .ended:   return .secondary
        case .unknown: return .gray
        }
    }

    private var glowColor: Color {
        switch status {
        case .running: return .yellow.opacity(0.5)
        case .idle:    return .green.opacity(0.25)
        default:       return .clear
        }
    }
}

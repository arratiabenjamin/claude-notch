// SessionListView.swift
// Root SwiftUI view hosted inside FloatingPanel.
// Reads UIState from SessionStore and branches into one of:
//   - skeleton/loading
//   - empty / fileMissing / dirMissing / error states (via EmptyStateView)
//   - populated (ACTIVE + RECENTLY COMPLETED sections)
import SwiftUI
import AppKit

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("use_notch_mode") private var useNotchMode: Bool = true
    @AppStorage("use_notch_mode_explicitly_set") private var useNotchModeExplicitlySet: Bool = false

    /// Hardware notch present? Drives whether to show the mode-toggle button.
    /// On non-notch Macs there's no second mode to toggle to.
    private var hasNotchHardware: Bool {
        (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
    }

    var body: some View {
        ZStack {
            // Base: translucent HUD-style vibrancy. `.hudWindow` is noticeably
            // more see-through than `.popover` and gives the wallpaper-bleed
            // that makes "liquid glass" read as glass instead of grey paint.
            VisualEffectBackground(material: .hudWindow, cornerRadius: 18)

            // Subtle vertical tint — top is a touch lighter, bottom a touch
            // darker. Gives the surface curvature without a heavy gradient.
            LinearGradient(
                colors: [
                    Color.white.opacity(0.10),
                    Color.white.opacity(0.02),
                    Color.black.opacity(0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            // Inner highlight stroke — a thin bright line on the top edge
            // catches the eye like a beveled glass rim. Doubled with a fainter
            // outer stroke for a soft outline against the wallpaper.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 12) {
                header
                content
            }
            .padding(16)
            .frame(width: 320, alignment: .topLeading)
        }
        .frame(width: 320)
        .frame(maxHeight: 480)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image("PanelLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text("Claude Code")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            counters
            if hasNotchHardware {
                modeToggleButton
            }
        }
    }

    /// Toggle between notch mode (Dynamic Island pill) and free-floating window.
    /// Same effect as the Settings toggle — flips `use_notch_mode` and posts
    /// `.claudeNotchModeDidChange`, which AppController re-applies.
    @ViewBuilder
    private var modeToggleButton: some View {
        Button {
            useNotchMode.toggle()
            useNotchModeExplicitlySet = true
            NotificationCenter.default.post(name: .claudeNotchModeDidChange, object: nil)
        } label: {
            Image(systemName: useNotchMode
                  ? "macwindow"                            // notch → detach to window
                  : "rectangle.center.inset.filled")       // floating → pin to notch
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(useNotchMode ? "Detach to floating window" : "Pin to notch")
    }

    @ViewBuilder
    private var counters: some View {
        switch store.state {
        case .populated(let active):
            Text("\(active.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        default:
            EmptyView()
        }
    }

    // MARK: - Content branching

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            VStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        case .empty:
            EmptyStateView(
                title: "No active sessions",
                subtitle: "Start a Claude Code session to see it here."
            )

        case .fileMissing:
            EmptyStateView(
                title: "Waiting for state file",
                subtitle: "~/.claude/active-sessions.json not found.\nRun claude-code-notifier first."
            )

        case .dirMissing:
            EmptyStateView(
                title: "~/.claude/ not found",
                subtitle: "Install Claude Code, then run a session."
            )

        case .decodeError:
            EmptyStateView(
                title: "Stale (read error)",
                subtitle: "State file is being written. Retrying…"
            )

        case .sizeLimitExceeded:
            EmptyStateView(
                title: "State file too large",
                subtitle: "Will resume when file shrinks below 1 MB."
            )

        case .schemaMismatch(let v):
            EmptyStateView(
                title: "Unsupported schema v\(v)",
                subtitle: "Update Claude Notch to read this state file."
            )

        case .populated(let active):
            populatedContent(active: active)
        }
    }

    @ViewBuilder
    private func populatedContent(active: [SessionState]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(title: "ACTIVE", rows: active)
            }
        }
    }

    @ViewBuilder
    private func section(title: String, rows: [SessionState]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)

            ForEach(rows) { session in
                SessionRow(session: session)
            }
        }
    }
}

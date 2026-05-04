// ExpandedSessionView.swift
// Inline detail shown directly under a SessionRow when the user clicks it.
// Three blocks: transcript snippet, meta line, action buttons.
//
// As of v1.3 the snippet is driven by a `TranscriptWatcher` that subscribes
// to FS events on the transcript file (no more 5s polling). The same watcher
// keeps a low-frequency safety timer for cases where the FD source goes
// silent (file rotation, sleep/wake, etc.).
import SwiftUI
import AppKit

struct ExpandedSessionView: View {
    let session: SessionState

    @StateObject private var watcher = TranscriptWatcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            snippetBlock
            Divider()
                .opacity(0.4)
            metaRow
            buttonsRow
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .padding(.top, 2)
        .padding(.horizontal, 4)
        .task(id: session.transcriptPath) {
            await watcher.start(path: session.transcriptPath ?? "")
        }
        .onDisappear {
            watcher.stop()
        }
    }

    // MARK: - Snippet

    @ViewBuilder
    private var snippetBlock: some View {
        switch watcher.snippet {
        case .loading:
            Text("Loading transcript…")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)

        case .ready(let text, _, _):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .empty:
            Text("Transcript is empty.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .italic()

        case .noText:
            Text("(thinking — tool calls in flight)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .italic()

        case .fileMissing:
            Text(session.transcriptPath == nil
                 ? "No transcript path recorded for this session."
                 : "Transcript file not found.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .italic()

        case .error(let msg):
            Text("Could not read transcript: \(msg)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .italic()
                .lineLimit(2)
        }
    }

    // MARK: - Meta row

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 6) {
            if let cwd = session.cwd, !cwd.isEmpty {
                Text(shorten(cwd))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(cwd)
            }
            if let pid = session.pid {
                Text("·").foregroundStyle(.tertiary)
                Text("pid \(pid)").monospacedDigit()
            }
            if let path = session.transcriptPath, let kb = transcriptKB(path: path) {
                Text("·").foregroundStyle(.tertiary)
                Text("\(kb) KB").monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttonsRow: some View {
        HStack(spacing: 6) {
            ActionButton(label: "Copy ID") {
                copyToPasteboard(session.id)
            }
            if let cwd = session.cwd, !cwd.isEmpty {
                ActionButton(label: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: cwd)]
                    )
                }
            }
            if let path = session.transcriptPath, !path.isEmpty {
                ActionButton(label: "Open transcript") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
            if let cwd = session.cwd, !cwd.isEmpty {
                ActionButton(label: "Terminal") {
                    _ = TerminalLauncher.openOrFocus(cwd: cwd)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func transcriptKB(path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return nil }
        return max(1, size / 1024)
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

// MARK: - ActionButton (small inline button, matches notch chrome)

private struct ActionButton: View {
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.18 : 0.10))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

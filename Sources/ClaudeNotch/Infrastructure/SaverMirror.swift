// SaverMirror.swift
// Re-publishes the live session state to /tmp so the .saver bundle can read
// it from inside its sandboxed legacyScreenSaver host process.
//
// Why /tmp?
// macOS 14+ runs ScreenSaverEngine and legacyScreenSaver under a tight
// sandbox profile that blocks reads of arbitrary user files (including
// ~/.claude/active-sessions.json). /tmp is one of the few paths reliably
// accessible from inside that sandbox without entitlements.
//
// Format mirrors the producer's envelope (version + sessions dict keyed by
// id) so the saver can decode it with the same JSONLoader used by the app —
// no new schema, no new serializer, no drift.
import Foundation

enum SaverMirror {
    static let path: String = "/tmp/com.velion.claude-notch.sessions.json"

    /// Atomically write a snapshot of `sessions` to the mirror path. Best-effort:
    /// any failure is swallowed because the mirror is convenience, not source
    /// of truth — the saver simply shows fewer satellites until the next tick.
    static func write(_ sessions: [SessionState]) {
        let envelope = MirrorEnvelope(
            version: 1,
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, MirrorSession.from($0)) })
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Wire types
    // Keys must match what JSONLoader.PartialSession expects so the saver can
    // decode the file with no special handling.

    private struct MirrorEnvelope: Encodable {
        let version: Int
        let sessions: [String: MirrorSession]
    }

    private struct MirrorSession: Encodable {
        let session_id: String?
        let pid: Int?
        let cwd: String?
        let project_label: String?
        let started_at: String?
        let prompt_started_at: String?
        let last_turn_duration_s: Int?
        let last_turn_finished_at: String?
        let ended_at: String?
        let status: String?
        let last_result: String?
        let transcript_path: String?

        static func from(_ s: SessionState) -> MirrorSession {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return MirrorSession(
                session_id: s.id,
                pid: s.pid,
                cwd: s.cwd,
                project_label: s.projectLabel,
                started_at: s.startedAt.map(f.string(from:)),
                prompt_started_at: s.promptStartedAt.map(f.string(from:)),
                last_turn_duration_s: s.lastTurnDurationS,
                last_turn_finished_at: s.lastTurnFinishedAt.map(f.string(from:)),
                ended_at: s.endedAt.map(f.string(from:)),
                status: SaverMirror.statusString(s.status),
                last_result: s.lastResult,
                transcript_path: s.transcriptPath
            )
        }
    }

    private static func statusString(_ s: SessionState.Status) -> String? {
        switch s {
        case .running: return "running"
        case .idle:    return "idle"
        case .ended:   return "ended"
        case .unknown: return nil
        }
    }
}

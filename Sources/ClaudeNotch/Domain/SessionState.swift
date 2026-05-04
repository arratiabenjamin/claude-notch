// SessionState.swift
// Pure value type that models a single Claude Code session as read from
// ~/.claude/active-sessions.json. All inner fields are optional because the
// producer (claude-code-notifier hooks) may omit them between writes.
// See discoveries: schema-quirks (#740) — outer dict key is canonical id.
import Foundation

struct SessionState: Identifiable, Hashable, Sendable {
    /// Canonical identifier — outer dict key from active-sessions.json
    /// (NOT the inner `session_id`, which may be missing).
    let id: String
    /// Friendly project label. Resolution order:
    /// 1. inner `project_label` field
    /// 2. basename of `cwd`
    /// 3. first 8 chars of `id` (per Discovery #740 fallback)
    let projectLabel: String
    let cwd: String?
    let pid: Int?
    let status: Status
    let startedAt: Date?
    let promptStartedAt: Date?
    let lastTurnDurationS: Int?
    let lastTurnFinishedAt: Date?
    let endedAt: Date?
    let lastResult: String?

    enum Status: String, Sendable, Hashable {
        case running
        case idle
        case ended
        case unknown

        init(rawString: String?) {
            switch rawString {
            case "running": self = .running
            case "idle":    self = .idle
            case "ended":   self = .ended
            default:        self = .unknown
            }
        }
    }
}

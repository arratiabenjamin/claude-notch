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
    /// Friendly project label. Resolution order (computed at decode time):
    /// 1. inner `project_label` field
    /// 2. basename of `cwd`
    /// 3. first 8 chars of `id` (per Discovery #740 fallback)
    /// NOTE: prefer `displayName` for UI. `projectLabel` stays as the
    /// secondary fallback so a renamed session falls back gracefully if
    /// the user clears the rename later.
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
    /// Absolute path to the JSONL transcript on disk, when the producer recorded it.
    /// Optional because older state files / partial writes may omit it.
    let transcriptPath: String?
    /// User-assigned name from Claude Code's `/rename` command. nil if never
    /// renamed (or if the per-pid session file is missing). Sourced from
    /// `~/.claude/sessions/<pid>.json` via SessionNameLoader.
    let customName: String?

    /// What to render in the UI. Resolution order:
    /// 1. `customName` (the `/rename` value) if set & non-empty — highest priority
    /// 2. `projectLabel` (already resolved through label/cwd basename fallback chain)
    /// 3. first 8 chars of `id` as last-resort
    /// `projectLabel` is normally non-empty (the loader fills its own fallback)
    /// so the third branch is just paranoia.
    var displayName: String {
        if let name = customName, !name.isEmpty {
            return name
        }
        if !projectLabel.isEmpty {
            return projectLabel
        }
        return String(id.prefix(8))
    }

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

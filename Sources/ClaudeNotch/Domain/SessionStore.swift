// SessionStore.swift
// MainActor-isolated observable that owns the UI state machine for the panel.
// The watcher publishes raw Data + errors; ingest() turns them into UIState.
import Foundation
import Combine

/// 8-state UI machine driving SessionListView.
enum UIState: Equatable {
    case loading
    case empty
    case populated(active: [SessionState])
    case fileMissing
    case dirMissing
    case decodeError(String)
    case sizeLimitExceeded
    case schemaMismatch(version: Int)
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var state: UIState = .loading

    /// Which row is currently expanded in the panel. `nil` means none.
    /// Lives here (not in a separate view-state object) because the row
    /// expansion is a single-selection invariant tied to the data the store
    /// already publishes. Setting this to a session id collapses any other.
    @Published var expandedSessionId: String?

    /// Last successful populated render — kept so we can degrade gracefully
    /// when the file is mid-write (decode error) without flashing empty state.
    private var lastSuccessful: [SessionState]?

    /// Last raw bytes successfully ingested. Cached so we can re-decode with
    /// an updated `customNames` map when `~/.claude/sessions/` changes (live
    /// `/rename` updates) without waiting for active-sessions.json to tick.
    private var lastIngestedData: Data?

    /// Snapshot of the most recent session list (active + recent merged), used
    /// by NotificationService to detect running -> idle/ended transitions.
    private var lastSessionsForNotify: [SessionState] = []

    /// Session IDs the user explicitly ended via the "End session" button.
    /// We hide these from BOTH active and recent lists immediately — the user
    /// just told us they're done with the row, ferrying it into RECENTLY
    /// COMPLETED is just visual noise. Cleared lazily once the notifier has
    /// dropped the id from active-sessions.json (so the set never grows
    /// unbounded across sessions).
    private var manuallyEndedIds: Set<String> = []

    /// Stable session-id → spatial-slot mapping. Slots are assigned at first
    /// sight and held until the session goes away, so the user's brain (and
    /// the spatial audio in Phase 5) get a consistent location per session.
    let slots = SpatialSlotManager()

    /// Avatar speaker that announces transitions (running → ended). The store
    /// owns the trigger logic; the speaker owns the queue + audio plumbing.
    /// Wired by AppController at startup.
    var speaker: AvatarSpeaker?

    /// Apply a fresh data payload from the watcher. `data == nil` indicates the
    /// file was absent. `error` is non-nil when the watcher itself failed to
    /// read (e.g., directory missing).
    func ingest(_ data: Data?, error: Error?) {
        // File-system level signals first.
        if let error {
            state = mapWatcherError(error)
            return
        }

        guard let data else {
            state = .fileMissing
            return
        }

        // Decode path.
        do {
            // Pull the latest /rename names every tick. With ~6 small files in
            // production this is trivial; if it grows, cache by directory mtime.
            let customNames = SessionNameLoader.loadAll()
            let sessions = try JSONLoader.decode(from: data, customNames: customNames)
            // Cache the bytes BEFORE apply so a `refreshNamesAndReingest`
            // racing with a real ingest finds a consistent snapshot.
            lastIngestedData = data
            apply(sessions: sessions)
        } catch let JSONLoaderError.schemaMismatch(version) {
            state = .schemaMismatch(version: version)
        } catch JSONLoaderError.sizeLimitExceeded {
            state = .sizeLimitExceeded
        } catch let JSONLoaderError.decode(message) {
            // Decode errors are typically transient (mid-write atomic rename).
            // Keep the last successful render visible so the panel does not
            // flicker; just transition to .decodeError. The next FSEvent will
            // re-attempt and most likely recover.
            if let last = lastSuccessful {
                state = .populated(active: last)
            } else {
                state = .decodeError(message)
            }
        } catch {
            state = .decodeError(String(describing: error))
        }
    }

    /// Hide a session from the panel right now. Called by the "End session"
    /// button before sending SIGINT — the notifier will eventually update
    /// active-sessions.json, but we don't want the row to flash through
    /// RECENTLY COMPLETED on the way out. The id is cleared from this set
    /// once the producer has dropped it from the file payload entirely.
    func markManuallyEnded(id: String) {
        manuallyEndedIds.insert(id)
        if expandedSessionId == id { expandedSessionId = nil }
        // Re-derive immediately from cached bytes so the UI updates without
        // waiting for the next FSEvent.
        refreshNamesAndReingest()
    }

    /// Re-load `customNames` from `~/.claude/sessions/` and re-decode the
    /// most recent active-sessions.json bytes. No-op if we never ingested
    /// any data yet. Triggered by the DirectoryWatcher on `/rename` events
    /// so the panel updates instantly instead of waiting for the next
    /// active-sessions.json tick.
    func refreshNamesAndReingest() {
        guard let data = lastIngestedData else { return }
        let customNames = SessionNameLoader.loadAll()
        guard let sessions = try? JSONLoader.decode(from: data, customNames: customNames) else {
            // Cached bytes failed to re-decode — leave existing UI alone;
            // the next real watcher tick will recover us.
            return
        }
        apply(sessions: sessions)
    }

    // MARK: - Pure derive

    private func apply(sessions: [SessionState]) {
        // Differentiate duplicate fallback labels (v1.3, Feature #2). Sessions
        // the user explicitly named via `/rename` (i.e. `customName != nil`)
        // are never disambiguated — that's the user's intent.
        let disambiguated = SessionStore.disambiguate(sessions)

        // Drop any manually-ended ids that are no longer present in the
        // payload at all — the notifier has caught up, we can stop tracking.
        let presentIds = Set(disambiguated.map { $0.id })
        manuallyEndedIds.formIntersection(presentIds)

        let active = disambiguated
            .filter { $0.status == .running || $0.status == .idle }
            .filter { !manuallyEndedIds.contains($0.id) }
            .sorted(by: SessionStore.activeOrdering)

        // Assign new sessions to slots; release slots whose sessions vanished.
        for s in active { slots.assign(s.id) }
        slots.prune(activeIds: Set(active.map { $0.id }))

        if active.isEmpty {
            state = .empty
            lastSuccessful = []
            pruneExpansion(in: [])
        } else {
            state = .populated(active: active)
            lastSuccessful = active
            pruneExpansion(in: active)
        }

        // Fire notifications based on running -> idle/ended transitions.
        // We pass the FULL set the producer reported (not just active) so
        // NotificationService sees the same `lastTurnDurationS` it did before.
        let previous = lastSessionsForNotify
        lastSessionsForNotify = sessions
        Task { [weak self] in
            await NotificationService.shared.evaluate(previous: previous, current: sessions)
            _ = self
        }

        // Announce sessions that just transitioned to .ended via the avatar.
        // Capture slots BEFORE prune so a session that ends + disappears
        // in the same tick still has a known direction for spatial audio.
        announceTransitions(previous: previous, current: sessions)
    }

    /// Detect transitions worth announcing on the avatar:
    ///   • running/idle → ended (explicit close)
    ///   • running/idle → vanished from payload (SIGINT close where the
    ///     producer removes the entry instead of writing status=ended)
    ///   • running → idle for turns LONGER than `notify_threshold_s`
    ///     (Claude finished a long task and is back to waiting; the avatar
    ///     announces what happened so the user doesn't have to switch
    ///     contexts to find out)
    ///
    /// Short turns (under threshold) are intentionally silent — speaking
    /// every five seconds during a quick back-and-forth would be torture.
    /// `previous` is the last full snapshot we saw; `current` is the new
    /// snapshot we just decoded.
    private func announceTransitions(previous: [SessionState], current: [SessionState]) {
        guard let speaker else { return }
        let prevById = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentIds = Set(current.map { $0.id })

        // Case A: explicit ended transition.
        for s in current {
            guard s.status == .ended else { continue }
            guard let prev = prevById[s.id], prev.status != .ended else { continue }
            announce(session: s, kind: .ended)
        }

        // Case B: silent vanish — a previously running/idle session is no
        // longer in the payload at all.
        for prev in previous {
            guard prev.status == .running || prev.status == .idle else { continue }
            guard !currentIds.contains(prev.id) else { continue }
            announce(session: prev, kind: .ended)
        }

        // Case C: long-turn completion (running → idle, duration ≥ threshold).
        let threshold = UserDefaults.standard.double(forKey: "notify_threshold_s")
        let effectiveThreshold = threshold > 0 ? threshold : 90.0
        for s in current {
            guard s.status == .idle else { continue }
            guard let prev = prevById[s.id], prev.status == .running else { continue }
            guard let dur = s.lastTurnDurationS, Double(dur) >= effectiveThreshold else { continue }
            announce(session: s, kind: .turnCompleted)
        }
    }

    /// What kind of announcement we're dispatching. Drives whether the
    /// avatar uses the close-of-session phrasing or the turn-finished one.
    private enum AnnouncementKind {
        case ended
        case turnCompleted
    }

    /// Resolve slot, kick off the summarizer, and enqueue the utterance.
    /// Captures the slot synchronously so a prune that lands during the
    /// async summary still has a stable direction for spatial audio.
    ///
    /// Name prefix is added ONLY when there's another session already in
    /// the same slot — the audio direction alone identifies the session
    /// when it's solo, so prefixing every announcement was redundant noise
    /// (and also doubled up with fallback summaries that already include
    /// the name).
    private func announce(session s: SessionState, kind: AnnouncementKind) {
        guard let speaker else { return }
        let slot = slots.assignments[s.id] ?? slots.assign(s.id)
        let needsPrefix = slots.ids(in: slot).filter({ $0 != s.id }).count >= 1
        let path = s.transcriptPath
        let name = s.displayName
        let id = s.id
        let duration: Double? = {
            switch kind {
            case .ended:
                guard let started = s.startedAt else { return nil }
                let end = s.endedAt ?? Date()
                let interval = end.timeIntervalSince(started)
                return interval > 0 ? interval : nil
            case .turnCompleted:
                return s.lastTurnDurationS.map(Double.init)
            }
        }()
        Task { [weak speaker] in
            let summary = await TranscriptSummarizer.summarize(
                transcriptPath: path,
                sessionName: name,
                kind: kind == .turnCompleted ? .turn : .session,
                durationSeconds: duration
            )
            // Only strip a leading name when we're about to re-prefix it.
            // If we're not prefixing (single session in slot), leave the
            // summary intact — the fallback line includes the name on
            // purpose so the user knows which one ended.
            let final: String
            if needsPrefix {
                let stripped = stripLeadingName(summary, name: name)
                final = "\(name). \(stripped)"
            } else {
                final = summary
            }
            await MainActor.run {
                speaker?.enqueue(
                    text: final,
                    slot: slot,
                    sessionId: id
                )
            }
        }
    }

    /// Remove a leading "Name " or "Name." prefix from an already-summary
    /// string so we never end up with double-prefixed announcements.
    private func stripLeadingName(_ text: String, name: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lowerName = name.lowercased()
        let lowerText = trimmed.lowercased()
        guard lowerText.hasPrefix(lowerName) else { return trimmed }
        let dropped = trimmed.dropFirst(name.count)
        // Skip a separator char if there is one (".", " ", ":", etc).
        let withoutSep = dropped.drop { ".:, ".contains($0) }
        return String(withoutSep).trimmingCharacters(in: .whitespaces)
    }

    /// Drop the expanded id if it is not in the visible set.
    private func pruneExpansion(in visible: [SessionState]) {
        guard let id = expandedSessionId else { return }
        if !visible.contains(where: { $0.id == id }) {
            expandedSessionId = nil
        }
    }

    /// Differentiate sessions that share a fallback display label.
    ///
    /// Rules:
    ///   - Sessions with a non-empty `customName` are NEVER touched. The user
    ///     chose that name via `/rename`; if two sessions happen to share it,
    ///     that's their problem.
    ///   - Sessions whose `displayName` (from project_label / cwd basename
    ///     fallback) collides with another get a `displayNameOverride` set:
    ///       1. If the parent dir basename of `cwd` differs across the group,
    ///          use `"<base> · <parent>"`.
    ///       2. Otherwise (same `cwd` parent, or `cwd` missing), append
    ///          `" · pid:<pid>"` if the pid is known, else `" · <id8>"`.
    ///
    /// Pure function over the input array — order is preserved.
    static func disambiguate(_ sessions: [SessionState]) -> [SessionState] {
        // Group by current displayName, but only consider sessions WITHOUT
        // a customName (renamed sessions are sacred — see rules above).
        var groups: [String: [Int]] = [:]
        for (i, s) in sessions.enumerated() {
            // Skip user-renamed sessions outright.
            if let name = s.customName, !name.isEmpty { continue }
            groups[s.displayName, default: []].append(i)
        }

        var out = sessions
        for (_, indices) in groups where indices.count > 1 {
            // Step 1: try parent-dir basename to differentiate.
            let parentBasenames: [String?] = indices.map { idx in
                guard let cwd = sessions[idx].cwd, !cwd.isEmpty else { return nil }
                let parent = (cwd as NSString).deletingLastPathComponent
                let parentBase = (parent as NSString).lastPathComponent
                return parentBase.isEmpty ? nil : parentBase
            }
            let uniqueParents = Set(parentBasenames.compactMap { $0 })
            let parentsHelp = uniqueParents.count == indices.count &&
                              parentBasenames.allSatisfy { $0 != nil }

            for (k, idx) in indices.enumerated() {
                let original = out[idx].displayName
                if parentsHelp, let parent = parentBasenames[k] {
                    out[idx].displayNameOverride = "\(original) · \(parent)"
                } else if let pid = out[idx].pid {
                    out[idx].displayNameOverride = "\(original) · pid:\(pid)"
                } else {
                    let short = String(out[idx].id.prefix(8))
                    out[idx].displayNameOverride = "\(original) · \(short)"
                }
            }
        }
        return out
    }

    /// Ordering rule: running first (newest activity first), then idle (newest finish first).
    private static func activeOrdering(_ a: SessionState, _ b: SessionState) -> Bool {
        if a.status != b.status {
            // running before idle
            return a.status == .running && b.status == .idle
        }
        // Both same status — prefer most-recent activity.
        let aTime = a.promptStartedAt ?? a.lastTurnFinishedAt ?? a.startedAt ?? .distantPast
        let bTime = b.promptStartedAt ?? b.lastTurnFinishedAt ?? b.startedAt ?? .distantPast
        return aTime > bTime
    }

    private func mapWatcherError(_ error: Error) -> UIState {
        let nsError = error as NSError
        // POSIX ENOENT / NSFileReadNoSuchFile family
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .fileMissing
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 2 /* ENOENT */ {
            return .fileMissing
        }
        // Last resort — surface as decode error so user knows something is up.
        return .decodeError(nsError.localizedDescription)
    }
}

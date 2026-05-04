// SessionStore.swift
// MainActor-isolated observable that owns the UI state machine for the panel.
// The watcher publishes raw Data + errors; ingest() turns them into UIState.
import Foundation
import Combine

/// 8-state UI machine driving SessionListView.
enum UIState: Equatable {
    case loading
    case empty
    case populated(active: [SessionState], recent: [SessionState])
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
    private var lastSuccessful: (active: [SessionState], recent: [SessionState])?

    /// Snapshot of the most recent session list (active + recent merged), used
    /// by NotificationService to detect running -> idle/ended transitions.
    private var lastSessionsForNotify: [SessionState] = []

    /// Cap on RECENTLY COMPLETED rows; overflow is silent for v1.0.
    private static let recentCap = 5

    /// Window of "recent" — only sessions that ended within this duration are
    /// considered for the RECENT section. The producer already prunes >1h.
    private static let recentWindow: TimeInterval = 24 * 60 * 60 // 24h

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
            let sessions = try JSONLoader.decode(from: data)
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
                state = .populated(active: last.active, recent: last.recent)
            } else {
                state = .decodeError(message)
            }
        } catch {
            state = .decodeError(String(describing: error))
        }
    }

    // MARK: - Pure derive

    private func apply(sessions: [SessionState]) {
        let now = Date()
        let active = sessions
            .filter { $0.status == .running || $0.status == .idle }
            .sorted(by: SessionStore.activeOrdering)

        let recent = sessions
            .filter { s in
                guard s.status == .ended, let endedAt = s.endedAt else { return false }
                return now.timeIntervalSince(endedAt) <= SessionStore.recentWindow
            }
            .sorted { (a, b) in
                let ai = a.endedAt ?? .distantPast
                let bi = b.endedAt ?? .distantPast
                return ai > bi
            }
            .prefix(SessionStore.recentCap)

        let recentArray = Array(recent)

        if active.isEmpty && recentArray.isEmpty {
            state = .empty
            lastSuccessful = ([], [])
            // Collapse expansion if the expanded session is gone.
            pruneExpansion(in: [])
        } else {
            state = .populated(active: active, recent: recentArray)
            lastSuccessful = (active, recentArray)
            pruneExpansion(in: active + recentArray)
        }

        // Fire notifications based on running -> idle/ended transitions.
        // We pass the FULL set the producer reported (not just active) so
        // NotificationService sees the same `lastTurnDurationS` it did before.
        let previous = lastSessionsForNotify
        lastSessionsForNotify = sessions
        Task { [weak self] in
            await NotificationService.shared.evaluate(previous: previous, current: sessions)
            _ = self // capture-list noop to keep ARC happy without retain.
        }
    }

    /// Drop the expanded id if it is not in the visible set.
    private func pruneExpansion(in visible: [SessionState]) {
        guard let id = expandedSessionId else { return }
        if !visible.contains(where: { $0.id == id }) {
            expandedSessionId = nil
        }
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

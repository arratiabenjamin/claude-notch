// NotificationService.swift
// Posts a local UserNotification when a Claude turn finishes that took longer
// than the user's threshold (default 90s) OR when there are still other
// active sessions in flight (multi-session juggling cue).
//
// We only fire on the running -> idle / running -> ended transition. New
// sessions appearing or sessions disappearing do NOT notify.
import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    // MARK: - Tunables

    /// UserDefaults key for the duration threshold (seconds).
    /// Read via `UserDefaults.standard.double(forKey:)` — 0 means "use default".
    private static let thresholdKey = "notify_threshold_s"
    private static let defaultThresholdSeconds: Double = 90

    /// Cooldown per session: avoid double-notifying if the watcher emits two
    /// consecutive ticks for the same transition (FSEvents + safety poll).
    private static let dedupeWindow: TimeInterval = 5

    // MARK: - State

    private var hasRequestedAuthorization = false
    private var authorizationGranted = false
    private var lastNotifiedAt: [String: Date] = [:]

    // MARK: - Authorization

    /// Idempotent. Safe to call multiple times — the system caches the answer.
    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorizationGranted = granted
        } catch {
            authorizationGranted = false
        }
    }

    // MARK: - Evaluate transitions

    /// Compare the previous and current snapshots and post a notification if
    /// the transition matches the long-turn / multi-session rule.
    func evaluate(previous: [SessionState], current: [SessionState]) async {
        // Build dictionaries by canonical id.
        var prevById: [String: SessionState] = [:]
        for s in previous { prevById[s.id] = s }
        var currById: [String: SessionState] = [:]
        for s in current { currById[s.id] = s }

        let threshold = effectiveThreshold()
        let activeCount = current
            .filter { $0.status == .running || $0.status == .idle }
            .count

        for (id, curr) in currById {
            guard let prev = prevById[id] else { continue }
            let justEnded = prev.status == .running &&
                            (curr.status == .idle || curr.status == .ended)
            guard justEnded else { continue }

            let duration = Double(curr.lastTurnDurationS ?? 0)
            let multiSession = activeCount > 1
            let longTurn = duration > threshold

            guard longTurn || multiSession else { continue }
            if recentlyNotified(id: id) { continue }

            await postNotification(
                for: curr,
                durationSeconds: Int(duration),
                activeCount: activeCount
            )
            lastNotifiedAt[id] = Date()
        }
    }

    // MARK: - Internals

    private func effectiveThreshold() -> Double {
        let raw = UserDefaults.standard.double(forKey: Self.thresholdKey)
        return raw > 0 ? raw : Self.defaultThresholdSeconds
    }

    private func recentlyNotified(id: String) -> Bool {
        guard let last = lastNotifiedAt[id] else { return false }
        return Date().timeIntervalSince(last) < Self.dedupeWindow
    }

    private func postNotification(
        for session: SessionState,
        durationSeconds: Int,
        activeCount: Int
    ) async {
        guard authorizationGranted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Claude Code · \(session.projectLabel)"
        content.body = "\(durationSeconds)s · \(activeCount) active session\(activeCount == 1 ? "" : "s")"
        content.sound = .default

        let identifier = "session-\(session.id)-\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Silent — notifications are best-effort, never crash the app over them.
        }
    }
}

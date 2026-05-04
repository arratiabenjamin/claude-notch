// NotificationService.swift
// Posts a local UserNotification when a Claude turn finishes that took longer
// than the user's threshold (default 90s) OR when there are still other
// active sessions in flight (multi-session juggling cue).
//
// We only fire on the running -> idle / running -> ended transition. New
// sessions appearing or sessions disappearing do NOT notify.
//
// Authorization is LAZY (v1.3): we never prompt on launch. The very first
// time we're about to post a real notification we check the current status
// and, if `notDetermined`, ask in response to that real event. If the user
// denied, we silently drop. This avoids the macOS "Notifications from
// Claude Notch — alerts, sounds, badges" prompt sticking around at startup
// when the user has never triggered an actual long-turn.
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

    /// UserDefaults key for the multi-session rule. Default ON.
    private static let multiSessionKey = "notify_on_multi_session"

    /// Cooldown per session: avoid double-notifying if the watcher emits two
    /// consecutive ticks for the same transition (FSEvents + safety poll).
    private static let dedupeWindow: TimeInterval = 5

    // MARK: - State

    private var lastNotifiedAt: [String: Date] = [:]

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
        let multiSessionEnabled = effectiveMultiSessionEnabled()
        let activeCount = current
            .filter { $0.status == .running || $0.status == .idle }
            .count

        for (id, curr) in currById {
            guard let prev = prevById[id] else { continue }
            let justEnded = prev.status == .running &&
                            (curr.status == .idle || curr.status == .ended)
            guard justEnded else { continue }

            let duration = Double(curr.lastTurnDurationS ?? 0)
            let multiSession = multiSessionEnabled && activeCount > 1
            let longTurn = duration > threshold

            guard longTurn || multiSession else { continue }
            if recentlyNotified(id: id) { continue }

            // Lazy authorization: only ask the OS NOW, in response to a real
            // event the user actually cares about.
            guard await ensureAuthorizedLazily() else { continue }

            await postNotification(
                for: curr,
                durationSeconds: Int(duration),
                activeCount: activeCount
            )
            lastNotifiedAt[id] = Date()
        }
    }

    /// Inspect the current notification settings and request authorization
    /// only when the user has not yet been asked. Returns true if the app may
    /// post a notification right now.
    private func ensureAuthorizedLazily() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            // First real event ever — ask the user now.
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return granted
        case .denied:
            return false
        case .authorized, .provisional, .ephemeral:
            return true
        @unknown default:
            return false
        }
    }

    // MARK: - Internals

    private func effectiveThreshold() -> Double {
        let raw = UserDefaults.standard.double(forKey: Self.thresholdKey)
        return raw > 0 ? raw : Self.defaultThresholdSeconds
    }

    /// Multi-session rule defaults to ON; UserDefaults.bool returns false
    /// when the key is unset, so we explicitly check for presence.
    private func effectiveMultiSessionEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.multiSessionKey) == nil {
            return true
        }
        return defaults.bool(forKey: Self.multiSessionKey)
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
        let content = UNMutableNotificationContent()
        content.title = "Claude Code · \(session.displayName)"
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

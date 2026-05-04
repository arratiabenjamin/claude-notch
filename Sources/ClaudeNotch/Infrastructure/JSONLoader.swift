// JSONLoader.swift
// Decodes the on-disk active-sessions.json into a normalized [SessionState].
// All inner fields are optional — see Discovery #740 ("schema-quirks").
// The outer dict key is the canonical session id; inner `session_id` is best-effort.
import Foundation

enum JSONLoaderError: Error, Equatable {
    case decode(String)
    case schemaMismatch(version: Int)
    case sizeLimitExceeded(bytes: Int)
}

struct JSONLoader: Sendable {
    /// Maximum size we will attempt to decode (defense against runaway/hostile files).
    /// 1 MB is ~10x the realistic upper bound for the producer's output.
    static let maxSizeBytes: Int = 1_000_000

    /// Schema version supported by this build of the app.
    static let supportedSchemaVersion: Int = 1

    /// Decode raw bytes from active-sessions.json into the normalized session list.
    /// Throws on malformed JSON, schema mismatch, or oversize input.
    static func decode(from data: Data) throws -> [SessionState] {
        if data.count > maxSizeBytes {
            throw JSONLoaderError.sizeLimitExceeded(bytes: data.count)
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw JSONLoaderError.decode(String(describing: error))
        }

        if let version = envelope.version, version != Self.supportedSchemaVersion {
            throw JSONLoaderError.schemaMismatch(version: version)
        }

        let sessions = envelope.sessions ?? [:]
        // Build formatters once per decode call (cheap; avoids cross-actor static state).
        let withFractional = makeISO8601Formatter(fractional: true)
        let plain = makeISO8601Formatter(fractional: false)

        return sessions.map { (outerKey, partial) in
            normalize(
                outerKey: outerKey,
                partial: partial,
                withFractional: withFractional,
                plain: plain
            )
        }
    }

    // MARK: - Private

    private static func normalize(
        outerKey: String,
        partial: PartialSession,
        withFractional: ISO8601DateFormatter,
        plain: ISO8601DateFormatter
    ) -> SessionState {
        // Canonical id: ALWAYS outer dict key. We never trust the inner `session_id`
        // field, but we tolerate it being present.
        let id = outerKey

        let projectLabel: String = {
            if let label = partial.project_label, !label.isEmpty {
                return label
            }
            if let cwd = partial.cwd, !cwd.isEmpty {
                let base = (cwd as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
            // Discovery #740 fallback: first 8 chars of canonical id
            return String(id.prefix(8))
        }()

        return SessionState(
            id: id,
            projectLabel: projectLabel,
            cwd: partial.cwd,
            pid: partial.pid,
            status: SessionState.Status(rawString: partial.status),
            startedAt: parseDate(partial.started_at, withFractional: withFractional, plain: plain),
            promptStartedAt: parseDate(partial.prompt_started_at, withFractional: withFractional, plain: plain),
            lastTurnDurationS: partial.last_turn_duration_s,
            lastTurnFinishedAt: parseDate(partial.last_turn_finished_at, withFractional: withFractional, plain: plain),
            endedAt: parseDate(partial.ended_at, withFractional: withFractional, plain: plain),
            lastResult: partial.last_result
        )
    }

    private static func parseDate(
        _ raw: String?,
        withFractional: ISO8601DateFormatter,
        plain: ISO8601DateFormatter
    ) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Try fractional-seconds form first; fall back to plain RFC 3339.
        // The live producer currently emits the plain form.
        return withFractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static func makeISO8601Formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }

    // MARK: - Wire types

    /// Outer envelope of active-sessions.json. Every field is optional so a
    /// mid-write or partial state cannot prevent the rest from decoding.
    private struct Envelope: Decodable {
        let version: Int?
        let updated_at: String?
        let sessions: [String: PartialSession]?
    }

    /// Inner session entry. Every field is optional — see Discovery #740.
    private struct PartialSession: Decodable {
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
    }
}

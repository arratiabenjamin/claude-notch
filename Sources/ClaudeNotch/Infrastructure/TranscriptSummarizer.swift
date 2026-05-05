// TranscriptSummarizer.swift
// Produce a short, human-readable summary of what a Claude Code session did,
// for the avatar to read aloud when the session ends.
//
// Strategy:
//   1. If macOS 26+ AND the Apple Intelligence Foundation Models framework
//      is available AND the on-device model is loaded, prompt it with the
//      tail of the transcript and return its one-sentence answer.
//   2. Otherwise, fall back to a heuristic that grabs the last assistant
//      text and trims it to one sentence. Never the best summary, but
//      always *some* summary so the avatar always has something to say.
//
// Compile-time guards (`#if canImport(FoundationModels)`) keep the build
// green on Xcodes/SDKs without the framework. Runtime guards (`#available`)
// keep the binary working on macOS 14/15 deployments — if we ever target
// older macOS, the code path is silently skipped.
//
// All entry points are `async` and never throw — failures degrade to the
// fallback string, never crash the speech queue.
import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels
#endif

private let log = Logger(subsystem: "com.velion.claude-notch", category: "transcript-summarizer")

@MainActor
enum TranscriptSummarizer {

    /// What is being summarized — the whole session that just closed,
    /// or just the most recent turn while the session stays alive.
    /// Drives both the prompt phrasing and the fallback line.
    enum Kind {
        /// Session ended (status=ended or vanished from payload).
        case session
        /// A long turn completed; session is now idle, waiting for the
        /// user's next prompt.
        case turn
    }

    /// Bytes of transcript tail we feed the model. Apple Intelligence's
    /// on-device LanguageModel has a small context window (~4K tokens);
    /// JSONL is dense, so even 8 KB chars reliably overflows. 3 KB keeps
    /// us comfortably under the limit while still capturing the last few
    /// turns in a normal session.
    private static let maxPromptBytes = 3_072

    /// Hard ceiling on the summary length. Keeps the spoken line short
    /// enough to not overstay its welcome at the avatar.
    private static let maxSummaryChars = 220

    /// Best-effort summary of `transcriptPath`. Always returns a non-empty
    /// human-readable string in Spanish, suitable for TTS. The session's
    /// total active duration (if known) is appended to the fallback line
    /// so even without AI the announcement carries some information.
    static func summarize(
        transcriptPath: String?,
        sessionName: String,
        kind: Kind = .session,
        durationSeconds: Double? = nil
    ) async -> String {
        log.info("summarize start name=\(sessionName, privacy: .public) kind=\(String(describing: kind), privacy: .public) hasPath=\(transcriptPath != nil, privacy: .public)")

        guard let path = transcriptPath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            log.info("no transcript path, neutral fallback")
            return fallbackLine(for: sessionName, kind: kind, durationSeconds: durationSeconds)
        }

        // Read a generous chunk so we can extract meaningful context
        // (user prompts, final assistant replies, tool list). The
        // extracted summary is then capped at maxPromptBytes before
        // being sent to the model.
        let raw = readTail(at: path, maxBytes: 65_536)
        if raw.isEmpty {
            log.info("transcript empty, neutral fallback")
            return fallbackLine(for: sessionName, kind: kind, durationSeconds: durationSeconds)
        }

        // Path A: Claude itself summarized via the SUMMARY: convention
        // (see ~/.claude/CLAUDE.md instruction). When present, this is
        // strictly better than anything an on-device model could produce —
        // Sonnet/Opus has full context and zero hallucination risk.
        if let claudeSummary = extractClaudeSummary(rawJSONL: raw) {
            log.info("using Claude-authored SUMMARY length=\(claudeSummary.count, privacy: .public)")
            return clamp(claudeSummary)
        }

        let context = extractMeaningfulContext(rawJSONL: raw)
        log.info("extracted context length=\(context.count, privacy: .public)")
        if context.count < 40 {
            log.info("context too thin, neutral fallback")
            return fallbackLine(for: sessionName, kind: kind, durationSeconds: durationSeconds)
        }

        let prompt = clipForPrompt(context)
        if let aiSummary = await tryFoundationModels(context: prompt, kind: kind) {
            log.info("AI summary length=\(aiSummary.count, privacy: .public)")
            return clamp(aiSummary)
        }

        log.info("AI unavailable, using neutral fallback")
        return fallbackLine(for: sessionName, kind: kind, durationSeconds: durationSeconds)
    }

    // MARK: - Claude-authored SUMMARY extraction

    /// Look for a `SUMMARY:` line that Claude itself wrote in its last
    /// assistant message, per the instruction we recommend adding to
    /// `~/.claude/CLAUDE.md`. We accept several formatting variants because
    /// Claude sometimes wraps the marker in bold or brackets:
    ///   SUMMARY: foo
    ///   Summary: foo
    ///   **SUMMARY:** foo
    ///   [SUMMARY]: foo
    ///   SUMMARY:
    ///       foo
    ///
    /// The match is on the LAST assistant text in the transcript — Claude
    /// might mention "summary" earlier in conversation; we want only the
    /// closing one.
    /// Internal for testing.
    static func extractClaudeSummary(rawJSONL: String) -> String? {
        guard let lastText = lastAssistantText(rawJSONL: rawJSONL) else { return nil }

        // Strip common markdown wrappers around the marker so the regex stays simple.
        let cleaned = lastText
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")

        // Find a line that begins with "SUMMARY:" (case-insensitive). The
        // value after it can be on the same line OR on the next non-empty line.
        let lines = cleaned.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: #"^summary:\s*"#, options: [.regularExpression, .caseInsensitive]) else {
                continue
            }
            let after = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty {
                return after
            }
            // Marker on its own line — take the next non-empty line.
            if i + 1 < lines.count {
                for j in (i + 1)..<lines.count {
                    let candidate = lines[j].trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty { return candidate }
                }
            }
        }
        return nil
    }

    /// Return the text payload of the LAST assistant message in the JSONL.
    private static func lastAssistantText(rawJSONL: String) -> String? {
        var lastText: String? = nil
        for line in rawJSONL.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            guard (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]]
            else { continue }
            for item in content {
                if (item["type"] as? String) == "text",
                   let t = item["text"] as? String, !t.isEmpty {
                    lastText = t
                }
            }
        }
        return lastText
    }

    // MARK: - Transcript distillation

    /// Walk the JSONL transcript and pull out a concise prose representation
    /// of what happened. We skip the parts a summarizer doesn't need:
    /// thinking blocks, tool_use payloads, repeated streaming chunks. We
    /// keep:
    ///   • The user's prompts (paraphrased / verbatim, capped per turn).
    ///   • A short list of tool names used.
    ///   • The final assistant text reply.
    /// The result is dense — typically 4-10× more informative per byte than
    /// raw JSONL.
    private static func extractMeaningfulContext(rawJSONL: String) -> String {
        var userPrompts: [String] = []
        var assistantTexts: [String] = []
        var toolUsage: [String: Int] = [:]

        let lines = rawJSONL.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            // Top-level "type" tells us the role direction.
            let type = (obj["type"] as? String) ?? ""

            if type == "user" {
                if let text = extractUserText(from: obj), !text.isEmpty {
                    userPrompts.append(text)
                }
            } else if type == "assistant" {
                if let msg = obj["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    var lastText: String? = nil
                    for item in content {
                        let itemType = (item["type"] as? String) ?? ""
                        switch itemType {
                        case "text":
                            if let t = item["text"] as? String, !t.isEmpty {
                                lastText = t
                            }
                        case "tool_use":
                            if let name = item["name"] as? String {
                                toolUsage[name, default: 0] += 1
                            }
                        default:
                            continue
                        }
                    }
                    if let t = lastText { assistantTexts.append(t) }
                }
            }
        }

        // Compose a dense summary text. Cap each section.
        var parts: [String] = []
        if !userPrompts.isEmpty {
            let kept = userPrompts.suffix(3).map { String($0.prefix(220)) }
            parts.append("Pidió:\n- " + kept.joined(separator: "\n- "))
        }
        if !toolUsage.isEmpty {
            let formatted = toolUsage
                .sorted { $0.value > $1.value }
                .prefix(6)
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: ", ")
            parts.append("Tools: \(formatted)")
        }
        if let lastReply = assistantTexts.last, !lastReply.isEmpty {
            parts.append("Respuesta final:\n" + String(lastReply.prefix(800)))
        }

        return parts.joined(separator: "\n\n")
    }

    /// Extract a user-message text body. The schema sometimes nests under
    /// `message.content[]` and sometimes lives at the top level — we walk
    /// both.
    private static func extractUserText(from obj: [String: Any]) -> String? {
        if let msg = obj["message"] as? [String: Any] {
            if let content = msg["content"] as? String { return content }
            if let arr = msg["content"] as? [[String: Any]] {
                let texts = arr.compactMap { item -> String? in
                    if (item["type"] as? String) == "text" {
                        return item["text"] as? String
                    }
                    return nil
                }
                if !texts.isEmpty { return texts.joined(separator: " ") }
            }
        }
        if let direct = obj["text"] as? String { return direct }
        return nil
    }

    /// Hard byte cap for the prompt body, just in case the extracted
    /// context is unusually long (e.g. a single mega-prompt).
    private static func clipForPrompt(_ s: String) -> String {
        guard s.utf8.count > maxPromptBytes else { return s }
        return String(s.prefix(maxPromptBytes))
    }

    // MARK: - Foundation Models

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func runFoundationModels(context: String, kind: Kind) async -> String? {
        // Small on-device models follow short, declarative prompts much
        // better than long rule lists. We deliberately avoid suggesting
        // example verbs — the model latches onto them and outputs whichever
        // we showed first regardless of what the session actually did.
        // The post-process sanitizer cleans up actor labels.
        let situationalLine: String
        switch kind {
        case .session:
            situationalLine = "Esta es una sesión de programación que acaba de cerrar."
        case .turn:
            situationalLine = "Esta es la última acción larga que terminó dentro de una sesión que sigue activa."
        }
        let prompt = """
        \(situationalLine) Leé el contexto y devolvé una sola oración en \
        español, en pasado, que diga qué se hizo. Máximo 20 palabras. No \
        inventes acciones que no estén en el contexto.

        Contexto:
        \(context)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = sanitizeAIOutput(raw)
            log.info("AI raw=\(raw.prefix(120), privacy: .public)")
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            log.error("FoundationModels error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    #endif

    /// Strip common preambles / wrappers / actor labels the model adds
    /// despite the prompt. Conservative — we'd rather leak some noise than
    /// truncate meaningful summaries.
    /// Internal for testing.
    static func sanitizeAIOutput(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop surrounding quotes if the model wrapped the whole response.
        if out.count > 2,
           let first = out.first, let last = out.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            out = String(out.dropFirst().dropLast())
        }

        // Strip meta preambles ("Resumen:" / "Aquí va: " / etc).
        let metaPrefixes = [
            "Resumen:", "Resumen en una oración:",
            "Aquí va:", "Aquí está el resumen:", "Resultado:"
        ]
        for prefix in metaPrefixes {
            if out.lowercased().hasPrefix(prefix.lowercased()) {
                out = String(out.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // Strip actor labels ("El asistente generó..." → "Generó...").
        // We capitalize the next character so the sentence still reads naturally.
        let actorPrefixes = [
            "El asistente ", "El usuario ", "La sesión ",
            "El modelo ", "Claude "
        ]
        for prefix in actorPrefixes {
            if out.lowercased().hasPrefix(prefix.lowercased()) {
                out = String(out.dropFirst(prefix.count))
                if let firstChar = out.first {
                    out = firstChar.uppercased() + out.dropFirst()
                }
                break
            }
        }

        return out
    }

    /// Wrapper that fences the call so callers don't have to worry about
    /// the compile-time / runtime availability matrix.
    private static func tryFoundationModels(context: String, kind: Kind) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await runFoundationModels(context: context, kind: kind)
        }
        #endif
        return nil
    }

    // MARK: - Helpers

    /// Read up to `maxBytes` from the END of `path`. Returns "" on any error.
    private static func readTail(at path: String, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return ""
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: maxBytes)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func clamp(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxSummaryChars { return trimmed }
        let cut = trimmed.prefix(maxSummaryChars)
        // Try to break on the last whitespace inside the prefix for cleaner cuts.
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// Neutral closing line when AI couldn't summarize. Appends the duration
    /// in minutes when we know it — even without a summary, "terminó después
    /// de 4 minutos" is more useful than a bare "terminó."
    private static func fallbackLine(for sessionName: String, kind: Kind, durationSeconds: Double?) -> String {
        let action: String = (kind == .turn)
            ? "completó una acción"
            : "terminó"
        if let secs = durationSeconds, secs > 30 {
            let mins = Int((secs / 60).rounded())
            if mins >= 1 {
                return "\(sessionName) \(action) después de \(mins) \(mins == 1 ? "minuto" : "minutos")."
            }
        }
        return "\(sessionName) \(action)."
    }
}

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

    /// Maximum characters of transcript tail to feed the model. Foundation
    /// Models has its own context window; we cap aggressively so latency
    /// stays under ~1s on M-series silicon.
    private static let maxPromptChars = 6_000

    /// Hard ceiling on the summary length. Keeps the spoken line short
    /// enough to not overstay its welcome at the avatar.
    private static let maxSummaryChars = 220

    /// Best-effort summary of `transcriptPath`. Always returns a non-empty
    /// human-readable string in Spanish, suitable for TTS.
    static func summarize(transcriptPath: String?, sessionName: String) async -> String {
        guard let path = transcriptPath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return defaultLine(for: sessionName)
        }

        let tail = readTail(at: path, maxBytes: 32_768)
        if tail.isEmpty {
            return defaultLine(for: sessionName)
        }

        // Try Apple Intelligence first.
        if let aiSummary = await tryFoundationModels(tail: tail, sessionName: sessionName) {
            log.info("AI summary length=\(aiSummary.count, privacy: .public)")
            return clamp(aiSummary)
        }

        // Heuristic fallback.
        let snippet = await TranscriptParser.lastAssistantText(at: path)
        switch snippet {
        case .ready(let text, _, _):
            return clamp(firstSentence(of: text))
        case .noText:
            return "\(sessionName) terminó tras una serie de comandos."
        case .empty, .fileMissing, .loading, .error:
            return defaultLine(for: sessionName)
        }
    }

    // MARK: - Foundation Models

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func runFoundationModels(tail: String, sessionName: String) async -> String? {
        let prompt = """
        Estás resumiendo una sesión de programación con un asistente de IA.
        En UNA sola oración corta en español rioplatense, describí qué se logró \
        o quedó en proceso. No menciones tu rol, no uses comillas, no menciones \
        "el asistente" — describí la acción directamente como la diría un \
        compañero de equipo.

        Nombre de la sesión: \(sessionName)

        Últimos eventos del transcript (JSONL):
        \(tail)

        Resumen (una oración):
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            log.error("FoundationModels error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    #endif

    /// Wrapper that fences the call so callers don't have to worry about
    /// the compile-time / runtime availability matrix.
    private static func tryFoundationModels(tail: String, sessionName: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await runFoundationModels(tail: tail, sessionName: sessionName)
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

    /// First sentence of `text`, falling back to a hard-truncated prefix.
    private static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        let punctuation: Set<Character> = [".", "!", "?", "。"]
        if let endIdx = trimmed.firstIndex(where: { punctuation.contains($0) }) {
            let next = trimmed.index(after: endIdx)
            return String(trimmed[..<next])
        }
        return trimmed
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

    private static func defaultLine(for sessionName: String) -> String {
        "\(sessionName) terminó."
    }
}

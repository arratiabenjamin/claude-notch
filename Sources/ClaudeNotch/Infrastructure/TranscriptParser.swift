// TranscriptParser.swift
// Reads the tail of a Claude Code JSONL transcript and extracts the most
// recent assistant text message for the expanded session view.
//
// The transcript format Claude Code writes (verified live, not from docs):
//   {"type":"assistant","message":{"role":"assistant",
//     "content":[{"type":"text","text":"..."},
//                {"type":"thinking","thinking":"..."},
//                {"type":"tool_use",...}]}, "timestamp":"..."}
//
// Schemas drift, so every field on the wire types is optional and we walk
// content arrays defensively. We never load more than `maxBytes` from disk
// so a multi-MB transcript does not stall the UI.
import Foundation

enum TranscriptParser {
    /// State of the snippet for an expanded session row.
    enum SnippetState: Equatable, Sendable {
        case loading
        /// `text` is already truncated to the snippet length; `at` is the
        /// timestamp of the message if the JSONL line carried one.
        case ready(text: String, role: String, at: Date?)
        case empty
        /// Last assistant message exists but has no text yet (tool calls only).
        case noText
        case fileMissing
        case error(String)
    }

    /// Hard cap on the snippet length so the row stays a few lines tall.
    static let snippetMaxChars = 280

    /// Default tail size we read from disk. 64 KB easily holds the last few
    /// turns of a normal conversation.
    static let defaultMaxBytes = 65_536

    /// Read the last assistant text from a JSONL transcript at `path`.
    /// Reads at most the trailing `maxBytes` of the file.
    /// Never throws; failure modes are encoded into `SnippetState`.
    static func lastAssistantText(
        at path: String,
        maxBytes: Int = defaultMaxBytes
    ) async -> SnippetState {
        // Hop off the caller's actor for the blocking IO.
        await Task.detached(priority: .utility) { () -> SnippetState in
            readTail(path: path, maxBytes: maxBytes)
        }.value
    }

    // MARK: - Synchronous core (testable)

    /// Pure synchronous variant used by both the async API and the tests.
    static func readTail(path: String, maxBytes: Int) -> SnippetState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .fileMissing
        }

        let data: Data
        do {
            data = try readTrailingBytes(path: path, maxBytes: maxBytes)
        } catch {
            return .error(String(describing: error))
        }

        if data.isEmpty {
            return .empty
        }

        // UTF-8 lossy because the leading chunk may slice into a multibyte
        // codepoint. We immediately drop the first line for the same reason.
        guard let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            return .error("decoding")
        }

        var lines = raw.split(omittingEmptySubsequences: true,
                              whereSeparator: { $0 == "\n" })

        // If we read fewer bytes than the cap, the chunk starts at offset 0
        // and the first line is whole. Otherwise drop it — it's a fragment.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        if fileSize > maxBytes, lines.count > 1 {
            lines.removeFirst()
        }

        // Walk back: pick the most recent assistant entry that yields text.
        var sawAssistantWithoutText = false
        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let entry = try? decoder.decode(TranscriptLine.self, from: lineData) else {
                continue
            }
            // Match either top-level type=="assistant" or message.role=="assistant".
            let isAssistant = (entry.type == "assistant") ||
                              (entry.message?.role == "assistant")
            guard isAssistant else { continue }

            guard let content = entry.message?.content else {
                sawAssistantWithoutText = true
                continue
            }

            if let text = firstText(in: content) {
                let truncated = truncate(text, to: snippetMaxChars)
                return .ready(
                    text: truncated,
                    role: entry.message?.role ?? "assistant",
                    at: parseTimestamp(entry.timestamp)
                )
            }
            // Assistant turn with no text yet (tool calls / thinking only).
            sawAssistantWithoutText = true
        }

        return sawAssistantWithoutText ? .noText : .empty
    }

    // MARK: - Helpers

    /// Read at most `maxBytes` from the end of the file via FileHandle.
    private static func readTrailingBytes(path: String, maxBytes: Int) throws -> Data {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = (try handle.seekToEnd())
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        if #available(macOS 10.15.4, *) {
            return (try handle.read(upToCount: maxBytes)) ?? Data()
        } else {
            return handle.readData(ofLength: maxBytes)
        }
    }

    /// Pick the first `text` content block from an assistant turn. We prefer
    /// `text` over `thinking` so the UI never surfaces internal monologue.
    private static func firstText(in content: [ContentBlock]) -> String? {
        for block in content where block.type == "text" {
            if let text = block.text, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func truncate(_ s: String, to max: Int) -> String {
        // Normalize newlines so the SwiftUI Text view does not stretch the
        // panel vertically with a 50-line snippet. Keep a few internal breaks.
        let collapsed = s.replacingOccurrences(of: "\r\n", with: "\n")
        if collapsed.count <= max { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: max)
        return collapsed[..<endIndex] + "…"
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    // MARK: - Wire types (every field optional — schemas drift)

    private struct TranscriptLine: Decodable {
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let role: String?
        let content: [ContentBlock]?
    }

    private struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }
}

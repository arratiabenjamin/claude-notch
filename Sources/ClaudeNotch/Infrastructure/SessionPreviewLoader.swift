// SessionPreviewLoader.swift
// Reads the tail of a Claude Code session JSONL transcript and extracts the
// most recent user prompt + most recent assistant text reply, without any
// model in the loop. Used by OrbView for the satellite hover bubble.
//
// Schema notes (matches the parser conventions in TranscriptParser):
//   • Each line is a JSON object.
//   • User entries have type=="user" and either a string `message.content`
//     or a content array of {type:"text", text:"…"}.
//   • Assistant entries have type=="assistant" with a content array that
//     may include text blocks AND tool_use blocks. We only want the text.
//   • Other types (system, tool_result, etc.) are ignored.
//
// Performance: only the last ~96 KB of the file is read — enough for several
// recent turns even with verbose tool output. Off the main actor.
import Foundation

enum SessionPreviewLoader {
    /// Tail size to inspect. Big enough to catch the last user prompt + last
    /// assistant text reply even when tool calls are chatty in between.
    private static let tailBytes: Int = 96 * 1024

    /// Maximum chars per field. Anything past this gets truncated with an
    /// ellipsis at the nearest word boundary. The bubble is laid out for
    /// short summaries — anything longer becomes wall-of-text and unreadable.
    private static let maxFieldChars: Int = 240

    /// Best-effort load. Returns nil only when the file is missing entirely.
    /// An empty/un-parseable file yields `SessionPreview.empty`.
    static func load(transcriptPath: String?) async -> SessionPreview? {
        guard let path = transcriptPath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            parse(rawJSONL: readTail(at: path, maxBytes: tailBytes))
        }.value
    }

    // MARK: - Parsing

    /// Walks JSONL lines (in order they appear in the file — newest is at
    /// the END) and tracks the latest user prompt and latest assistant text.
    /// Both are independent: the latest user might be after the latest
    /// assistant if the user already typed the next turn's prompt.
    private static func parse(rawJSONL: String) -> SessionPreview {
        guard !rawJSONL.isEmpty else { return .empty }

        var latestUser: String?
        var latestAssistant: String?

        // Iterate by line. Skip the first line if we entered mid-record:
        // partial JSON at the top of the buffer is harmless because we only
        // assign on successful decode.
        let lines = rawJSONL.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let type = obj["type"] as? String else { continue }

            switch type {
            case "user":
                if let text = extractUserText(from: obj), !text.isEmpty {
                    latestUser = text
                }
            case "assistant":
                if let text = extractAssistantText(from: obj), !text.isEmpty {
                    latestAssistant = text
                }
            default:
                continue
            }
        }

        return SessionPreview(
            lastUserPrompt: latestUser.map { truncate($0) },
            lastAssistantText: latestAssistant.map { truncate($0) }
        )
    }

    /// User entries: `message.content` is either a String or an Array<Block>.
    /// Strings are the prompt verbatim; arrays carry typed blocks where we
    /// pick text-typed blocks only (a user can also paste files/images).
    private static func extractUserText(from obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] else { return nil }
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return nil }
                return text
            }.joined(separator: " ")
        }
        return nil
    }

    /// Assistant entries: `message.content` is always an Array<Block>. We
    /// keep only `type:"text"` blocks. Tool calls are tracked elsewhere; if
    /// the user wants to know the tool list, the summarizer covers it.
    private static func extractAssistantText(from obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String else { return nil }
            return text
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: " ")
    }

    private static func truncate(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxFieldChars { return trimmed }
        let cut = trimmed.prefix(maxFieldChars)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    // MARK: - File I/O

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
}

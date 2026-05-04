// SessionNameLoader.swift
// Reads ~/.claude/sessions/*.json files and exposes a session_id → custom_name map.
// Each session file is JSON with at least { sessionId, name }. The `name` field is
// what the user assigned via Claude Code's `/rename <name>` command. Many session
// files have name == nil or "" — those are filtered out so callers can rely on a
// simple non-empty check.
//
// IMPORTANT: filenames in ~/.claude/sessions/ are <pid>.json, NOT <session_id>.json.
// The mapping is established by reading the inner `sessionId` field of each file.
import Foundation

struct SessionNameLoader: Sendable {
    /// Default location of Claude Code's per-process session metadata files.
    /// Files are named `<pid>.json`. Each contains a `sessionId` and may
    /// contain a user-assigned `name` from the `/rename` command.
    static let defaultDirectory: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
    }()

    /// Returns dictionary [sessionId: name] for every session file with a non-empty
    /// name. Skips files that fail to parse, are missing fields, or have empty/whitespace
    /// names. IO errors are swallowed silently — this is a best-effort lookup.
    ///
    /// The default directory contains a small number of files in production
    /// (one per running/recent Claude Code process), so a synchronous batch read
    /// is fine. If this set ever grows large enough to matter, refactor to async
    /// + cache invalidated on directory mtime.
    static func loadAll(from directory: String = defaultDirectory) -> [String: String] {
        let fm = FileManager.default

        // Resolve symlinks so a symlinked sessions dir works the same.
        let resolved = (directory as NSString).resolvingSymlinksInPath

        guard let entries = try? fm.contentsOfDirectory(atPath: resolved) else {
            return [:]
        }

        var map: [String: String] = [:]
        let decoder = JSONDecoder()

        for entry in entries where entry.hasSuffix(".json") {
            let path = (resolved as NSString).appendingPathComponent(entry)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                continue
            }
            guard let partial = try? decoder.decode(PartialSessionFile.self, from: data) else {
                continue
            }
            guard let sessionId = partial.sessionId, !sessionId.isEmpty,
                  let rawName = partial.name else {
                continue
            }
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            map[sessionId] = trimmed
        }
        return map
    }

    // MARK: - Wire types

    /// Partial decode of a `~/.claude/sessions/<pid>.json` file. We only care
    /// about the two fields required for the rename → notch mapping.
    private struct PartialSessionFile: Decodable {
        let sessionId: String?
        let name: String?
    }
}

// TranscriptParserTests.swift
// Cover the synchronous core of TranscriptParser using JSONL fixtures.
import XCTest
@testable import ClaudeNotch

final class TranscriptParserTests: XCTestCase {

    // MARK: - Fixture lookup

    private func fixturePath(_ name: String) throws -> String {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "jsonl",
                                subdirectory: "Fixtures/transcripts")
            ?? bundle.url(forResource: name, withExtension: "jsonl",
                          subdirectory: "transcripts")
            ?? bundle.url(forResource: name, withExtension: "jsonl") {
            return url.path
        }
        // Walk up from this source file.
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("\(name).jsonl")
            .path
        return path
    }

    // MARK: - Tests

    func testFindsLastAssistantText() throws {
        let path = try fixturePath("normal")
        let result = TranscriptParser.readTail(path: path, maxBytes: 65_536)
        guard case let .ready(text, role, _) = result else {
            XCTFail("Expected .ready, got \(result)")
            return
        }
        XCTAssertEqual(role, "assistant")
        XCTAssertTrue(text.contains("All green"),
                      "Expected the LAST assistant message, got: \(text)")
    }

    func testHandlesToolsOnlyAssistant() throws {
        let path = try fixturePath("tools-only-tail")
        let result = TranscriptParser.readTail(path: path, maxBytes: 65_536)
        // The last assistant entry has only thinking + tool_use; we should
        // walk back to the previous one that has text.
        guard case let .ready(text, _, _) = result else {
            XCTFail("Expected .ready (walked back to earlier assistant), got \(result)")
            return
        }
        XCTAssertTrue(text.contains("Looking at the directory"),
                      "Expected fallback to previous assistant text, got: \(text)")
    }

    func testHandlesEmptyFile() throws {
        let path = try fixturePath("empty")
        let result = TranscriptParser.readTail(path: path, maxBytes: 65_536)
        XCTAssertEqual(result, .empty)
    }

    func testHandlesMissingFile() {
        let result = TranscriptParser.readTail(
            path: "/tmp/does-not-exist-claude-notch-\(UUID().uuidString).jsonl",
            maxBytes: 65_536
        )
        XCTAssertEqual(result, .fileMissing)
    }

    func testHandlesMalformedLines() throws {
        let path = try fixturePath("malformed-mixed")
        let result = TranscriptParser.readTail(path: path, maxBytes: 65_536)
        guard case let .ready(text, _, _) = result else {
            XCTFail("Expected .ready (last valid assistant), got \(result)")
            return
        }
        XCTAssertTrue(text.contains("Second valid assistant response"),
                      "Should pick most recent VALID assistant entry, got: \(text)")
    }

    func testTruncatesLongTextTo280Chars() {
        // Build a single assistant line with a long text content so we hit truncation.
        let long = String(repeating: "abcdefghij", count: 60) // 600 chars
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(long)"}]},"timestamp":"2026-05-04T10:00:00Z"}"#
        let tmp = NSTemporaryDirectory() + "claude-notch-truncate-\(UUID().uuidString).jsonl"
        try? (line + "\n").write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let result = TranscriptParser.readTail(path: tmp, maxBytes: 65_536)
        guard case let .ready(text, _, _) = result else {
            XCTFail("Expected .ready, got \(result)")
            return
        }
        XCTAssertLessThanOrEqual(text.count, TranscriptParser.snippetMaxChars + 1,
                                 "Snippet should be capped at \(TranscriptParser.snippetMaxChars) chars (+ 1 for ellipsis)")
        XCTAssertTrue(text.hasSuffix("…"), "Truncated snippet should end with ellipsis")
    }
}

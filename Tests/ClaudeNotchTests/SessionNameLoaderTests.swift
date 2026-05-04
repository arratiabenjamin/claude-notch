// SessionNameLoaderTests.swift
// Cover the synchronous batch reader for ~/.claude/sessions/*.json files
// (the source of truth for `/rename` custom names).
import XCTest
@testable import ClaudeNotch

final class SessionNameLoaderTests: XCTestCase {

    // MARK: - Fixture path

    /// Resolve the bundled `Fixtures/sessions/` directory. We don't read
    /// individual files via the bundle here — the loader takes a directory
    /// path, so we only need to find the directory.
    private func sessionsFixtureDir() -> String {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: "sessions", withExtension: nil,
                                subdirectory: "Fixtures") {
            return url.path
        }
        // Fallback: walk up from this source file.
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .path
    }

    // MARK: - Tests

    func testLoadsCustomNames() {
        let dir = sessionsFixtureDir()
        let map = SessionNameLoader.loadAll(from: dir)

        // Two fixtures have a real name; the others should be filtered out
        // (no name, whitespace-only name, malformed JSON, missing sessionId).
        XCTAssertEqual(
            map["0dbdb8bb-5b09-4650-992f-874fd73b5541"],
            "Notificacion-Claude-Code"
        )
        XCTAssertEqual(
            map["3a49bc7b-649c-4dc6-9961-36b76f6ec5ec"],
            "PracticaEntrevistaTecnica"
        )
        XCTAssertEqual(map.count, 2,
                       "Only the two well-formed, non-empty-name files should appear")
    }

    func testHandlesMissingDirectory() {
        let bogus = "/tmp/claude-notch-does-not-exist-\(UUID().uuidString)"
        let map = SessionNameLoader.loadAll(from: bogus)
        XCTAssertTrue(map.isEmpty,
                      "Missing directory should return empty map without throwing")
    }

    func testIgnoresFilesWithoutSessionId() {
        // The directory contains no-sessionid.json (has name but no sessionId).
        // It MUST be silently skipped — the map is keyed by sessionId, so an
        // entry with no key would be useless.
        let dir = sessionsFixtureDir()
        let map = SessionNameLoader.loadAll(from: dir)

        // The orphan name "OrphanName" appears in no-sessionid.json — verify
        // it does not leak into the map under any key.
        XCTAssertFalse(map.values.contains("OrphanName"),
                       "Files without a sessionId must not contribute names")
    }

    func testHandlesMalformedJSON() {
        // The directory contains malformed.json. The loader must NOT throw;
        // it must skip that file and still return the well-formed entries.
        let dir = sessionsFixtureDir()
        let map = SessionNameLoader.loadAll(from: dir)

        XCTAssertGreaterThanOrEqual(map.count, 2,
            "Malformed file must not block the rest from being returned")
        XCTAssertNotNil(map["0dbdb8bb-5b09-4650-992f-874fd73b5541"],
            "Well-formed entry must still be present despite a sibling malformed file")
    }

    func testIgnoresEmptyAndWhitespaceNames() {
        // empty-name.json has name == "   ". After trimming it becomes "".
        // It must be filtered out — callers rely on a non-empty contract.
        let dir = sessionsFixtureDir()
        let map = SessionNameLoader.loadAll(from: dir)

        XCTAssertNil(map["fb69c49a-7ed2-4956-bf3a-1e5c95894212"],
                     "Whitespace-only names must be filtered out post-trim")
    }
}

// JSONLoaderTests.swift
// Fixture-based tests for the schema-quirk-tolerant JSONLoader.
import XCTest
@testable import ClaudeNotch

final class JSONLoaderTests: XCTestCase {

    // MARK: - Helpers

    /// Locate a fixture by name. Tries the test bundle first, then walks up
    /// from the source file location to find Tests/ClaudeNotchTests/Fixtures/.
    /// Falling back to filesystem lookup keeps us resilient to project.yml
    /// resource configuration drift while still preferring the bundled copy.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        // Fallback: walk up from this source file to Tests/ClaudeNotchTests/Fixtures/.
        let here = URL(fileURLWithPath: #filePath)
        let fixtureURL = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("\(name).json")
        return try Data(contentsOf: fixtureURL)
    }

    // MARK: - Golden

    func testGoldenFixtureDecodesAllSessions() throws {
        let data = try loadFixture("golden")
        let sessions = try JSONLoader.decode(from: data)

        XCTAssertEqual(sessions.count, 9, "Golden fixture should yield 9 sessions")

        let running = sessions.filter { $0.status == .running }
        let idle = sessions.filter { $0.status == .idle }
        let ended = sessions.filter { $0.status == .ended }

        XCTAssertEqual(running.count, 3, "Expected 3 running sessions")
        XCTAssertEqual(idle.count, 2, "Expected 2 idle sessions")
        XCTAssertEqual(ended.count, 4, "Expected 4 ended sessions")

        // Pick a known session and verify its fields decoded correctly.
        let velionRunning = sessions.first { $0.id.hasPrefix("run-001-") }
        XCTAssertNotNil(velionRunning)
        XCTAssertEqual(velionRunning?.projectLabel, "Velion")
        XCTAssertEqual(velionRunning?.pid, 11001)
        XCTAssertEqual(velionRunning?.cwd, "/Users/benja/code/velion")
        XCTAssertEqual(velionRunning?.status, .running)
        XCTAssertNotNil(velionRunning?.startedAt)
        XCTAssertNotNil(velionRunning?.promptStartedAt)
        XCTAssertEqual(velionRunning?.lastTurnDurationS, 60)
        XCTAssertEqual(velionRunning?.lastResult, "ok")
    }

    // MARK: - Missing fields (Discovery #740)

    func testMissingFieldsUseOuterKeyAndFallbacks() throws {
        let data = try loadFixture("missing-fields")
        let sessions = try JSONLoader.decode(from: data)

        XCTAssertEqual(sessions.count, 3, "Three entries in missing-fields fixture")

        // Entry 1: outer key has hyphens; no inner session_id; no cwd; no project_label.
        // -> projectLabel should fall back to first 8 chars of outer key.
        guard let partial = sessions.first(where: { $0.id == "0dbdb8bb-5b09-4650-992f-874fd73b5541" }) else {
            XCTFail("Did not find 0dbdb8bb session by outer key")
            return
        }
        XCTAssertEqual(partial.projectLabel, "0dbdb8bb",
                       "When project_label and cwd both missing, label is first 8 chars of id")
        XCTAssertNil(partial.cwd)
        XCTAssertNil(partial.pid)
        XCTAssertEqual(partial.status, .running)

        // Entry 2: completely empty inner object -> id from outer key, label fallback.
        guard let empty = sessions.first(where: { $0.id == "fully-empty-key-aaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }) else {
            XCTFail("Did not find fully-empty session by outer key")
            return
        }
        XCTAssertEqual(empty.projectLabel, "fully-em",
                       "Empty inner object falls back to first 8 chars of outer key")
        XCTAssertEqual(empty.status, .unknown)
        XCTAssertNil(empty.cwd)

        // Entry 3: only cwd present -> projectLabel comes from basename(cwd).
        guard let cwdOnly = sessions.first(where: { $0.id == "with-cwd-only-key-aaaa-bbbb-cccc-dddd-eeeeeeeeee" }) else {
            XCTFail("Did not find cwd-only session by outer key")
            return
        }
        XCTAssertEqual(cwdOnly.projectLabel, "Workly",
                       "When project_label is missing but cwd is present, label is basename(cwd)")
        XCTAssertEqual(cwdOnly.cwd, "/Users/benja/code/Workly-GestionTrabajos/Workly")
    }

    // MARK: - Malformed

    func testMalformedJSONThrowsDecodeError() throws {
        let data = try loadFixture("malformed")
        XCTAssertThrowsError(try JSONLoader.decode(from: data)) { error in
            guard case JSONLoaderError.decode = error else {
                XCTFail("Expected JSONLoaderError.decode, got \(error)")
                return
            }
        }
    }

    // MARK: - Schema mismatch

    func testSchemaV2ThrowsSchemaMismatch() throws {
        let data = try loadFixture("schema-v2")
        XCTAssertThrowsError(try JSONLoader.decode(from: data)) { error in
            guard case JSONLoaderError.schemaMismatch(let v) = error else {
                XCTFail("Expected JSONLoaderError.schemaMismatch, got \(error)")
                return
            }
            XCTAssertEqual(v, 2)
        }
    }
}

// DisambiguationTests.swift
// Cover SessionStore.disambiguate(_:) — the post-decode pass that gives
// fallback-labeled duplicates a unique displayName so the user can tell them
// apart in the panel.
//
// Rules under test (mirrored from the implementation):
//   - Sessions with a non-empty customName are NEVER touched.
//   - Sessions sharing a fallback displayName (e.g. two "Workly") get a
//     `displayNameOverride` set:
//       * If parent dir basenames differ → "<base> · <parent>"
//       * Otherwise → "<base> · pid:<pid>"  (or "<base> · <id8>" if no pid)
import XCTest
@testable import ClaudeNotch

@MainActor
final class DisambiguationTests: XCTestCase {

    // MARK: - Builder

    private func make(
        id: String,
        projectLabel: String,
        cwd: String? = nil,
        pid: Int? = nil,
        customName: String? = nil
    ) -> SessionState {
        SessionState(
            id: id,
            projectLabel: projectLabel,
            cwd: cwd,
            pid: pid,
            status: .running,
            startedAt: nil,
            promptStartedAt: nil,
            lastTurnDurationS: nil,
            lastTurnFinishedAt: nil,
            endedAt: nil,
            lastResult: nil,
            transcriptPath: nil,
            customName: customName,
            displayNameOverride: nil
        )
    }

    // MARK: - Case 1: unique labels — no override

    func testNoDuplicates_NoOverridesApplied() {
        let input = [
            make(id: "a", projectLabel: "Workly", cwd: "/u/Projects/Workly", pid: 1),
            make(id: "b", projectLabel: "Velion", cwd: "/u/Projects/Velion", pid: 2),
        ]
        let out = SessionStore.disambiguate(input)
        for s in out {
            XCTAssertNil(s.displayNameOverride, "Unique labels should never get an override")
        }
        XCTAssertEqual(out.first { $0.id == "a" }?.displayName, "Workly")
        XCTAssertEqual(out.first { $0.id == "b" }?.displayName, "Velion")
    }

    // MARK: - Case 2: duplicate fallback label, distinct parent dirs

    func testDuplicateFallbackLabel_DisambiguatesByParentDir() {
        let input = [
            make(id: "a",
                 projectLabel: "Workly",
                 cwd: "/Users/me/Documents/Velion/Workly",
                 pid: 100),
            make(id: "b",
                 projectLabel: "Workly",
                 cwd: "/Users/me/Documents/Other/Workly",
                 pid: 200),
        ]
        let out = SessionStore.disambiguate(input)

        let a = out.first { $0.id == "a" }
        let b = out.first { $0.id == "b" }
        XCTAssertEqual(a?.displayName, "Workly · Velion")
        XCTAssertEqual(b?.displayName, "Workly · Other")
        XCTAssertNotEqual(a?.displayName, b?.displayName)
    }

    // MARK: - Case 3: duplicate fallback label, same parent dir → fallback to pid

    func testDuplicateFallbackLabel_SameParent_FallsBackToPid() {
        let input = [
            make(id: "a",
                 projectLabel: "Workly",
                 cwd: "/Users/me/Projects/Workly",
                 pid: 1234),
            make(id: "b",
                 projectLabel: "Workly",
                 cwd: "/Users/me/Projects/Workly",
                 pid: 5678),
        ]
        let out = SessionStore.disambiguate(input)
        let a = out.first { $0.id == "a" }
        let b = out.first { $0.id == "b" }

        XCTAssertEqual(a?.displayName, "Workly · pid:1234")
        XCTAssertEqual(b?.displayName, "Workly · pid:5678")
        XCTAssertNotEqual(a?.displayName, b?.displayName)
    }

    // MARK: - Case 4: customName always wins, never disambiguated

    func testCustomNameSessions_AreNeverDisambiguated() {
        // Two sessions with the same customName "Backend" — that's the user's
        // explicit choice; we don't touch them. A third session with a clean
        // duplicate fallback ("Workly" vs "Workly") still gets handled.
        let input = [
            make(id: "a",
                 projectLabel: "ServerA",
                 cwd: "/u/A",
                 pid: 1,
                 customName: "Backend"),
            make(id: "b",
                 projectLabel: "ServerB",
                 cwd: "/u/B",
                 pid: 2,
                 customName: "Backend"),
            make(id: "c",
                 projectLabel: "Workly",
                 cwd: "/u/X/Workly",
                 pid: 3),
            make(id: "d",
                 projectLabel: "Workly",
                 cwd: "/u/Y/Workly",
                 pid: 4),
        ]
        let out = SessionStore.disambiguate(input)

        // Custom-named sessions are untouched, even though they share names.
        let a = out.first { $0.id == "a" }
        let b = out.first { $0.id == "b" }
        XCTAssertNil(a?.displayNameOverride)
        XCTAssertNil(b?.displayNameOverride)
        XCTAssertEqual(a?.displayName, "Backend")
        XCTAssertEqual(b?.displayName, "Backend")

        // Fallback-labeled duplicates are still differentiated.
        let c = out.first { $0.id == "c" }
        let d = out.first { $0.id == "d" }
        XCTAssertEqual(c?.displayName, "Workly · X")
        XCTAssertEqual(d?.displayName, "Workly · Y")
    }
}

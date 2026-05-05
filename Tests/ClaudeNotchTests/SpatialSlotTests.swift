// SpatialSlotTests.swift
// Cover SpatialSlotManager — the front/left/right slot allocator that drives
// where each session lives in space (visually and audibly).
//
// Rules under test (mirrored from the implementation):
//   - First session gets `front`, second `left`, third `right`.
//   - 4th+ session goes to whichever slot has the fewest current ids,
//     ties broken in front → left → right order.
//   - assign(_:) is idempotent — re-assigning the same id returns the
//     same slot, never reallocates.
//   - prune(activeIds:) removes assignments not in the set; nothing else.
//   - ids(in:) returns ids deterministically (sorted).
//   - counts() always returns all three slots (zero if empty).
import XCTest
@testable import ClaudeNotch

@MainActor
final class SpatialSlotTests: XCTestCase {

    // MARK: - Allocation

    func testFirstThreeSessionsGetCanonicalSlots() {
        let m = SpatialSlotManager()
        XCTAssertEqual(m.assign("a"), .front)
        XCTAssertEqual(m.assign("b"), .left)
        XCTAssertEqual(m.assign("c"), .right)
    }

    func testFourthSessionStacksOntoFrontFirst() {
        let m = SpatialSlotManager()
        _ = m.assign("a")  // front
        _ = m.assign("b")  // left
        _ = m.assign("c")  // right
        // All three slots have count 1; tie broken in front order.
        XCTAssertEqual(m.assign("d"), .front)
    }

    func testFifthAndSixthFollowAllocationOrder() {
        let m = SpatialSlotManager()
        _ = m.assign("a")  // front (1)
        _ = m.assign("b")  // left (1)
        _ = m.assign("c")  // right (1)
        _ = m.assign("d")  // front (2)
        // Now front=2, left=1, right=1 → tie between left and right, left wins.
        XCTAssertEqual(m.assign("e"), .left)
        // front=2, left=2, right=1 → right is now strictly emptiest.
        XCTAssertEqual(m.assign("f"), .right)
    }

    // MARK: - Idempotence

    func testAssignIsIdempotent() {
        let m = SpatialSlotManager()
        let first = m.assign("a")
        let second = m.assign("a")
        XCTAssertEqual(first, second)
        XCTAssertEqual(m.counts()[.front], 1)
    }

    // MARK: - Prune

    func testPruneRemovesAssignmentsNotInActiveSet() {
        let m = SpatialSlotManager()
        _ = m.assign("a")
        _ = m.assign("b")
        _ = m.assign("c")
        m.prune(activeIds: ["a", "c"])
        XCTAssertEqual(m.assignments.count, 2)
        XCTAssertNotNil(m.assignments["a"])
        XCTAssertNotNil(m.assignments["c"])
        XCTAssertNil(m.assignments["b"])
    }

    func testPruneEmptySetClearsAll() {
        let m = SpatialSlotManager()
        _ = m.assign("a")
        _ = m.assign("b")
        m.prune(activeIds: [])
        XCTAssertTrue(m.assignments.isEmpty)
    }

    func testPruneDoesNotResequenceRemainingSessions() {
        let m = SpatialSlotManager()
        _ = m.assign("a")  // front
        _ = m.assign("b")  // left
        _ = m.assign("c")  // right
        m.prune(activeIds: ["b", "c"])
        XCTAssertEqual(m.assignments["b"], .left)
        XCTAssertEqual(m.assignments["c"], .right)
        XCTAssertNil(m.assignments["a"])
    }

    // MARK: - Querying

    func testIdsInSlotReturnsDeterministicOrder() {
        let m = SpatialSlotManager()
        _ = m.assign("z-second")  // front
        _ = m.assign("a-first")   // left
        _ = m.assign("m-third")   // right
        _ = m.assign("a-fourth")  // front (stacks)
        let frontIds = m.ids(in: .front)
        XCTAssertEqual(frontIds, ["a-fourth", "z-second"])
    }

    func testCountsAlwaysHasThreeSlots() {
        let m = SpatialSlotManager()
        let countsEmpty = m.counts()
        XCTAssertEqual(countsEmpty.count, 3)
        XCTAssertEqual(countsEmpty[.front], 0)
        XCTAssertEqual(countsEmpty[.left], 0)
        XCTAssertEqual(countsEmpty[.right], 0)

        _ = m.assign("a")
        let countsAfter = m.counts()
        XCTAssertEqual(countsAfter[.front], 1)
        XCTAssertEqual(countsAfter[.left], 0)
        XCTAssertEqual(countsAfter[.right], 0)
    }

    // MARK: - Edge

    func testReassignAfterPruneFillsTheVacancy() {
        let m = SpatialSlotManager()
        _ = m.assign("a")  // front
        _ = m.assign("b")  // left
        _ = m.assign("c")  // right
        m.prune(activeIds: ["a", "c"])
        // left is now empty; new session should land there.
        XCTAssertEqual(m.assign("d"), .left)
    }
}

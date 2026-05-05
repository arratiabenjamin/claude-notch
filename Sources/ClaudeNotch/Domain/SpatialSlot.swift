// SpatialSlot.swift
// Maps a session id → one of three positions around the central orb (front,
// left, right). The slot is stable across the lifetime of the app process
// once assigned — your brain learns "Workly is on the left" and the audio
// in Phase 5 will keep the same direction.
//
// Allocation policy:
//   1. New session not yet mapped: pick the slot with the smallest count
//      (ties broken in `front, left, right` order). This places the first
//      session in the front, the second on the left, the third on the right,
//      and any 4th+ stacks onto whichever slot has fewest sessions so far.
//   2. Session disappears (left active list AND not in manuallyEnded): we
//      release its slot so a future session can fill it.
//
// The slot manager is `@MainActor` so OrbView can read it without bridging.
// All mutation funnels through `assign(_:)` and `prune(activeIds:)`.
//
// This type owns presentation state, not domain truth — putting it in
// Domain/ is a small abuse but it's a pure data structure with no UI types
// imported, and SessionStore wants to coordinate slot lifecycle alongside
// session lifecycle.
import Foundation

enum SpatialSlot: String, CaseIterable, Sendable, Hashable {
    case front
    case left
    case right

    /// The deterministic order we assign slots to first-time sessions when
    /// multiple slots are equally empty. Front first so a single session
    /// always sits dead center.
    static let allocationOrder: [SpatialSlot] = [.front, .left, .right]
}

@MainActor
final class SpatialSlotManager {
    /// session id → slot. Persists across watcher ticks while the app runs.
    private(set) var assignments: [String: SpatialSlot] = [:]

    /// Assign or return the existing slot for `id`. Idempotent.
    @discardableResult
    func assign(_ id: String) -> SpatialSlot {
        if let existing = assignments[id] { return existing }
        let slot = pickEmptiestSlot()
        assignments[id] = slot
        return slot
    }

    /// Drop assignments whose session id is no longer alive. Called by the
    /// store after every successful ingest.
    func prune(activeIds: Set<String>) {
        assignments = assignments.filter { activeIds.contains($0.key) }
    }

    /// Return the ids assigned to `slot`, sorted by assignment recency
    /// (oldest first → tops of the visual stack).
    func ids(in slot: SpatialSlot) -> [String] {
        assignments
            .filter { $0.value == slot }
            .map { $0.key }
            .sorted()
    }

    /// Counts per slot, including empty ones. Always returns 3 entries.
    func counts() -> [SpatialSlot: Int] {
        var c: [SpatialSlot: Int] = [:]
        for slot in SpatialSlot.allCases { c[slot] = 0 }
        for slot in assignments.values { c[slot, default: 0] += 1 }
        return c
    }

    // MARK: - Internals

    /// Pick the slot with the fewest sessions. Tie-break by `allocationOrder`
    /// so `front` wins when everything is empty, `left` when front and left
    /// tie, and so on.
    private func pickEmptiestSlot() -> SpatialSlot {
        let counts = counts()
        return SpatialSlot.allocationOrder.min { lhs, rhs in
            (counts[lhs] ?? 0) < (counts[rhs] ?? 0)
        } ?? .front
    }
}

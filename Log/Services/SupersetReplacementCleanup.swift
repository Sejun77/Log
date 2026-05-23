import Foundation

// MARK: - Phase 6.C3 — Superset replacement round-order consistency
//
// When a slot in a superset block is replaced/swapped, the replaced
// slot's logs are cleared by the existing swap path. That clear is
// correct in isolation, but it can leave the superset in an
// inconsistent state because round completion is a cross-slot
// invariant: the logs across the block must form a prefix of the
// round-interleaved sequence
//
//     slot0[0], slot1[0], ..., slotN[0],
//     slot0[1], slot1[1], ..., slotN[1],
//     ...
//
// Example (superset A, B; A is replaced after A1 + B1 were logged):
//
//   Before:  A logged={0},  B logged={0}        (round 1 complete)
//   After:   A logged={},   B logged={0}        ← invalid: B1 logged
//                                                  while A1 (the
//                                                  earlier required
//                                                  member of round 1)
//                                                  is unlogged.
//
// This helper computes exactly which `(slotID, setIndex)` pairs must
// also be cleared to restore the prefix invariant. Callers pass the
// `loggedBySlot` state *after* the replaced slot's own logs have been
// cleared; the returned dictionary lists the additional clears
// needed.
//
// The helper is pure (no SwiftData, no UI, no I/O) so it is safe to
// call from a SwiftUI `View` and from tests with literal fixtures.

/// Compute the additional logged-set indices that must be cleared
/// in a superset block to restore the strict round-order invariant.
///
/// - Parameters:
///   - slotOrder: The superset's slots in block-execution order
///     (`PlanBlock.exercises.map(\.routineSlotID)`). Order is
///     load-bearing — defines which slot is "earlier" in a round.
///   - setCounts: Effective working-set count for each slot. A round
///     index `r >= setCounts[slot]` is treated as "this slot does not
///     participate in round r"; no truncation triggers for it. This
///     keeps the helper correct for superset blocks where members
///     have unequal set counts.
///   - loggedBySlot: Current per-slot logged set indices. Pass the
///     state *after* the replaced slot's logs have been cleared
///     (i.e. `loggedBySlot[replacedSlot]` should be empty or absent).
///
/// - Returns: A dictionary mapping each slot ID to the set indices
///   in that slot whose logs are now invalidated by the prefix rule
///   and must be cleared. Slots with no extraneous logs are omitted.
///
/// Pure function. Time complexity is O(slots × maxRound).
func supersetLogsToInvalidate(
    slotOrder: [UUID],
    setCounts: [UUID: Int],
    loggedBySlot: [UUID: Set<Int>]
) -> [UUID: Set<Int>] {
    var extraneous: [UUID: Set<Int>] = [:]
    guard !slotOrder.isEmpty else { return extraneous }

    let maxRound = loggedBySlot.values.flatMap { $0 }.max() ?? -1
    guard maxRound >= 0 else { return extraneous }

    // Walk the round-interleaved sequence. Once any slot in a round is
    // found unlogged (where it should have participated), every later
    // log in the sequence is extraneous.
    var truncating = false
    for r in 0...maxRound {
        for slotID in slotOrder {
            // Slots that don't reach round r don't participate; skip
            // without triggering truncation. This matches
            // `supersetRoundComplete` in the active workout, which
            // also skips slots with `setCount <= r`.
            let setCount = setCounts[slotID] ?? 0
            guard r < setCount else { continue }

            let isLogged = loggedBySlot[slotID]?.contains(r) ?? false
            if truncating {
                if isLogged {
                    extraneous[slotID, default: []].insert(r)
                }
            } else if !isLogged {
                truncating = true
            }
        }
    }
    return extraneous
}

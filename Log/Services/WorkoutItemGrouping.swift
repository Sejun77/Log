import Foundation

// MARK: - Phase 6.C1 — History source-block grouping

/// One History-display group of `WorkoutItem` rows. A group is either:
///   * a single standalone exercise (`isSuperset == false`, one member),
///   * a single superset-block aggregation (`isSuperset == true`,
///     one-or-more members sharing the same `sourceBlockSlotID`), or
///   * a legacy item with no snapshot fields (`isSuperset == false`,
///     `sourceBlockSlotID == nil`, one member — renders flat under the
///     future Phase 6.C2 display path, matching pre-6.C1 behavior).
struct WorkoutItemGroup {
    var items: [WorkoutItem]
    /// `true` only when the source block was a superset *and* the items
    /// in this group all share its `sourceBlockSlotID`. A superset block
    /// with a single surviving member still reports `true` — display
    /// code (Phase 6.C2) can choose how to render single-member supersets.
    var isSuperset: Bool
    /// Group identity for superset members. `nil` for standalone /
    /// legacy items.
    var sourceBlockSlotID: UUID?
    /// Snapshot of `RoutineBlock.order` in the source variant. `nil` for
    /// legacy items; ordered last (stable input-order tiebreaker keeps
    /// legacy items in the workout's chronological order of first
    /// appearance).
    var sourceBlockOrder: Int?
}

/// Partition `WorkoutItem`s into source-block groups, then sort.
///
/// Grouping rule:
///   * Items where `sourceBlockIsSuperset == true` *and*
///     `sourceBlockSlotID != nil` are merged with any earlier item
///     sharing the same `sourceBlockSlotID` into one group.
///   * All other items (`sourceBlockIsSuperset == false`, nil, or
///     missing `sourceBlockSlotID`) become singleton groups.
///
/// Sort rule:
///   * Outer groups sorted by `sourceBlockOrder ?? Int.max`, stable —
///     ties (including legacy nil rows that all coalesce to
///     `Int.max`) keep their first-appearance order in the input.
///   * Superset-group members sorted by
///     `sourceExerciseOrderInBlock ?? Int.max`, stable — preserves
///     intra-block authoring order; legacy nil falls last.
///
/// Pure function — no SwiftData mutation, no `ctx.save()`, no side
/// effects. Safe to call from a View `body` and from tests.
func groupItemsBySourceBlock(
    _ items: [WorkoutItem]
) -> [WorkoutItemGroup] {
    var groups: [WorkoutItemGroup] = []
    var supersetIndexByBlockID: [UUID: Int] = [:]

    for item in items {
        if item.sourceBlockIsSuperset == true,
           let blockID = item.sourceBlockSlotID
        {
            if let groupIdx = supersetIndexByBlockID[blockID] {
                groups[groupIdx].items.append(item)
                // First non-nil sourceBlockOrder we see for this group
                // becomes its sort key; later non-nil values are ignored
                // because the snapshot is supposed to be consistent across
                // members of the same source block.
                if groups[groupIdx].sourceBlockOrder == nil {
                    groups[groupIdx].sourceBlockOrder = item.sourceBlockOrder
                }
            } else {
                supersetIndexByBlockID[blockID] = groups.count
                groups.append(WorkoutItemGroup(
                    items: [item],
                    isSuperset: true,
                    sourceBlockSlotID: blockID,
                    sourceBlockOrder: item.sourceBlockOrder
                ))
            }
        } else {
            groups.append(WorkoutItemGroup(
                items: [item],
                isSuperset: false,
                sourceBlockSlotID: item.sourceBlockSlotID,
                sourceBlockOrder: item.sourceBlockOrder
            ))
        }
    }

    // Sort superset-group members by sourceExerciseOrderInBlock (stable).
    for i in groups.indices where groups[i].isSuperset {
        let stable = groups[i].items.enumerated().sorted { a, b in
            let aOrder = a.element.sourceExerciseOrderInBlock ?? Int.max
            let bOrder = b.element.sourceExerciseOrderInBlock ?? Int.max
            if aOrder != bOrder { return aOrder < bOrder }
            return a.offset < b.offset
        }
        groups[i].items = stable.map(\.element)
    }

    // Stable outer sort by sourceBlockOrder.
    let stable = groups.enumerated().sorted { a, b in
        let aOrder = a.element.sourceBlockOrder ?? Int.max
        let bOrder = b.element.sourceBlockOrder ?? Int.max
        if aOrder != bOrder { return aOrder < bOrder }
        return a.offset < b.offset
    }
    return stable.map(\.element)
}

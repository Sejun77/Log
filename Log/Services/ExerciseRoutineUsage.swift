import Foundation

/// Read-only summary of which routines reference a given `Exercise`.
///
/// Built once from a live `[Routine]` snapshot (typically a sorted `@Query`)
/// and a target `exerciseID`. Pure value type — no SwiftData fetches, no
/// mutation — so it is safe to compute outside the SwiftUI `body` and unit
/// testable in isolation.
///
/// Counting rules (Exercise Detail "Used in Routines" polish):
///  - Counts **unique routines**, not slots. A routine that references the
///    exercise in two slots is one `Entry` with `slotCount == 2`.
///  - Scans `Routine.blocks` only. `RoutineVariant.blocks` are intentionally
///    ignored: variants are seeded empty at bootstrap and the routine editor
///    operates exclusively on `Routine.blocks`, matching the delete-impact
///    and Routines-tab summary logic.
///  - Matches by `RoutineExercise.exercise?.id == exerciseID`. A `nil`
///    (unlinked / deleted) exercise reference never matches and is skipped.
///  - Entries are ordered by `(Routine.order, Routine.name)` — the same order
///    the Routines tab shows.
struct ExerciseRoutineUsage {
    struct Entry: Equatable {
        let routineID: UUID
        let routineName: String
        /// Number of `RoutineExercise` slots in this routine that reference
        /// the target exercise. Always `>= 1` for an entry that exists.
        let slotCount: Int

        /// Slot-count suffix shown after the routine name, e.g. `"· 2 slots"`.
        /// `nil` for normal single usage so the row shows the bare name —
        /// `"· 1 slot"` is never rendered.
        var slotSuffix: String? {
            slotCount > 1 ? "· \(slotCount) slots" : nil
        }
    }

    /// One entry per routine that references the exercise at least once,
    /// ordered by `(Routine.order, Routine.name)`.
    let entries: [Entry]

    init(routines: [Routine], exerciseID: UUID) {
        let ordered = routines.sorted {
            ($0.order, $0.name) < ($1.order, $1.name)
        }

        var built: [Entry] = []
        for routine in ordered {
            var slots = 0
            for block in routine.blocks {
                for slot in block.exercises where slot.exercise?.id == exerciseID {
                    slots += 1
                }
            }
            if slots > 0 {
                built.append(
                    Entry(
                        routineID: routine.id,
                        routineName: routine.name,
                        slotCount: slots
                    )
                )
            }
        }
        self.entries = built
    }

    /// Number of unique routines referencing the exercise.
    var routineCount: Int { entries.count }

    /// Pluralized count line, e.g. `"Used in 0 routines"` / `"Used in 1 routine"`.
    var summary: String {
        "Used in \(routineCount) routine\(routineCount == 1 ? "" : "s")"
    }
}

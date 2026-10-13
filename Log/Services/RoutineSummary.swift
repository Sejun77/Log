import Foundation

/// Read-only one-line summary of a `Routine`'s contents, shown as the subtitle
/// under each routine name in the Saved Routines list.
///
/// Pure value type — no SwiftData fetches, no `ModelContext`, no mutation — so
/// it is safe to compute outside the SwiftUI `body` (build a `map(for:)` once
/// per render and look up by `routine.id`) and unit-testable in isolation.
///
/// Counting rules:
///  - **Exercises = total `RoutineExercise` slots** across every `RoutineBlock`
///    in `Routine.blocks` (sum of `block.exercises.count`). It counts *slots*,
///    not unique exercises, so a routine that lists the same exercise twice
///    reports two. Supersets contribute their member slots to this total too.
///  - **Supersets = count of blocks where `isSuperset == true`.**
///  - `RoutineVariant.blocks` are intentionally **not** counted: variants seed
///    empty at bootstrap and the routine editor operates exclusively on
///    `Routine.blocks`, matching `ExerciseRoutineUsage` and the delete-impact
///    logic.
///  - A slot whose `exercise` reference is **nil** (deleted / unlinked) still
///    counts toward the exercise total. The summary reflects *programmed slots*;
///    orphan slots are transient (`RoutineEditor.normalizeRoutineModel` removes
///    them when the editor opens). Counting structurally — by `exercises.count`,
///    never dereferencing `re.exercise` — also keeps this helper pure and free
///    of any model-faulting, so a nil reference can never crash it.
struct RoutineSummary: Equatable {
    /// Total `RoutineExercise` slots across all `Routine.blocks`.
    let exerciseCount: Int
    /// Number of blocks with `isSuperset == true`.
    let supersetCount: Int

    /// Value-in initializer — exercised by unit tests for the wording rules
    /// without needing a SwiftData model.
    init(exerciseCount: Int, supersetCount: Int) {
        self.exerciseCount = exerciseCount
        self.supersetCount = supersetCount
    }

    /// Build from a live `Routine`. Scans `routine.blocks` only.
    init(routine: Routine) {
        var exercises = 0
        var supersets = 0
        for block in routine.blocks {
            exercises += block.exercises.count
            if block.isSuperset { supersets += 1 }
        }
        self.init(exerciseCount: exercises, supersetCount: supersets)
    }

    /// Subtitle shown under the routine name.
    ///  - no slots → `"Empty routine"`
    ///  - slots, no supersets → `"5 exercises"` / `"1 exercise"`
    ///  - slots + supersets → `"8 exercises · 2 supersets"` / `"… · 1 superset"`
    var subtitle: String {
        guard exerciseCount > 0 else { return String(localized: "Empty routine") }
        let exercises = exerciseCount == 1
            ? String(localized: "\(exerciseCount) exercise")
            : String(localized: "\(exerciseCount) exercises")
        guard supersetCount > 0 else { return exercises }
        let supersets = supersetCount == 1
            ? String(localized: "\(supersetCount) superset")
            : String(localized: "\(supersetCount) supersets")
        return "\(exercises) · \(supersets)"
    }

    /// Body copy for the "delete this routine" confirmation.
    ///
    /// Counts the same two things the subtitle above it counts, with the same
    /// localized noun phrases, so the sentence cannot contradict the row the
    /// user just tapped. It used to report the routine's **block** count
    /// ("remove 4 blocks (1 superset)"), which named the model's grouping
    /// type and disagreed with the subtitle's exercise count on the same
    /// screen.
    ///
    /// Two shapes rather than one: a routine with no supersets said
    /// "(0 superset)", a parenthetical that was both ungrammatical and about
    /// nothing. The parenthetical now appears only when there is a superset to
    /// name.
    ///
    /// Built from `String(localized:)` throughout. The previous sentence was a
    /// raw multi-line literal that appended `"s"` at runtime, so it had no
    /// catalog key and a Korean user met this destructive confirmation in
    /// English.
    func deleteConfirmationMessage(routineName: String) -> String {
        let exercises =
            exerciseCount == 1
            ? String(localized: "\(exerciseCount) exercise")
            : String(localized: "\(exerciseCount) exercises")

        guard supersetCount > 0 else {
            return String(
                localized:
                    "Delete “\(routineName)”? This will remove \(exercises) and all of their exercise references. This cannot be undone."
            )
        }

        let supersets =
            supersetCount == 1
            ? String(localized: "\(supersetCount) superset")
            : String(localized: "\(supersetCount) supersets")
        return String(
            localized:
                "Delete “\(routineName)”? This will remove \(exercises) (\(supersets)) and all of their exercise references. This cannot be undone."
        )
    }

    /// Precompute one summary per routine, keyed by `routine.id`, so the
    /// Routines list can build the map once per render and avoid re-scanning
    /// `routine.blocks` inside each row's `body`.
    static func map(for routines: [Routine]) -> [UUID: RoutineSummary] {
        var result: [UUID: RoutineSummary] = [:]
        result.reserveCapacity(routines.count)
        for routine in routines {
            result[routine.id] = RoutineSummary(routine: routine)
        }
        return result
    }
}

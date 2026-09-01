import Foundation
import SwiftData

// ======================================================
// MARK: - Deleting an Exercise (Build 10 C1)
// ======================================================
//
// Deleting an `Exercise` has always removed the routine slots that referenced
// it. It did **not** touch prepared alternatives, because alternatives are
// stored inside `SlotPrescription.alternativesData` rather than as their own
// `@Model` rows, so no delete rule reaches them.
//
// That left two defects, both of them the user being misinformed rather than
// the store being wrong:
//
//  1. `ExerciseRoutineUsage` never counted alternatives, so an exercise used
//     only as a prepared alternative reported "Used in 0 routines" — and the
//     delete confirmation said "This cannot be undone" without naming the
//     prepared work it was about to strand.
//  2. Nothing pruned the alternatives afterwards, so every one of them became
//     a dangling `exerciseID` that resurfaced mid-workout as a disabled
//     `Exercise unavailable` row in the switch sheet.
//
// **Product decision for this slice: prune, don't strand.** The user deleted
// the exercise from their library, and the confirmation now tells them the
// prepared alternatives go with it. Keeping a deleted exercise alive as a
// permanently-unusable row in a routine the user cannot repair (the editor
// offers no "re-point this alternative") is the worse of the two, and it is
// the behaviour the Build 10 audit filed as Critical.
//
// The impact type and the cleanup live here, out of the SwiftUI alert closure
// that used to hold them, so both are unit-testable — the same split
// `ExerciseSwitchDeletionImpact` / `ExerciseSwitchConfirmationCopy` already
// use for the mid-workout switch confirmation.

// ======================================================
// MARK: - Impact
// ======================================================

/// What deleting one `Exercise` would cost, counted before anything is
/// deleted.
///
/// Pure value type over a `[Routine]` snapshot — no fetches, no mutation, no
/// `ModelContext` — so the confirmation copy can be pinned by tests without
/// rendering a view or deleting anything.
///
/// Matches direct slots by `RoutineExercise.exercise?.id`, exactly as
/// `ExerciseRoutineUsage` does. (`safeExercise(in:)`, which the pre-C1 inline
/// version used, additionally rejects models detached from a context — a state
/// that cannot occur here, because the message is built from a live `@Query`
/// *before* any deletion runs. Matching the sibling helper that renders on the
/// same screen keeps the two counts from ever disagreeing.)
struct ExerciseDeletionImpact: Equatable {

    /// Unique routines holding at least one **direct** reference. This is the
    /// number the existing confirmation sentence reports, and it deliberately
    /// excludes alternative-only routines so that sentence keeps its pre-C1
    /// meaning.
    let routineCount: Int

    /// Superset blocks that will be deleted whole (a superset that loses a
    /// member is deleted rather than left short — the pre-existing rule).
    let supersetBlockCount: Int

    /// Non-superset blocks holding a direct reference, whose slot is unlinked.
    let normalReferenceCount: Int

    /// Prepared alternatives that will be pruned, across every routine and
    /// slot. Disabled alternatives are counted: they are still prepared work.
    let alternativeCount: Int

    init(routines: [Routine], exerciseID: UUID) {
        var supersets = 0
        var normals = 0
        var alternatives = 0
        var affected = Set<UUID>()

        for routine in routines {
            for block in routine.blocks {
                var blockHasDirectReference = false
                for slot in block.exercises {
                    if slot.exercise?.id == exerciseID {
                        blockHasDirectReference = true
                    }
                    // Tolerant decode: a nil / empty / corrupt column reads as
                    // `[]`, so stored data can never make this scan fail.
                    alternatives += slot.prescription?.slotAlternatives
                        .filter { $0.exerciseID == exerciseID }.count ?? 0
                }
                if blockHasDirectReference {
                    affected.insert(routine.id)
                    if block.isSuperset { supersets += 1 } else { normals += 1 }
                }
            }
        }

        self.routineCount = affected.count
        self.supersetBlockCount = supersets
        self.normalReferenceCount = normals
        self.alternativeCount = alternatives
    }

    /// Value-in initializer, for wording tests that need no model graph.
    init(
        routineCount: Int,
        supersetBlockCount: Int,
        normalReferenceCount: Int,
        alternativeCount: Int
    ) {
        self.routineCount = routineCount
        self.supersetBlockCount = supersetBlockCount
        self.normalReferenceCount = normalReferenceCount
        self.alternativeCount = alternativeCount
    }

    /// Whether any routine references the exercise directly.
    var hasDirectUsage: Bool {
        supersetBlockCount > 0 || normalReferenceCount > 0
    }

    /// Whether the exercise is referenced at all.
    var isUsed: Bool { hasDirectUsage || alternativeCount > 0 }

    /// Body copy for the delete confirmation.
    ///
    /// Three shapes, so the message never claims more than it knows:
    ///
    ///  - **Unused** → the bare "cannot be undone" line.
    ///  - **Direct usage** → the pre-C1 sentence, word for word. It is the one
    ///    branch this slice deliberately leaves alone: its counts and phrasing
    ///    are unchanged, so nothing about deleting a normally-used exercise
    ///    reads differently than it did in Build 9.
    ///  - **Alternatives present** → a second sentence appended to whichever of
    ///    the two heads applies. It is its own sentence rather than another
    ///    clause because alternatives are a different kind of loss from a
    ///    removed slot, and burying them mid-list is how they went unnoticed in
    ///    the first place.
    func message(exerciseName: String) -> String {
        let head: String
        if hasDirectUsage {
            // Preserved verbatim from the pre-C1 inline implementation.
            head = """
                Delete “\(exerciseName)”? This will remove it from \(routineCount) routine\(routineCount == 1 ? "" : "s"), delete \(supersetBlockCount) superset block\(supersetBlockCount == 1 ? "" : "s"), and unlink \(normalReferenceCount) exercise reference\(normalReferenceCount == 1 ? "" : "s"). This cannot be undone.
                """
        } else {
            head = String(
                localized: "Delete “\(exerciseName)”? This cannot be undone.")
        }

        guard alternativeCount > 0 else { return head }

        let alternatives =
            alternativeCount == 1
            ? String(
                localized:
                    "It is also used as \(alternativeCount) prepared alternative, which will be removed."
            )
            : String(
                localized:
                    "It is also used as \(alternativeCount) prepared alternatives, which will be removed."
            )
        return head + "\n\n" + alternatives
    }
}

// ======================================================
// MARK: - Cleanup
// ======================================================

/// The deletion itself: the `Exercise`, its direct routine references, and its
/// prepared alternatives.
///
/// Lifted out of `ExercisesView`'s alert closure so the alternative pruning
/// this slice adds is testable next to the direct-slot cleanup it runs with.
///
/// `@MainActor` to match `RoutineBlockBuilder`, which it delegates the child
/// detach-then-delete ordering to, and the SwiftUI alert that calls it.
@MainActor
enum ExerciseDeletionService {

    /// Delete `exercise` and every reference to it.
    ///
    /// **Both cleanups run before the `Exercise` itself is deleted.** The
    /// pre-C1 code deleted first and swept afterwards, which two things make
    /// unworkable now:
    ///
    ///  - `Exercise.routineUsages` is a `.cascade` relationship, so deleting
    ///    the exercise turns the very slots the sweep is looking for into
    ///    invalidated tombstones with a nil `exercise` — the sweep can no
    ///    longer recognise what it is meant to remove.
    ///  - Those tombstones stay in `RoutineBlock.exercises` (a
    ///    `RoutineExercise` declares no inverse to its block), and the pre-C1
    ///    sweep then wrote a renumbered `order` onto them. That made the
    ///    closing `ctx.save()` fail validation — silently, because the save was
    ///    a `try?`. Harmless while nothing else depended on that save; **not**
    ///    harmless now, because the alternative pruning this slice adds is
    ///    written in the same transaction and would be rolled back with it.
    ///
    /// Resolving references while the exercise is still alive avoids both.
    static func delete(_ exercise: Exercise, in ctx: ModelContext) {
        let deletedID = exercise.id
        let routines = (try? ctx.fetch(FetchDescriptor<Routine>())) ?? []

        removeDirectReferences(to: deletedID, in: routines, ctx: ctx)
        pruneAlternatives(referencing: deletedID, in: routines)

        ctx.delete(exercise)
        try? ctx.save()
    }

    /// Remove the exercise's direct routine slots.
    ///
    /// Same rules as pre-C1 — a superset block holding the exercise is deleted
    /// whole, a normal block has just the matching slots removed and its
    /// survivors renumbered — but routed through `RoutineBlockBuilder`, which
    /// detaches each child from its parent `@Relationship` **before** deleting
    /// it. That ordering is the whole reason those helpers exist (see
    /// `RoutineEditorDeletionTests`); the pre-C1 copy here open-coded the
    /// delete without it and left the parent arrays holding tombstones.
    static func removeDirectReferences(
        to exerciseID: UUID, in routines: [Routine], ctx: ModelContext
    ) {
        for routine in routines {
            for block in Array(routine.blocks) {
                let matching = block.exercises.filter { slot in
                    slot.exercise?.id == exerciseID
                }
                guard !matching.isEmpty else { continue }

                if block.isSuperset {
                    // A superset that loses a member is deleted whole, not left
                    // short — the pre-existing rule.
                    RoutineBlockBuilder.deleteBlock(
                        block, from: routine, in: ctx)
                } else {
                    RoutineBlockBuilder.removeExercises(
                        matching, from: block, in: ctx)
                }
            }
            let blocks = routine.blocks.sorted { $0.order < $1.order }
            for (index, block) in blocks.enumerated() { block.order = index }
        }
    }

    /// Drop every prepared alternative pointing at `exerciseID`, from every
    /// slot of every routine.
    ///
    /// Writes through `setSlotAlternatives`, which is what guarantees the three
    /// things this cleanup must not get wrong: surviving alternatives keep
    /// their ids and are renumbered densely, and removing the **last** one
    /// clears `alternativesData` to nil rather than storing an empty payload —
    /// so a slot that has lost all of its alternatives is indistinguishable
    /// from one that never had any.
    ///
    /// Only writes when something actually matched. A slot whose column is nil,
    /// empty, or corrupt decodes to `[]`, matches nothing, and is left exactly
    /// as it was — so this pass can neither crash on unreadable data nor
    /// silently rewrite it.
    ///
    /// - Returns: how many alternatives were removed.
    @discardableResult
    static func pruneAlternatives(
        referencing exerciseID: UUID, in routines: [Routine]
    ) -> Int {
        var removed = 0
        for routine in routines {
            for block in routine.blocks {
                for slot in block.exercises {
                    guard let prescription = slot.prescription else { continue }
                    let current = prescription.slotAlternatives
                    let kept = current.filter { $0.exerciseID != exerciseID }
                    guard kept.count != current.count else { continue }
                    removed += current.count - kept.count
                    prescription.setSlotAlternatives(kept)
                }
            }
        }
        return removed
    }
}

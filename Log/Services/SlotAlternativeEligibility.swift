import Foundation

// ======================================================
// MARK: - Which exercises may be a slot's alternative (Build 10)
// ======================================================
//
// An Alternative Exercise is a *replacement* for the slot's own exercise, so
// the slot's own exercise is not one of them. Until this slice that was a
// warning in the detail editor and a filter in the switch sheet — the routine
// editor's Add Alternative picker still listed the slot's exercise, and adding
// it stored a row that could never be offered.
//
// The rule is centralized here rather than repeated at each site because it is
// applied in three different layers:
//
//   * **Authoring** — `SlotAlternativeAuthoring.append` refuses it, and the
//     picker never lists it (`SlotAlternativesEditor`).
//   * **Display** — the routine editor still *shows* an alternative that is
//     already the slot's exercise, marked, so a legacy row can be seen and
//     deleted (§8.7's rule for a deleted exercise, applied to this case).
//   * **Workout-facing** — `PreparedAlternatives` never offers one, and
//     `BlockPrescriptionSummary` never counts one.
//
// **Comparison is by `exerciseID`, never by name.** Two library exercises may
// legitimately share a display name; they are different exercises, and one is
// a perfectly valid alternative for the other.
//
// **Nothing here deletes.** An alternative stored before this rule existed
// (or arriving through import / duplication, which copy a document faithfully)
// stays on the slot until the user removes it. Silently dropping prepared work
// on read would be the one behavior worse than never offering it.

/// Whether an exercise may serve as a prepared alternative for a slot.
enum SlotAlternativeEligibility {

    /// Whether `exerciseID` may be added as an alternative for a slot whose own
    /// exercise is `slotExerciseID`.
    ///
    /// A `nil` `slotExerciseID` — an orphan slot, or a caller with no slot in
    /// hand — imposes no restriction: there is no main exercise to collide
    /// with, and refusing everything would be worse than refusing nothing.
    static func isEligible(exerciseID: UUID, slotExerciseID: UUID?) -> Bool {
        guard let slotExerciseID else { return true }
        return exerciseID != slotExerciseID
    }

    /// Whether a stored alternative names the slot's own exercise.
    ///
    /// The inverse of `isEligible` over a `SlotAlternative`, spelled separately
    /// because the display sites read better asking the positive question.
    static func isSameAsSlotExercise(
        _ alternative: SlotAlternative, slotExerciseID: UUID?
    ) -> Bool {
        !isEligible(
            exerciseID: alternative.exerciseID, slotExerciseID: slotExerciseID)
    }

    /// The library rows an Add Alternative picker may list for this slot.
    ///
    /// Generic over the id accessor so it stays free of SwiftData: the editor
    /// passes `\Exercise.id`.
    static func selectable<T>(
        _ candidates: [T], slotExerciseID: UUID?, id: (T) -> UUID
    ) -> [T] {
        candidates.filter {
            isEligible(exerciseID: id($0), slotExerciseID: slotExerciseID)
        }
    }

    /// The alternatives that count as *prepared* for a workout: enabled, and
    /// not the slot's own exercise.
    ///
    /// The shared basis for the two workout-facing numbers — the routine
    /// editor's `… · 2 alternatives` block subtitle and the active workout's
    /// Switch Exercise badge — so neither can promise a row the switch sheet
    /// will not show. Availability (whether the exercise still exists) is
    /// deliberately *not* part of this: an unavailable alternative is still
    /// rendered, disabled and explained, by `PreparedAlternatives`.
    static func workoutFacing(
        _ alternatives: [SlotAlternative], slotExerciseID: UUID?
    ) -> [SlotAlternative] {
        alternatives.filter {
            $0.isEnabled && !isSameAsSlotExercise($0, slotExerciseID: slotExerciseID)
        }
    }
}

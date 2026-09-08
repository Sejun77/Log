import Foundation

// ======================================================
// MARK: - Which alternatives a slot offers mid-workout (Phase F1)
// ======================================================

/// One prepared alternative as the active-workout switch sheet sees it.
///
/// Pure value type — no SwiftData, no SwiftUI — so the filtering rules below
/// are unit-testable without a store or a view.
struct PreparedAlternativeOffer: Identifiable, Equatable {

    let alternative: SlotAlternative

    /// Whether the alternative's `exerciseID` still resolves to an exercise in
    /// the library. `false` renders a disabled `Exercise unavailable` row —
    /// **not** a hidden one (§8.7): the user prepared this work and deserves to
    /// see why it is not being offered, and the frozen `exerciseName` is what
    /// makes that possible.
    let isAvailable: Bool

    var id: UUID { alternative.id }
    var exerciseName: String { alternative.exerciseName }

    /// The usage note, if the user wrote one. Blank notes are already
    /// normalized to nil by the Phase B codec, so this needs no second rule.
    var note: String? { alternative.note }
}

/// The offer rules for the active-workout switch sheet.
///
/// Every rule here is a *visibility* decision. What happens when one is applied
/// belongs to `ExerciseSwitchPlanAdapter`; nothing in this file adapts,
/// compares tracking modes, or touches a prescription.
enum PreparedAlternatives {

    /// The alternatives this slot can offer right now, in authored order.
    ///
    /// - Parameters:
    ///   - alternatives: the slot's **frozen** list, from its `SessionPlan` —
    ///     never the routine's current one. The session offers what it froze at
    ///     start (§4.2).
    ///   - currentExerciseID: the exercise in the slot right now, which may
    ///     already be an alternative the user applied.
    ///   - slotExerciseID: the exercise the slot **started** with
    ///     (`PlanExercise.originalExerciseID`). Distinct from
    ///     `currentExerciseID` the moment the user switches: after a switch the
    ///     original becomes a legitimate thing to switch *back* to, while an
    ///     alternative that names it was never a switch at all. Nil imposes no
    ///     restriction.
    ///   - availableExerciseIDs: ids present in the library, for the
    ///     unavailable check.
    ///
    /// Four rules, all from §8.5 / §8.7:
    ///
    ///  1. **Disabled alternatives are hidden.** `isEnabled == false` means
    ///     "keep the prepared work, don't offer it" — the routine editor still
    ///     lists it with an `Off` marker.
    ///  2. **The exercise currently in the slot is hidden.** Switching Bench
    ///     Press to Bench Press is not a switch; offering it would quietly turn
    ///     the feature into a second plan-preset system.
    ///  3. **An alternative that names the slot's own exercise is hidden**,
    ///     even once the slot holds something else. Authoring one is refused
    ///     now (`SlotAlternativeEligibility`), but a slot prepared before that
    ///     rule — or imported / duplicated from a document that carries one —
    ///     can still hold it, and applying it would "replace" the exercise
    ///     with itself. No warning is shown mid-workout; the routine editor
    ///     marks the row instead.
    ///  4. **A deleted exercise is kept, and marked.** Hiding it silently would
    ///     look like the app lost the user's prepared work.
    static func offers(
        from alternatives: [SlotAlternative],
        currentExerciseID: UUID?,
        slotExerciseID: UUID? = nil,
        availableExerciseIDs: Set<UUID>
    ) -> [PreparedAlternativeOffer] {
        SlotAlternativeEligibility
            .workoutFacing(alternatives, slotExerciseID: slotExerciseID)
            .filter { $0.exerciseID != currentExerciseID }
            .map {
                PreparedAlternativeOffer(
                    alternative: $0,
                    isAvailable: availableExerciseIDs.contains($0.exerciseID))
            }
    }

    /// Whether the switch flow should show the prepared-alternatives sheet at
    /// all.
    ///
    /// When this is false the flow must stay **byte-identical to pre-F1** — the
    /// exercise picker opens directly and ends in the same two-option dialog —
    /// so a routine that never used the feature sees no new screen. That is a
    /// UX rule and a required regression test (§8.1).
    static func hasOffers(
        from alternatives: [SlotAlternative],
        currentExerciseID: UUID?,
        slotExerciseID: UUID? = nil,
        availableExerciseIDs: Set<UUID>
    ) -> Bool {
        !offers(
            from: alternatives, currentExerciseID: currentExerciseID,
            slotExerciseID: slotExerciseID,
            availableExerciseIDs: availableExerciseIDs
        ).isEmpty
    }
}

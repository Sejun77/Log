import Foundation

// MARK: - Exercise switch — destructive impact
//
// Switching a slot's exercise mid-workout is **destructive**: the swap path
// removes the slot's `WorkoutItem` (taking every `SetLog` under it), resets
// `loggedByExercise[slotID]`, and — inside a superset — cascades a clear of any
// partner logs that the round-prefix invariant no longer allows
// (`supersetLogsToInvalidate`). None of that is announced today; the user taps
// Keep / Reset and the sets are gone.
//
// This namespace answers one question, ahead of the switch, so the UI can gate
// it behind a confirmation: **how many logged sets would this switch remove?**
//
// It does not delete anything and does not change what gets deleted. It mirrors
// the existing cleanup by calling the same pure helper the cascade itself uses,
// so the number shown and the sets removed cannot drift apart.
//
// Pure: no SwiftData, no SwiftUI, no I/O.

/// How many logged sets a pending exercise switch would remove.
struct ExerciseSwitchDeletionImpact: Equatable {
    /// Logged sets on the slot whose exercise is being switched. These go with
    /// the slot's `WorkoutItem`.
    var slotLoggedSets: Int

    /// Additional logged sets removed from **other slots in the same superset
    /// block** by the round-order cascade. Zero for a non-superset block.
    var partnerLoggedSets: Int

    init(slotLoggedSets: Int = 0, partnerLoggedSets: Int = 0) {
        self.slotLoggedSets = slotLoggedSets
        self.partnerLoggedSets = partnerLoggedSets
    }

    var totalLoggedSets: Int { slotLoggedSets + partnerLoggedSets }

    /// True when the switch would destroy logged work. The confirmation gate.
    var requiresConfirmation: Bool { totalLoggedSets > 0 }

    /// True when the removal reaches beyond the switched slot, which changes the
    /// wording from "for this exercise" to "from this block".
    var includesPartnerSets: Bool { partnerLoggedSets > 0 }
}

/// Compute what a pending exercise switch would delete.
///
/// - Parameters:
///   - slotID: the slot whose exercise is being switched.
///   - isSuperset: whether the enclosing block is a superset. Only a superset
///     can cascade into partner slots — the swap path invokes the cascade under
///     exactly this condition.
///   - slotOrder: the block's slots in execution order
///     (`PlanBlock.exercises.map(\.routineSlotID)`).
///   - setCounts: effective working-set count per slot, **pre-switch**.
///   - loggedBySlot: current per-slot logged set indices, **pre-switch**.
///
/// The partner count is derived by simulating the swap's own first step —
/// emptying the switched slot's logs — and then asking
/// `supersetLogsToInvalidate` what else becomes extraneous. That is precisely
/// what `cascadeClearSupersetRoundOrderViolations` does after the swap, so the
/// prediction matches the deletion by construction.
///
/// Using the **pre-switch** set count for the switched slot is safe even though
/// the switch may change it: the slot's simulated logs are empty and
/// `effectiveSetCount` never returns less than 1, so truncation always begins at
/// that slot's position in round 0 regardless of what its count becomes. Later
/// rounds cannot change the answer once truncation has begun.
func exerciseSwitchDeletionImpact(
    slotID: UUID,
    isSuperset: Bool,
    slotOrder: [UUID],
    setCounts: [UUID: Int],
    loggedBySlot: [UUID: Set<Int>]
) -> ExerciseSwitchDeletionImpact {
    let slotLogged = loggedBySlot[slotID]?.count ?? 0

    guard isSuperset else {
        // A non-superset block never cascades: the swap path invokes
        // `cascadeClearSupersetRoundOrderViolations` only for `isSuperset`.
        return ExerciseSwitchDeletionImpact(slotLoggedSets: slotLogged)
    }

    var afterSlotCleared = loggedBySlot
    afterSlotCleared[slotID] = []

    let extraneous = supersetLogsToInvalidate(
        slotOrder: slotOrder,
        setCounts: setCounts,
        loggedBySlot: afterSlotCleared
    )

    // The switched slot is already counted in `slotLoggedSets`; its simulated
    // logs are empty so it cannot appear here, but filtering keeps the two
    // counts disjoint by construction rather than by assumption.
    let partner = extraneous
        .filter { $0.key != slotID }
        .reduce(0) { $0 + $1.value.count }

    return ExerciseSwitchDeletionImpact(
        slotLoggedSets: slotLogged,
        partnerLoggedSets: partner
    )
}

// MARK: - Copy

/// User-facing copy for the destructive switch confirmation.
///
/// Kept beside the impact calculation, and pure, so the wording is unit-testable
/// without standing up a view. Four message variants rather than one
/// interpolated string: English needs singular/plural, and the removal reaching
/// a superset partner is a materially different statement than losing this
/// exercise's own sets.
enum ExerciseSwitchConfirmationCopy {

    static var title: String { String(localized: "Switch exercise?") }

    static var confirmButton: String {
        String(localized: "Switch and Remove Sets")
    }

    /// Body text for the given impact. Returns nil when nothing would be
    /// removed — that case must not present a confirmation at all.
    ///
    /// - Parameter incomingExerciseName: the exercise being switched **to**.
    ///   Naming it is the audit's L4: the warning stated a cost without stating
    ///   what the cost buys, so a user mid-set had to remember which row they
    ///   had just tapped in order to judge the trade. Nil — an unresolvable or
    ///   deleted exercise — falls back to the original unnamed wording rather
    ///   than rendering an empty name into the sentence.
    static func message(
        for impact: ExerciseSwitchDeletionImpact,
        incomingExerciseName: String? = nil
    ) -> String? {
        guard impact.requiresConfirmation else { return nil }
        let count = impact.totalLoggedSets

        let name = incomingExerciseName?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            if impact.includesPartnerSets {
                if count == 1 {
                    return String(
                        localized:
                            "Switching to \(name) will remove 1 logged set from this block."
                    )
                }
                return String(
                    localized:
                        "Switching to \(name) will remove \(count) logged sets from this block."
                )
            }
            if count == 1 {
                return String(
                    localized:
                        "Switching to \(name) will remove 1 logged set for this exercise."
                )
            }
            return String(
                localized:
                    "Switching to \(name) will remove \(count) logged sets for this exercise."
            )
        }

        if impact.includesPartnerSets {
            if count == 1 {
                return String(
                    localized:
                        "Switching exercises will remove 1 logged set from this block."
                )
            }
            return String(
                localized:
                    "Switching exercises will remove \(count) logged sets from this block."
            )
        }

        if count == 1 {
            return String(
                localized:
                    "Switching exercises will remove 1 logged set for this exercise."
            )
        }
        return String(
            localized:
                "Switching exercises will remove \(count) logged sets for this exercise."
        )
    }
}

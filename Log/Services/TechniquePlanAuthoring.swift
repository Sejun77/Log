import Foundation
import SwiftData

// ======================================================
// MARK: - Technique authoring — the write path
// ======================================================
//
// The sibling of `WarmupSchemeAuthoring`, for the same reason and with the same
// rule: **the context to write into is the one the edited prescription already
// belongs to**, not whatever `@Environment(\.modelContext)` happens to resolve
// to in a pushed editor.
//
// `SlotAlternativeDetailEditor` renders `SlotPrescriptionSection` for a scratch
// slot living in `AlternativeDraftStore`'s own throwaway in-memory container,
// and injects that container's context into the section's environment. That
// injection does not reach `TechniquePlanEditor`, which the section *pushes*:
// the pushed editor read the app's context instead.
//
// Unlike the warm-up bug this did **not** crash. `SlotPrescription.warmupScheme`
// is to-one, and relating a to-one across containers is a SwiftData
// `fatalError`; `techniquePlans` is to-many, and the same cross-container
// relate is accepted silently. What it produced instead is worse to find:
//
//  - every technique added to a prepared alternative was inserted **and saved
//    into the user's store**, related to a prescription that lives in another
//    container — an orphan row no cascade owns and no screen can reach, i.e.
//    exactly the leak `AlternativeDraftStore` was built to make impossible and
//    the bug class `BackfillService.purgeOrphanSetTemplates` exists to clean up;
//  - `ModelContext.delete` on a model registered in a *different* container is
//    a silent no-op (`isDeleted` stays false and the row survives), so the
//    delete path only appeared to work because the relationship detach in front
//    of it did the visible half.
//
// Resolving the context from the model fixes both, and is a no-op for every
// routine slot: a real prescription is registered in the app's main context,
// which *is* the environment's context.

/// The one place a `TechniquePlan` is created and destroyed.
///
/// Extracted from `TechniquePlanEditor` so the context rule above is reachable
/// without a UI harness — the editor keeps its list, sheet, filtering and
/// renumbering rules and calls straight into this.
@MainActor
enum TechniquePlanAuthoring {

    /// The context that owns `prescription`, and therefore the only context its
    /// technique children may be inserted into.
    ///
    /// Falls back to the caller's context for a prescription that is not yet
    /// registered anywhere (an orphan slot mid-creation), which is exactly the
    /// pre-fix behavior for that case.
    static func writeContext(
        for prescription: SlotPrescription, fallback: ModelContext
    ) -> ModelContext {
        prescription.modelContext ?? fallback
    }

    /// Append one technique of `type`, seeded with its per-type defaults.
    ///
    /// `order` continues from the highest existing plan, so an append never
    /// collides with a reorder.
    @discardableResult
    static func addPlan(
        type: TechniqueType,
        to prescription: SlotPrescription,
        fallbackContext: ModelContext
    ) -> TechniquePlan {
        let ctx = writeContext(for: prescription, fallback: fallbackContext)

        let nextOrder = (prescription.techniquePlans.map(\.order).max() ?? -1) + 1
        let plan: TechniquePlan
        switch type {
        case .dropset:
            plan = TechniquePlan(order: nextOrder, type: type,
                                 dropPercent: 20, dropCount: 1,
                                 dropsetEffortRaw: "amrap")
        case .partialReps:
            // Default to "Not set" (nil partialRangeRaw) — no preseeded note.
            plan = TechniquePlan(order: nextOrder, type: type, reps: 8)
        case .restPause:
            plan = TechniquePlan(order: nextOrder, type: type,
                                 restSeconds: 15, rounds: 2)
        case .cluster:
            plan = TechniquePlan(order: nextOrder, type: type,
                                 reps: 3, restSeconds: 10, rounds: 3)
        default:
            plan = TechniquePlan(order: nextOrder, type: type)
        }
        ctx.insert(plan)
        // Reassign the whole relationship array instead of `techniquePlans.append`,
        // matching `WarmupSchemeAuthoring.addStep`: an in-place append on a
        // SwiftData to-many relationship does not reliably fire the Observation
        // change notification, and the alternative detail editor's commit is
        // driven by exactly that notification (it re-reads the draft payload
        // when the scratch graph changes). Order and persistence are unchanged.
        prescription.techniquePlans = prescription.techniquePlans + [plan]
        try? ctx.save()
        return plan
    }

    /// Detach and destroy `plans`.
    ///
    /// Each plan is deleted through **its own** context rather than the
    /// prescription's, so a row that predates this fix — one the old code
    /// leaked into the app store while editing an alternative — is still
    /// destroyed rather than silently surviving. For every normal plan the two
    /// are the same context.
    ///
    /// Does not save: the caller renumbers what survives first, so one save
    /// covers both halves, exactly as before.
    static func delete(
        _ plans: [TechniquePlan],
        from prescription: SlotPrescription,
        fallbackContext: ModelContext
    ) {
        let ctx = writeContext(for: prescription, fallback: fallbackContext)
        let doomed = Set(plans.map(\.id))
        prescription.techniquePlans = prescription.techniquePlans.filter {
            !doomed.contains($0.id)
        }
        for plan in plans {
            (plan.modelContext ?? ctx).delete(plan)
        }
    }
}

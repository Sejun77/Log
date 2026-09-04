import Foundation
import SwiftData

// ======================================================
// MARK: - Warm-up authoring — the write path
// ======================================================
//
// `WarmupSchemeEditor` used to create its `WarmupScheme` / `WarmupStep` rows
// directly in `@Environment(\.modelContext)`. That is the right context for
// every routine slot — and the wrong one for the **scratch** slot the
// Alternative Exercises detail editor binds the same editor to.
//
// `SlotAlternativeDetailEditor` renders `SlotPrescriptionSection` for a slot
// that lives in `AlternativeDraftStore`'s own throwaway in-memory container,
// and injects that container's context into the section's environment. The
// injection does not reach `WarmupSchemeEditor`, which the section *pushes*:
// the pushed editor read the app's context instead, inserted a new
// `WarmupScheme` there, and then assigned it to the scratch prescription —
// relating two models across containers, which SwiftData traps on:
//
//     SwiftData/PersistentModel.swift:432: Fatal error: attempting to relate
//     model - PersistentIdentifier(...) with model context - ModelContext to
//     destination model - Optional(PersistentIdentifier(...)) from
//     destination's model context - ModelContext
//
// (EXC_BREAKPOINT on `SlotPrescription.warmupScheme.setter`, main thread —
// exactly the shipped 1.0 (9) crash when the first warm-up step was added to a
// prepared alternative.)
//
// The fix is to stop asking the environment which store to write into and ask
// **the model being edited**. That answer is correct in both worlds and needs
// no plumbing:
//
//  - a real routine slot's prescription is registered in the app's main
//    context, which *is* the environment's context, so normal warm-up editing
//    is unchanged;
//  - a scratch prescription is registered in the draft container, so the scheme
//    and its steps are created where the prescription already lives, never
//    cross a container boundary, and can never reach the user's store.

/// The one place a warm-up scheme is created and extended.
///
/// Extracted from `WarmupSchemeEditor` so the crash path above is reachable
/// without a UI harness — the editor keeps its list, sheets and ordering rules
/// and calls straight into this.
@MainActor
enum WarmupSchemeAuthoring {

    /// The context that owns `prescription`, and therefore the only context its
    /// warm-up children may be inserted into.
    ///
    /// Falls back to the caller's context for a prescription that is not yet
    /// registered anywhere (an orphan slot mid-creation), which is exactly the
    /// pre-fix behavior for that case.
    static func writeContext(
        for prescription: SlotPrescription, fallback: ModelContext
    ) -> ModelContext {
        prescription.modelContext ?? fallback
    }

    /// Append one step, creating the scheme on first use.
    ///
    /// `order` continues from the highest existing step, so an append never
    /// collides with a reorder.
    @discardableResult
    static func addStep(
        to prescription: SlotPrescription,
        kind: WarmupStepKind,
        reps: Int?,
        percentOfWorking: Double?,
        restSecondsAfter: Int?,
        note: String?,
        weight: Double?,
        fallbackContext: ModelContext
    ) -> WarmupStep {
        let ctx = writeContext(for: prescription, fallback: fallbackContext)

        let scheme: WarmupScheme
        if let existing = prescription.warmupScheme {
            scheme = existing
        } else {
            let s = WarmupScheme(name: "Warmup")
            ctx.insert(s)
            prescription.warmupScheme = s
            scheme = s
        }

        let nextOrder = (scheme.steps.map(\.order).max() ?? -1) + 1
        let step = WarmupStep(
            order: nextOrder, kind: kind, reps: reps,
            percentOfWorking: percentOfWorking,
            restSecondsAfter: restSecondsAfter, note: note, weight: weight)
        ctx.insert(step)
        // Reassign the whole relationship array instead of `scheme.steps.append`.
        // An in-place append on a SwiftData to-many relationship does not
        // reliably fire the Observation change notification, so the editor's
        // `@Bindable prescription` body did not re-read `warmupScheme.steps` —
        // the new row only appeared after popping and re-pushing the editor.
        // A full setter assignment guarantees SwiftUI observes the change and
        // renders the new step immediately. Order/persistence are unchanged.
        scheme.steps = scheme.steps + [step]
        try? ctx.save()
        return step
    }
}

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

    /// Write edited values back to an existing step.
    ///
    /// Only the passed step is mutated — `order` is deliberately left untouched
    /// so reordering stays the sole owner of position. The kind-conditional
    /// nil-ing happens in the edit sheet, so stale fields clear when the kind
    /// changes.
    static func updateStep(
        _ step: WarmupStep,
        in prescription: SlotPrescription,
        kind: WarmupStepKind,
        reps: Int?,
        percentOfWorking: Double?,
        restSecondsAfter: Int?,
        note: String?,
        weight: Double?,
        fallbackContext: ModelContext
    ) {
        step.kind = kind
        step.reps = reps
        step.percentOfWorking = percentOfWorking
        step.restSecondsAfter = restSecondsAfter
        step.note = note
        step.weight = weight
        try? writeContext(for: prescription, fallback: fallbackContext).save()
    }

    /// Delete the steps at `offsets` **into the sorted display list**, then
    /// renumber the survivors contiguously.
    ///
    /// Renumbering operates on the re-sorted survivors, never on the raw
    /// relationship array: `scheme.steps` ordering is not guaranteed to match
    /// `order`, so reindexing it directly could swap surviving rows.
    static func deleteSteps(
        at offsets: IndexSet,
        in prescription: SlotPrescription,
        fallbackContext: ModelContext
    ) {
        guard let scheme = prescription.warmupScheme else { return }
        let ctx = writeContext(for: prescription, fallback: fallbackContext)
        let sorted = WarmupSummary.steps(of: scheme)
        let doomed = offsets.compactMap { $0 < sorted.count ? sorted[$0] : nil }
        guard !doomed.isEmpty else { return }

        let doomedIDs = Set(doomed.map(\.persistentModelID))
        // Whole-array reassignment, not an in-place `removeAll` — same rule the
        // append above follows, so a delete fires the relationship's mutation
        // exactly like an add does.
        scheme.steps = scheme.steps.filter {
            !doomedIDs.contains($0.persistentModelID)
        }
        for step in doomed { ctx.delete(step) }

        renumber(WarmupSummary.steps(of: scheme))
        try? ctx.save()
    }

    /// Reorder the sorted display list and write the new positions back.
    ///
    /// `order` is the sole record of position — SwiftData does not promise any
    /// particular ordering for a to-many relationship array, and `scheme.steps`
    /// is observed to come back permuted after a save. The array is still
    /// reassigned wholesale rather than mutated in place: that is what fires
    /// the relationship's change notification, the same rule `addStep` and
    /// `deleteSteps` follow. Read positions through `WarmupSummary.steps`,
    /// never off the raw array.
    static func moveSteps(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        in prescription: SlotPrescription,
        fallbackContext: ModelContext
    ) {
        guard let scheme = prescription.warmupScheme else { return }
        var sorted = WarmupSummary.steps(of: scheme)
        sorted.move(fromOffsets: source, toOffset: destination)
        renumber(sorted)
        scheme.steps = sorted
        try? writeContext(for: prescription, fallback: fallbackContext).save()
    }

    /// Contiguous 0..<count in the given (display) order.
    private static func renumber(_ steps: [WarmupStep]) {
        for (index, step) in steps.enumerated() { step.order = index }
    }
}

// ======================================================
// MARK: - Warm-up read model — the one list source
// ======================================================
//
// Both the warm-up editor's own list and the prescription row's `N steps`
// preview used to compute their own answer inline, straight off
// `prescription.warmupScheme?.steps`. Neither read is observed by the view that
// performs it (see `WarmupSchemeRow` for why), and having two of them meant the
// refresh fix had to be written twice and could be tested in neither place.
//
// These are pure functions of the scheme, so the render source and the preview
// count are literally the same value, and both are unit-testable without a view.

/// Sorted step list and step count for a warm-up scheme.
@MainActor
enum WarmupSummary {

    /// The display order: ascending `order`, which is the sequence the editor
    /// lists and the session freeze captures. Never the raw relationship array
    /// — its ordering is not guaranteed to match `order`.
    static func steps(of scheme: WarmupScheme?) -> [WarmupStep] {
        (scheme?.steps ?? []).sorted { $0.order < $1.order }
    }

    /// Same list, addressed from the prescription.
    static func steps(of prescription: SlotPrescription?) -> [WarmupStep] {
        steps(of: prescription?.warmupScheme)
    }

    /// How many steps the preview reports — the same relationship the editor
    /// lists, so the row can never disagree with the screen it pushes.
    ///
    /// The `N steps` wording stays in the view: it is a `LocalizedStringKey`
    /// interpolation (catalog key `%lld step%@`, already translated), and
    /// rebuilding it here as a `String` would orphan that translation.
    static func stepCount(of prescription: SlotPrescription?) -> Int {
        prescription?.warmupScheme?.steps.count ?? 0
    }
}

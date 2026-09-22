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

// ======================================================
// MARK: - Technique descriptions (ux/training-term-help)
// ======================================================

/// The one-line definition of every `TechniqueType`, in one place.
///
/// Before this there were three sets of technique copy that no rule kept in
/// step: the Add Technique picker's own tuple table (all seven types), the
/// technique parameter editor (AMRAP / To Failure only, worded differently),
/// and the read-only `TechniqueDetailSheet` in an active workout (AMRAP / To
/// Failure again, worded differently a third time — "on last set" vs. "on this
/// set"). A user meeting AMRAP in a workout and again while editing the routine
/// read two different sentences about the same technique, and the four
/// parameterized types explained themselves nowhere at all.
///
/// Exhaustive by construction: the `switch` has no `default`, so adding a
/// `TechniqueType` case is a compile error here rather than a silent blank line
/// in three screens.
///
/// Copy only — the shape `EffortTargetHelp` / `SupersetHelp` /
/// `CardioChecklistHelp` already use. Nothing here reads, writes, validates or
/// combines a plan; the conflict rules (`techniquePairConflict`,
/// `techniquesIncompatibleWithDuration`) are untouched.
///
/// ## Which wording each case uses
///
/// Five cases return the **picker's existing literal verbatim**, so they
/// resolve to the string-catalog key they already had and keep their existing
/// Korean — no key added, changed or retranslated for the consolidation.
///
/// Two were rewritten and carry new keys:
///
///  - `.amrap` — every prior wording pinned the technique to a particular set
///    ("on last set" / "on this set"), but AMRAP is authored per set index and
///    the detail sheet renders it beside whichever set it targets. One
///    set-neutral sentence is correct in both places, which is the whole point
///    of a single source.
///  - `.cluster` — "Intra-set pause clusters." defines cluster with *clusters*.
///    It is the one description that explained nothing to the reader who needed
///    it, so it states the actual structure instead.
enum TechniqueHelp {

    /// A short, self-contained definition, returned as its **English
    /// string-catalog key**: callers wrap it in `LocalizedStringKey` exactly as
    /// the picker already did, so lookup and English fallback are unchanged.
    static func description(for type: TechniqueType) -> String {
        switch type {
        case .dropset:
            return "Reduce weight immediately after reaching failure."
        case .partialReps:
            return "Continue with partial range of motion after failure."
        case .restPause:
            return "Short intra-set rest, then continue."
        case .amrap:
            return "As many reps as possible in the set."
        case .toFailure:
            return "Push until technical failure."
        case .cluster:
            return "Split a set into small groups of reps separated by short rests."
        case .tempoOverride:
            return "Override tempo for this exercise."
        }
    }

    /// Trailer for the two types that configure nothing, shown under their
    /// description in the parameter editor. Separate from the description so
    /// the sentence itself stays usable everywhere else.
    static let noParameters = "No additional parameters."
}

// ======================================================
// MARK: - Technique conflict copy (ux/training-term-help)
// ======================================================

/// The messages shown when a technique cannot be added to a set: the greyed-out
/// subtitle in the Add Technique picker, and the inline error under the per-set
/// checkboxes in the technique editor.
///
/// Every one of these used to be an English literal composed in Swift with an
/// **already-localized** `displayName` interpolated into it, then rendered
/// through `Text(LocalizedStringKey(_:))`. That key can never exist — it
/// carries a set number and a translated technique name — so the lookup always
/// fell through and a Korean user read "부분 반복 already exists on set 2."
///
/// The fix is the repo's existing pattern (`BlockPrescriptionSummary`,
/// `TechniqueAppliesTo.displayLabel`): `String(localized:)` with interpolation,
/// which produces a **format key** (`"%@ already exists on set %lld."`) that
/// the catalog can translate once and reuse for every technique and every set
/// number. No language branching, no Korean in view code.
///
/// Two consolidations came with the move, both copy-only:
///
///  - The picker said "already exists on set 2." and the per-set editor said
///    "already on set 2." — the same sentence twice, so they now share one key.
///  - The pairwise messages hard-coded English technique names ("Rest-Pause and
///    Cluster…") even though `displayName` was right there; they now
///    interpolate it, so the names translate with everything else. The two
///    "can't share a set" pairs also collapse onto a single format key.
///
/// Conflict *rules* are untouched: this namespace only renders the sentence a
/// rule has already decided to show.
enum TechniqueConflictCopy {

    /// The picker's and the per-set editor's shared duplicate message.
    static func duplicateOnSet(_ type: TechniqueType, setNumber: Int) -> String {
        String(localized: "\(type.displayName) already exists on set \(setNumber).")
    }

    /// Same technique twice where the set is implied by context rather than
    /// numbered — a distinct sentence, so a distinct key.
    static func duplicateOnThisSet(_ type: TechniqueType) -> String {
        String(localized: "\(type.displayName) is already on this set.")
    }

    /// Two techniques whose set structures cannot coexist. One key serves both
    /// pairs that hit it (Rest-Pause × Cluster, Cluster × AMRAP).
    static func cannotShareSet(
        _ a: TechniqueType, _ b: TechniqueType
    ) -> String {
        String(localized: "\(a.displayName) and \(b.displayName) can't share a set.")
    }

    /// The Drop Set × Cluster case, which reads as a direction ("cluster can't
    /// combine with drop set") rather than a symmetric pair.
    static func cannotCombine(
        _ a: TechniqueType, with b: TechniqueType
    ) -> String {
        String(localized: "\(a.displayName) can't combine with \(b.displayName) on the same set.")
    }

    /// Drop Set already carries its own AMRAP / fixed-reps effort mode. AMRAP
    /// stays inline rather than interpolated: it is the one technique name that
    /// is identical in both languages, and spelling it out keeps the sentence
    /// translatable as one phrase.
    static func dropsetAlreadyDefinesEffort() -> String {
        String(
            localized:
                "\(TechniqueType.dropset.displayName) already defines AMRAP/fixed reps; remove it to use AMRAP."
        )
    }

    /// Blocks switching a Drop Set to fixed reps while an AMRAP overlaps it.
    static func amrapOverlapBlocksFixedReps() -> String {
        String(localized: "AMRAP exists on an overlapping set; can't use fixed reps.")
    }

    /// Type-level availability. **Byte-identical English preserved**: these two
    /// literals are asserted verbatim by `BodyweightTechniqueTests` and
    /// `SwitchExerciseTempoAndPrefillTests`, and `String(localized:)` returns
    /// the key itself in English, so those assertions are unaffected.
    static func unavailableForBodyweight() -> String {
        String(localized: "Not available for bodyweight exercises.")
    }

    static func unavailableForDuration() -> String {
        String(localized: "Not available for duration-based exercises.")
    }
}

// ======================================================
// MARK: - Technique summary vocabulary (ux/korean-localization-consistency)
// ======================================================

/// The localized fragments every technique preview is built from.
///
/// Two screens describe the same `TechniquePlan` at two densities: the routine
/// editor's row subtitle ("sets 1,3 · 20% drop · AMRAP") and the active
/// workout's chip label ("Drop Set −20% ×3 (AMRAP)"). Both composed their text
/// from **plain English literals** joined into a `String`, which `Text` then
/// rendered verbatim — so the fragments could never localize no matter what the
/// catalog held, and the two screens had drifted into different vocabularies
/// for the same fields.
///
/// This namespace does not force the two densities into one output — a chip has
/// to stay short and a subtitle does not, and collapsing them would change what
/// the workout screen shows. It gives them **one vocabulary**: every
/// natural-language word comes from here, so "reps" is translated once and both
/// screens move together.
///
/// ## What is translated and what is not
///
/// Words are translated (`set`, `sets`, `reps`, `rounds`, `drop`, `all`).
/// Notation is not: `%`, `×`, `−`, digits, and `AMRAP` — an acronym this app
/// deliberately keeps identical in both languages, like `kg` and `bpm`.
/// Durations route through `DurationDisplay`, so a technique's rest reads the
/// same as every other rest in the app.
///
/// Pure copy: nothing here reads, writes or validates a plan.
enum TechniqueSummaryCopy {

    /// Which sets a technique applies to, from 0-based indices: `"set 2"` /
    /// `"sets 1,3"`. The numbers keep their bare comma-joined form — a list of
    /// digits, not prose.
    static func appliesToSets(indices: Set<Int>) -> String? {
        guard !indices.isEmpty else { return nil }
        let numbers = indices.sorted().map { String($0 + 1) }
            .joined(separator: ",")
        return indices.count == 1
            ? String(localized: "set \(numbers)")
            : String(localized: "sets \(numbers)")
    }

    /// The bracketed qualifier a chip appends: `"[set 2]"` / `"[sets 1,3]"` /
    /// `"[all]"`. The brackets are notation; what is inside them is prose.
    static func bracketed(_ inner: String) -> String { "[\(inner)]" }

    /// Every working set, as the word inside a chip's `[…]` qualifier.
    ///
    /// A **symbolic** key (the shape `activeWorkout.back` already uses), not
    /// the English word: a bare `"all"` key collides with the catalog's
    /// existing `"All"` filter label under String Catalog symbol generation,
    /// which fails the build. The English value lives in the catalog beside
    /// the Korean one.
    static var allSets: String {
        String(localized: "technique.appliesTo.all")
    }

    static func rounds(_ count: Int) -> String {
        String(localized: "\(count) rounds")
    }

    static func reps(_ count: Int) -> String {
        String(localized: "\(count) reps")
    }

    /// The weight cut on a drop set, as a percentage: `"20% drop"`.
    static func dropPercent(_ percent: Int) -> String {
        String(localized: "\(percent)% drop")
    }

    /// Fixed reps on each drop of a drop set: `"3 reps/drop"`.
    static func repsPerDrop(_ count: Int) -> String {
        String(localized: "\(count) reps/drop")
    }

    /// The effort mode of a drop set. AMRAP stays AMRAP.
    static func dropsetEffort(_ effort: DropsetEffort) -> String {
        switch effort {
        case .amrap: return "AMRAP"
        case .fixedReps(let n): return repsPerDrop(n)
        }
    }

    /// The separator every summary in this app joins its segments with.
    static let separator = " · "

    static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: separator)
    }
}

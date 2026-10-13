import Foundation
import SwiftData

// ======================================================
// MARK: - Slot plan bundle
// ======================================================
//
// The **complete exercise-specific plan** of a routine slot, as one value.
//
// `AlternativePrescriptionPayload` is the bundle: it is already the value type a
// prepared alternative stores, so "the plan A had as primary" and "the plan A
// has as an alternative" are the same shape and moving a plan between the two
// is a copy, not a translation. Everything that belongs to the exercise's plan
// is in it:
//
//   SlotPrescription  sets, reps, rest, duration, distance + unit, tempo,
//                     RIR/RPE, effort mode, progression start/end, custom
//                     per-set targets, cardio segments
//   WarmupScheme      name + every step field
//   TechniquePlan     every field, including repMin / repMax / durationSeconds
//   RoutineExercise   plan notes (`templateNotes`) and the legacy per-set
//                     overrides (`setTemplates`, all six fields)
//
// What is deliberately **not** in it, because it is not plan data:
//   - `alternativesData` — the slot's list of alternatives, not a plan,
//   - the `Exercise` reference — identity, moved by the caller,
//   - equipment / setup — definition-level, they live on `Exercise`.
//
// Three conversions, one definition:
//   routine slot     → bundle  `capture(from:)`
//   bundle           → slot    `apply(_:to:in:)`
//   session snapshot → bundle  `switchTimePlan(of:)`
// plus the one overlay of session edits, `overlaying(_:over:onto:)`.

enum SlotPlanBundle {

    /// The name `WarmupSchemeAuthoring` gives every scheme it creates. A
    /// bundle stores nil for it so editor-authored payloads keep encoding
    /// exactly as they did before scheme names were carried.
    static let defaultWarmupSchemeName = "Warmup"

    // MARK: Slot → bundle

    /// The slot's complete plan, as a value. Reads only — nothing on the slot
    /// is touched, and nothing in the result references a model object, so
    /// the slot can be rewritten afterwards without disturbing the capture.
    ///
    /// `tempo` is captured **raw**, not through `effectiveTempo`: a stale tempo
    /// on a duration slot is inert everywhere it is read, and capturing it
    /// verbatim is what makes slot → bundle → slot exact.
    static func capture(from slot: RoutineExercise) -> AlternativePrescriptionPayload {
        var bundle = AlternativePrescriptionPayload()
        if let p = slot.prescription {
            bundle.sets = p.sets
            bundle.repMin = p.repMin
            bundle.repMax = p.repMax
            bundle.restSecondsBetweenSets = p.restSecondsBetweenSets
            bundle.restSecondsAfterExercise = p.restSecondsAfterExercise
            bundle.rir = p.rir
            bundle.rpe = p.rpe
            bundle.tempo = p.tempo
            bundle.effortModeRaw = p.effortModeRaw
            bundle.rirStart = p.rirStart
            bundle.rirEnd = p.rirEnd
            bundle.rpeStart = p.rpeStart
            bundle.rpeEnd = p.rpeEnd
            bundle.customRIRTargets =
                p.customRIRTargets.isEmpty ? nil : p.customRIRTargets
            bundle.customRPETargets =
                p.customRPETargets.isEmpty ? nil : p.customRPETargets
            bundle.durationMinSeconds = p.durationMinSeconds
            bundle.durationMaxSeconds = p.durationMaxSeconds
            bundle.usesDuration = p.usesDuration
            bundle.targetDistanceMeters = p.targetDistanceMeters
            bundle.targetDistanceUnitRaw = p.targetDistanceUnitRaw
            bundle.cardioSegments = p.structuredCardioPlan
            if let scheme = p.warmupScheme {
                bundle.warmupSchemeName =
                    scheme.name == defaultWarmupSchemeName ? nil : scheme.name
                bundle.warmupSteps = scheme.steps
                    .sorted { $0.order < $1.order }
                    .map(WarmupStepSnapshot.init(from:))
            }
            bundle.techniques = p.techniquePlans
                .sorted { $0.order < $1.order }
                .map(TechniquePlanSnapshot.init(from:))
        }
        bundle.slotNotes = slot.templateNotes
        let overrides = slot.setTemplates
            .sorted { $0.order < $1.order }
            .map {
                SetTemplatePayload(
                    order: $0.order,
                    kindRaw: $0.kindRaw,
                    targetReps: $0.targetReps,
                    targetWeight: $0.targetWeight,
                    restSecondsAfter: $0.restSecondsAfter,
                    durationSeconds: $0.durationSeconds)
            }
        bundle.setTemplates = overrides.isEmpty ? nil : overrides
        return bundle.normalized()
    }

    // MARK: Bundle → slot

    /// Replace the slot's complete plan with `bundle`.
    ///
    /// Every owned child — warm-up scheme and steps, technique plans, per-set
    /// overrides — is **created fresh** from the bundle's values, never
    /// reassigned from another slot or alternative, and the replaced children
    /// are deleted. The one exception is a warm-up scheme some *other*
    /// prescription still references (`warmupScheme` is `.nullify`, so the
    /// model allows sharing): that scheme is detached from this slot and left
    /// alone, so the other slot can never change as a side effect.
    ///
    /// New children are inserted into the slot's own context — the rule
    /// `WarmupSchemeAuthoring.writeContext` exists for — so a scratch slot in
    /// `AlternativeDraftStore` and a real routine slot both stay inside their
    /// own store.
    ///
    /// Leaves `alternativesData` and the slot's `Exercise` alone. Does not save.
    static func apply(
        _ bundle: AlternativePrescriptionPayload,
        to slot: RoutineExercise,
        in fallbackContext: ModelContext
    ) {
        let ctx = slot.modelContext ?? fallbackContext

        let p: SlotPrescription
        if let existing = slot.prescription {
            p = existing
        } else {
            p = SlotPrescription()
            ctx.insert(p)
            slot.prescription = p
        }

        p.sets = bundle.sets
        p.repMin = bundle.repMin
        p.repMax = bundle.repMax
        p.restSecondsBetweenSets = bundle.restSecondsBetweenSets
        p.restSecondsAfterExercise = bundle.restSecondsAfterExercise
        p.rir = bundle.rir
        p.rpe = bundle.rpe
        p.tempo = bundle.tempo
        p.effortModeRaw = bundle.effortModeRaw
        p.rirStart = bundle.rirStart
        p.rirEnd = bundle.rirEnd
        p.rpeStart = bundle.rpeStart
        p.rpeEnd = bundle.rpeEnd
        // Through the codec, so the payload's array form and the column's
        // comma-separated form stay one value.
        p.customRIRTargetsRaw = EffortTargetList.encode(
            bundle.customRIRTargets ?? [])
        p.customRPETargetsRaw = EffortTargetList.encode(
            bundle.customRPETargets ?? [])
        p.durationMinSeconds = bundle.durationMinSeconds
        p.durationMaxSeconds = bundle.durationMaxSeconds
        p.usesDuration = bundle.usesDuration
        p.targetDistanceMeters = bundle.targetDistanceMeters
        p.targetDistanceUnitRaw = bundle.targetDistanceUnitRaw
        p.setStructuredCardioPlan(bundle.cardioSegments)
        slot.templateNotes = bundle.slotNotes

        // Warm-up: a new scheme, or none.
        let oldScheme = p.warmupScheme
        if bundle.warmupSchemeName != nil || !bundle.warmupSteps.isEmpty {
            let scheme = WarmupScheme(
                name: bundle.warmupSchemeName ?? defaultWarmupSchemeName)
            ctx.insert(scheme)
            let steps = bundle.warmupSteps.map { snapshot -> WarmupStep in
                let step = WarmupStep(
                    order: snapshot.order,
                    kind: snapshot.kind,
                    reps: snapshot.reps,
                    percentOfWorking: snapshot.percentOfWorking,
                    restSecondsAfter: snapshot.restSecondsAfter,
                    note: snapshot.note,
                    weight: snapshot.weight)
                ctx.insert(step)
                return step
            }
            scheme.steps = steps
            p.warmupScheme = scheme
        } else {
            p.warmupScheme = nil
        }
        if let oldScheme,
            !isWarmupScheme(oldScheme, referencedByAnyOtherThan: p, in: ctx)
        {
            ctx.delete(oldScheme)
        }

        // Techniques: owned (`.cascade`), so the replaced rows are deleted.
        let oldTechniques = p.techniquePlans
        p.techniquePlans = bundle.techniques.map { snapshot -> TechniquePlan in
            let plan = TechniquePlan(
                order: snapshot.order,
                type: snapshot.type,
                repMin: snapshot.repMin,
                repMax: snapshot.repMax,
                reps: snapshot.reps,
                durationSeconds: snapshot.durationSeconds,
                restSeconds: snapshot.restSeconds,
                rounds: snapshot.rounds,
                dropPercent: snapshot.dropPercent,
                dropCount: snapshot.dropCount,
                partialRangeNote: snapshot.partialRangeNote,
                partialRangeRaw: snapshot.partialRangeRaw,
                note: snapshot.note,
                appliesToRaw: snapshot.appliesToRaw ?? "lastWorkingSet",
                appliesToSetNumber: snapshot.appliesToSetNumber,
                appliesToSetIndicesRaw: snapshot.appliesToSetIndicesRaw ?? "",
                dropsetEffortRaw: snapshot.dropsetEffortRaw,
                dropsetEffortReps: snapshot.dropsetEffortReps)
            ctx.insert(plan)
            return plan
        }
        oldTechniques.forEach { ctx.delete($0) }

        // Per-set overrides: owned (`.cascade`) by the slot.
        let oldTemplates = slot.setTemplates
        slot.setTemplates = (bundle.setTemplates ?? []).map { row -> SetTemplate in
            let tpl = SetTemplate(
                targetReps: row.targetReps,
                targetWeight: row.targetWeight,
                restSecondsAfter: row.restSecondsAfter)
            // Raw, so a kind this build does not know survives.
            tpl.kindRaw = row.kindRaw
            tpl.order = row.order
            tpl.durationSeconds = row.durationSeconds
            ctx.insert(tpl)
            return tpl
        }
        oldTemplates.forEach { ctx.delete($0) }
    }

    /// Whether any prescription other than `owner` points at `scheme`.
    ///
    /// The app never shares a scheme today (authoring, duplication and import
    /// each create their own), but the relationship permits it, and deleting a
    /// shared scheme would silently strip another slot's warm-up.
    private static func isWarmupScheme(
        _ scheme: WarmupScheme,
        referencedByAnyOtherThan owner: SlotPrescription,
        in ctx: ModelContext
    ) -> Bool {
        // If the store cannot be read, assume shared: leaving an unreferenced
        // scheme behind is harmless, deleting a referenced one is not.
        guard
            let all = try? ctx.fetch(FetchDescriptor<SlotPrescription>())
        else { return true }
        let schemeID = scheme.persistentModelID
        let ownerID = owner.persistentModelID
        return all.contains {
            $0.persistentModelID != ownerID
                && $0.warmupScheme?.persistentModelID == schemeID
        }
    }

    // MARK: Session → bundle

    /// The plan a slot was running with **when it was last switched** — or at
    /// workout start, for an unswitched slot.
    ///
    /// Read from the plan's snapshots, which only the session freeze and a
    /// switch ever write: mid-workout Edit Plan changes land on the
    /// `SessionPlan`, never here. That separation is what lets a saved replacement
    /// tell "the plan this switch produced" apart from "edits the user may or
    /// may not choose to apply". The snapshots survive a cold resume through
    /// the workout's `WorkoutItem`.
    ///
    /// Carries no per-set overrides: a switch rebuilds the slot's templates
    /// from the plan, so the switched-in exercise has none.
    static func switchTimePlan(of exercise: PlanExercise) -> AlternativePrescriptionPayload {
        var bundle = AlternativePrescriptionPayload()
        if let snap = exercise.prescriptionSnapshot {
            bundle.sets = snap.sets
            bundle.repMin = snap.repMin
            bundle.repMax = snap.repMax
            bundle.restSecondsBetweenSets = snap.restSecondsBetweenSets
            bundle.restSecondsAfterExercise = snap.restSecondsAfterExercise
            bundle.rir = snap.rir
            bundle.rpe = snap.rpe
            bundle.tempo = snap.tempo
            bundle.effortModeRaw = snap.effortModeRaw
            bundle.rirStart = snap.rirStart
            bundle.rirEnd = snap.rirEnd
            bundle.rpeStart = snap.rpeStart
            bundle.rpeEnd = snap.rpeEnd
            let rir = EffortTargetList.decode(snap.customRIRTargetsRaw)
            let rpe = EffortTargetList.decode(snap.customRPETargetsRaw)
            bundle.customRIRTargets = rir.isEmpty ? nil : rir
            bundle.customRPETargets = rpe.isEmpty ? nil : rpe
            bundle.durationMinSeconds = snap.durationMinSeconds
            bundle.durationMaxSeconds = snap.durationMaxSeconds
            bundle.usesDuration = snap.usesDuration
            bundle.targetDistanceMeters = snap.targetDistanceMeters
            bundle.targetDistanceUnitRaw = snap.targetDistanceUnitRaw
            bundle.cardioSegments = snap.structuredCardioPlan
        }
        bundle.warmupSteps = exercise.warmupStepsSnapshot
        bundle.techniques = exercise.techniquePlansSnapshot
        bundle.slotNotes = exercise.templateNotesSnapshot
        return bundle.normalized()
    }

    // MARK: Session edits

    /// The session plan's editable fields as the session **started them** —
    /// at workout start, or at the slot's last switch — rebuilt from the same
    /// snapshots and in the same way `sessionPlanHasEdits`
    /// builds its "original". A field of the live session plan that differs
    /// from this is an edit the user made.
    static func sessionBaseline(of exercise: PlanExercise) -> SessionPlan {
        if let snap = exercise.prescriptionSnapshot {
            return SessionPlan(from: snap, notes: exercise.templateNotesSnapshot)
        }
        var plan = SessionPlan()
        plan.slotNotes = exercise.templateNotesSnapshot
        return plan
    }

    /// `base` with the user's session **edits** laid over it — and nothing
    /// else.
    ///
    /// Only the fields the active Edit Plan sheet can change (the ones
    /// `sessionPlanHasEdits` compares) are candidates, and of those only the
    /// ones that differ from `baseline` are written. So an untouched field
    /// keeps `base`'s value exactly, even where the switch adapter normalized
    /// the session's copy for the new exercise's tracking mode. Everything
    /// outside that set — effort mode, progression, custom targets, warm-ups,
    /// techniques, cardio segments, per-set overrides — always comes from
    /// `base`.
    ///
    /// This is the only definition of how saved plan changes are written. Because `base`
    /// is always the complete plan of the exercise that ends up in the slot,
    /// the result can never be half one exercise and half another.
    static func overlaying(
        _ session: SessionPlan,
        over baseline: SessionPlan,
        onto base: AlternativePrescriptionPayload
    ) -> AlternativePrescriptionPayload {
        func norm(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s
        }
        var result = base
        if session.sets != baseline.sets { result.sets = session.sets }
        if session.repMin != baseline.repMin { result.repMin = session.repMin }
        if session.repMax != baseline.repMax { result.repMax = session.repMax }
        if session.restSecondsBetweenSets != baseline.restSecondsBetweenSets {
            result.restSecondsBetweenSets = session.restSecondsBetweenSets
        }
        if session.restSecondsAfterExercise != baseline.restSecondsAfterExercise {
            result.restSecondsAfterExercise = session.restSecondsAfterExercise
        }
        if session.durationMinSeconds != baseline.durationMinSeconds {
            result.durationMinSeconds = session.durationMinSeconds
        }
        if session.durationMaxSeconds != baseline.durationMaxSeconds {
            result.durationMaxSeconds = session.durationMaxSeconds
        }
        if session.usesDuration != baseline.usesDuration {
            result.usesDuration = session.usesDuration
        }
        if session.rir != baseline.rir { result.rir = session.rir }
        if session.rpe != baseline.rpe { result.rpe = session.rpe }
        // Written as a pair so the two columns never disagree about whether a
        // target exists.
        if session.targetDistanceMeters != baseline.targetDistanceMeters
            || session.targetDistanceUnitRaw != baseline.targetDistanceUnitRaw
        {
            result.targetDistanceMeters = session.targetDistanceMeters
            result.targetDistanceUnitRaw = session.targetDistanceUnitRaw
        }
        if norm(session.tempo) != norm(baseline.tempo) {
            result.tempo = norm(session.tempo)
        }
        if norm(session.slotNotes) != norm(baseline.slotNotes) {
            result.slotNotes = norm(session.slotNotes)
        }
        return result.normalized()
    }
}

// ======================================================
// MARK: - Routine template update (finish → apply back)
// ======================================================
//
// What the Save Routine Changes sheet's selected rows write back to the
// routine. Owned here, not in `ActiveWorkoutView`, so it is testable and the
// whole mutation for a slot happens in one place.
//
// **Saving a replacement is a reversible promotion.** For a slot
// switched A → B:
//
//   before   primary A + A's plan        alternatives [ …, B + B's plan, … ]
//   after    primary B + B's plan        alternatives [ …, A + A's plan, … ]
//
//   * B's plan is its **prepared payload** when the session recorded that B
//     was chosen through the prepared-alternative action
//     (`SessionPlan.appliedAlternativeID`); otherwise it is the plan the
//     generic switch produced (Keep / Reset), read from the switch-time
//     snapshots. Mid-workout edits are added only when the user explicitly
//     chose to apply them.
//   * A's complete plan, captured before anything is written, becomes an
//     alternative. Prepared: it takes B's exact list position and enabled
//     state. Generic: it is appended, enabled.
//   * Either way, no row for B survives: the primary is never also its own
//     alternative. On a generic switch that removes B's prepared row too —
//     the user's explicit Keep/Reset choice superseded it.
//
// The round-trip guarantee covers **exercise-specific plan data** only — every
// field of `SlotPlanBundle`. It does not cover an alternative's relationship
// metadata: B's "why/when" note is dropped on promotion (the relationship it
// described no longer exists), the demoted A gets no note, and alternative ids
// are freshly issued.
//
// **Replacement and plan changes are independent choices.** A switched slot
// offers two pending changes — "B replaces A" and "B's plan changes" — and
// either can be saved without the other:
//
//   replacement only   promote B with its base plan (above), edits not applied
//   plan only          A stays primary; B's edited plan is saved as B's
//                      alternative (`savingSwitchedPlan`)
//   both               promote B with its base plan plus the edits
//   neither            nothing
//
// "Base plan" means the same thing in every row: the prepared payload when the
// session has prepared provenance, else the generic switch-time plan.

enum RoutineTemplateUpdate {

    /// One plan slot's state at finish, assembled by the caller from the
    /// session. Pure values — the routine is looked up by `routineExerciseID`.
    struct SlotRequest {
        var routineExerciseID: PersistentIdentifier
        var originalExerciseID: UUID
        var currentExerciseID: UUID
        /// The session plan as it stands at finish (edits included).
        var sessionPlan: SessionPlan?
        /// `SlotPlanBundle.switchTimePlan(of:)` for this slot.
        var switchTimePlan: AlternativePrescriptionPayload
        /// `SlotPlanBundle.sessionBaseline(of:)` — what the session's editable
        /// fields were before the user edited them.
        var sessionBaseline: SessionPlan
        /// Whether the session plan differs from the switch-time plan — the
        /// `sessionPlanHasEdits`.
        var hasPlanEdits: Bool

        var isSwitched: Bool { originalExerciseID != currentExerciseID }
    }

    /// The new primary plan and alternatives list for a promoted slot.
    struct Promotion: Equatable {
        var primaryPlan: AlternativePrescriptionPayload
        var alternatives: [SlotAlternative]
    }

    // MARK: Pure promotion

    /// Swap which exercise is primary. Pure.
    ///
    /// - Parameters:
    ///   - demotedExerciseID / demotedExerciseName / demotedPlan: A — the
    ///     slot's exercise and its complete captured plan.
    ///   - promotedExerciseID: B.
    ///   - appliedAlternativeID: the session's provenance. Only a match on
    ///     **both** id and exercise counts as prepared; anything else is a
    ///     generic switch, even if B also appears in the list.
    ///   - routineAlternatives: the slot's stored list (authoring truth, and
    ///     the list that is rewritten).
    ///   - frozenAlternatives: the session's frozen copy — consulted only if
    ///     the prepared entry is somehow no longer in the stored list.
    ///   - switchTimePlan: B's plan as the switch produced it (generic path).
    ///   - planEdits: the session plan and its baseline to overlay, or nil
    ///     when the user did not choose to apply plan edits (or made none).
    static func promotion(
        demotedExerciseID: UUID,
        demotedExerciseName: String,
        demotedPlan: AlternativePrescriptionPayload,
        promotedExerciseID: UUID,
        appliedAlternativeID: UUID?,
        routineAlternatives: [SlotAlternative],
        frozenAlternatives: [SlotAlternative],
        switchTimePlan: AlternativePrescriptionPayload,
        planEdits: (session: SessionPlan, baseline: SessionPlan)?
    ) -> Promotion {
        var list = routineAlternatives
        var base = switchTimePlan
        // A as an alternative. No note: B's "why/when" described B relative
        // to A and does not transfer. A fresh id: alternative ids are not plan
        // data.
        var demoted = SlotAlternative(
            isEnabled: true,
            exerciseID: demotedExerciseID,
            exerciseName: demotedExerciseName,
            note: nil,
            prescription: demotedPlan)

        var placed = false
        let prepared = preparedBase(
            exerciseID: promotedExerciseID,
            appliedAlternativeID: appliedAlternativeID,
            routineAlternatives: list,
            frozenAlternatives: frozenAlternatives)
        if let prepared {
            base = prepared.plan
            if let index = prepared.routineIndex {
                demoted.isEnabled = list[index].isEnabled
                demoted.order = list[index].order
                list[index] = demoted
                placed = true
            }
        }
        // Invariant: the primary is never also its own alternative. After a
        // prepared promotion this only matters for a duplicate B row; after a
        // **generic** promotion it removes B's prepared row, which the user's
        // explicit Keep/Reset + saved replacement has superseded. That is not
        // prepared-alternative inference — B's plan above is still the generic
        // one; the row is removed only because B is now the primary.
        list.removeAll { $0.exerciseID == promotedExerciseID }
        if !placed {
            demoted.order = (list.map(\.order).max() ?? -1) + 1
            list.append(demoted)
        }

        let primary =
            planEdits.map {
                SlotPlanBundle.overlaying(
                    $0.session, over: $0.baseline, onto: base)
            } ?? base
        return Promotion(
            primaryPlan: primary.normalized(),
            alternatives: SlotAlternatives.normalize(list))
    }

    /// The prepared plan B is running, when the session has prepared
    /// provenance for B: the routine's row if it is still there (with its
    /// index), else the session's frozen copy. Only a match on **both** id and
    /// exercise counts — anything else is a generic switch, even if B also
    /// appears in the list.
    private static func preparedBase(
        exerciseID: UUID,
        appliedAlternativeID: UUID?,
        routineAlternatives: [SlotAlternative],
        frozenAlternatives: [SlotAlternative]
    ) -> (plan: AlternativePrescriptionPayload, routineIndex: Int?)? {
        guard let appliedID = appliedAlternativeID else { return nil }
        func matches(_ alt: SlotAlternative) -> Bool {
            alt.id == appliedID && alt.exerciseID == exerciseID
        }
        if let index = routineAlternatives.firstIndex(where: matches) {
            return (routineAlternatives[index].prescription, index)
        }
        if let frozen = frozenAlternatives.first(where: matches) {
            return (frozen.prescription, nil)
        }
        return nil
    }

    // MARK: Pure plan-only save

    /// Save B's edited plan **without** promoting B. Pure; returns the slot's
    /// new alternatives list. A stays primary and its plan is not touched.
    ///
    /// The edited plan is B's base plan (prepared payload, or the generic
    /// switch-time plan) with only the edited fields overlaid — the same plan
    /// a promotion with edits would make primary.
    ///
    /// Destination, so B never gains a second row:
    ///  1. prepared provenance and B's prepared row is still listed → that row;
    ///  2. otherwise the first existing row for B (a generic switch to an
    ///     exercise that is already an alternative — no provenance inferred,
    ///     only the destination);
    ///  3. otherwise a new row for B: enabled, no note, appended.
    ///
    /// An updated row keeps its id, position, enabled state and note; only
    /// its plan changes.
    static func savingSwitchedPlan(
        switchedExerciseID: UUID,
        switchedExerciseName: String,
        appliedAlternativeID: UUID?,
        routineAlternatives: [SlotAlternative],
        frozenAlternatives: [SlotAlternative],
        switchTimePlan: AlternativePrescriptionPayload,
        session: SessionPlan,
        baseline: SessionPlan
    ) -> [SlotAlternative] {
        var list = routineAlternatives
        let prepared = preparedBase(
            exerciseID: switchedExerciseID,
            appliedAlternativeID: appliedAlternativeID,
            routineAlternatives: list,
            frozenAlternatives: frozenAlternatives)
        let edited = SlotPlanBundle.overlaying(
            session, over: baseline,
            onto: prepared?.plan ?? switchTimePlan)

        if let index = prepared?.routineIndex
            ?? list.firstIndex(where: { $0.exerciseID == switchedExerciseID })
        {
            list[index].prescription = edited
        } else {
            list.append(
                SlotAlternative(
                    order: (list.map(\.order).max() ?? -1) + 1,
                    isEnabled: true,
                    exerciseID: switchedExerciseID,
                    exerciseName: switchedExerciseName,
                    note: nil,
                    prescription: edited))
        }
        return SlotAlternatives.normalize(list)
    }

    // MARK: Pending changes

    /// One independently selectable routine change offered at finish.
    ///
    /// A switched slot contributes a `.replacement` row and, when its plan was
    /// edited, a `.planChanges` row; an unswitched slot contributes a
    /// `.planChanges` row when edited. Rows never imply one another — the
    /// caller passes back exactly the set the user selected.
    struct PendingChange: Hashable, Identifiable {
        enum Kind: Hashable { case replacement, planChanges }
        var kind: Kind
        var routineExerciseID: PersistentIdentifier
        var id: Self { self }
    }

    /// Every pending change for these slots, in slot order (a slot's
    /// replacement before its plan changes).
    static func pendingChanges(for requests: [SlotRequest]) -> [PendingChange] {
        requests.flatMap { request -> [PendingChange] in
            var rows: [PendingChange] = []
            if request.isSwitched {
                rows.append(
                    PendingChange(
                        kind: .replacement,
                        routineExerciseID: request.routineExerciseID))
            }
            if request.hasPlanEdits {
                rows.append(
                    PendingChange(
                        kind: .planChanges,
                        routineExerciseID: request.routineExerciseID))
            }
            return rows
        }
    }

    // MARK: Apply

    /// Apply exactly the selected pending changes, then save once.
    ///
    /// Per slot:
    ///  - unswitched + plan changes → the edits, on the slot's own plan;
    ///  - switched + replacement → promotion, with the edits iff the slot's
    ///    plan changes are also selected;
    ///  - switched + plan changes only → `savingSwitchedPlan` (A stays).
    ///
    /// Three phases, so a failure can never leave a half-written routine:
    /// every routine object is resolved first (the only step that can throw
    /// before saving), then every slot is mutated from values captured before
    /// any write, then one save.
    @MainActor
    static func apply(
        _ requests: [SlotRequest],
        selected: Set<PendingChange>,
        in ctx: ModelContext
    ) throws {
        enum Work {
            case promote(RoutineExercise, Exercise, SlotRequest, withEdits: Bool)
            case saveSwitchedPlan(RoutineExercise, Exercise, SlotRequest, SessionPlan)
            case edit(RoutineExercise, SessionPlan, SessionPlan)
        }

        // 1) Resolve.
        var work: [Work] = []
        for request in requests {
            let id = request.routineExerciseID
            let replace = selected.contains(
                PendingChange(kind: .replacement, routineExerciseID: id))
            // A plan row is honoured only when there is something to write.
            let session =
                request.hasPlanEdits
                && selected.contains(
                    PendingChange(kind: .planChanges, routineExerciseID: id))
                ? request.sessionPlan : nil

            if request.isSwitched {
                guard replace || session != nil else { continue }
                guard
                    let slot = try routineExercise(id, in: ctx),
                    // Write only against the exercise the session started
                    // with. The routine is locked during a workout, so this
                    // holds; if it ever does not, demoting whatever is there
                    // now would file the wrong exercise under A's plan (and a
                    // plan-only save could make B its own alternative).
                    slot.exercise?.id == request.originalExerciseID,
                    let switched = try exercise(
                        request.currentExerciseID, in: ctx)
                else { continue }
                if replace {
                    work.append(
                        .promote(slot, switched, request, withEdits: session != nil))
                } else if let session {
                    work.append(.saveSwitchedPlan(slot, switched, request, session))
                }
            } else if let session,
                let slot = try routineExercise(id, in: ctx)
            {
                work.append(.edit(slot, session, request.sessionBaseline))
            }
        }
        guard !work.isEmpty else { return }

        // 2) Mutate. Every value a slot is rewritten from is captured before
        //    that slot is touched.
        for item in work {
            switch item {
            case .promote(let slot, let promoted, let request, let withEdits):
                let demotedPlan = SlotPlanBundle.capture(from: slot)
                let result = Self.promotion(
                    demotedExerciseID: request.originalExerciseID,
                    demotedExerciseName: slot.exercise?.name ?? "",
                    demotedPlan: demotedPlan,
                    promotedExerciseID: promoted.id,
                    appliedAlternativeID:
                        request.sessionPlan?.appliedAlternativeID,
                    routineAlternatives:
                        slot.prescription?.slotAlternatives ?? [],
                    frozenAlternatives:
                        request.sessionPlan?.alternatives ?? [],
                    switchTimePlan: request.switchTimePlan,
                    planEdits: withEdits
                        ? request.sessionPlan.map {
                            ($0, request.sessionBaseline)
                        } : nil)

                slot.exercise = promoted
                SlotPlanBundle.apply(result.primaryPlan, to: slot, in: ctx)
                // `apply` guarantees a prescription.
                slot.prescription?.setSlotAlternatives(result.alternatives)

            case .saveSwitchedPlan(let slot, let switched, let request, let session):
                let alternatives = Self.savingSwitchedPlan(
                    switchedExerciseID: switched.id,
                    switchedExerciseName: switched.name,
                    appliedAlternativeID: session.appliedAlternativeID,
                    routineAlternatives:
                        slot.prescription?.slotAlternatives ?? [],
                    frozenAlternatives: session.alternatives,
                    switchTimePlan: request.switchTimePlan,
                    session: session,
                    baseline: request.sessionBaseline)
                // A's plan is untouched; only the list changes. A slot that
                // somehow has no prescription gets one to hold the list.
                if slot.prescription == nil {
                    SlotPlanBundle.apply(
                        SlotPlanBundle.capture(from: slot), to: slot, in: ctx)
                }
                slot.prescription?.setSlotAlternatives(alternatives)

            case .edit(let slot, let session, let baseline):
                // Same complete-plan path as a promotion: the slot's own plan
                // is the base, so only the edited fields change.
                let edited = SlotPlanBundle.overlaying(
                    session, over: baseline,
                    onto: SlotPlanBundle.capture(from: slot))
                SlotPlanBundle.apply(edited, to: slot, in: ctx)
            }
        }

        // 3) Save once.
        try ctx.save()
    }

    private static func routineExercise(
        _ id: PersistentIdentifier, in ctx: ModelContext
    ) throws -> RoutineExercise? {
        let descriptor = FetchDescriptor<RoutineExercise>(
            predicate: #Predicate { $0.id == id })
        return try ctx.fetch(descriptor).first
    }

    private static func exercise(
        _ id: UUID, in ctx: ModelContext
    ) throws -> Exercise? {
        let descriptor = FetchDescriptor<Exercise>(
            predicate: #Predicate { $0.id == id })
        return try ctx.fetch(descriptor).first
    }
}

extension RoutineTemplateUpdate.SlotRequest {
    /// Assemble a request from the active workout's state for one slot.
    init(planExercise: PlanExercise, sessionPlan: SessionPlan?, hasPlanEdits: Bool) {
        self.init(
            routineExerciseID: planExercise.routineExerciseID,
            originalExerciseID: planExercise.originalExerciseID,
            currentExerciseID: planExercise.currentExerciseID,
            sessionPlan: sessionPlan,
            switchTimePlan: SlotPlanBundle.switchTimePlan(of: planExercise),
            sessionBaseline: SlotPlanBundle.sessionBaseline(of: planExercise),
            hasPlanEdits: hasPlanEdits)
    }
}

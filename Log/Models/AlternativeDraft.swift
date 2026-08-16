import Foundation
import SwiftData

// ======================================================
// MARK: - Alternative Exercises — the authoring draft (Phase D)
// ======================================================
//
// `ALTERNATIVE_EXERCISES_DESIGN.md` §6.4 approach A, made concrete.
//
// An alternative's prescription is a **value payload**, but every editor the
// app already has — `PrescriptionFields`, `WarmupSchemeEditor`,
// `TechniquePlanEditor`, `CardioSegmentPlanEditor` — is written against a live
// `SlotPrescription` `@Model`. Those editors encode every rule the feature needs
// (cardio gating, tempo suppression on duration, technique conflict rules,
// distance-unit handling, duration ceilings). Forking them would mean
// re-implementing all of it; generalizing them over a protocol would mean
// touching ~2,000 lines of shipped authoring code.
//
// So the alternative editor **materializes a scratch slot** — an `Exercise`, a
// `RoutineExercise`, a `SlotPrescription` and its warm-up / technique children
// — binds the existing editors to it, and reads the payload back out.
//
// ## The leak question, answered structurally
//
// §6.4 names the risk: "the scratch graph must be inserted-then-deleted or
// built in a throwaway context, and that deletion must be reliable, or it
// becomes the orphan-row bug class" (the class
// `BackfillService.purgeOrphanSetTemplates` exists to clean up).
//
// This implementation takes the second option and makes the deletion
// unnecessary rather than reliable: the scratch graph is built in its **own
// in-memory `ModelContainer`**, never in the app's. There is no code path by
// which a scratch object can reach the user's store — not a forgotten delete,
// not an early return, not a crash mid-edit — because the two stores share no
// context, and nothing built here is ever assigned into an app-store object.
// The container dies with the editor screen; an in-memory store leaves no file.
//
// The one rule that keeps that true: **never assign an app-store object into
// the draft graph.** The scratch `Exercise` is a fresh copy of the chosen
// exercise's definition fields, not the exercise itself.

/// A throwaway SwiftData world holding one editable slot.
///
/// `@MainActor` because it owns a `ModelContainer.mainContext` and is driven
/// from SwiftUI.
@MainActor
final class AlternativeDraftStore {

    /// Everything the scratch slot graph can reach. `SetTemplate` is included
    /// because `RoutineExercise` owns a cascade relationship to it (the draft
    /// never creates one); the rest are the prescription's own children.
    private static let schema = Schema([
        Exercise.self, RoutineExercise.self, SetTemplate.self,
        SlotPrescription.self, WarmupScheme.self, WarmupStep.self,
        TechniquePlan.self,
    ])

    let container: ModelContainer
    let exercise: Exercise
    let slot: RoutineExercise
    let prescription: SlotPrescription

    var context: ModelContext { container.mainContext }

    /// Build a draft for one alternative.
    ///
    /// - Parameters:
    ///   - exerciseName: display name for the scratch exercise. Only ever read
    ///     by the editors (headers, bodyweight/cardio gating is by flag).
    ///   - trackingMode: the **live** mode of the resolved exercise, so the
    ///     editor offers the controls that exercise can actually use. An
    ///     alternative authored before its exercise was flipped to cardio
    ///     therefore edits under the new mode, which is the same rule the
    ///     switch adapter applies at apply time (§8.4).
    ///   - payload: the stored prescription to hydrate from.
    init(
        exerciseName: String,
        trackingMode: TrackingMode,
        equipmentType: String?,
        includesBodyweightInLoad: Bool,
        payload: AlternativePrescriptionPayload
    ) throws {
        container = try ModelContainer(
            for: Self.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        let ctx = container.mainContext

        // A **copy** of the definition fields, never the app's `Exercise`.
        let scratchExercise = Exercise(
            name: exerciseName,
            equipmentType: equipmentType,
            includesBodyweightInLoad: includesBodyweightInLoad)
        scratchExercise.isTimeBased = trackingMode.usesDuration
        scratchExercise.isCardio = trackingMode == .cardio
        ctx.insert(scratchExercise)

        let scratchSlot = RoutineExercise(
            exercise: scratchExercise, order: 0, setTemplates: [])
        ctx.insert(scratchSlot)

        let scratchPrescription = SlotPrescription()
        ctx.insert(scratchPrescription)
        scratchSlot.prescription = scratchPrescription

        exercise = scratchExercise
        slot = scratchSlot
        prescription = scratchPrescription

        hydrate(from: payload)
    }

    // MARK: - Payload → draft

    /// Write a stored payload onto the scratch slot.
    ///
    /// Field-for-field and lossless in the direction that matters: everything
    /// `AlternativePrescriptionPayload` carries has a home on the scratch slot,
    /// so what the user sees in the editor is exactly what was stored.
    private func hydrate(from payload: AlternativePrescriptionPayload) {
        let p = prescription
        p.sets = payload.sets
        p.repMin = payload.repMin
        p.repMax = payload.repMax
        p.restSecondsBetweenSets = payload.restSecondsBetweenSets
        p.restSecondsAfterExercise = payload.restSecondsAfterExercise
        p.rir = payload.rir
        p.rpe = payload.rpe
        p.tempo = payload.tempo
        p.effortModeRaw = payload.effortModeRaw
        p.rirStart = payload.rirStart
        p.rirEnd = payload.rirEnd
        p.rpeStart = payload.rpeStart
        p.rpeEnd = payload.rpeEnd
        // Encoded through the codec on both sides, so the payload's array form
        // and the slot's comma-separated column stay one value.
        p.customRIRTargetsRaw = EffortTargetList.encode(
            payload.customRIRTargets ?? [])
        p.customRPETargetsRaw = EffortTargetList.encode(
            payload.customRPETargets ?? [])
        p.durationMinSeconds = payload.durationMinSeconds
        p.durationMaxSeconds = payload.durationMaxSeconds
        p.usesDuration = payload.usesDuration
        p.targetDistanceMeters = payload.targetDistanceMeters
        p.targetDistanceUnitRaw = payload.targetDistanceUnitRaw
        // Through the tolerant accessor, so a plan this build would normalize
        // is normalized once, here, rather than on every render.
        p.setStructuredCardioPlan(payload.cardioSegments)
        slot.templateNotes = payload.slotNotes

        if !payload.warmupSteps.isEmpty {
            let scheme = WarmupScheme(name: "Warmup")
            context.insert(scheme)
            let steps = payload.warmupSteps
                .sorted { $0.order < $1.order }
                .enumerated()
                .map { index, snapshot -> WarmupStep in
                    let step = WarmupStep(
                        order: index,
                        kind: snapshot.kind,
                        reps: snapshot.reps,
                        percentOfWorking: snapshot.percentOfWorking,
                        restSecondsAfter: snapshot.restSecondsAfter,
                        note: snapshot.note,
                        weight: snapshot.weight)
                    context.insert(step)
                    return step
                }
            scheme.steps = steps
            p.warmupScheme = scheme
        }

        p.techniquePlans = payload.techniques
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { index, snapshot -> TechniquePlan in
                let plan = TechniquePlan(
                    order: index,
                    type: snapshot.type,
                    reps: snapshot.reps,
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
                context.insert(plan)
                return plan
            }
    }

    // MARK: - Draft → payload

    /// Read the edited slot back out as a payload.
    ///
    /// The inverse of `hydrate`, and the **only** way edits leave the draft.
    /// Lossy in exactly one documented place: `TechniquePlanSnapshot` has no
    /// `repMin` / `repMax` / `durationSeconds`, so a technique's rep-range
    /// fields do not survive — the same fields the session freeze already drops
    /// when it snapshots a routine's own techniques, so an alternative carries
    /// precisely what a slot carries into a workout.
    func payload() -> AlternativePrescriptionPayload {
        let p = prescription
        return AlternativePrescriptionPayload(
            sets: p.sets,
            repMin: p.repMin,
            repMax: p.repMax,
            restSecondsBetweenSets: p.restSecondsBetweenSets,
            restSecondsAfterExercise: p.restSecondsAfterExercise,
            rir: p.rir,
            rpe: p.rpe,
            // `effectiveTempo`, not `tempo`: a duration-based draft must not
            // write a stale tempo back into the payload. Same capture rule
            // `PrescriptionSnapshotPayload.init(from:exercise:)` uses.
            tempo: p.effectiveTempo,
            effortModeRaw: p.effortModeRaw,
            rirStart: p.rirStart,
            rirEnd: p.rirEnd,
            rpeStart: p.rpeStart,
            rpeEnd: p.rpeEnd,
            customRIRTargets: p.customRIRTargets.isEmpty
                ? nil : p.customRIRTargets,
            customRPETargets: p.customRPETargets.isEmpty
                ? nil : p.customRPETargets,
            durationMinSeconds: p.durationMinSeconds,
            durationMaxSeconds: p.durationMaxSeconds,
            usesDuration: p.usesDuration,
            targetDistanceMeters: p.targetDistanceMeters,
            targetDistanceUnitRaw: p.targetDistanceUnitRaw,
            warmupSteps: (p.warmupScheme?.steps ?? [])
                .sorted { $0.order < $1.order }
                .map {
                    WarmupStepSnapshot(
                        order: $0.order,
                        kind: $0.kind,
                        reps: $0.reps,
                        percentOfWorking: $0.percentOfWorking,
                        note: $0.note,
                        restSecondsAfter: $0.restSecondsAfter,
                        weight: $0.weight)
                },
            techniques: p.techniquePlans
                .sorted { $0.order < $1.order }
                .map {
                    TechniquePlanSnapshot(
                        order: $0.order,
                        type: $0.type,
                        dropPercent: $0.dropPercent,
                        dropCount: $0.dropCount,
                        rounds: $0.rounds,
                        restSeconds: $0.restSeconds,
                        partialRangeNote: $0.partialRangeNote,
                        partialRangeRaw: $0.partialRangeRaw,
                        note: $0.note,
                        reps: $0.reps,
                        appliesToRaw: $0.appliesToRaw,
                        appliesToSetNumber: $0.appliesToSetNumber,
                        appliesToSetIndicesRaw: $0.appliesToSetIndicesRaw.isEmpty
                            ? nil : $0.appliesToSetIndicesRaw,
                        dropsetEffortRaw: $0.dropsetEffortRaw,
                        dropsetEffortReps: $0.dropsetEffortReps)
                },
            cardioSegments: p.structuredCardioPlan,
            slotNotes: slot.templateNotes)
    }

    // MARK: - Seeding a new alternative

    /// The prescription a freshly-added alternative starts from: **the app's
    /// defaults for the picked exercise's tracking mode** (§6.3), not the
    /// primary slot's plan — the whole premise of the feature is that the
    /// primary's plan may be wrong for this exercise.
    ///
    /// Built by running the real `makeDefaultPrescription` factory inside a
    /// throwaway draft store, so "an alternative's defaults" and "a new routine
    /// slot's defaults" cannot drift apart: `AppSettings`, `CardioRoutineRules`
    /// and the autoreg seeding rules are read exactly once, in one place.
    ///
    /// Returns an empty payload if the throwaway container cannot be built —
    /// an alternative with no plan is recoverable by editing; a crash while
    /// adding one is not.
    static func defaultPayload(for mode: TrackingMode) -> AlternativePrescriptionPayload {
        guard
            let store = try? AlternativeDraftStore(
                exerciseName: "",
                trackingMode: mode,
                equipmentType: nil,
                includesBodyweightInLoad: false,
                payload: AlternativePrescriptionPayload())
        else { return AlternativePrescriptionPayload() }

        let seeded = makeDefaultPrescription(
            isTimeBased: mode.usesDuration,
            isCardio: mode == .cardio,
            in: store.context)
        return AlternativeDraftStore.payload(of: seeded, slotNotes: nil)
    }

    /// Payload projection for a prescription that is not this store's own —
    /// used by `defaultPayload(for:)`, which swaps in a factory-built one.
    private static func payload(
        of p: SlotPrescription, slotNotes: String?
    ) -> AlternativePrescriptionPayload {
        AlternativePrescriptionPayload(
            sets: p.sets,
            repMin: p.repMin,
            repMax: p.repMax,
            restSecondsBetweenSets: p.restSecondsBetweenSets,
            restSecondsAfterExercise: p.restSecondsAfterExercise,
            rir: p.rir,
            rpe: p.rpe,
            tempo: p.effectiveTempo,
            effortModeRaw: p.effortModeRaw,
            rirStart: p.rirStart,
            rirEnd: p.rirEnd,
            rpeStart: p.rpeStart,
            rpeEnd: p.rpeEnd,
            customRIRTargets: p.customRIRTargets.isEmpty
                ? nil : p.customRIRTargets,
            customRPETargets: p.customRPETargets.isEmpty
                ? nil : p.customRPETargets,
            durationMinSeconds: p.durationMinSeconds,
            durationMaxSeconds: p.durationMaxSeconds,
            usesDuration: p.usesDuration,
            targetDistanceMeters: p.targetDistanceMeters,
            targetDistanceUnitRaw: p.targetDistanceUnitRaw,
            cardioSegments: p.structuredCardioPlan,
            slotNotes: slotNotes)
    }
}

// ======================================================
// MARK: - List authoring operations
// ======================================================

/// Add / update / delete / reorder for a slot's alternatives.
///
/// The editor screens call these rather than assembling arrays inline, so every
/// mutation goes through one write path (`setSlotAlternatives`, which
/// normalizes) and every one of them is testable without a view.
///
/// Each operation reads the stored list, changes exactly what it names, and
/// writes the whole list back — so an edit to one alternative can never disturb
/// another, and none of them touch the slot's own prescription fields.
@MainActor
enum SlotAlternativeAuthoring {

    /// Append a new alternative, ordered last.
    @discardableResult
    static func append(
        exerciseID: UUID,
        exerciseName: String,
        prescription payload: AlternativePrescriptionPayload,
        to slotPrescription: SlotPrescription
    ) -> SlotAlternative {
        var list = slotPrescription.slotAlternatives
        let alternative = SlotAlternative(
            order: list.count,
            exerciseID: exerciseID,
            exerciseName: exerciseName,
            prescription: payload)
        list.append(alternative)
        slotPrescription.setSlotAlternatives(list)
        return alternative
    }

    /// Mutate one alternative in place, addressed by id.
    ///
    /// A no-op when the id is not present — the row may have been deleted on
    /// another screen while a detail editor was open, and re-adding it from a
    /// stale editor would resurrect deleted work.
    static func update(
        id: UUID,
        in slotPrescription: SlotPrescription,
        transform: (inout SlotAlternative) -> Void
    ) {
        var list = slotPrescription.slotAlternatives
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        transform(&list[index])
        slotPrescription.setSlotAlternatives(list)
    }

    static func delete(
        atOffsets offsets: IndexSet, in slotPrescription: SlotPrescription
    ) {
        var list = slotPrescription.slotAlternatives
        list.remove(atOffsets: offsets)
        slotPrescription.setSlotAlternatives(list)
    }

    /// Reorder. `setSlotAlternatives` renumbers `order` densely, so the moved
    /// list is written already normalized.
    static func move(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        in slotPrescription: SlotPrescription
    ) {
        var list = slotPrescription.slotAlternatives
        list.move(fromOffsets: source, toOffset: destination)
        for index in list.indices { list[index].order = index }
        slotPrescription.setSlotAlternatives(list)
    }
}

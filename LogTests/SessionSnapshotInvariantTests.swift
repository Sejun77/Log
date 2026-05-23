import SwiftData
import XCTest

@testable import Log

/// Phase 7 stabilization close-out — pins the two oldest invariants
/// from the refactor:
///
///   1. **Session creation snapshots prescription** (Phase 3.3).
///      Building a workout plan from a routine must denormalize the
///      live `SlotPrescription` + slot identity + 6.C1 source-block
///      fields onto each `PlanExercise`, so the populator
///      (`ActiveWorkoutView.populateSnapshotFields(on:from:)`) has the
///      right values to copy onto every lazy-created `WorkoutItem`.
///
///   2. **No silent mutation** (Phase 2). Editing a `SessionPlan` in
///      memory must not flow back into the routine's
///      `SlotPrescription` / `templateNotes`. The only path that
///      mutates them is the explicit "Update slot prescription" apply
///      action (`ActiveWorkoutView.applySessionPlansToSlotPrescriptions`).
///
/// **Testable surface chosen**: `WorkoutResumeService.rebuildPlan(for:in:)`
/// is the pure `@MainActor static` entry point whose primary path
/// (`planFromRoutine`) mirrors `StartWorkoutFromRoutineView.makePlan`
/// field-for-field (documented at the top of `planFromRoutine` and
/// pinned by the 6.C1 + 9-B2 cross-path resume tests). Driving these
/// tests through `rebuildPlan` exercises the same Routine →
/// PlanExercise denormalization a freshly-started workout uses, with
/// no View instantiation required.
///
/// **Note on duplicating existing 6.C1 coverage**:
/// `WorkoutResumeServiceTests.testRebuildPlanPrimaryPathCarriesBlockSnapshotFields`
/// already exhaustively covers the four 6.C1 source-block fields on
/// both a standalone and a superset block; this file adds a single
/// per-slot smoke check rather than re-deriving the full matrix, so
/// the coverage is composable but not redundant.
@MainActor
final class SessionSnapshotInvariantTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeExercise(name: String, isTimeBased: Bool = false)
        -> Exercise
    {
        let e = Exercise(name: name, isCustom: true)
        e.isTimeBased = isTimeBased
        context.insert(e)
        return e
    }

    /// Build a rep-based `SlotPrescription` with every meaningful field
    /// set so the snapshot can be asserted field-by-field. The values
    /// are deliberately distinctive (no defaults) so a regression that
    /// dropped a single field would fail loudly.
    private func makeRepBasedPrescription() -> SlotPrescription {
        let p = SlotPrescription(
            sets: 4,
            repMin: 6,
            repMax: 10,
            restSecondsBetweenSets: 75,
            restSecondsAfterExercise: 180,
            rir: 1.5,
            rpe: 8.5,
            tempo: "3-1-1-0",
            durationMinSeconds: nil,
            durationMaxSeconds: nil,
            usesDuration: false,
            equipment: "Barbell",
            setupNotes: "Bench, narrow grip"
        )
        context.insert(p)
        return p
    }

    /// Build a time-based `SlotPrescription` so the duration fields
    /// are non-nil and the rep fields are nil. Mirrors the routine
    /// editor's mode-switch behavior.
    private func makeTimeBasedPrescription() -> SlotPrescription {
        let p = SlotPrescription(
            sets: 3,
            repMin: nil,
            repMax: nil,
            restSecondsBetweenSets: 60,
            restSecondsAfterExercise: 120,
            rir: nil,
            rpe: nil,
            tempo: nil,
            durationMinSeconds: 30,
            durationMaxSeconds: 45,
            usesDuration: true,
            equipment: "Mat",
            setupNotes: nil
        )
        context.insert(p)
        return p
    }

    /// Build a one-block / one-exercise routine with the given
    /// prescription attached to its sole slot. Returns the routine
    /// plus the `Workout` that the cold-restart path would consume.
    @discardableResult
    private func makeRoutineAndWorkout(
        prescription: SlotPrescription?,
        slotExercise: Exercise,
        slotNotes: String? = nil,
        blockIsSuperset: Bool = false,
        routineName: String = "Push"
    ) -> (routine: Routine, slot: RoutineExercise, block: RoutineBlock, workout: Workout) {
        let re = RoutineExercise(
            exercise: slotExercise, order: 0, setTemplates: []
        )
        re.prescription = prescription
        re.templateNotes = slotNotes
        context.insert(re)
        let block = RoutineBlock(
            isSuperset: blockIsSuperset, order: 0, exercises: [re]
        )
        context.insert(block)
        let routine = Routine(name: routineName, blocks: [block])
        context.insert(routine)
        let w = Workout(
            routineName: routineName,
            routineID: routine.id,
            routineVariantID: nil,
            items: []
        )
        context.insert(w)
        try? context.save()
        return (routine, re, block, w)
    }

    // MARK: - 1) SlotPrescription → PlanExercise.prescriptionSnapshot
    //          (every meaningful field round-trips)

    /// Rep-based slot: every non-duration field on the live
    /// `SlotPrescription` must surface on
    /// `PlanExercise.prescriptionSnapshot` after `rebuildPlan` (the
    /// shared start/resume primary path). This is the headline
    /// "session-creation snapshots prescription" invariant.
    func testStart_SnapshotsAllRepBasedPrescriptionFields() {
        let ex = makeExercise(name: "Bench")
        let p = makeRepBasedPrescription()
        let fx = makeRoutineAndWorkout(
            prescription: p, slotExercise: ex, slotNotes: "Slow eccentric"
        )

        let plan = WorkoutResumeService.rebuildPlan(
            for: fx.workout, in: context
        )
        let snap = plan?.blocks.first?.exercises.first?.prescriptionSnapshot

        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.sets, 4)
        XCTAssertEqual(snap?.repMin, 6)
        XCTAssertEqual(snap?.repMax, 10)
        XCTAssertEqual(snap?.restSecondsBetweenSets, 75)
        XCTAssertEqual(snap?.restSecondsAfterExercise, 180)
        XCTAssertEqual(snap?.rir, 1.5)
        XCTAssertEqual(snap?.rpe, 8.5)
        XCTAssertEqual(snap?.tempo, "3-1-1-0")
        XCTAssertEqual(snap?.usesDuration, false)
        XCTAssertNil(snap?.durationMinSeconds)
        XCTAssertNil(snap?.durationMaxSeconds)
        XCTAssertEqual(snap?.equipment, "Barbell")
        XCTAssertEqual(snap?.setupNotes, "Bench, narrow grip")
    }

    /// Time-based slot: duration fields populate, rep fields don't,
    /// `usesDuration` carries the flag.
    func testStart_SnapshotsAllTimeBasedPrescriptionFields() {
        let ex = makeExercise(name: "Plank", isTimeBased: true)
        let p = makeTimeBasedPrescription()
        let fx = makeRoutineAndWorkout(
            prescription: p, slotExercise: ex
        )

        let plan = WorkoutResumeService.rebuildPlan(
            for: fx.workout, in: context
        )
        let snap = plan?.blocks.first?.exercises.first?.prescriptionSnapshot

        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.sets, 3)
        XCTAssertNil(snap?.repMin)
        XCTAssertNil(snap?.repMax)
        XCTAssertEqual(snap?.restSecondsBetweenSets, 60)
        XCTAssertEqual(snap?.restSecondsAfterExercise, 120)
        XCTAssertEqual(snap?.usesDuration, true)
        XCTAssertEqual(snap?.durationMinSeconds, 30)
        XCTAssertEqual(snap?.durationMaxSeconds, 45)
        XCTAssertEqual(snap?.equipment, "Mat")
        XCTAssertNil(snap?.setupNotes)
    }

    /// A slot with no prescription must produce a nil snapshot —
    /// proves the populator doesn't synthesize values out of thin
    /// air, and aligns with the legacy pre-3.3 contract (snapshot is
    /// absent rather than zero-filled).
    func testStart_NilPrescriptionProducesNilSnapshot() {
        let ex = makeExercise(name: "Curl")
        let fx = makeRoutineAndWorkout(
            prescription: nil, slotExercise: ex
        )

        let plan = WorkoutResumeService.rebuildPlan(
            for: fx.workout, in: context
        )
        let snap = plan?.blocks.first?.exercises.first?.prescriptionSnapshot

        XCTAssertNil(snap)
    }

    // MARK: - 2) routineSlotID is stored on every PlanExercise

    /// `PlanExercise.routineSlotID` is the per-slot identity that
    /// `ActiveWorkoutView` keys every state store on (loggedByExercise,
    /// dropsLoggedByExercise, sessionPlans, drop-draft keys, …) since
    /// Phase 5.2 Slice A. The populator copies it onto each
    /// `WorkoutItem` so resume can re-bind the same per-slot state
    /// after a cold restart. This test pins that the start path
    /// (mirrored by `planFromRoutine`) carries it across.
    func testStart_StoresRoutineSlotIDOnEveryPlanExercise() {
        let ex = makeExercise(name: "Bench")
        let p = makeRepBasedPrescription()
        let fx = makeRoutineAndWorkout(
            prescription: p, slotExercise: ex
        )

        let plan = WorkoutResumeService.rebuildPlan(
            for: fx.workout, in: context
        )
        let planEx = plan?.blocks.first?.exercises.first

        XCTAssertEqual(planEx?.routineSlotID, fx.slot.slotID)
    }

    /// Two slots referencing the same Exercise in one superset must
    /// receive **distinct** `routineSlotID` values — the duplicate-
    /// Exercise-superset identity contract pinned at the helper
    /// level by `PlanSlotLookupTests` and pinned end-to-end here.
    func testStart_DistinctRoutineSlotIDsForDuplicateExerciseSlots() {
        let ex = makeExercise(name: "Twin")
        let p1 = makeRepBasedPrescription()
        let p2 = makeRepBasedPrescription()
        let re1 = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        re1.prescription = p1
        let re2 = RoutineExercise(exercise: ex, order: 1, setTemplates: [])
        re2.prescription = p2
        context.insert(re1); context.insert(re2)

        let block = RoutineBlock(
            isSuperset: true, order: 0, exercises: [re1, re2]
        )
        context.insert(block)
        let routine = Routine(name: "Dup", blocks: [block])
        context.insert(routine)
        let w = Workout(
            routineName: "Dup",
            routineID: routine.id,
            routineVariantID: nil,
            items: []
        )
        context.insert(w)
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let exs = plan?.blocks.first?.exercises ?? []

        XCTAssertEqual(exs.count, 2)
        XCTAssertEqual(
            Set(exs.map(\.routineSlotID)),
            Set([re1.slotID, re2.slotID]),
            "Duplicate-Exercise superset slots must remain identity-distinct"
        )
        XCTAssertEqual(
            exs.map(\.routineSlotID).count,
            Set(exs.map(\.routineSlotID)).count,
            "No collisions across the two duplicate slots"
        )
    }

    // MARK: - 3) templateNotesSnapshot stored

    /// Per-slot coaching notes are denormalized onto the
    /// `PlanExercise` so the populator can write them onto
    /// `WorkoutItem.templateNotesSnapshot` (the read-only History
    /// surface from Phase 3.3 + Phase 6.A).
    func testStart_StoresTemplateNotesSnapshot() {
        let ex = makeExercise(name: "Bench")
        let p = makeRepBasedPrescription()
        let fx = makeRoutineAndWorkout(
            prescription: p,
            slotExercise: ex,
            slotNotes: "Pause 1s on chest"
        )

        let plan = WorkoutResumeService.rebuildPlan(
            for: fx.workout, in: context
        )
        let planEx = plan?.blocks.first?.exercises.first

        XCTAssertEqual(planEx?.templateNotesSnapshot, "Pause 1s on chest")
    }

    /// nil slot notes must surface as nil — confirms no fallback to
    /// `Exercise.notes` or the empty string. (`Exercise.notes` is a
    /// distinct category in the Phase 6.A canonical reference.)
    func testStart_NilSlotNotesProduceNilSnapshot() {
        let ex = makeExercise(name: "Bench")
        let p = makeRepBasedPrescription()
        let fx = makeRoutineAndWorkout(
            prescription: p, slotExercise: ex, slotNotes: nil
        )

        let plan = WorkoutResumeService.rebuildPlan(
            for: fx.workout, in: context
        )

        XCTAssertNil(plan?.blocks.first?.exercises.first?.templateNotesSnapshot)
    }

    // MARK: - 4) Phase 6.C1 source-block fields populated at start

    /// Lightweight per-slot smoke that the 6.C1 fields are populated
    /// at start. Deep coverage of multi-block + superset layouts
    /// lives in `WorkoutResumeServiceTests.testRebuildPlanPrimaryPathCarriesBlockSnapshotFields`;
    /// this case ensures the four-field tuple is plumbed for the
    /// standard single-slot workout shape this file exercises.
    func testStart_PopulatesSourceBlockSnapshotFields() {
        let ex = makeExercise(name: "Bench")
        let p = makeRepBasedPrescription()
        let fx = makeRoutineAndWorkout(
            prescription: p,
            slotExercise: ex,
            blockIsSuperset: false
        )

        let plan = WorkoutResumeService.rebuildPlan(
            for: fx.workout, in: context
        )
        let planEx = plan?.blocks.first?.exercises.first

        XCTAssertEqual(planEx?.sourceBlockSlotID, fx.block.slotID)
        XCTAssertEqual(planEx?.sourceBlockIsSuperset, false)
        XCTAssertEqual(planEx?.sourceBlockOrder, 0)
        XCTAssertEqual(planEx?.sourceExerciseOrderInBlock, 0)
    }

    // MARK: - 5) No silent mutation: SessionPlan edits do not flow
    //          back into SlotPrescription / templateNotes

    /// Construct a `SessionPlan` from a live prescription snapshot,
    /// mutate every field, save the context, refetch the
    /// `SlotPrescription` by id, and assert every field is byte-for-
    /// byte unchanged. This pins the Phase 2 contract that
    /// `SessionPlan` is an in-memory `Codable` value-type override —
    /// no implicit propagation, no SwiftData write path.
    ///
    /// The type-system already disallows accidental writes (struct
    /// vs `@Model` class), but this test guards against any future
    /// code path that might add a synchronization shim.
    func testEditingSessionPlan_DoesNotMutateSlotPrescription() {
        let ex = makeExercise(name: "Bench")
        let p = makeRepBasedPrescription()
        let fx = makeRoutineAndWorkout(
            prescription: p,
            slotExercise: ex,
            slotNotes: "Pause 1s on chest"
        )
        let originalPrescriptionID = p.persistentModelID
        let originalSlotID = fx.slot.slotID

        // Capture baseline values to compare against post-edit.
        let baselineSets = p.sets
        let baselineRepMin = p.repMin
        let baselineRepMax = p.repMax
        let baselineRestBetween = p.restSecondsBetweenSets
        let baselineRestAfter = p.restSecondsAfterExercise
        let baselineRIR = p.rir
        let baselineRPE = p.rpe
        let baselineTempo = p.tempo
        let baselineUsesDuration = p.usesDuration
        let baselineDurationMin = p.durationMinSeconds
        let baselineDurationMax = p.durationMaxSeconds
        let baselineEquipment = p.equipment
        let baselineSetupNotes = p.setupNotes
        let baselineTemplateNotes = fx.slot.templateNotes

        // Build a SessionPlan from the snapshot payload and mutate
        // every field to a deliberately distinct value.
        let payload = PrescriptionSnapshotPayload(from: p)
        var sp = SessionPlan(
            from: payload,
            notes: fx.slot.templateNotes
        )
        sp.sets = 99
        sp.repMin = 99
        sp.repMax = 99
        sp.restSecondsBetweenSets = 999
        sp.restSecondsAfterExercise = 999
        sp.rir = 9.9
        sp.rpe = 9.9
        sp.tempo = "9-9-9-9"
        sp.usesDuration = true
        sp.durationMinSeconds = 999
        sp.durationMaxSeconds = 999
        sp.slotNotes = "MUTATED — should not propagate"
        // SessionPlan does not carry equipment / setupNotes —
        // they're Exercise-level (Phase 10 scope) and never editable
        // from the session-plan sheet. We do not assert against them
        // here beyond the unchanged baseline.

        // Force a save to flush any latent mutations. If a write-back
        // shim existed, this is where it would surface.
        try? context.save()

        // Refetch the prescription by id (not by reference) so we
        // bypass any in-memory caching of the original object.
        let fetched: SlotPrescription? = {
            let desc = FetchDescriptor<SlotPrescription>(
                predicate: #Predicate {
                    $0.persistentModelID == originalPrescriptionID
                }
            )
            return try? context.fetch(desc).first
        }()

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.sets, baselineSets)
        XCTAssertEqual(fetched?.repMin, baselineRepMin)
        XCTAssertEqual(fetched?.repMax, baselineRepMax)
        XCTAssertEqual(fetched?.restSecondsBetweenSets, baselineRestBetween)
        XCTAssertEqual(fetched?.restSecondsAfterExercise, baselineRestAfter)
        XCTAssertEqual(fetched?.rir, baselineRIR)
        XCTAssertEqual(fetched?.rpe, baselineRPE)
        XCTAssertEqual(fetched?.tempo, baselineTempo)
        XCTAssertEqual(fetched?.usesDuration, baselineUsesDuration)
        XCTAssertEqual(fetched?.durationMinSeconds, baselineDurationMin)
        XCTAssertEqual(fetched?.durationMaxSeconds, baselineDurationMax)
        XCTAssertEqual(fetched?.equipment, baselineEquipment)
        XCTAssertEqual(fetched?.setupNotes, baselineSetupNotes)

        // Refetch the slot's templateNotes by slotID so we likewise
        // bypass any in-memory caching.
        let refetchedSlot: RoutineExercise? = {
            let desc = FetchDescriptor<RoutineExercise>(
                predicate: #Predicate { $0.slotID == originalSlotID }
            )
            return try? context.fetch(desc).first
        }()
        XCTAssertEqual(refetchedSlot?.templateNotes, baselineTemplateNotes)
    }

    /// Multi-slot variant: editing the SessionPlan for slot A must
    /// not bleed into slot B's prescription either, even when both
    /// slots reference the same `Exercise` (the duplicate-superset
    /// shape from Phase 5.2 Slice A's per-slot identity model).
    func testEditingOneSessionPlan_DoesNotBleedIntoSiblingSlot() {
        let ex = makeExercise(name: "Twin")
        let pA = makeRepBasedPrescription()
        let pB = SlotPrescription(
            sets: 5,
            repMin: 3,
            repMax: 5,
            restSecondsBetweenSets: 120,
            restSecondsAfterExercise: 240,
            rir: 0.5,
            rpe: 9.5,
            tempo: "2-0-1-0",
            durationMinSeconds: nil,
            durationMaxSeconds: nil,
            usesDuration: false,
            equipment: "Cable",
            setupNotes: "Heavy"
        )
        context.insert(pB)

        let reA = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        reA.prescription = pA
        let reB = RoutineExercise(exercise: ex, order: 1, setTemplates: [])
        reB.prescription = pB
        context.insert(reA); context.insert(reB)

        let block = RoutineBlock(
            isSuperset: true, order: 0, exercises: [reA, reB]
        )
        context.insert(block)
        let routine = Routine(name: "Dup", blocks: [block])
        context.insert(routine)
        try? context.save()

        let baselineB = (
            sets: pB.sets,
            repMin: pB.repMin,
            repMax: pB.repMax,
            rest: pB.restSecondsBetweenSets,
            tempo: pB.tempo
        )

        // Mutate a SessionPlan derived from slot A. Slot B's
        // prescription must remain untouched.
        var spA = SessionPlan(
            from: PrescriptionSnapshotPayload(from: pA),
            notes: reA.templateNotes
        )
        spA.sets = 11
        spA.repMin = 11
        spA.repMax = 11
        spA.restSecondsBetweenSets = 11
        spA.tempo = "1-1-1-1"

        try? context.save()

        let slotBID = reB.slotID
        let refetchedB: SlotPrescription? = {
            let desc = FetchDescriptor<RoutineExercise>(
                predicate: #Predicate { $0.slotID == slotBID }
            )
            return (try? context.fetch(desc).first)?.prescription
        }()

        XCTAssertNotNil(refetchedB)
        XCTAssertEqual(refetchedB?.sets, baselineB.sets)
        XCTAssertEqual(refetchedB?.repMin, baselineB.repMin)
        XCTAssertEqual(refetchedB?.repMax, baselineB.repMax)
        XCTAssertEqual(
            refetchedB?.restSecondsBetweenSets, baselineB.rest
        )
        XCTAssertEqual(refetchedB?.tempo, baselineB.tempo)
    }

    /// Stale-fetch defense: re-running `rebuildPlan` after a
    /// SessionPlan was modified in memory must continue to surface
    /// the **original** prescription values in the rebuilt snapshot.
    /// If a write-back regression existed, the second rebuild would
    /// reflect the SessionPlan's edited values rather than the
    /// persisted `SlotPrescription`'s.
    func testRebuildAfterSessionPlanEdit_StillReflectsPersistedPrescription() {
        let ex = makeExercise(name: "Bench")
        let p = makeRepBasedPrescription()
        let fx = makeRoutineAndWorkout(
            prescription: p, slotExercise: ex
        )

        var sp = SessionPlan(
            from: PrescriptionSnapshotPayload(from: p),
            notes: fx.slot.templateNotes
        )
        sp.sets = 42
        sp.tempo = "MUT"
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(
            for: fx.workout, in: context
        )
        let snap = plan?.blocks.first?.exercises.first?.prescriptionSnapshot

        XCTAssertEqual(snap?.sets, 4, "Original SlotPrescription.sets")
        XCTAssertEqual(snap?.tempo, "3-1-1-0", "Original tempo")
    }

    // MARK: - 6) Positive-control apply-back test — INTENTIONALLY SKIPPED

    /// `ActiveWorkoutView.applySessionPlansToSlotPrescriptions()` is
    /// `private` and lives inside the SwiftUI View struct. It reads
    /// `self.plan` + `self.sessionPlans` + `self.ctx` and writes
    /// onto the matching `RoutineExercise.prescription`. Testing it
    /// directly would require either:
    ///
    ///   (a) bumping the method (and `isSessionPlanDirty(for:in:)`,
    ///       `sessionPlans`, `plan`) from `private` to
    ///       module-internal — a meaningful widening of the View's
    ///       access surface for a one-test gain; or
    ///
    ///   (b) extracting the apply-back into a `@MainActor` service
    ///       (mirroring `WorkoutLifecycleService`'s 7.7 / 8-B
    ///       extraction). That's appropriate Phase 11 / Phase 12
    ///       follow-up work but is out of scope for this stabilization
    ///       slice (test-only change requested).
    ///
    /// The audit explicitly authorized skipping this positive control
    /// when the path is view-coupled, "rather than adding risky
    /// production access." The negative-control suite above
    /// (`testEditingSessionPlan_*` / `testEditingOneSessionPlan_*` /
    /// `testRebuildAfterSessionPlanEdit_*`) is sufficient to prove
    /// the no-silent-mutation invariant; the apply-back path
    /// remains exercised by the existing manual finish-dialog
    /// regression and by the `ApplySessionPlansToSlotPrescriptions`
    /// behavior already audited inline at
    /// `ActiveWorkoutView.swift:1801`. Documented here so a future
    /// reader sees the explicit decision rather than an unexplained
    /// gap.
    func testApplyBack_PositiveControl_SKIPPED_documentedRationale() {
        // No-op; the rationale above is the test artifact.
    }
}

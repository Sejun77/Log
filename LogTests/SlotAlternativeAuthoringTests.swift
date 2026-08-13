import SwiftData
import XCTest

@testable import Log

/// Alternative Exercises Phase D — the routine editor's authoring model.
///
/// The screens themselves are SwiftUI and untestable without a UI harness, so
/// what these tests exercise is everything the screens *call*:
/// `SlotAlternativeAuthoring` (add / update / delete / reorder),
/// `AlternativeDraftStore` (the scratch-slot bridge the detail editor binds
/// existing prescription editors to), and its seeding.
///
/// Two rules matter most:
///
///  1. **The scratch slot cannot leak.** It lives in its own in-memory
///     container, so no `SlotPrescription`, `WarmupScheme`, `WarmupStep` or
///     `TechniquePlan` row can reach the user's store while an alternative is
///     being edited — the orphan-row bug class
///     `BackfillService.purgeOrphanSetTemplates` exists to clean up.
///  2. **Editing one alternative touches nothing else.** Not the slot's own
///     prescription, not its siblings.
@MainActor
final class SlotAlternativeAuthoringTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func prescription() -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        return p
    }

    private func exercise(
        _ name: String, timeBased: Bool = false, cardio: Bool = false
    ) -> Exercise {
        let e = Exercise(name: name)
        e.isTimeBased = timeBased
        e.isCardio = cardio
        context.insert(e)
        return e
    }

    private func draft(
        _ payload: AlternativePrescriptionPayload = .init(),
        mode: TrackingMode = .strength
    ) throws -> AlternativeDraftStore {
        try AlternativeDraftStore(
            exerciseName: "Machine Chest Press",
            trackingMode: mode,
            equipmentType: nil,
            includesBodyweightInLoad: false,
            payload: payload)
    }

    private func cardioPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                CardioSegment(kind: .warmUp, durationSeconds: 300),
                CardioSegment(kind: .work, durationSeconds: 1_200),
            ])
        ])
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    // MARK: - 1. Adding

    func testAddingAnAlternativeWritesTheColumn() throws {
        let p = prescription()
        let machine = exercise("Machine Chest Press")

        let added = SlotAlternativeAuthoring.append(
            exerciseID: machine.id,
            exerciseName: machine.name,
            prescription: AlternativeDraftStore.defaultPayload(for: .strength),
            to: p)
        try context.save()

        XCTAssertNotNil(p.alternativesData)
        XCTAssertEqual(p.slotAlternatives.count, 1)
        XCTAssertEqual(p.slotAlternatives.first?.id, added.id)
        XCTAssertEqual(p.slotAlternatives.first?.exerciseID, machine.id)
        XCTAssertEqual(
            p.slotAlternatives.first?.exerciseName, "Machine Chest Press")
        XCTAssertTrue(
            p.slotAlternatives.first?.isEnabled ?? false,
            "a new alternative is offered by default")
    }

    func testAddingSeveralKeepsTapOrder() throws {
        let p = prescription()
        for name in ["first", "second", "third"] {
            SlotAlternativeAuthoring.append(
                exerciseID: UUID(), exerciseName: name,
                prescription: AlternativePrescriptionPayload(), to: p)
        }
        try context.save()

        XCTAssertEqual(
            p.slotAlternatives.map(\.exerciseName),
            ["first", "second", "third"])
        XCTAssertEqual(p.slotAlternatives.map(\.order), [0, 1, 2])
    }

    // MARK: - 2. Seeding from app defaults

    /// The seed must be **the app's default prescription for the picked
    /// exercise's mode** (§6.3), not the slot's plan and not a hand-written
    /// copy of the defaults. Asserted by running the real factory and comparing.
    private func assertSeedMatchesAppDefaults(
        _ mode: TrackingMode, file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = makeDefaultPrescription(
            isTimeBased: mode.usesDuration, isCardio: mode == .cardio,
            in: context)
        let seeded = AlternativeDraftStore.defaultPayload(for: mode)

        XCTAssertEqual(seeded.sets, expected.sets, file: file, line: line)
        XCTAssertEqual(seeded.repMin, expected.repMin, file: file, line: line)
        XCTAssertEqual(seeded.repMax, expected.repMax, file: file, line: line)
        XCTAssertEqual(
            seeded.restSecondsBetweenSets, expected.restSecondsBetweenSets,
            file: file, line: line)
        XCTAssertEqual(
            seeded.restSecondsAfterExercise, expected.restSecondsAfterExercise,
            file: file, line: line)
        XCTAssertEqual(seeded.rir, expected.rir, file: file, line: line)
        XCTAssertEqual(seeded.rpe, expected.rpe, file: file, line: line)
        XCTAssertEqual(
            seeded.usesDuration, expected.usesDuration, file: file, line: line)
    }

    func testNewAlternativeIsSeededFromStrengthDefaults() {
        assertSeedMatchesAppDefaults(.strength)
        let seeded = AlternativeDraftStore.defaultPayload(for: .strength)
        XCTAssertFalse(seeded.usesDuration)
        XCTAssertNotNil(seeded.repMin)
    }

    func testNewAlternativeIsSeededFromTimedHoldDefaults() {
        assertSeedMatchesAppDefaults(.timedHold)
        let seeded = AlternativeDraftStore.defaultPayload(for: .timedHold)
        XCTAssertTrue(seeded.usesDuration)
        XCTAssertNil(seeded.repMin, "a timed hold has no rep range")
    }

    func testNewAlternativeIsSeededFromCardioDefaults() {
        assertSeedMatchesAppDefaults(.cardio)
        let seeded = AlternativeDraftStore.defaultPayload(for: .cardio)
        XCTAssertTrue(seeded.usesDuration)
        XCTAssertEqual(
            seeded.sets, CardioRoutineRules.defaultSets(.cardio),
            "cardio is one bout")
        XCTAssertNil(seeded.rir, "cardio seeds no effort target")
        XCTAssertNil(seeded.rpe)
    }

    /// Seeding never carries prepared plans — there is no default warm-up,
    /// technique, distance or segment plan, and inventing one would be
    /// programming a session on the user's behalf.
    func testSeedCarriesNoPreparedPlans() {
        for mode in [TrackingMode.strength, .timedHold, .cardio] {
            let seeded = AlternativeDraftStore.defaultPayload(for: mode)
            XCTAssertTrue(seeded.warmupSteps.isEmpty)
            XCTAssertTrue(seeded.techniques.isEmpty)
            XCTAssertNil(seeded.cardioSegments)
            XCTAssertNil(seeded.targetDistanceMeters)
            XCTAssertNil(seeded.slotNotes)
        }
    }

    /// The seed is not the slot's plan: that is the whole premise of §6.3.
    func testSeedIgnoresTheSlotsOwnPrescription() {
        let p = prescription()
        p.sets = 9
        p.repMin = 3
        p.repMax = 4
        p.restSecondsBetweenSets = 240

        let seeded = AlternativeDraftStore.defaultPayload(for: .strength)

        XCTAssertNotEqual(seeded.sets, 9)
        XCTAssertNotEqual(seeded.repMin, 3)
        XCTAssertNotEqual(seeded.restSecondsBetweenSets, 240)
    }

    // MARK: - 3. The draft bridge

    func testDraftHydratesEveryPrescriptionField() throws {
        var payload = AlternativePrescriptionPayload(
            sets: 4, repMin: 6, repMax: 10,
            restSecondsBetweenSets: 120, restSecondsAfterExercise: 180,
            rir: 2, rpe: 8, tempo: "3-0-1-0",
            effortModeRaw: EffortMode.single.rawValue,
            targetDistanceMeters: 5_000, targetDistanceUnitRaw: "km",
            slotNotes: "seat height 4")
        payload.warmupSteps = [
            WarmupStepSnapshot(
                order: 0, kind: .percentage, reps: 10, percentOfWorking: 50,
                note: "bar only", restSecondsAfter: 60)
        ]
        payload.techniques = [
            TechniquePlanSnapshot(
                order: 0, type: .dropset, dropPercent: 20, dropCount: 2,
                rounds: nil, restSeconds: 15, partialRangeNote: nil,
                note: nil, reps: nil)
        ]
        payload.cardioSegments = try cardioPlan()

        let store = try draft(payload)

        XCTAssertEqual(store.prescription.sets, 4)
        XCTAssertEqual(store.prescription.repMin, 6)
        XCTAssertEqual(store.prescription.repMax, 10)
        XCTAssertEqual(store.prescription.restSecondsBetweenSets, 120)
        XCTAssertEqual(store.prescription.restSecondsAfterExercise, 180)
        XCTAssertEqual(store.prescription.rir, 2)
        XCTAssertEqual(store.prescription.tempo, "3-0-1-0")
        XCTAssertEqual(store.prescription.targetDistanceMeters, 5_000)
        XCTAssertEqual(store.prescription.warmupScheme?.steps.count, 1)
        XCTAssertEqual(store.prescription.techniquePlans.count, 1)
        XCTAssertEqual(
            store.prescription.structuredCardioPlan, payload.cardioSegments)
        XCTAssertEqual(store.slot.templateNotes, "seat height 4")
    }

    func testDraftRoundTripsAPayloadUnchanged() throws {
        var payload = AlternativePrescriptionPayload(
            sets: 3, repMin: 8, repMax: 12, restSecondsBetweenSets: 90,
            rir: 2, tempo: "3-0-1-0", slotNotes: "cue")
        payload.warmupSteps = [
            WarmupStepSnapshot(
                order: 0, kind: .fixedReps, reps: 5, restSecondsAfter: 45,
                weight: 40)
        ]
        payload.techniques = [
            TechniquePlanSnapshot(
                order: 0, type: .restPause, dropPercent: nil, dropCount: nil,
                rounds: 3, restSeconds: 20, partialRangeNote: nil, note: nil,
                reps: nil,
                // Explicit, because the draft materializes the model's
                // non-optional default — see the test below.
                appliesToRaw: "lastWorkingSet")
        ]
        payload.cardioSegments = try cardioPlan()

        let store = try draft(payload)

        XCTAssertEqual(store.payload(), payload)
    }

    /// A technique snapshot with no `appliesToRaw` means "last working set" —
    /// `TechniquePlanSnapshot.appliesTo` reads nil that way. The draft holds a
    /// `TechniquePlan`, whose `appliesToRaw` is non-optional, so the round trip
    /// writes the default back explicitly. Same value, stated rather than
    /// implied, and identical to what the session freeze already stores.
    func testNilAppliesToMaterializesAsTheExplicitDefault() throws {
        var payload = AlternativePrescriptionPayload(sets: 3)
        payload.techniques = [
            TechniquePlanSnapshot(
                order: 0, type: .amrap, dropPercent: nil, dropCount: nil,
                rounds: nil, restSeconds: nil, partialRangeNote: nil,
                note: nil, reps: nil)
        ]
        XCTAssertNil(payload.techniques[0].appliesToRaw)

        let readBack = try draft(payload).payload()

        XCTAssertEqual(readBack.techniques.first?.appliesToRaw, "lastWorkingSet")
        XCTAssertEqual(
            readBack.techniques.first?.appliesTo,
            payload.techniques[0].appliesTo,
            "the meaning is unchanged")
    }

    /// The draft is the editor's working copy, so an edit made through it is
    /// exactly what gets stored — this is tests 11 and 18–21 in one shape.
    func testEditsMadeOnTheDraftPersistToTheAlternative() throws {
        let p = prescription()
        let added = SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "Machine Chest Press",
            prescription: AlternativeDraftStore.defaultPayload(for: .strength),
            to: p)

        // What the detail editor does: hydrate, let the existing editors
        // mutate the scratch slot, read back, commit.
        let store = try draft(p.slotAlternatives[0].prescription)
        store.prescription.sets = 5
        store.prescription.repMin = 5
        store.prescription.repMax = 5
        store.prescription.restSecondsBetweenSets = 150
        store.prescription.rir = 1
        store.prescription.tempo = "4-0-1-0"
        store.prescription.targetDistanceMeters = 3_000
        store.prescription.targetDistanceUnitRaw = "km"
        store.prescription.setStructuredCardioPlan(try cardioPlan())
        store.slot.templateNotes = "elbows tucked"
        let scheme = WarmupScheme(name: "Warmup")
        store.context.insert(scheme)
        let step = WarmupStep(order: 0, kind: .percentage, reps: 8,
            percentOfWorking: 60)
        store.context.insert(step)
        scheme.steps = [step]
        store.prescription.warmupScheme = scheme
        let technique = TechniquePlan(
            order: 0, type: .dropset, restSeconds: 15, dropPercent: 20,
            dropCount: 2)
        store.context.insert(technique)
        store.prescription.techniquePlans = [technique]

        SlotAlternativeAuthoring.update(id: added.id, in: p) {
            $0.prescription = store.payload()
        }
        try context.save()

        let stored = try XCTUnwrap(p.slotAlternatives.first).prescription
        XCTAssertEqual(stored.sets, 5)
        XCTAssertEqual(stored.repMin, 5)
        XCTAssertEqual(stored.restSecondsBetweenSets, 150)
        XCTAssertEqual(stored.rir, 1)
        XCTAssertEqual(stored.tempo, "4-0-1-0")
        XCTAssertEqual(stored.targetDistanceMeters, 3_000)
        XCTAssertEqual(stored.slotNotes, "elbows tucked")
        XCTAssertEqual(stored.warmupSteps.count, 1)
        XCTAssertEqual(stored.warmupSteps.first?.reps, 8)
        XCTAssertEqual(stored.warmupSteps.first?.percentOfWorking, 60)
        XCTAssertEqual(stored.techniques.count, 1)
        XCTAssertEqual(stored.techniques.first?.type, .dropset)
        XCTAssertEqual(stored.techniques.first?.dropCount, 2)
        XCTAssertEqual(stored.cardioSegments?.segmentCount, 2)
    }

    /// A duration draft never writes tempo back, matching the capture rule the
    /// session snapshot already applies.
    func testDurationDraftDropsTempoOnReadBack() throws {
        let store = try draft(mode: .timedHold)
        store.prescription.usesDuration = true
        store.prescription.tempo = "3-0-1-0"

        XCTAssertNil(store.payload().tempo)
    }

    // MARK: - 4. The scratch slot cannot leak

    func testDraftInsertsNothingIntoTheAppStore() throws {
        let prescriptionsBefore = try count(SlotPrescription.self)
        let exercisesBefore = try count(Exercise.self)
        let slotsBefore = try count(RoutineExercise.self)
        let schemesBefore = try count(WarmupScheme.self)
        let stepsBefore = try count(WarmupStep.self)
        let techniquesBefore = try count(TechniquePlan.self)

        var payload = AlternativePrescriptionPayload(sets: 3)
        payload.warmupSteps = [
            WarmupStepSnapshot(order: 0, kind: .fixedReps, reps: 5),
            WarmupStepSnapshot(order: 1, kind: .noteOnly, note: "stretch"),
        ]
        payload.techniques = [
            TechniquePlanSnapshot(
                order: 0, type: .amrap, dropPercent: nil, dropCount: nil,
                rounds: nil, restSeconds: nil, partialRangeNote: nil,
                note: nil, reps: nil)
        ]
        let store = try draft(payload)
        // Edit it the way the pushed editors would.
        store.prescription.sets = 6
        let extra = WarmupStep(order: 2, kind: .fixedReps, reps: 3)
        store.context.insert(extra)
        store.prescription.warmupScheme?.steps.append(extra)
        try store.context.save()
        try context.save()

        XCTAssertEqual(try count(SlotPrescription.self), prescriptionsBefore)
        XCTAssertEqual(try count(Exercise.self), exercisesBefore)
        XCTAssertEqual(try count(RoutineExercise.self), slotsBefore)
        XCTAssertEqual(try count(WarmupScheme.self), schemesBefore)
        XCTAssertEqual(try count(WarmupStep.self), stepsBefore)
        XCTAssertEqual(try count(TechniquePlan.self), techniquesBefore)
    }

    /// Seeding builds a draft too, so the same guarantee has to hold for it.
    func testSeedingInsertsNothingIntoTheAppStore() throws {
        let before = try count(SlotPrescription.self)

        _ = AlternativeDraftStore.defaultPayload(for: .strength)
        _ = AlternativeDraftStore.defaultPayload(for: .cardio)

        XCTAssertEqual(try count(SlotPrescription.self), before)
    }

    /// The scratch exercise is a **copy**, never the library's row — the one
    /// rule that keeps the two stores separate.
    func testDraftDoesNotReferenceTheLibraryExercise() throws {
        let machine = exercise("Machine Chest Press")
        let store = try draft()

        XCTAssertNotEqual(store.exercise.id, machine.id)
        XCTAssertEqual(machine.routineUsages.count, 0)
    }

    // MARK: - 5. Metadata edits

    func testEditingTheNotePersists() throws {
        let p = prescription()
        let added = SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "DB Bench Press",
            prescription: AlternativePrescriptionPayload(), to: p)

        SlotAlternativeAuthoring.update(id: added.id, in: p) {
            $0.note = "when the rack is busy"
        }
        try context.save()

        XCTAssertEqual(p.slotAlternatives.first?.note, "when the rack is busy")
    }

    func testTogglingEnabledPersistsBothWays() throws {
        let p = prescription()
        let added = SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "DB Bench Press",
            prescription: AlternativePrescriptionPayload(), to: p)

        SlotAlternativeAuthoring.update(id: added.id, in: p) {
            $0.isEnabled = false
        }
        try context.save()
        XCTAssertEqual(p.slotAlternatives.first?.isEnabled, false)
        XCTAssertTrue(
            p.hasSlotAlternatives,
            "a disabled alternative is still stored and still listed")

        SlotAlternativeAuthoring.update(id: added.id, in: p) {
            $0.isEnabled = true
        }
        try context.save()
        XCTAssertEqual(p.slotAlternatives.first?.isEnabled, true)
    }

    /// An edit addressed to an id that is no longer there is a no-op: the row
    /// may have been deleted while a detail editor was open, and resurrecting
    /// it from a stale screen would undo the delete.
    func testUpdatingAMissingAlternativeIsANoOp() throws {
        let p = prescription()
        SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "kept",
            prescription: AlternativePrescriptionPayload(), to: p)

        SlotAlternativeAuthoring.update(id: UUID(), in: p) {
            $0.exerciseName = "ghost"
        }

        XCTAssertEqual(p.slotAlternatives.map(\.exerciseName), ["kept"])
    }

    // MARK: - 6. Delete and reorder

    func testDeletingAnAlternativePersists() throws {
        let p = prescription()
        for name in ["first", "second", "third"] {
            SlotAlternativeAuthoring.append(
                exerciseID: UUID(), exerciseName: name,
                prescription: AlternativePrescriptionPayload(), to: p)
        }

        SlotAlternativeAuthoring.delete(atOffsets: IndexSet(integer: 1), in: p)
        try context.save()

        XCTAssertEqual(
            p.slotAlternatives.map(\.exerciseName), ["first", "third"])
        XCTAssertEqual(
            p.slotAlternatives.map(\.order), [0, 1],
            "order is re-densified by the write path")
    }

    func testDeletingTheLastAlternativeClearsTheColumn() throws {
        let p = prescription()
        SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "only",
            prescription: AlternativePrescriptionPayload(), to: p)

        SlotAlternativeAuthoring.delete(atOffsets: IndexSet(integer: 0), in: p)
        try context.save()

        XCTAssertNil(p.alternativesData)
        XCTAssertEqual(p.slotAlternatives, [])
        XCTAssertFalse(p.hasSlotAlternatives)
    }

    func testReorderingPersistsAndNormalizesOrder() throws {
        let p = prescription()
        for name in ["first", "second", "third"] {
            SlotAlternativeAuthoring.append(
                exerciseID: UUID(), exerciseName: name,
                prescription: AlternativePrescriptionPayload(), to: p)
        }

        // Drag "third" to the top.
        SlotAlternativeAuthoring.move(
            fromOffsets: IndexSet(integer: 2), toOffset: 0, in: p)
        try context.save()

        XCTAssertEqual(
            p.slotAlternatives.map(\.exerciseName),
            ["third", "first", "second"])
        XCTAssertEqual(p.slotAlternatives.map(\.order), [0, 1, 2])
    }

    func testReorderSurvivesRefetch() throws {
        let p = prescription()
        for name in ["a", "b"] {
            SlotAlternativeAuthoring.append(
                exerciseID: UUID(), exerciseName: name,
                prescription: AlternativePrescriptionPayload(), to: p)
        }
        SlotAlternativeAuthoring.move(
            fromOffsets: IndexSet(integer: 1), toOffset: 0, in: p)
        try context.save()

        let refetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SlotPrescription>()).first)

        XCTAssertEqual(refetched.slotAlternatives.map(\.exerciseName), ["b", "a"])
    }

    // MARK: - 7. Isolation

    func testEditingAnAlternativeDoesNotTouchTheSlotsOwnPrescription() throws {
        let p = prescription()
        p.sets = 4
        p.repMin = 6
        p.repMax = 10
        p.restSecondsBetweenSets = 120
        p.tempo = "2-0-1-0"
        p.targetDistanceMeters = 5_000
        let slotPlan = try cardioPlan()
        p.setStructuredCardioPlan(slotPlan)

        let added = SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "Machine Chest Press",
            prescription: AlternativeDraftStore.defaultPayload(for: .strength),
            to: p)
        let store = try draft(p.slotAlternatives[0].prescription)
        store.prescription.sets = 12
        store.prescription.tempo = "5-0-5-0"
        store.prescription.targetDistanceMeters = 42_195
        SlotAlternativeAuthoring.update(id: added.id, in: p) {
            $0.prescription = store.payload()
        }
        try context.save()

        XCTAssertEqual(p.sets, 4)
        XCTAssertEqual(p.repMin, 6)
        XCTAssertEqual(p.repMax, 10)
        XCTAssertEqual(p.restSecondsBetweenSets, 120)
        XCTAssertEqual(p.tempo, "2-0-1-0")
        XCTAssertEqual(p.targetDistanceMeters, 5_000)
        XCTAssertEqual(p.structuredCardioPlan, slotPlan)
        XCTAssertEqual(p.slotAlternatives.first?.prescription.sets, 12)
    }

    func testEditingOneAlternativeDoesNotTouchAnother() throws {
        let p = prescription()
        let first = SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "first",
            prescription: AlternativePrescriptionPayload(sets: 3, repMin: 8, repMax: 12),
            to: p)
        SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "second",
            prescription: AlternativePrescriptionPayload(sets: 5, repMin: 5, repMax: 5),
            to: p)
        let untouched = try XCTUnwrap(p.slotAlternatives.last)

        SlotAlternativeAuthoring.update(id: first.id, in: p) {
            $0.prescription.sets = 10
            $0.note = "edited"
            $0.isEnabled = false
        }
        try context.save()

        XCTAssertEqual(p.slotAlternatives.last, untouched)
        XCTAssertEqual(p.slotAlternatives.first?.prescription.sets, 10)
        XCTAssertEqual(
            p.slotAlternatives.first?.id, first.id, "identity survives an edit")
        XCTAssertEqual(p.slotAlternatives.first?.order, 0)
    }

    // MARK: - 8. Slots with no alternatives are unchanged

    func testASlotWithNoAlternativesBehavesAsBefore() throws {
        let p = prescription()
        p.sets = 3
        p.repMin = 8
        p.repMax = 12
        try context.save()

        XCTAssertNil(p.alternativesData)
        XCTAssertEqual(p.slotAlternatives, [])
        XCTAssertFalse(p.hasSlotAlternatives)
        XCTAssertEqual(SlotAlternativeSummary.countLabel(0), "None")
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
    }

    /// Reordering or deleting on an empty list is harmless — the editor's
    /// `.onDelete` / `.onMove` are live before anything is added.
    func testDeleteAndMoveOnAnEmptyListAreSafe() throws {
        let p = prescription()

        SlotAlternativeAuthoring.delete(atOffsets: IndexSet(), in: p)
        SlotAlternativeAuthoring.move(
            fromOffsets: IndexSet(), toOffset: 0, in: p)

        XCTAssertNil(p.alternativesData)
        XCTAssertEqual(p.slotAlternatives, [])
    }
}

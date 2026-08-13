import SwiftData
import XCTest

@testable import Log

/// Alternative Exercises Phase H1 — duplicating a routine duplicates its
/// prepared alternatives.
///
/// The rule worth pinning is the one §12.1 states: **everything is copied, and
/// only the `id` is new.** An alternative's id identifies prepared work within
/// a slot, and the duplicate's slots already get fresh `slotID`s — but its
/// `exerciseID` points at a definition-level `Exercise`, which duplication
/// shares by design, exactly as the slot's own exercise reference is shared.
///
/// The precedent for getting this wrong is on the record: `8337219 fix(routines):
/// duplicate cardio target distance with the prescription` was a field-copy
/// miss in this same function, which is why this file checks every field rather
/// than a representative one.
@MainActor
final class SlotAlternativeDuplicationTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private let machineID = UUID()
    private let dumbbellID = UUID()

    private func cardioPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                CardioSegment(kind: .warmUp, durationSeconds: 300),
                CardioSegment(kind: .work, durationSeconds: 1_200),
            ])
        ])
    }

    /// An alternative carrying everything a slot can hold.
    private func richAlternative(
        order: Int = 0, enabled: Bool = true
    ) throws -> SlotAlternative {
        SlotAlternative(
            order: order,
            isEnabled: enabled,
            exerciseID: machineID,
            exerciseName: "Machine Chest Press",
            note: "when the rack is busy",
            prescription: AlternativePrescriptionPayload(
                sets: 3, repMin: 8, repMax: 12,
                restSecondsBetweenSets: 90, restSecondsAfterExercise: 120,
                rir: 2, rpe: 8, tempo: "3-0-1-0",
                effortModeRaw: EffortMode.single.rawValue,
                rirStart: 3, rirEnd: 1,
                durationMinSeconds: 30, durationMaxSeconds: 45,
                targetDistanceMeters: 5_000,
                targetDistanceUnitRaw: DistanceUnit.kilometers.rawValue,
                warmupSteps: [
                    WarmupStepSnapshot(
                        order: 0, kind: .percentage, reps: 10,
                        percentOfWorking: 50, note: "bar only",
                        restSecondsAfter: 60)
                ],
                techniques: [
                    TechniquePlanSnapshot(
                        order: 0, type: .dropset, dropPercent: 20,
                        dropCount: 2, rounds: nil, restSeconds: 15,
                        partialRangeNote: nil, note: nil, reps: nil)
                ],
                cardioSegments: try cardioPlan(),
                slotNotes: "seat height 4"))
    }

    private func simpleAlternative(
        _ name: String, order: Int, enabled: Bool = true
    ) -> SlotAlternative {
        SlotAlternative(
            order: order, isEnabled: enabled, exerciseID: dumbbellID,
            exerciseName: name,
            prescription: AlternativePrescriptionPayload(
                sets: 3, repMin: 8, repMax: 12))
    }

    /// A one-slot routine whose prescription carries the given alternatives.
    @discardableResult
    private func routine(
        _ name: String = "Upper A", with alternatives: [SlotAlternative]
    ) -> (Routine, SlotPrescription) {
        let ex = Exercise(name: "Barbell Bench Press")
        context.insert(ex)

        let p = SlotPrescription(sets: 4, repMin: 6, repMax: 10)
        context.insert(p)
        p.setSlotAlternatives(alternatives)

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        re.prescription = p
        context.insert(re)

        let block = RoutineBlock(order: 0, exercises: [re])
        context.insert(block)

        let r = Routine(name: name, blocks: [block])
        let variant = RoutineVariant(name: "Default", order: 0)
        context.insert(variant)
        r.variants.append(variant)
        context.insert(r)
        return (r, p)
    }

    private func duplicate(_ source: Routine) -> Routine {
        RoutineDuplicator.duplicate(source, among: [source], in: context)
    }

    /// The copy's one slot prescription.
    private func copiedPrescription(
        _ copy: Routine, file: StaticString = #filePath, line: UInt = #line
    ) throws -> SlotPrescription {
        try XCTUnwrap(
            copy.blocks.first?.exercises.first?.prescription,
            "duplicated slot prescription", file: file, line: line)
    }

    // MARK: - 1. The alternatives come across

    func testDuplicatingCopiesOneAlternative() throws {
        let authored = try richAlternative()
        let (source, _) = routine(with: [authored])

        let copied = try copiedPrescription(duplicate(source)).slotAlternatives

        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(copied.first?.exerciseName, "Machine Chest Press")
    }

    func testDuplicatingCopiesEveryAlternativeInOrder() throws {
        let (source, _) = routine(with: [
            try richAlternative(order: 0),
            simpleAlternative("DB Bench Press", order: 1),
            simpleAlternative("Push-Up", order: 2),
        ])

        let copied = try copiedPrescription(duplicate(source)).slotAlternatives

        XCTAssertEqual(
            copied.map(\.exerciseName),
            ["Machine Chest Press", "DB Bench Press", "Push-Up"])
        XCTAssertEqual(copied.map(\.order), [0, 1, 2])
    }

    func testDisabledAlternativesAreCopiedAsDisabled() throws {
        let (source, _) = routine(with: [
            simpleAlternative("on", order: 0),
            simpleAlternative("off", order: 1, enabled: false),
        ])

        let copied = try copiedPrescription(duplicate(source)).slotAlternatives

        XCTAssertEqual(copied.map(\.isEnabled), [true, false])
    }

    // MARK: - 2. Fresh ids, shared exercises

    func testDuplicatedAlternativesGetFreshIDs() throws {
        let authored = try richAlternative()
        let (source, original) = routine(with: [authored])

        let copied = try copiedPrescription(duplicate(source)).slotAlternatives

        XCTAssertNotEqual(
            copied.first?.id, authored.id,
            "two routines must not share authored alternative identity")
        XCTAssertEqual(
            original.slotAlternatives.first?.id, authored.id,
            "the original keeps its own id")
    }

    func testEveryDuplicatedIDIsDistinct() throws {
        let (source, original) = routine(with: [
            try richAlternative(order: 0),
            simpleAlternative("DB Bench Press", order: 1),
            simpleAlternative("Push-Up", order: 2),
        ])

        let copied = try copiedPrescription(duplicate(source)).slotAlternatives
        let originalIDs = Set(original.slotAlternatives.map(\.id))
        let copiedIDs = Set(copied.map(\.id))

        XCTAssertEqual(copiedIDs.count, 3)
        XCTAssertTrue(copiedIDs.isDisjoint(with: originalIDs))
    }

    /// The exercise reference is **shared**, exactly as the slot's own
    /// `Exercise` is: duplication copies programming, not the library.
    func testExerciseReferenceIsShared() throws {
        let authored = try richAlternative()
        let (source, _) = routine(with: [authored])

        let copied = try copiedPrescription(duplicate(source)).slotAlternatives

        XCTAssertEqual(copied.first?.exerciseID, machineID)
    }

    /// The pure helper, with a pinned generator — the id is the only field it
    /// touches.
    func testDuplicatedHelperChangesOnlyTheID() throws {
        let authored = try richAlternative()
        let fresh = UUID()

        let copy = try XCTUnwrap(
            SlotAlternatives.duplicated([authored], idGenerator: { fresh })
                .first)

        XCTAssertEqual(copy.id, fresh)
        XCTAssertEqual(copy.order, authored.order)
        XCTAssertEqual(copy.isEnabled, authored.isEnabled)
        XCTAssertEqual(copy.exerciseID, authored.exerciseID)
        XCTAssertEqual(copy.exerciseName, authored.exerciseName)
        XCTAssertEqual(copy.note, authored.note)
        XCTAssertEqual(copy.prescription, authored.prescription)
    }

    // MARK: - 3. Every field survives

    func testTheWholePrescriptionSurvivesDuplication() throws {
        let authored = try richAlternative()
        let (source, _) = routine(with: [authored])

        let copied = try XCTUnwrap(
            try copiedPrescription(duplicate(source)).slotAlternatives.first)

        XCTAssertEqual(copied.note, "when the rack is busy")

        let p = copied.prescription
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(p.restSecondsBetweenSets, 90)
        XCTAssertEqual(p.restSecondsAfterExercise, 120)
        XCTAssertEqual(p.rir, 2)
        XCTAssertEqual(p.rpe, 8)
        XCTAssertEqual(p.tempo, "3-0-1-0")
        XCTAssertEqual(p.effortModeRaw, EffortMode.single.rawValue)
        XCTAssertEqual(p.rirStart, 3)
        XCTAssertEqual(p.rirEnd, 1)
        XCTAssertEqual(p.durationMinSeconds, 30)
        XCTAssertEqual(p.durationMaxSeconds, 45)
        XCTAssertEqual(p.targetDistanceMeters, 5_000)
        XCTAssertEqual(p.targetDistanceUnitRaw, "km")
        XCTAssertEqual(p.slotNotes, "seat height 4")
        // The whole payload compares equal — a new field added to
        // `AlternativePrescriptionPayload` without a copy path fails here.
        XCTAssertEqual(p, authored.prescription)
    }

    func testWarmupAndTechniqueSnapshotsSurvive() throws {
        let authored = try richAlternative()
        let (source, _) = routine(with: [authored])

        let p = try XCTUnwrap(
            try copiedPrescription(duplicate(source)).slotAlternatives.first
        ).prescription

        XCTAssertEqual(p.warmupSteps.count, 1)
        XCTAssertEqual(p.warmupSteps.first?.kind, .percentage)
        XCTAssertEqual(p.warmupSteps.first?.percentOfWorking, 50)
        XCTAssertEqual(p.warmupSteps.first?.note, "bar only")
        XCTAssertEqual(p.techniques.count, 1)
        XCTAssertEqual(p.techniques.first?.type, .dropset)
        XCTAssertEqual(p.techniques.first?.dropCount, 2)
    }

    /// Segment ids are **shared**, matching the slot's own plan: the duplicator
    /// copies `cardioSegmentsData` as raw bytes, so its segments keep their ids
    /// too. One rule for segment identity, not two.
    func testCardioPlanSurvivesWithItsSegmentIDs() throws {
        let authored = try richAlternative()
        let (source, _) = routine(with: [authored])

        let copy = duplicate(source)
        let copied = try XCTUnwrap(
            try copiedPrescription(copy).slotAlternatives.first
        ).prescription.cardioSegments

        XCTAssertEqual(copied, authored.prescription.cardioSegments)
        XCTAssertEqual(copied?.segmentCount, 2)
        XCTAssertEqual(copied?.totalDurationSeconds, 1_500)
    }

    // MARK: - 4. Degenerate inputs

    func testASlotWithNoAlternativesDuplicatesWithNone() throws {
        let (source, _) = routine(with: [])

        let copied = try copiedPrescription(duplicate(source))

        XCTAssertNil(
            copied.alternativesData,
            "no alternatives stays a nil column, never an empty payload")
        XCTAssertEqual(copied.slotAlternatives, [])
        XCTAssertFalse(copied.hasSlotAlternatives)
    }

    func testCorruptAlternativesDataDuplicatesAsNone() throws {
        let (source, original) = routine(with: [try richAlternative()])
        original.alternativesData = Data([0x00, 0x01, 0x02, 0xFF])

        let copied = try copiedPrescription(duplicate(source))

        XCTAssertNil(copied.alternativesData)
        XCTAssertEqual(copied.slotAlternatives, [])
    }

    /// A slot without a prescription at all still duplicates.
    func testASlotWithNoPrescriptionDuplicatesCleanly() throws {
        let ex = Exercise(name: "Barbell Bench Press")
        context.insert(ex)
        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        let block = RoutineBlock(order: 0, exercises: [re])
        context.insert(block)
        let source = Routine(name: "No prescription", blocks: [block])
        context.insert(source)

        let copy = duplicate(source)

        XCTAssertNil(copy.blocks.first?.exercises.first?.prescription)
    }

    // MARK: - 5. The original is untouched, and the two are independent

    func testDuplicatingDoesNotMutateTheOriginal() throws {
        let authored = try richAlternative()
        let (source, original) = routine(with: [authored])
        let before = original.alternativesData

        _ = duplicate(source)

        XCTAssertEqual(original.alternativesData, before, "byte-for-byte")
        XCTAssertEqual(original.slotAlternatives, [authored])
        XCTAssertEqual(original.sets, 4, "nor the slot's own prescription")
        XCTAssertEqual(original.repMin, 6)
        XCTAssertEqual(original.repMax, 10)
    }

    func testEditingTheDuplicatesAlternativesLeavesTheOriginalAlone() throws {
        let authored = try richAlternative()
        let (source, original) = routine(with: [authored])
        let copy = duplicate(source)
        let copiedPrescription = try copiedPrescription(copy)

        let copiedID = try XCTUnwrap(
            copiedPrescription.slotAlternatives.first?.id)
        SlotAlternativeAuthoring.update(id: copiedID, in: copiedPrescription) {
            $0.exerciseName = "Edited on the copy"
            $0.isEnabled = false
            $0.prescription.sets = 99
        }
        SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "Added on the copy",
            prescription: AlternativePrescriptionPayload(),
            to: copiedPrescription)
        try context.save()

        XCTAssertEqual(original.slotAlternatives, [authored])
        XCTAssertEqual(copiedPrescription.slotAlternatives.count, 2)
    }

    func testEditingTheOriginalsAlternativesLeavesTheDuplicateAlone() throws {
        let authored = try richAlternative()
        let (source, original) = routine(with: [authored])
        let copy = duplicate(source)
        let copiedBefore = try copiedPrescription(copy).slotAlternatives

        original.clearSlotAlternatives()
        try context.save()

        XCTAssertEqual(try copiedPrescription(copy).slotAlternatives, copiedBefore)
        XCTAssertEqual(original.slotAlternatives, [])
    }
}

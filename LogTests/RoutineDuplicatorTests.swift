import SwiftData
import XCTest

@testable import Log

/// Pure tests for `RoutineDuplicator.copiedName(for:existingNames:)` — the
/// copied-routine-name generator (Slice A). Value-in / value-out, no SwiftData
/// model or `ModelContext` needed, mirroring `RoutineNameValidatorTests`.
final class RoutineDuplicatorTests: XCTestCase {

    func testNoCollisionUsesBaseCopyName() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A", existingNames: ["Lower A"]
            ),
            "Upper A copy"
        )
    }

    func testFirstCopyCollisionAppendsTwo() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A", existingNames: ["Upper A", "Upper A copy"]
            ),
            "Upper A copy 2"
        )
    }

    func testMultipleCollisionsIncrementSuffix() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A",
                existingNames: ["Upper A copy", "Upper A copy 2"]
            ),
            "Upper A copy 3"
        )
    }

    func testCaseInsensitiveCollision() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A", existingNames: ["upper a copy"]
            ),
            "Upper A copy 2"
        )
    }

    func testOriginalNameTrimmed() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "  Upper A  ", existingNames: []
            ),
            "Upper A copy"
        )
    }

    func testExistingNamesTrimmedForCollision() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A", existingNames: [" Upper A copy "]
            ),
            "Upper A copy 2"
        )
    }

    func testEmptyOriginalFallsBackToRoutine() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(for: "", existingNames: []),
            "Routine copy"
        )
    }

    func testWhitespaceOnlyOriginalFallsBackToRoutine() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(for: "   ", existingNames: []),
            "Routine copy"
        )
        // And the fallback still de-dupes against existing "Routine copy".
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: " ", existingNames: ["Routine copy"]
            ),
            "Routine copy 2"
        )
    }
}

/// Deep-copy tests for `RoutineDuplicator.duplicate(_:among:in:)` (Slice B).
/// Uses `SwiftDataTestHarness` because the routine graph is SwiftData `@Model`s;
/// the service itself only reads the source and writes new instances.
@MainActor
final class RoutineDuplicatorServiceTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    @discardableResult
    private func makeExercise(_ name: String) -> Exercise {
        let e = Exercise(name: name, isCustom: true)
        context.insert(e)
        return e
    }

    @discardableResult
    private func makeRoutine(_ name: String, order: Int = 0) -> Routine {
        let r = Routine(name: name, blocks: [])
        r.order = order
        // Every routine has a Default variant in the real app (bootstrap).
        let v = RoutineVariant(name: "Default", order: 0)
        context.insert(v)
        r.variants.append(v)
        context.insert(r)
        return r
    }

    /// Appends a single-exercise (optionally superset) block with one slot +
    /// prescription. Returns the created slot for further customization.
    @discardableResult
    private func addSlot(
        to routine: Routine,
        exercise: Exercise?,
        order: Int,
        isSuperset: Bool = false,
        withPrescription: Bool = true
    ) -> RoutineExercise {
        let re: RoutineExercise
        if let exercise {
            re = RoutineExercise(exercise: exercise, order: order, setTemplates: [])
        } else {
            re = RoutineExercise(exercise: Exercise(name: ""), order: order, setTemplates: [])
            re.exercise = nil
        }
        context.insert(re)
        if withPrescription {
            let p = SlotPrescription(sets: 3, repMin: 8, repMax: 12, restSecondsBetweenSets: 90)
            context.insert(p)
            re.prescription = p
        }
        let block = RoutineBlock(
            isSuperset: isSuperset, order: order, exercises: [re]
        )
        context.insert(block)
        routine.blocks.append(block)
        return re
    }

    // MARK: - 1. Empty routine

    func testDuplicateEmptyRoutine() {
        let src = makeRoutine("Upper A", order: 0)
        let other = makeRoutine("Lower A", order: 1)

        let copy = RoutineDuplicator.duplicate(
            src, among: [src, other], in: context
        )

        XCTAssertNotEqual(copy.id, src.id)
        XCTAssertEqual(copy.name, "Upper A copy")
        XCTAssertEqual(copy.order, 2)              // trailing
        XCTAssertEqual(copy.blocks.count, 0)
        XCTAssertEqual(copy.variants.count, 1)
        XCTAssertEqual(copy.variants.first?.name, "Default")
        XCTAssertNotEqual(copy.variants.first?.id, src.variants.first?.id)
    }

    // MARK: - 2/3/4. Structure, identities, shared exercise

    func testStructureIdentitiesAndSharedExercise() {
        let src = makeRoutine("Push", order: 0)
        let bench = makeExercise("Bench")
        let fly = makeExercise("Fly")
        addSlot(to: src, exercise: bench, order: 0)
        addSlot(to: src, exercise: fly, order: 1)

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)

        // Structural equality
        XCTAssertEqual(copy.blocks.count, src.blocks.count)
        let srcBlocks = src.blocks.sorted { $0.order < $1.order }
        let copyBlocks = copy.blocks.sorted { $0.order < $1.order }
        XCTAssertEqual(copyBlocks.map(\.order), srcBlocks.map(\.order))
        XCTAssertEqual(copyBlocks.map(\.isSuperset), srcBlocks.map(\.isSuperset))
        XCTAssertEqual(
            copyBlocks.map { $0.exercises.count },
            srcBlocks.map { $0.exercises.count }
        )

        // Fresh identities
        XCTAssertNotEqual(copy.id, src.id)
        let srcBlockIDs = Set(srcBlocks.map(\.slotID))
        let copyBlockIDs = Set(copyBlocks.map(\.slotID))
        XCTAssertTrue(srcBlockIDs.isDisjoint(with: copyBlockIDs))

        let srcSlotIDs = Set(srcBlocks.flatMap { $0.exercises.map(\.slotID) })
        let copySlotIDs = Set(copyBlocks.flatMap { $0.exercises.map(\.slotID) })
        XCTAssertTrue(srcSlotIDs.isDisjoint(with: copySlotIDs))

        // Shared exercise references (not cloned)
        for (s, c) in zip(srcBlocks, copyBlocks) {
            for (sre, cre) in zip(
                s.exercises.sorted { $0.order < $1.order },
                c.exercises.sorted { $0.order < $1.order }
            ) {
                XCTAssertEqual(cre.exercise?.id, sre.exercise?.id)
                XCTAssertTrue(cre.exercise === sre.exercise)
            }
        }
    }

    // MARK: - 5. Prescription deep copy + isolation

    func testPrescriptionDeepCopyIsIsolated() {
        let src = makeRoutine("R", order: 0)
        let ex = makeExercise("Bench")
        let srcSlot = addSlot(to: src, exercise: ex, order: 0)
        srcSlot.prescription?.sets = 4
        srcSlot.prescription?.repMin = 6
        srcSlot.prescription?.repMax = 10

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copySlot = copy.blocks.first!.exercises.first!

        XCTAssertEqual(copySlot.prescription?.sets, 4)
        XCTAssertEqual(copySlot.prescription?.repMin, 6)
        XCTAssertEqual(copySlot.prescription?.repMax, 10)
        XCTAssertFalse(copySlot.prescription === srcSlot.prescription)

        // Mutating the copy does not change the source.
        copySlot.prescription?.sets = 99
        XCTAssertEqual(srcSlot.prescription?.sets, 4)
    }

    // MARK: - 5b. Effort target mode fields deep-copied (Slice B)

    func testEffortModeFieldsDeepCopied() {
        let src = makeRoutine("R", order: 0)
        let ex = makeExercise("Bench")
        let srcSlot = addSlot(to: src, exercise: ex, order: 0)
        srcSlot.prescription?.effortModeRaw = "progression"
        srcSlot.prescription?.rirStart = 2
        srcSlot.prescription?.rirEnd = 0
        srcSlot.prescription?.rpeStart = 8
        srcSlot.prescription?.rpeEnd = 10

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copyP = copy.blocks.first!.exercises.first!.prescription

        XCTAssertEqual(copyP?.effortModeRaw, "progression")
        XCTAssertEqual(copyP?.effortMode, .progression)
        XCTAssertEqual(copyP?.rirStart, 2)
        XCTAssertEqual(copyP?.rirEnd, 0)
        XCTAssertEqual(copyP?.rpeStart, 8)
        XCTAssertEqual(copyP?.rpeEnd, 10)

        // Isolation: mutating the copy does not touch the source.
        copyP?.rirEnd = 1
        XCTAssertEqual(srcSlot.prescription?.rirEnd, 0)
    }

    // MARK: - 5c. Legacy prescription (nil effortModeRaw) copies + derives .single

    func testLegacyEffortFieldsCopyAndDeriveSingle() {
        let src = makeRoutine("R", order: 0)
        let ex = makeExercise("Bench")
        let srcSlot = addSlot(to: src, exercise: ex, order: 0)
        srcSlot.prescription?.rir = 2          // legacy single value, nil mode raw

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copyP = copy.blocks.first!.exercises.first!.prescription

        XCTAssertNil(copyP?.effortModeRaw)
        XCTAssertEqual(copyP?.rir, 2)
        XCTAssertEqual(copyP?.effortMode, .single)
    }

    // MARK: - 6. Technique plan deep copy

    func testTechniquePlanDeepCopy() {
        let src = makeRoutine("R", order: 0)
        let ex = makeExercise("Bench")
        let srcSlot = addSlot(to: src, exercise: ex, order: 0)
        let plan = TechniquePlan(
            order: 0, type: .dropset, dropPercent: 20, dropCount: 2
        )
        plan.appliesToSetIndicesRaw = "0,2"
        plan.dropsetEffortRaw = "fixedReps"
        plan.dropsetEffortReps = 8
        plan.partialRangeRaw = "stickingPoint"
        plan.partialRangeNote = "low third"
        context.insert(plan)
        srcSlot.prescription?.techniquePlans = [plan]

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copyPlan = copy.blocks.first!.exercises.first!
            .prescription!.techniquePlans.first!

        XCTAssertEqual(
            copy.blocks.first!.exercises.first!.prescription!.techniquePlans.count,
            1
        )
        XCTAssertEqual(copyPlan.typeRaw, "dropset")
        XCTAssertEqual(copyPlan.dropPercent, 20)
        XCTAssertEqual(copyPlan.dropCount, 2)
        XCTAssertEqual(copyPlan.appliesToSetIndicesRaw, "0,2")
        XCTAssertEqual(copyPlan.dropsetEffortRaw, "fixedReps")
        XCTAssertEqual(copyPlan.dropsetEffortReps, 8)
        XCTAssertEqual(copyPlan.partialRangeRaw, "stickingPoint")
        XCTAssertEqual(copyPlan.partialRangeNote, "low third")
        XCTAssertFalse(copyPlan === plan)
    }

    // MARK: - 7. Warmup scheme deep copy + isolation

    func testWarmupSchemeDeepCopyIsIsolated() {
        let src = makeRoutine("R", order: 0)
        let ex = makeExercise("Bench")
        let srcSlot = addSlot(to: src, exercise: ex, order: 0)
        let scheme = WarmupScheme(name: "Warmup")
        context.insert(scheme)
        let step = WarmupStep(order: 0, kind: .percentage, percentOfWorking: 0.5)
        context.insert(step)
        scheme.steps = [step]
        srcSlot.prescription?.warmupScheme = scheme

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copyScheme = copy.blocks.first!.exercises.first!
            .prescription!.warmupScheme!

        XCTAssertEqual(copyScheme.name, "Warmup")
        XCTAssertEqual(copyScheme.steps.count, 1)
        XCTAssertFalse(copyScheme === scheme)
        XCTAssertFalse(copyScheme.steps.first === step)

        // Mutating the copy's step does not change the source step.
        copyScheme.steps.first?.percentOfWorking = 0.9
        XCTAssertEqual(step.percentOfWorking, 0.5)
    }

    // MARK: - 8. SetTemplate deep copy + isolation

    func testSetTemplateDeepCopyIsIsolated() {
        let src = makeRoutine("R", order: 0)
        let ex = makeExercise("Bench")
        let srcSlot = addSlot(to: src, exercise: ex, order: 0, withPrescription: false)
        let tpl = SetTemplate(kind: .working, targetReps: 8, targetWeight: 60, restSecondsAfter: 90)
        tpl.order = 0
        tpl.durationSeconds = nil
        context.insert(tpl)
        srcSlot.setTemplates = [tpl]

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copyTpl = copy.blocks.first!.exercises.first!.setTemplates.first!

        XCTAssertEqual(copyTpl.targetReps, 8)
        XCTAssertEqual(copyTpl.targetWeight, 60)
        XCTAssertEqual(copyTpl.restSecondsAfter, 90)
        XCTAssertEqual(copyTpl.kindRaw, "working")
        XCTAssertFalse(copyTpl === tpl)

        copyTpl.targetReps = 99
        XCTAssertEqual(tpl.targetReps, 8)
    }

    // MARK: - 9. Superset copy

    func testSupersetBlockCopied() {
        let src = makeRoutine("R", order: 0)
        let a = makeExercise("A")
        let b = makeExercise("B")
        let re1 = RoutineExercise(exercise: a, order: 0, setTemplates: [])
        let re2 = RoutineExercise(exercise: b, order: 1, setTemplates: [])
        context.insert(re1)
        context.insert(re2)
        for re in [re1, re2] {
            let p = SlotPrescription(sets: 3)
            context.insert(p)
            re.prescription = p
        }
        let block = RoutineBlock(isSuperset: true, order: 0, exercises: [re1, re2])
        block.supersetRoundRestSeconds = 60
        context.insert(block)
        src.blocks.append(block)

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copyBlock = copy.blocks.first!

        XCTAssertTrue(copyBlock.isSuperset)
        XCTAssertEqual(copyBlock.supersetRoundRestSeconds, 60)
        XCTAssertEqual(copyBlock.exercises.count, 2)
        XCTAssertNotEqual(copyBlock.slotID, block.slotID)
        let copySlotIDs = Set(copyBlock.exercises.map(\.slotID))
        let srcSlotIDs = Set(block.exercises.map(\.slotID))
        XCTAssertTrue(copySlotIDs.isDisjoint(with: srcSlotIDs))
    }

    // MARK: - 10. nil edge cases

    func testNilExerciseAndNilPrescriptionCopyWithoutCrash() {
        let src = makeRoutine("R", order: 0)
        // nil exercise slot
        addSlot(to: src, exercise: nil, order: 0, withPrescription: true)
        // nil prescription slot
        let ex = makeExercise("Bench")
        addSlot(to: src, exercise: ex, order: 1, withPrescription: false)

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let blocks = copy.blocks.sorted { $0.order < $1.order }

        XCTAssertEqual(blocks.count, 2)
        XCTAssertNil(blocks[0].exercises.first?.exercise)         // stays nil
        XCTAssertNotNil(blocks[0].exercises.first?.prescription)  // prescription copied
        XCTAssertNotNil(blocks[1].exercises.first?.exercise)
        XCTAssertNil(blocks[1].exercises.first?.prescription)     // stays nil
    }

    // MARK: - 11. Name collision

    func testNameCollisionProducesCopy2() {
        let src = makeRoutine("Upper A", order: 0)
        let existing = makeRoutine("Upper A copy", order: 1)

        let copy = RoutineDuplicator.duplicate(
            src, among: [src, existing], in: context
        )
        XCTAssertEqual(copy.name, "Upper A copy 2")
    }

    // MARK: - 12. Source unchanged

    func testSourceRoutineUnchanged() {
        let src = makeRoutine("R", order: 0)
        let ex = makeExercise("Bench")
        let srcSlot = addSlot(to: src, exercise: ex, order: 0)
        let srcBlockCount = src.blocks.count
        let srcSlotID = srcSlot.slotID
        let srcSets = srcSlot.prescription?.sets
        let srcVariantID = src.variants.first?.id

        _ = RoutineDuplicator.duplicate(src, among: [src], in: context)

        XCTAssertEqual(src.name, "R")
        XCTAssertEqual(src.blocks.count, srcBlockCount)
        XCTAssertEqual(srcSlot.slotID, srcSlotID)
        XCTAssertEqual(srcSlot.prescription?.sets, srcSets)
        XCTAssertEqual(src.variants.count, 1)
        XCTAssertEqual(src.variants.first?.id, srcVariantID)
        XCTAssertEqual(srcSlot.exercise?.id, ex.id)
    }

    // MARK: - 13. Save / refetch

    func testDuplicateSavesAndRefetches() throws {
        let src = makeRoutine("Upper A", order: 0)
        let ex = makeExercise("Bench")
        addSlot(to: src, exercise: ex, order: 0)

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copyID = copy.id
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<Routine>(
                predicate: #Predicate { $0.id == copyID }
            )
        )
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.blocks.count, 1)

        // Both source and duplicate remain valid.
        let all = try context.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - 11. copyBlock primitive (Slice 1 — direct pin)

    /// Pins the extracted `copyBlock` primitive directly: a fresh block + slot
    /// `slotID`, carried block fields (incl. superset round rest), shared
    /// `Exercise`, deep-copied + isolated prescription, and an unmutated source.
    func testCopyBlockPrimitive() {
        let src = makeRoutine("Push", order: 0)
        let bench = makeExercise("Bench")
        let slot = addSlot(
            to: src, exercise: bench, order: 0, isSuperset: true
        )
        let srcBlock = src.blocks[0]
        srcBlock.restAfterSeconds = 45
        srcBlock.supersetRoundRestSeconds = 120
        slot.prescription?.sets = 4

        let copy = RoutineDuplicator.copyBlock(srcBlock, in: context)

        // Fresh identities.
        XCTAssertNotEqual(copy.slotID, srcBlock.slotID)
        XCTAssertEqual(copy.exercises.count, 1)
        let copiedSlot = copy.exercises[0]
        XCTAssertNotEqual(copiedSlot.slotID, slot.slotID)

        // Carried block fields.
        XCTAssertEqual(copy.isSuperset, true)
        XCTAssertEqual(copy.order, srcBlock.order)
        XCTAssertEqual(copy.restAfterSeconds, 45)
        XCTAssertEqual(copy.supersetRoundRestSeconds, 120)

        // Shared definition-level Exercise; deep-copied prescription.
        XCTAssertEqual(copiedSlot.exercise?.id, bench.id)
        XCTAssertNotNil(copiedSlot.prescription)
        XCTAssertNotEqual(
            copiedSlot.prescription?.persistentModelID,
            slot.prescription?.persistentModelID
        )
        XCTAssertEqual(copiedSlot.prescription?.sets, 4)

        // Mutating the copy's prescription does not touch the source.
        copiedSlot.prescription?.sets = 9
        XCTAssertEqual(slot.prescription?.sets, 4)

        // Source block is not appended anywhere by copyBlock and is unmutated.
        XCTAssertEqual(src.blocks.count, 1)
        XCTAssertTrue(src.blocks[0] === srcBlock)
    }
}

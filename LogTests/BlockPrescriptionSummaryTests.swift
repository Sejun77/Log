import SwiftData
import XCTest

@testable import Log

/// Pure tests for the `BlockPrescriptionSummary` namespace (RoutineEditor block
/// row subtitle helper). Wording is pinned via the value-in initializers; the
/// model-driven cases insert `RoutineBlock` / `RoutineExercise` /
/// `SlotPrescription` fixtures into the harness's in-memory store, but the
/// helper itself never touches the context and never dereferences
/// `RoutineExercise.exercise`.
@MainActor
final class BlockPrescriptionSummaryTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    /// One `RoutineExercise` slot with an attached `SlotPrescription`
    /// (or nil prescription when `hasPrescription == false`). Pass
    /// `attachExercise: false` to simulate a deleted/unlinked exercise.
    @discardableResult
    private func makeSlot(
        sets: Int?,
        repMin: Int? = nil,
        repMax: Int? = nil,
        usesDuration: Bool = false,
        durationMax: Int? = nil,
        rest: Int? = nil,
        order: Int = 0,
        hasPrescription: Bool = true,
        attachExercise: Bool = true,
        rir: Double? = nil,
        rpe: Double? = nil,
        effortModeRaw: String? = nil,
        rirStart: Double? = nil,
        rirEnd: Double? = nil,
        rpeStart: Double? = nil,
        rpeEnd: Double? = nil
    ) -> RoutineExercise {
        let ex = Exercise(name: "Lift \(order)", isCustom: true)
        context.insert(ex)
        let re = RoutineExercise(exercise: ex, order: order, setTemplates: [])
        if !attachExercise { re.exercise = nil }
        if hasPrescription {
            let p = SlotPrescription(
                sets: sets,
                repMin: repMin,
                repMax: repMax,
                restSecondsBetweenSets: rest,
                rir: rir,
                rpe: rpe,
                effortModeRaw: effortModeRaw,
                rirStart: rirStart,
                rirEnd: rirEnd,
                rpeStart: rpeStart,
                rpeEnd: rpeEnd,
                durationMaxSeconds: durationMax,
                usesDuration: usesDuration
            )
            context.insert(p)
            re.prescription = p
        }
        context.insert(re)
        return re
    }

    @discardableResult
    private func makeBlock(
        isSuperset: Bool,
        slots: [RoutineExercise]
    ) -> RoutineBlock {
        let b = RoutineBlock(isSuperset: isSuperset, order: 0, exercises: slots)
        context.insert(b)
        return b
    }

    // MARK: - Normal block wording (value-in)

    func testSetsWithRepRange() {
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 3, repMin: 8, repMax: 12).subtitle,
            "3 × 8–12"
        )
    }

    func testSetsWithRepRangeAndRest() {
        XCTAssertEqual(
            BlockPrescriptionSummary(
                sets: 3, repMin: 8, repMax: 12, restSeconds: 90
            ).subtitle,
            "3 × 8–12 · 90s rest"
        )
    }

    func testEqualRepBoundsCollapseToSingle() {
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 3, repMin: 8, repMax: 8).subtitle,
            "3 × 8"
        )
    }

    func testSingleRepBound() {
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 3, repMin: 8, repMax: nil).subtitle,
            "3 × 8"
        )
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 3, repMin: nil, repMax: 8).subtitle,
            "3 × 8"
        )
    }

    func testSetsWithNoReps() {
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 3, repMin: nil, repMax: nil).subtitle,
            "3 sets"
        )
    }

    func testTimeBasedWithDuration() {
        XCTAssertEqual(
            BlockPrescriptionSummary(
                sets: 3, durationSeconds: 45, usesDuration: true
            ).subtitle,
            "3 × 45s"
        )
    }

    func testTimeBasedWithNoDuration() {
        XCTAssertEqual(
            BlockPrescriptionSummary(
                sets: 3, durationSeconds: nil, usesDuration: true
            ).subtitle,
            "3 sets"
        )
    }

    func testNoUsableSetsIsNotSet() {
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: nil, repMin: 8, repMax: 12).subtitle,
            "Not set"
        )
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 0).subtitle,
            "Not set"
        )
    }

    func testRestNilOrZeroOmitsRestClause() {
        XCTAssertEqual(
            BlockPrescriptionSummary(
                sets: 3, repMin: 8, repMax: 12, restSeconds: 0
            ).subtitle,
            "3 × 8–12"
        )
        XCTAssertEqual(
            BlockPrescriptionSummary(
                sets: 3, repMin: 8, repMax: 12, restSeconds: nil
            ).subtitle,
            "3 × 8–12"
        )
    }

    // MARK: - Normal block (model)

    func testNormalBlockFromModelUsesLowestOrderSlot() {
        // A non-superset block carries one slot; assert the model path reads
        // its prescription.
        let slot = makeSlot(sets: 4, repMin: 5, repMax: 5, rest: 120)
        let block = makeBlock(isSuperset: false, slots: [slot])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "4 × 5 · 120s rest"
        )
    }

    func testNormalBlockNilPrescriptionIsNotSet() {
        let slot = makeSlot(sets: nil, hasPrescription: false)
        let block = makeBlock(isSuperset: false, slots: [slot])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "Not set"
        )
    }

    // MARK: - Superset wording (value-in)

    func testSupersetUniformSets() {
        XCTAssertEqual(
            BlockPrescriptionSummary(supersetExerciseCount: 3, maxSets: 3)
                .subtitle,
            "Superset · 3 exercises · 3 sets"
        )
    }

    func testSupersetSingularWording() {
        XCTAssertEqual(
            BlockPrescriptionSummary(supersetExerciseCount: 1, maxSets: 1)
                .subtitle,
            "Superset · 1 exercise · 1 set"
        )
    }

    func testSupersetNoChildSetsOmitsSetClause() {
        XCTAssertEqual(
            BlockPrescriptionSummary(supersetExerciseCount: 3, maxSets: nil)
                .subtitle,
            "Superset · 3 exercises"
        )
    }

    // MARK: - Superset (model)

    func testSupersetFromModelUniform() {
        let slots = [
            makeSlot(sets: 3, order: 0),
            makeSlot(sets: 3, order: 1),
            makeSlot(sets: 3, order: 2),
        ]
        let block = makeBlock(isSuperset: true, slots: slots)
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "Superset · 3 exercises · 3 sets"
        )
    }

    func testSupersetMixedSetsUsesMax() {
        let slots = [
            makeSlot(sets: 2, order: 0),
            makeSlot(sets: 3, order: 1),
            makeSlot(sets: 2, order: 2),
        ]
        let block = makeBlock(isSuperset: true, slots: slots)
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "Superset · 3 exercises · 3 sets"
        )
    }

    func testSupersetAllNilSetsOmitsSetClause() {
        let slots = [
            makeSlot(sets: nil, order: 0, hasPrescription: false),
            makeSlot(sets: nil, order: 1, hasPrescription: false),
            makeSlot(sets: nil, order: 2, hasPrescription: false),
        ]
        let block = makeBlock(isSuperset: true, slots: slots)
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "Superset · 3 exercises"
        )
    }

    func testSupersetNilExerciseSlotStillCounts() {
        let slots = [
            makeSlot(sets: 3, order: 0),
            makeSlot(sets: 3, order: 1, attachExercise: false),
            makeSlot(sets: 3, order: 2),
        ]
        let block = makeBlock(isSuperset: true, slots: slots)
        // The detached slot still counts structurally and does not crash.
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "Superset · 3 exercises · 3 sets"
        )
    }

    // MARK: - Effort target summary (Slice C)

    func testValueInEffortSuffixAppended() {
        XCTAssertEqual(
            BlockPrescriptionSummary(
                sets: 3, repMin: 8, repMax: 12, restSeconds: 90,
                effort: "RIR 2 → 0"
            ).subtitle,
            "3 × 8–12 · 90s rest · RIR 2 → 0"
        )
    }

    func testValueInEffortWithoutRest() {
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 3, repMin: 8, effort: "RPE 8").subtitle,
            "3 × 8 · RPE 8"
        )
    }

    func testBlockSummarySingleRIR() {
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12, rest: 90,
                     rir: 2, effortModeRaw: "single")
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rir).subtitle,
            "3 × 8–12 · 90s rest · RIR 2"
        )
    }

    func testBlockSummarySingleRPE() {
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 8, rpe: 8.5,
                     effortModeRaw: "single")
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rpe).subtitle,
            "3 × 8 · RPE 8.5"
        )
    }

    func testBlockSummaryLegacyNilModeDerivesSingleRIR() {
        // rir set, effortModeRaw nil → derives .single → "RIR 2".
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12, rir: 2)
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rir).subtitle,
            "3 × 8–12 · RIR 2"
        )
    }

    func testBlockSummaryProgressionRIR() {
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12,
                     effortModeRaw: "progression", rirStart: 2, rirEnd: 0)
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rir).subtitle,
            "3 × 8–12 · RIR 2 → 0"
        )
    }

    func testBlockSummaryProgressionRPE() {
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12,
                     effortModeRaw: "progression", rpeStart: 8, rpeEnd: 10)
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rpe).subtitle,
            "3 × 8–12 · RPE 8 → 10"
        )
    }

    func testBlockSummaryNoneOmitsEffort() {
        // No effort values → mode derives .none → no suffix.
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12, rest: 90)
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rir).subtitle,
            "3 × 8–12 · 90s rest"
        )
    }

    func testBlockSummaryNilMetricOmitsEffortEvenWhenPresent() {
        // Autoreg disabled (metric nil) → no suffix even with a value present;
        // the default init (no metric arg) behaves identically — pinning that
        // existing summary behavior is unchanged.
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12, rir: 2,
                     effortModeRaw: "single")
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: nil).subtitle,
            "3 × 8–12"
        )
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "3 × 8–12"
        )
    }

    func testSupersetIgnoresEffortMetric() {
        let block = makeBlock(isSuperset: true, slots: [
            makeSlot(sets: 3, order: 0, rir: 2, effortModeRaw: "single"),
            makeSlot(sets: 3, order: 1, rir: 2, effortModeRaw: "single"),
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rir).subtitle,
            "Superset · 2 exercises · 3 sets"
        )
    }

    // MARK: - map(for:)

    func testMapKeyedByBlockSlotID() {
        let normal = makeBlock(
            isSuperset: false,
            slots: [makeSlot(sets: 3, repMin: 8, repMax: 12)]
        )
        let superset = makeBlock(
            isSuperset: true,
            slots: [makeSlot(sets: 4, order: 0), makeSlot(sets: 4, order: 1)]
        )

        let map = BlockPrescriptionSummary.map(for: [normal, superset])
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[normal.slotID]?.subtitle, "3 × 8–12")
        XCTAssertEqual(
            map[superset.slotID]?.subtitle,
            "Superset · 2 exercises · 4 sets"
        )
    }

    func testMapEmptyInputReturnsEmpty() {
        XCTAssertTrue(BlockPrescriptionSummary.map(for: []).isEmpty)
    }
}

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

    func testBlockSummaryLegacyNilModeDerivesSingleRPE() {
        // rpe set, effortModeRaw nil → derives .single → "RPE 8".
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12, rpe: 8)
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rpe).subtitle,
            "3 × 8–12 · RPE 8"
        )
    }

    func testBlockSummaryExplicitNoneSuppressesEffort() {
        // effortModeRaw "none" wins over a present legacy rir → no suffix.
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12, rest: 90,
                     rir: 2, effortModeRaw: "none")
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rir).subtitle,
            "3 × 8–12 · 90s rest"
        )
    }

    func testBlockSummarySingleFallsBackToPairedMetric() {
        // Value stored only under RIR, app metric is RPE → fall back via 10−x.
        let rirOnly = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12, rir: 2)
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: rirOnly, effortMetric: .rpe).subtitle,
            "3 × 8–12 · RPE 8"
        )
        // Value stored only under RPE, app metric is RIR → fall back via 10−x.
        let rpeOnly = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12, rpe: 8)
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: rpeOnly, effortMetric: .rir).subtitle,
            "3 × 8–12 · RIR 2"
        )
    }

    func testBlockSummaryProgressionFallsBackToPairedMetric() {
        // Progression stored only under RIR, app metric is RPE → mirror endpoints.
        let block = makeBlock(isSuperset: false, slots: [
            makeSlot(sets: 3, repMin: 8, repMax: 12,
                     effortModeRaw: "progression", rirStart: 2, rirEnd: 0)
        ])
        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rpe).subtitle,
            "3 × 8–12 · RPE 8 → 10"
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

    // MARK: - Prepared alternatives (Build 10 C4)

    /// One prepared alternative pointing at a throwaway exercise id.
    private func alternative(
        _ name: String, order: Int = 0, enabled: Bool = true
    ) -> SlotAlternative {
        SlotAlternative(
            order: order, isEnabled: enabled, exerciseID: UUID(),
            exerciseName: name)
    }

    private func blockWithAlternatives(
        _ alternatives: [SlotAlternative]
    ) -> RoutineBlock {
        let slot = makeSlot(sets: 3, repMin: 8, repMax: 12)
        slot.prescription?.setSlotAlternatives(alternatives)
        return makeBlock(isSuperset: false, slots: [slot])
    }

    /// The count is the point of the slice: a routine row now says that
    /// switching this exercise mid-workout has something prepared behind it.
    func testEnabledAlternativesAppearAsATrailingCount() {
        let block = blockWithAlternatives([
            alternative("Machine Press", order: 0),
            alternative("Dumbbell Press", order: 1),
        ])

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "3 × 8–12 · 2 alternatives")
    }

    func testASingleAlternativeIsSingular() {
        let block = blockWithAlternatives([alternative("Machine Press")])

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "3 × 8–12 · 1 alternative")
    }

    /// A slot with nothing prepared must read exactly as it did before this
    /// slice — no "0 alternatives", no trailing separator.
    func testNoAlternativesAddsNothingToTheSubtitle() {
        let block = blockWithAlternatives([])

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle, "3 × 8–12")
    }

    /// **The product rule:** the row counts only alternatives the switch sheet
    /// would offer, so disabled ones are excluded. A disabled alternative is
    /// prepared work the user asked not to be offered; promising it on the
    /// routine row would be a count the workout does not honor. The authoring
    /// row inside the slot still lists every one of them, disabled included.
    func testDisabledAlternativesAreExcludedFromTheCount() {
        let block = blockWithAlternatives([
            alternative("Machine Press", order: 0),
            alternative("Treadmill", order: 1, enabled: false),
        ])

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "3 × 8–12 · 1 alternative")
    }

    func testASlotWhoseAlternativesAreAllDisabledReadsAsHavingNone() {
        let block = blockWithAlternatives([
            alternative("Machine Press", order: 0, enabled: false),
            alternative("Treadmill", order: 1, enabled: false),
        ])

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle, "3 × 8–12")
    }

    /// The count is the last segment, after rest and effort — the plan reads
    /// first, and this is the one part a user scans for rather than reads.
    func testTheCountIsTheLastSegment() {
        let slot = makeSlot(
            sets: 3, repMin: 8, repMax: 12, rest: 90, rir: 2,
            effortModeRaw: EffortMode.single.rawValue)
        slot.prescription?.setSlotAlternatives([alternative("Machine Press")])
        let block = makeBlock(isSuperset: false, slots: [slot])

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, effortMetric: .rir).subtitle,
            "3 × 8–12 · 90s rest · RIR 2 · 1 alternative")
    }

    /// A corrupt payload counts zero rather than breaking the row — the same
    /// tolerance the storage accessor gives every other reader.
    func testACorruptAlternativesPayloadCountsZero() {
        let slot = makeSlot(sets: 3, repMin: 8, repMax: 12)
        slot.prescription?.alternativesData = Data("not a payload".utf8)
        let block = makeBlock(isSuperset: false, slots: [slot])

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle, "3 × 8–12")
    }

    /// Supersets stay block-level: a per-slot count would not say which of the
    /// block's exercises it belongs to. Same reasoning that keeps effort off a
    /// superset row.
    func testSupersetRowsDoNotShowAnAlternativeCount() {
        let first = makeSlot(sets: 4, order: 0)
        first.prescription?.setSlotAlternatives([alternative("Machine Press")])
        let second = makeSlot(sets: 4, order: 1)
        let block = makeBlock(isSuperset: true, slots: [first, second])

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block).subtitle,
            "Superset · 2 exercises · 4 sets")
    }

    /// The value-in initializer is what the wording tests above pin, so it must
    /// carry the same segment. Defaulting to zero keeps every existing caller
    /// and test unchanged.
    func testValueInInitializerCarriesTheCount() {
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 3, repMin: 8, alternatives: 2)
                .subtitle,
            "3 × 8 · 2 alternatives")
        XCTAssertEqual(
            BlockPrescriptionSummary(sets: 3, repMin: 8).subtitle, "3 × 8")
    }

    /// The Start Workout screen renders this same type, so a plan a user
    /// confirms before starting is worded by the routine editor's own source.
    func testMapCarriesTheCountForTheStartWorkoutScreen() {
        let block = blockWithAlternatives([alternative("Machine Press")])

        let map = BlockPrescriptionSummary.map(for: [block])
        XCTAssertEqual(map[block.slotID]?.subtitle, "3 × 8–12 · 1 alternative")
    }
}

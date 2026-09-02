import SwiftData
import XCTest

@testable import Log

/// Build 10 H5a — the planned effort target a finished workout shows in
/// History.
///
/// Two halves, deliberately separated:
///
///  1. **Wording**, over `WorkoutEffortTargetResolver.Fields` values. Pure, no
///     store, so every effort mode and every "nothing to say" shape is a fast
///     assertion rather than a screenshot.
///  2. **Freshness**, over real `SlotPrescription` / `PlannedPrescriptionSnapshot`
///     rows in the harness. This is the property the feature actually rests on:
///     the snapshot is a copy, so editing the routine afterwards cannot rewrite
///     what an old workout says it planned.
///
/// Nothing here asserts an *achieved* effort. No `SetLog` carries one, and H5a
/// deliberately does not add one.
@MainActor
final class HistoryPlannedEffortTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func fields(
        mode: EffortMode? = nil,
        rir: Double? = nil, rpe: Double? = nil,
        rirStart: Double? = nil, rirEnd: Double? = nil,
        rpeStart: Double? = nil, rpeEnd: Double? = nil,
        customRIR: String? = nil, customRPE: String? = nil
    ) -> WorkoutEffortTargetResolver.Fields {
        WorkoutEffortTargetResolver.Fields(
            effortModeRaw: mode?.rawValue,
            rir: rir, rpe: rpe,
            rirStart: rirStart, rirEnd: rirEnd,
            rpeStart: rpeStart, rpeEnd: rpeEnd,
            customRIRTargetsRaw: customRIR, customRPETargetsRaw: customRPE)
    }

    private func summary(
        _ fields: WorkoutEffortTargetResolver.Fields?,
        autoreg: AutoregMode = .rir,
        sets: Int? = 4
    ) -> String? {
        HistoryPlannedEffort.summary(
            fields: fields, autoregMode: autoreg, workingSetCount: sets)
    }

    // ==================================================
    // MARK: - 1. Every mode renders
    // ==================================================

    func testSameTargetRenders() {
        XCTAssertEqual(summary(fields(mode: .single, rir: 2)), "RIR 2")
    }

    func testProgressionRendersWithADirectionalArrow() {
        XCTAssertEqual(
            summary(fields(mode: .progression, rirStart: 2, rirEnd: 0)),
            "RIR 2 → 0")
    }

    func testCustomPerSetRendersEveryTargetItFits() {
        XCTAssertEqual(
            summary(fields(mode: .custom, customRIR: "2,1.5,1,0")),
            "RIR 2/1.5/1/0")
    }

    /// The C6 elision rule reaches History for free, because History formats
    /// through the same resolver as every other summary in the app.
    func testALongCustomListElidesAfterFourValues() {
        XCTAssertEqual(
            summary(
                fields(mode: .custom, customRIR: "3,3,2,2,1,1,0,0"), sets: 8),
            "RIR 3/3/2/2…")
    }

    /// A custom list is fitted to the **planned** set count from the same
    /// frozen snapshot, not to however many sets were actually logged.
    func testCustomListIsFittedToThePlannedSetCount() {
        XCTAssertEqual(
            summary(fields(mode: .custom, customRIR: "2,1.5,1,0"), sets: 2),
            "RIR 2/1.5")
    }

    func testRPEModeRenders() {
        XCTAssertEqual(
            summary(fields(mode: .single, rpe: 8), autoreg: .rpe), "RPE 8")
        XCTAssertEqual(
            summary(
                fields(mode: .custom, customRPE: "8,8,9,10"), autoreg: .rpe),
            "RPE 8/8/9/10")
    }

    /// A target authored under one metric still reads for a user who has since
    /// switched the app to the other — the resolver's paired `10 - x` fallback,
    /// which History inherits rather than reimplements.
    func testATargetAuthoredInTheOtherMetricStillReads() {
        XCTAssertEqual(
            summary(fields(mode: .single, rir: 2), autoreg: .rpe), "RPE 8")
        XCTAssertEqual(
            summary(fields(mode: .single, rpe: 8), autoreg: .rir), "RIR 2")
    }

    /// A legacy snapshot predating explicit modes: a bare stored value derives
    /// `.single`, exactly as it does everywhere else.
    func testALegacySnapshotWithNoModeStillReads() {
        XCTAssertEqual(summary(fields(rir: 2)), "RIR 2")
    }

    // ==================================================
    // MARK: - 2. Nothing to say renders no row
    // ==================================================

    func testNoSnapshotRendersNothing() {
        XCTAssertNil(summary(nil))
    }

    func testModeNoneRendersNothing() {
        XCTAssertNil(summary(fields(mode: EffortMode.none)))
    }

    func testAnEmptySnapshotRendersNothing() {
        XCTAssertNil(summary(fields()))
    }

    /// Mode says progression / custom, values say nothing. The row disappears
    /// rather than rendering a label with an empty value beside it.
    func testAModeWithNoValuesRendersNothing() {
        XCTAssertNil(summary(fields(mode: .progression)))
        XCTAssertNil(summary(fields(mode: .custom)))
        XCTAssertNil(summary(fields(mode: .single)))
    }

    /// A hand-edited or truncated column is rejected whole by
    /// `EffortTargetList`, and with no other values to degrade to there is
    /// nothing to show. It must not crash and must not print raw storage.
    func testACorruptCustomListRendersNothing() {
        for raw in ["not,a,list", "2,,0", "2,99", "", " "] {
            XCTAssertNil(
                summary(fields(mode: .custom, customRIR: raw)),
                "corrupt custom list \"\(raw)\" must render no row")
        }
    }

    /// A corrupt custom list on a snapshot that *does* still carry a
    /// progression degrades to that, rather than to nothing — the resolver's
    /// existing tolerance, restated here because History is where a user would
    /// notice a target silently vanishing.
    func testACorruptCustomListFallsBackToTheValuesTheSnapshotKeeps() {
        XCTAssertEqual(
            summary(
                fields(
                    mode: .custom, rirStart: 2, rirEnd: 0,
                    customRIR: "not,a,list")),
            "RIR 2 → 0")
    }

    /// Autoregulation off means no metric is selected, so there is no unit to
    /// state a target in. Matches every other effort display in the app.
    func testAutoregulationOffRendersNothing() {
        XCTAssertNil(
            summary(fields(mode: .single, rir: 2), autoreg: AutoregMode.none))
        XCTAssertNil(
            summary(
                fields(mode: .custom, customRIR: "2,1,0"),
                autoreg: AutoregMode.none))
    }

    /// A zero or absent planned set count summarizes the authored list as
    /// stored rather than fitting it to nothing.
    func testAZeroSetCountSummarizesTheAuthoredList() {
        XCTAssertEqual(
            summary(fields(mode: .custom, customRIR: "2,1,0"), sets: 0),
            "RIR 2/1/0")
        XCTAssertEqual(
            summary(fields(mode: .custom, customRIR: "2,1,0"), sets: nil),
            "RIR 2/1/0")
    }

    // ==================================================
    // MARK: - 3. Frozen, not live
    // ==================================================

    /// The snapshot copies the prescription's effort fields at session start.
    private func snapshot(
        from prescription: SlotPrescription
    ) -> PlannedPrescriptionSnapshot {
        let snap = PlannedPrescriptionSnapshot(
            sets: prescription.sets,
            rir: prescription.rir,
            rpe: prescription.rpe,
            effortModeRaw: prescription.effortModeRaw,
            rirStart: prescription.rirStart,
            rirEnd: prescription.rirEnd,
            rpeStart: prescription.rpeStart,
            rpeEnd: prescription.rpeEnd,
            customRIRTargetsRaw: prescription.customRIRTargetsRaw,
            customRPETargetsRaw: prescription.customRPETargetsRaw)
        context.insert(snap)
        return snap
    }

    private func historySummary(
        for snapshot: PlannedPrescriptionSnapshot
    ) -> String? {
        HistoryPlannedEffort.summary(
            fields: WorkoutEffortTargetResolver.Fields(snapshot: snapshot),
            autoregMode: .rir,
            workingSetCount: snapshot.sets)
    }

    /// **The property the whole slice rests on.** Finish a workout, then edit
    /// the routine: History must still state the target the workout was started
    /// with, because it reads the frozen copy and never the live template.
    func testEditingTheRoutineAfterwardsDoesNotChangeHistory() throws {
        let prescription = SlotPrescription(
            sets: 4, rir: 2, effortModeRaw: EffortMode.single.rawValue)
        context.insert(prescription)
        let frozen = snapshot(from: prescription)

        XCTAssertEqual(historySummary(for: frozen), "RIR 2")

        // The user reprograms the routine after the workout is done.
        prescription.rir = 0
        prescription.effortModeRaw = EffortMode.progression.rawValue
        prescription.rirStart = 4
        prescription.rirEnd = 1
        try context.save()

        XCTAssertEqual(
            historySummary(for: frozen), "RIR 2",
            "History must state the target the workout was started with")
    }

    /// Same rule for a custom list, which is the mode this slice exists for:
    /// Build 9 shipped it and History showed nothing of it.
    func testEditingACustomListAfterwardsDoesNotChangeHistory() throws {
        let prescription = SlotPrescription(
            sets: 4, effortModeRaw: EffortMode.custom.rawValue,
            customRIRTargetsRaw: "2,1.5,1,0")
        context.insert(prescription)
        let frozen = snapshot(from: prescription)

        XCTAssertEqual(historySummary(for: frozen), "RIR 2/1.5/1/0")

        prescription.customRIRTargetsRaw = "5,5,5,5"
        try context.save()

        XCTAssertEqual(historySummary(for: frozen), "RIR 2/1.5/1/0")
    }

    /// Reading the snapshot must not write to it: History is a reader, and a
    /// display path that normalized its source would rewrite old workouts.
    func testRenderingDoesNotMutateTheSnapshot() throws {
        let prescription = SlotPrescription(
            sets: 8, effortModeRaw: EffortMode.custom.rawValue,
            customRIRTargetsRaw: "3,3,2,2,1,1,0,0")
        context.insert(prescription)
        let frozen = snapshot(from: prescription)

        XCTAssertEqual(historySummary(for: frozen), "RIR 3/3/2/2…")
        XCTAssertEqual(
            frozen.customRIRTargetsRaw, "3,3,2,2,1,1,0,0",
            "the elided summary must not shorten the stored list")
        XCTAssertEqual(frozen.effortModeRaw, EffortMode.custom.rawValue)
        XCTAssertEqual(frozen.sets, 8)
    }

    /// A snapshot with no effort fields — every cardio slot, since the routine
    /// editor does not offer effort for one — renders no row without any
    /// cardio-specific branch.
    func testASnapshotWithNoEffortRendersNothing() {
        let snap = PlannedPrescriptionSnapshot(sets: 1, usesDuration: true)
        context.insert(snap)

        XCTAssertNil(historySummary(for: snap))
    }
}

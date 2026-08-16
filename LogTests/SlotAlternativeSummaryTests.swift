import XCTest

@testable import Log

/// Alternative Exercises Phase D — the routine editor's row wording.
///
/// Pure: `SlotAlternativeSummary` has no SwiftData, so these are plain
/// `XCTestCase` tests with literal payloads, matching `BlockPrescriptionSummary`
/// and `RoutineSummary`'s wording suites.
///
/// The rule worth pinning is **delegation**: the prescription half of an
/// alternative's summary is `BlockPrescriptionSummary`'s output verbatim, so a
/// future change to how a block row reads changes an alternative row with it,
/// and there is no fourth summary format to keep in sync.
final class SlotAlternativeSummaryTests: XCTestCase {

    // MARK: - Fixtures

    private func payload(
        sets: Int? = 3,
        repMin: Int? = 8,
        repMax: Int? = 12,
        rest: Int? = 90
    ) -> AlternativePrescriptionPayload {
        AlternativePrescriptionPayload(
            sets: sets, repMin: repMin, repMax: repMax,
            restSecondsBetweenSets: rest)
    }

    private func warmupStep(order: Int = 0) -> WarmupStepSnapshot {
        WarmupStepSnapshot(
            order: order, kind: .percentage, reps: 10, percentOfWorking: 50)
    }

    private func technique(order: Int = 0) -> TechniquePlanSnapshot {
        TechniquePlanSnapshot(
            order: order, type: .dropset, dropPercent: 20, dropCount: 2,
            rounds: nil, restSeconds: 15, partialRangeNote: nil, note: nil,
            reps: nil)
    }

    private func cardioPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                CardioSegment(kind: .work, durationSeconds: 1_200)
            ])
        ])
    }

    private func alternative(
        _ p: AlternativePrescriptionPayload, enabled: Bool = true
    ) -> SlotAlternative {
        SlotAlternative(
            isEnabled: enabled, exerciseID: UUID(),
            exerciseName: "Machine Chest Press", prescription: p)
    }

    // MARK: - 1. Strength prescription

    func testStrengthSummaryReadsLikeABlockRow() {
        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(for: payload()),
            "3 × 8–12 · 90s rest")
    }

    /// The delegation claim, asserted rather than described.
    func testSummaryMatchesBlockPrescriptionSummaryForTheSameValues() {
        let expected = BlockPrescriptionSummary(
            sets: 3, repMin: 8, repMax: 12, restSeconds: 90
        ).subtitle

        XCTAssertEqual(SlotAlternativeSummary.subtitle(for: payload()), expected)
    }

    func testDurationSummaryUsesTheDurationTarget() {
        var p = payload(repMin: nil, repMax: nil, rest: nil)
        p.usesDuration = true
        p.durationMaxSeconds = 45

        XCTAssertEqual(SlotAlternativeSummary.subtitle(for: p), "3 × 45s")
    }

    func testEmptyPrescriptionReadsAsNotSet() {
        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(
                for: AlternativePrescriptionPayload()),
            "Not set")
    }

    func testEffortIsIncludedWhenTheMetricIsSupplied() {
        var p = payload()
        p.rir = 2

        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(for: p, effortMetric: .rir),
            "3 × 8–12 · 90s rest · RIR 2")
        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(for: p, effortMetric: nil),
            "3 × 8–12 · 90s rest",
            "autoreg off omits the effort segment, like every other summary")
    }

    // MARK: - 2/3/4. Presence flags

    func testSummaryIncludesWarmupFlag() {
        var p = payload()
        p.warmupSteps = [warmupStep()]

        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(for: p),
            "3 × 8–12 · 90s rest · Warmup")
    }

    func testSummaryIncludesTechniquesFlag() {
        var p = payload()
        p.techniques = [technique()]

        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(for: p),
            "3 × 8–12 · 90s rest · Techniques")
    }

    func testSummaryIncludesCardioPlanFlag() throws {
        var p = payload(repMin: nil, repMax: nil, rest: nil)
        p.usesDuration = true
        p.cardioSegments = try cardioPlan()

        XCTAssertTrue(
            SlotAlternativeSummary.subtitle(for: p).hasSuffix(
                "Structured Cardio"))
    }

    /// All three, in the order the prescription editor lists the tools.
    func testFlagOrderMatchesTheEditorsToolOrder() throws {
        var p = payload()
        p.warmupSteps = [warmupStep()]
        p.techniques = [technique()]
        p.cardioSegments = try cardioPlan()

        XCTAssertEqual(
            SlotAlternativeSummary.presenceFlags(for: p),
            ["Warmup", "Techniques", "Structured Cardio"])
    }

    func testNoFlagsWhenNothingIsCarried() {
        XCTAssertEqual(SlotAlternativeSummary.presenceFlags(for: payload()), [])
    }

    /// An empty plan is "no plan" — the flag must not appear for one.
    func testEmptyCardioPlanRaisesNoFlag() {
        var p = payload()
        p.cardioSegments = .empty

        XCTAssertEqual(SlotAlternativeSummary.presenceFlags(for: p), [])
    }

    // MARK: - 5. Target distance

    func testTargetDistanceAppearsInTheSummary() {
        var p = payload(repMin: nil, repMax: nil, rest: nil)
        p.usesDuration = true
        p.targetDistanceMeters = 5_000

        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(
                for: p, displayUnit: .kilometers),
            "3 sets · 5 km")
    }

    // MARK: - 6. Count label

    func testCountLabelForZeroReadsNone() {
        XCTAssertEqual(SlotAlternativeSummary.countLabel(0), "None")
    }

    func testCountLabelForOneAndMany() {
        XCTAssertEqual(SlotAlternativeSummary.countLabel(1), "1")
        XCTAssertEqual(SlotAlternativeSummary.countLabel(7), "7")
    }

    // MARK: - Disabled state

    /// The row dims and tags a disabled alternative; the summary itself is
    /// unchanged, because the prepared plan is still what it is.
    func testDisabledAlternativeKeepsItsSummary() {
        let enabled = alternative(payload(), enabled: true)
        let disabled = alternative(payload(), enabled: false)

        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(for: disabled),
            SlotAlternativeSummary.subtitle(for: enabled))
        XCTAssertFalse(disabled.isEnabled)
    }

    // MARK: - Effort mode derivation

    func testEffortModeFallsBackToSingleForALegacyValue() {
        var p = payload()
        p.rir = 2

        XCTAssertEqual(SlotAlternativeSummary.effortMode(for: p), .single)
    }

    func testExplicitEffortModeWins() {
        var p = payload()
        p.rir = 2
        p.effortModeRaw = EffortMode.none.rawValue

        XCTAssertEqual(SlotAlternativeSummary.effortMode(for: p), .none)
        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(for: p, effortMetric: .rir),
            "3 × 8–12 · 90s rest")
    }
}

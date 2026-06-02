import XCTest

@testable import Log

/// Pure tests for the `EffortTargetResolver` namespace and the derived
/// `SlotPrescription.effortMode` accessor (Effort Target Modes — Slice A).
/// The resolver never touches a `ModelContext`; the derivation tests build a
/// plain `SlotPrescription` value (no insert) since `effortMode` reads only
/// stored fields.
final class EffortTargetResolverTests: XCTestCase {

    // MARK: - Progression interpolation

    func testProgressionRIR_2to0_over3Sets() {
        let values = EffortTargetResolver.resolve(
            mode: .progression, single: nil, start: 2, end: 0, setCount: 3)
        XCTAssertEqual(values, [2, 1, 0])
    }

    func testProgressionRIR_2to1_over3Sets() {
        let values = EffortTargetResolver.resolve(
            mode: .progression, single: nil, start: 2, end: 1, setCount: 3)
        XCTAssertEqual(values, [2, 1.5, 1])
    }

    func testProgressionRIR_2to1_over4Sets() {
        let values = EffortTargetResolver.resolve(
            mode: .progression, single: nil, start: 2, end: 1, setCount: 4)
        XCTAssertEqual(values, [2, 1.5, 1.5, 1])
    }

    func testProgressionRPE_8to10_over3Sets() {
        let values = EffortTargetResolver.resolve(
            mode: .progression, single: nil, start: 8, end: 10, setCount: 3)
        XCTAssertEqual(values, [8, 9, 10])
    }

    func testReverseProgressionWorks() {
        let values = EffortTargetResolver.resolve(
            mode: .progression, single: nil, start: 0, end: 2, setCount: 3)
        XCTAssertEqual(values, [0, 1, 2])
    }

    // MARK: - Single / None

    func testSingleRepeatsValue() {
        let values = EffortTargetResolver.resolve(
            mode: .single, single: 2, start: nil, end: nil, setCount: 4)
        XCTAssertEqual(values, [2, 2, 2, 2])
    }

    func testNoneReturnsNoTargetsAndNoSummary() {
        let values = EffortTargetResolver.resolve(
            mode: .none, single: 2, start: 2, end: 0, setCount: 3)
        XCTAssertEqual(values, [])

        let summary = EffortTargetResolver.summary(
            metric: .rir, mode: .none, single: 2, start: 2, end: 0)
        XCTAssertNil(summary)
    }

    // MARK: - Set count edge cases

    func testSetCountZeroReturnsEmpty() {
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                mode: .single, single: 2, start: nil, end: nil, setCount: 0),
            [])
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                mode: .progression, single: nil, start: 2, end: 0, setCount: 0),
            [])
    }

    func testSetCountOneReturnsStartValue() {
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                mode: .progression, single: nil, start: 2, end: 0, setCount: 1),
            [2])
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                mode: .single, single: 3, start: nil, end: nil, setCount: 1),
            [3])
    }

    // MARK: - Missing value handling

    func testProgressionWithOnlyStartBehavesLikeSingle() {
        let values = EffortTargetResolver.resolve(
            mode: .progression, single: nil, start: 2, end: nil, setCount: 3)
        XCTAssertEqual(values, [2, 2, 2])
    }

    func testProgressionWithMissingStartAndEndReturnsNoTargets() {
        let values = EffortTargetResolver.resolve(
            mode: .progression, single: nil, start: nil, end: nil, setCount: 3)
        XCTAssertEqual(values, [])

        let summary = EffortTargetResolver.summary(
            metric: .rir, mode: .progression, single: nil, start: nil, end: nil)
        XCTAssertNil(summary)
    }

    func testSingleWithMissingValueReturnsNoTargets() {
        let values = EffortTargetResolver.resolve(
            mode: .single, single: nil, start: nil, end: nil, setCount: 3)
        XCTAssertEqual(values, [])
        XCTAssertNil(
            EffortTargetResolver.summary(
                metric: .rir, mode: .single, single: nil, start: nil, end: nil))
    }

    // MARK: - Formatting

    func testFormattingDropsTrailingZero() {
        XCTAssertEqual(EffortTargetResolver.format(2.0), "2")
        XCTAssertEqual(EffortTargetResolver.format(0.0), "0")
        XCTAssertEqual(EffortTargetResolver.format(10.0), "10")
    }

    func testFormattingKeepsHalfStep() {
        XCTAssertEqual(EffortTargetResolver.format(1.5), "1.5")
        XCTAssertEqual(EffortTargetResolver.format(8.5), "8.5")
    }

    // MARK: - Summary wording

    func testSummarySingle() {
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rir, mode: .single, single: 2, start: nil, end: nil),
            "RIR 2")
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rpe, mode: .single, single: 8.5, start: nil, end: nil),
            "RPE 8.5")
    }

    func testSummaryProgressionUsesDirectionalArrow() {
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rir, mode: .progression, single: nil, start: 2, end: 0),
            "RIR 2 → 0")
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rpe, mode: .progression, single: nil, start: 8, end: 10),
            "RPE 8 → 10")
    }

    func testSummaryProgressionCollapsesEqualEndpoints() {
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rir, mode: .progression, single: nil, start: 2, end: 2),
            "RIR 2")
    }

    // MARK: - SlotPrescription.effortMode derivation

    func testLegacyRIRWithNilEffortModeDerivesSingle() {
        let p = SlotPrescription(rir: 2)
        XCTAssertNil(p.effortModeRaw)
        XCTAssertEqual(p.effortMode, .single)
    }

    func testLegacyRPEWithNilEffortModeDerivesSingle() {
        let p = SlotPrescription(rpe: 8)
        XCTAssertNil(p.effortModeRaw)
        XCTAssertEqual(p.effortMode, .single)
    }

    func testNilRIRandRPEwithNilEffortModeDerivesNone() {
        let p = SlotPrescription()
        XCTAssertNil(p.effortModeRaw)
        XCTAssertEqual(p.effortMode, .none)
    }

    func testExplicitEffortModeRawOverridesDerivation() {
        // Explicit `.none` wins even though a legacy rir is present.
        let noneOverride = SlotPrescription(rir: 2, effortModeRaw: "none")
        XCTAssertEqual(noneOverride.effortMode, .none)

        // Explicit `.progression` wins even with no single value present.
        let progOverride = SlotPrescription(effortModeRaw: "progression")
        XCTAssertEqual(progOverride.effortMode, .progression)

        // An unrecognized raw string falls back to derivation (here `.single`).
        let bogus = SlotPrescription(rir: 2, effortModeRaw: "garbage")
        XCTAssertEqual(bogus.effortMode, .single)
    }
}

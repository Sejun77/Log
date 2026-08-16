import XCTest

@testable import Log

/// Pure tests for the `EffortTargetResolver` namespace, the `EffortTargetList`
/// codec, and the derived `SlotPrescription.effortMode` accessor.
///
/// The resolver never touches a `ModelContext`; the derivation tests build a
/// plain `SlotPrescription` value (no insert) since `effortMode` reads only
/// stored fields.
final class EffortTargetResolverTests: XCTestCase {

    // MARK: - Automatic progression (the final human-friendly rules)

    private func rir(_ start: Double, _ end: Double, _ sets: Int) -> [Double] {
        EffortTargetResolver.resolve(
            metric: .rir, mode: .progression, single: nil,
            start: start, end: end, setCount: sets)
    }

    private func rpe(_ start: Double, _ end: Double, _ sets: Int) -> [Double] {
        EffortTargetResolver.resolve(
            metric: .rpe, mode: .progression, single: nil,
            start: start, end: end, setCount: sets)
    }

    func testProgressionRIR_2to0_over2Sets() {
        XCTAssertEqual(rir(2, 0, 2), [2, 0])
    }

    func testProgressionRIR_2to0_over3Sets() {
        XCTAssertEqual(rir(2, 0, 3), [2, 1, 0])
    }

    func testProgressionRIR_2to0_over4Sets() {
        XCTAssertEqual(rir(2, 0, 4), [2, 2, 1, 0])
    }

    func testProgressionRIR_2to0_over5Sets() {
        XCTAssertEqual(rir(2, 0, 5), [2, 2, 1, 1, 0])
    }

    func testProgressionRIR_2to0_over6Sets() {
        XCTAssertEqual(rir(2, 0, 6), [2, 2, 2, 1, 1, 0])
    }

    func testProgressionRPE_8to10_over2Sets() {
        XCTAssertEqual(rpe(8, 10, 2), [8, 10])
    }

    func testProgressionRPE_8to10_over3Sets() {
        XCTAssertEqual(rpe(8, 10, 3), [8, 9, 10])
    }

    func testProgressionRPE_8to10_over4Sets() {
        XCTAssertEqual(rpe(8, 10, 4), [8, 8, 9, 10])
    }

    func testProgressionRPE_8to10_over5Sets() {
        XCTAssertEqual(rpe(8, 10, 5), [8, 8, 9, 9, 10])
    }

    func testProgressionRPE_8to10_over6Sets() {
        XCTAssertEqual(rpe(8, 10, 6), [8, 8, 8, 9, 9, 10])
    }

    /// Set 1 is always exactly `start` and the last set exactly `end`, across
    /// every set count and both metrics — including half-step endpoints, which
    /// survive even though interiors never invent one.
    func testEndpointsArePreservedExactly() {
        for sets in 2...12 {
            for (start, end) in [(2.0, 0.0), (5.0, 1.0), (2.5, 0.5)] {
                let values = rir(start, end, sets)
                XCTAssertEqual(values.first, start, "RIR \(start)→\(end) ×\(sets)")
                XCTAssertEqual(values.last, end, "RIR \(start)→\(end) ×\(sets)")
            }
            for (start, end) in [(8.0, 10.0), (5.0, 9.0), (8.5, 9.5)] {
                let values = rpe(start, end, sets)
                XCTAssertEqual(values.first, start, "RPE \(start)→\(end) ×\(sets)")
                XCTAssertEqual(values.last, end, "RPE \(start)→\(end) ×\(sets)")
            }
        }
    }

    /// RIR never gets easier as the sets go on: reps in reserve stay the same
    /// or fall.
    func testRIRProgressionIsMonotonicNonIncreasing() {
        for sets in 2...12 {
            for (start, end) in [(2.0, 0.0), (5.0, 0.0), (3.0, 1.0), (0.5, 0.0)] {
                let values = rir(start, end, sets)
                for (a, b) in zip(values, values.dropFirst()) {
                    XCTAssertLessThanOrEqual(
                        b, a, "RIR \(start)→\(end) ×\(sets): \(values)")
                }
            }
        }
    }

    /// RPE never gets easier as the sets go on: perceived exertion stays the
    /// same or rises.
    func testRPEProgressionIsMonotonicNonDecreasing() {
        for sets in 2...12 {
            for (start, end) in [(8.0, 10.0), (5.0, 10.0), (7.0, 9.0), (9.5, 10.0)] {
                let values = rpe(start, end, sets)
                for (a, b) in zip(values, values.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(
                        b, a, "RPE \(start)→\(end) ×\(sets): \(values)")
                }
            }
        }
    }

    /// The bug this system replaces: whole-number endpoints must never generate
    /// a half step in between (`2, 1.5, 0.5, 0`), and never a duplicated one
    /// (`2, 1.5, 1.5, 0`).
    func testNoHalfStepsGeneratedFromWholeNumberEndpoints() {
        for sets in 2...12 {
            for values in [rir(2, 0, sets), rir(5, 0, sets), rpe(8, 10, sets),
                           rpe(5, 10, sets)] {
                for value in values {
                    XCTAssertEqual(
                        value.truncatingRemainder(dividingBy: 1), 0,
                        "half step generated in \(values)")
                }
            }
        }
    }

    /// A short ramp whose interiors would round *past* an endpoint is clamped,
    /// so the sequence never gets easier than the set it starts from.
    func testInteriorsAreClampedInsideTheEndpoints() {
        XCTAssertEqual(rir(0.5, 0, 4), [0.5, 0.5, 0.5, 0])
        XCTAssertEqual(rpe(9.5, 10, 4), [9.5, 9.5, 9.5, 10])
    }

    /// Reverse ramps (an easier last set) stay supported and stay monotonic.
    func testReverseProgressionWorks() {
        XCTAssertEqual(rir(0, 2, 3), [0, 1, 2])
        XCTAssertEqual(rir(0, 2, 4), [0, 1, 2, 2])
    }

    func testEqualEndpointsProduceAFlatSequence() {
        XCTAssertEqual(rir(2, 2, 4), [2, 2, 2, 2])
        XCTAssertEqual(rpe(9, 9, 4), [9, 9, 9, 9])
    }

    /// Floating-point interpolation must not round an exact integer up: RIR
    /// 3 → 0 over 4 sets computes `3 - 3 × (1/3)` for set 2, which is
    /// `2.0000000000000004` in binary — rounding *that* up would prescribe a
    /// target harder than set 1.
    func testExactInteriorsAreNotInflatedByFloatingPointError() {
        XCTAssertEqual(rir(3, 0, 4), [3, 2, 1, 0])
        XCTAssertEqual(rir(6, 0, 7), [6, 5, 4, 3, 2, 1, 0])
        XCTAssertEqual(rpe(4, 10, 7), [4, 5, 6, 7, 8, 9, 10])
    }

    // MARK: - Single / None

    func testSingleRepeatsValue() {
        let values = EffortTargetResolver.resolve(
            metric: .rir, mode: .single, single: 2, start: nil, end: nil,
            setCount: 4)
        XCTAssertEqual(values, [2, 2, 2, 2])
    }

    func testNoneReturnsNoTargetsAndNoSummary() {
        let values = EffortTargetResolver.resolve(
            metric: .rir, mode: .none, single: 2, start: 2, end: 0, setCount: 3)
        XCTAssertEqual(values, [])

        let summary = EffortTargetResolver.summary(
            metric: .rir, mode: .none, single: 2, start: 2, end: 0)
        XCTAssertNil(summary)
    }

    // MARK: - Custom per-set targets

    private func custom(
        _ values: [Double], sets: Int, metric: EffortMetric = .rir
    ) -> [Double] {
        EffortTargetResolver.resolve(
            metric: metric, mode: .custom, single: nil, start: nil, end: nil,
            custom: values, setCount: sets)
    }

    func testCustomTargetsResolveVerbatim() {
        XCTAssertEqual(custom([2, 1, 1, 0], sets: 4), [2, 1, 1, 0])
        XCTAssertEqual(
            custom([8, 9, 9, 10], sets: 4, metric: .rpe), [8, 9, 9, 10])
    }

    /// Half steps a user typed are preserved exactly — the generator's
    /// whole-number rule is about *automatic* targets only.
    func testCustomTargetsPreserveHalfStepsExactly() {
        XCTAssertEqual(custom([2, 1.5, 1, 0], sets: 4), [2, 1.5, 1, 0])
        XCTAssertEqual(
            custom([8, 8.5, 9.5, 10], sets: 4, metric: .rpe),
            [8, 8.5, 9.5, 10])
    }

    func testCustomTargetsRepeatTheLastValueWhenSetsIncrease() {
        XCTAssertEqual(custom([2, 1.5, 0], sets: 5), [2, 1.5, 0, 0, 0])
    }

    func testCustomTargetsTruncateWhenSetsDecrease() {
        XCTAssertEqual(custom([2, 1.5, 1, 0], sets: 2), [2, 1.5])
    }

    func testCustomWorksForOneSet() {
        XCTAssertEqual(custom([1.5], sets: 1), [1.5])
        XCTAssertEqual(custom([2, 1, 0], sets: 1), [2])
    }

    /// A `.custom` slot whose list is missing or unreadable still shows the
    /// progression / single values it carries, rather than nothing.
    func testCustomWithNoListDegradesToTheStoredProgression() {
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                metric: .rir, mode: .custom, single: nil, start: 2, end: 0,
                custom: [], setCount: 4),
            [2, 2, 1, 0])
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                metric: .rir, mode: .custom, single: 2, start: nil, end: nil,
                custom: [], setCount: 3),
            [2, 2, 2])
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                metric: .rir, mode: .custom, single: nil, start: nil, end: nil,
                custom: [], setCount: 3),
            [])
    }

    // MARK: - Set count edge cases

    func testSetCountZeroReturnsEmpty() {
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                metric: .rir, mode: .single, single: 2, start: nil, end: nil,
                setCount: 0),
            [])
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                metric: .rir, mode: .progression, single: nil, start: 2, end: 0,
                setCount: 0),
            [])
        XCTAssertEqual(custom([2, 1, 0], sets: 0), [])
    }

    func testSetCountOneReturnsStartValue() {
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                metric: .rir, mode: .progression, single: nil, start: 2, end: 0,
                setCount: 1),
            [2])
        XCTAssertEqual(
            EffortTargetResolver.resolve(
                metric: .rir, mode: .single, single: 3, start: nil, end: nil,
                setCount: 1),
            [3])
    }

    // MARK: - Missing value handling

    func testProgressionWithOnlyStartBehavesLikeSingle() {
        let values = EffortTargetResolver.resolve(
            metric: .rir, mode: .progression, single: nil, start: 2, end: nil,
            setCount: 3)
        XCTAssertEqual(values, [2, 2, 2])
    }

    func testProgressionWithMissingStartAndEndReturnsNoTargets() {
        let values = EffortTargetResolver.resolve(
            metric: .rir, mode: .progression, single: nil, start: nil, end: nil,
            setCount: 3)
        XCTAssertEqual(values, [])

        let summary = EffortTargetResolver.summary(
            metric: .rir, mode: .progression, single: nil, start: nil, end: nil)
        XCTAssertNil(summary)
    }

    func testSingleWithMissingValueReturnsNoTargets() {
        let values = EffortTargetResolver.resolve(
            metric: .rir, mode: .single, single: nil, start: nil, end: nil,
            setCount: 3)
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

    func testSummaryCustomListsEveryTarget() {
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rir, mode: .custom, single: nil, start: nil, end: nil,
                custom: [2, 1.5, 1, 0]),
            "RIR 2/1.5/1/0")
    }

    func testSummaryCustomFitsTheSetCountWhenKnown() {
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rir, mode: .custom, single: nil, start: nil, end: nil,
                custom: [2, 1.5, 1, 0], setCount: 2),
            "RIR 2/1.5")
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rir, mode: .custom, single: nil, start: nil, end: nil,
                custom: [2, 0], setCount: 3),
            "RIR 2/0/0")
    }

    func testSummaryCustomWithNoListFallsBackToTheStoredValues() {
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rir, mode: .custom, single: nil, start: 2, end: 0,
                custom: []),
            "RIR 2 → 0")
        XCTAssertEqual(
            EffortTargetResolver.summary(
                metric: .rir, mode: .custom, single: 2, start: nil, end: nil,
                custom: []),
            "RIR 2")
    }

    // MARK: - Per-set strings

    func testPerSetStringsLabelEveryTarget() {
        XCTAssertEqual(
            EffortTargetResolver.perSetStrings(
                metric: .rir, mode: .custom, single: nil, start: nil, end: nil,
                custom: [2, 1.5, 0], setCount: 3),
            ["RIR 2", "RIR 1.5", "RIR 0"])
    }

    // MARK: - EffortTargetList codec

    func testCustomTargetListRoundTrips() {
        let values: [Double] = [2, 1.5, 1, 0]
        let raw = EffortTargetList.encode(values)
        XCTAssertEqual(raw, "2,1.5,1,0")
        XCTAssertEqual(EffortTargetList.decode(raw), values)
    }

    func testCustomTargetListEmptyEncodesToNil() {
        XCTAssertNil(EffortTargetList.encode([]))
        XCTAssertEqual(EffortTargetList.decode(nil), [])
        XCTAssertEqual(EffortTargetList.decode(""), [])
    }

    /// A malformed or out-of-range list is refused **whole**, because dropping
    /// one entry would shift every later set's target onto the wrong set.
    func testCustomTargetListRejectsMalformedInputWhole() {
        XCTAssertEqual(EffortTargetList.decode("2,oops,0"), [])
        XCTAssertEqual(EffortTargetList.decode("2,,0"), [])
        XCTAssertEqual(EffortTargetList.decode("2,99,0"), [])
        XCTAssertEqual(EffortTargetList.decode("2,-1,0"), [])
        XCTAssertNil(EffortTargetList.encode([2, 99, 0]))
    }

    func testCustomTargetListResizing() {
        XCTAssertEqual(EffortTargetList.resized([2, 1, 0], to: 5), [2, 1, 0, 0, 0])
        XCTAssertEqual(EffortTargetList.resized([2, 1, 0], to: 2), [2, 1])
        XCTAssertEqual(EffortTargetList.resized([2, 1, 0], to: 3), [2, 1, 0])
        XCTAssertEqual(EffortTargetList.resized([], to: 3), [])
        XCTAssertEqual(EffortTargetList.resized([2], to: 0), [])
    }

    // MARK: - SlotPrescription custom target accessors

    func testSetCustomEffortTargetsMirrorsTheOppositeMetric() {
        let p = SlotPrescription()
        p.setCustomEffortTargets([2, 1.5, 1, 0], metric: .rir)
        XCTAssertEqual(p.customRIRTargetsRaw, "2,1.5,1,0")
        XCTAssertEqual(p.customRPETargetsRaw, "8,8.5,9,10")
        XCTAssertEqual(p.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(p.customRPETargets, [8, 8.5, 9, 10])
    }

    func testSetCustomEffortTargetsEmptyClearsBothColumns() {
        let p = SlotPrescription()
        p.setCustomEffortTargets([2, 1, 0], metric: .rpe)
        XCTAssertNotNil(p.customRPETargetsRaw)
        p.setCustomEffortTargets([], metric: .rpe)
        XCTAssertNil(p.customRIRTargetsRaw)
        XCTAssertNil(p.customRPETargetsRaw)
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

        // Explicit `.custom` likewise.
        let customOverride = SlotPrescription(effortModeRaw: "custom")
        XCTAssertEqual(customOverride.effortMode, .custom)

        // An unrecognized raw string falls back to derivation (here `.single`).
        let bogus = SlotPrescription(rir: 2, effortModeRaw: "garbage")
        XCTAssertEqual(bogus.effortMode, .single)
    }
}

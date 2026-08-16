import XCTest

@testable import Log

/// Pure tests for `WorkoutEffortTargetResolver` — the snapshot/value → per-
/// working-set label helper for active-workout rows (Slice E2). No SwiftData /
/// `ModelContext`; inputs are the value-based `Fields` struct, plus one path
/// through a `PrescriptionSnapshotPayload` to prove the snapshot-only overload.
final class ActiveWorkoutEffortTargetResolverTests: XCTestCase {

    private typealias Resolver = WorkoutEffortTargetResolver
    private typealias Fields = WorkoutEffortTargetResolver.Fields

    // MARK: - Progression

    func testProgressionRIR_2to0_over3Sets() {
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
            autoregMode: .rir, workingSetCount: 3)
        XCTAssertEqual(labels, ["RIR 2", "RIR 1", "RIR 0"])
    }

    func testProgressionRPE_8to10_over3Sets() {
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "progression", rpeStart: 8, rpeEnd: 10),
            autoregMode: .rpe, workingSetCount: 3)
        XCTAssertEqual(labels, ["RPE 8", "RPE 9", "RPE 10"])
    }

    func testReverseProgressionWorks() {
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "progression", rirStart: 0, rirEnd: 2),
            autoregMode: .rir, workingSetCount: 3)
        XCTAssertEqual(labels, ["RIR 0", "RIR 1", "RIR 2"])
    }

    func testProgressionMissingEndpointFallsBackToSingle() {
        // Only start present → flat at the start value.
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "progression", rirStart: 2),
            autoregMode: .rir, workingSetCount: 3)
        XCTAssertEqual(labels, ["RIR 2", "RIR 2", "RIR 2"])
    }

    // MARK: - Single (incl. legacy nil-mode)

    func testLegacySingleRIR_RepeatsValue() {
        // rir set, effortModeRaw nil → derives .single.
        let labels = Resolver.perSetLabels(
            fields: Fields(rir: 2), autoregMode: .rir, workingSetCount: 3)
        XCTAssertEqual(labels, ["RIR 2", "RIR 2", "RIR 2"])
    }

    func testLegacySingleRPE_RepeatsValue() {
        let labels = Resolver.perSetLabels(
            fields: Fields(rpe: 8), autoregMode: .rpe, workingSetCount: 3)
        XCTAssertEqual(labels, ["RPE 8", "RPE 8", "RPE 8"])
    }

    func testExplicitSingleRIR() {
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "single", rir: 1.5),
            autoregMode: .rir, workingSetCount: 2)
        XCTAssertEqual(labels, ["RIR 1.5", "RIR 1.5"])
    }

    // MARK: - Paired-metric fallback

    func testRIROnlySnapshotDisplayedInRPEModeConverts() {
        // rir 2 stored, app metric RPE → 10 − 2 = 8.
        let labels = Resolver.perSetLabels(
            fields: Fields(rir: 2), autoregMode: .rpe, workingSetCount: 2)
        XCTAssertEqual(labels, ["RPE 8", "RPE 8"])
    }

    func testRPEOnlySnapshotDisplayedInRIRModeConverts() {
        // rpe 8 stored, app metric RIR → 10 − 8 = 2.
        let labels = Resolver.perSetLabels(
            fields: Fields(rpe: 8), autoregMode: .rir, workingSetCount: 2)
        XCTAssertEqual(labels, ["RIR 2", "RIR 2"])
    }

    func testProgressionRIROnlyDisplayedInRPEModeConverts() {
        // rir 2 → 0 stored, app metric RPE → 8 → 10.
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
            autoregMode: .rpe, workingSetCount: 3)
        XCTAssertEqual(labels, ["RPE 8", "RPE 9", "RPE 10"])
    }

    // MARK: - None / autoreg off

    func testExplicitNoneReturnsNoLabels() {
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "none", rir: 2),
            autoregMode: .rir, workingSetCount: 3)
        XCTAssertEqual(labels, [])
    }

    func testDerivedNoneReturnsNoLabels() {
        // No values at all → derives .none.
        let labels = Resolver.perSetLabels(
            fields: Fields(), autoregMode: .rir, workingSetCount: 3)
        XCTAssertEqual(labels, [])
    }

    func testAutoregNoneReturnsNoLabels() {
        // Even with a value present, autoreg .none suppresses display.
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "single", rir: 2),
            autoregMode: .none, workingSetCount: 3)
        XCTAssertEqual(labels, [])
    }

    // MARK: - Set count edges

    func testSetCountZeroReturnsEmpty() {
        XCTAssertEqual(
            Resolver.perSetLabels(
                fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
                autoregMode: .rir, workingSetCount: 0),
            [])
    }

    func testSetCountOneReturnsOneLabel() {
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
            autoregMode: .rir, workingSetCount: 1)
        XCTAssertEqual(labels, ["RIR 2"])
    }

    // MARK: - Formatting

    func testFormattingDropsTrailingZero() {
        // 2, not 2.0. The interior of RIR 2 → 1 over 3 sets rounds *up* to 2
        // under the final progression rules — an automatic ramp never invents a
        // half step (it used to read "2, 1.5, 1").
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 1),
            autoregMode: .rir, workingSetCount: 3)
        XCTAssertEqual(labels, ["RIR 2", "RIR 2", "RIR 1"])
    }

    /// A half step the user typed is still rendered as one — it just has to
    /// come from an endpoint or a custom target, never from the generator.
    func testFormattingKeepsAnAuthoredHalfStep() {
        XCTAssertEqual(
            Resolver.perSetLabels(
                fields: Fields(effortModeRaw: "single", rir: 1.5),
                autoregMode: .rir, workingSetCount: 2),
            ["RIR 1.5", "RIR 1.5"])
        XCTAssertEqual(
            Resolver.perSetLabels(
                fields: Fields(
                    effortModeRaw: "custom", customRIRTargetsRaw: "2,1.5,0"),
                autoregMode: .rir, workingSetCount: 3),
            ["RIR 2", "RIR 1.5", "RIR 0"])
    }

    // MARK: - Numeric values (routine editor preview basis)

    func testPerSetValues_ProgressionRIR() {
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
                autoregMode: .rir, workingSetCount: 3),
            [2, 1, 0])
    }

    func testPerSetValues_ProgressionRPE() {
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: Fields(effortModeRaw: "progression", rpeStart: 8, rpeEnd: 10),
                autoregMode: .rpe, workingSetCount: 3),
            [8, 9, 10])
    }

    func testPerSetValues_PairedFallbackRIROnlyInRPEMode() {
        // RIR 2 → 0 stored, viewed in RPE mode → 8 → 10 (the editor-preview bug).
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
                autoregMode: .rpe, workingSetCount: 3),
            [8, 9, 10])
    }

    func testPerSetValues_LegacySingleNilModeRepeats() {
        // rir set, effortModeRaw nil → derives .single.
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: Fields(rir: 2), autoregMode: .rir, workingSetCount: 3),
            [2, 2, 2])
    }

    func testPerSetValues_ProgressionInteriorsAreWholeNumbers() {
        // 2 → 1 over 3 sets = 2, 2, 1 (numeric, pre-formatting): the interior
        // rounds up for RIR, so no half step is generated and the ramp never
        // gets harder earlier than the endpoints imply.
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 1),
                autoregMode: .rir, workingSetCount: 3),
            [2, 2, 1])
    }

    // MARK: - Custom per-set targets

    func testPerSetValues_CustomTargetsResolveVerbatim() {
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: Fields(
                    effortModeRaw: "custom", customRIRTargetsRaw: "2,1.5,1,0"),
                autoregMode: .rir, workingSetCount: 4),
            [2, 1.5, 1, 0])
    }

    /// A custom list stored under one metric renders in the other through the
    /// same `10 - x` fallback the single value and the start/end pair use.
    func testPerSetValues_CustomPairedFallback() {
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: Fields(
                    effortModeRaw: "custom", customRIRTargetsRaw: "2,1.5,1,0"),
                autoregMode: .rpe, workingSetCount: 4),
            [8, 8.5, 9, 10])
    }

    func testPerSetValues_CustomFitsTheSetCount() {
        let fields = Fields(
            effortModeRaw: "custom", customRIRTargetsRaw: "2,1,0")
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: fields, autoregMode: .rir, workingSetCount: 5),
            [2, 1, 0, 0, 0])
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: fields, autoregMode: .rir, workingSetCount: 2),
            [2, 1])
    }

    func testEffortModeDerivesCustom() {
        XCTAssertEqual(
            Resolver.effortMode(
                for: Fields(
                    effortModeRaw: "custom", customRIRTargetsRaw: "2,1,0")),
            .custom)
    }

    func testSummary_CustomListsEveryTarget() {
        XCTAssertEqual(
            Resolver.summary(
                fields: Fields(
                    effortModeRaw: "custom", customRIRTargetsRaw: "2,1.5,1,0"),
                autoregMode: .rir),
            "RIR 2/1.5/1/0")
    }

    /// A custom snapshot keeps its authored list through `effectiveFields`:
    /// the session's single override is not laid over it, exactly as a
    /// progression is left alone.
    func testEffectiveFieldsDoesNotOverlayCustomTargets() {
        let snapshot = Fields(
            effortModeRaw: "custom", customRIRTargetsRaw: "2,1.5,1,0")
        let effective = Resolver.effectiveFields(
            snapshot: snapshot, sessionRIR: 4, sessionRPE: 6)
        XCTAssertEqual(effective, snapshot)
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: effective, autoregMode: .rir, workingSetCount: 4),
            [2, 1.5, 1, 0])
    }

    /// The converse: a single-mode snapshot still takes the session override,
    /// and any stale custom list is cleared with the start/end pair so it can
    /// never outrank the value the user just set.
    func testEffectiveFieldsClearsStaleCustomTargetsOnOverlay() {
        let effective = Resolver.effectiveFields(
            snapshot: Fields(
                effortModeRaw: "single", rir: 2, customRIRTargetsRaw: "2,1,0"),
            sessionRIR: 3, sessionRPE: 7)
        XCTAssertNil(effective.customRIRTargetsRaw)
        XCTAssertNil(effective.customRPETargetsRaw)
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: effective, autoregMode: .rir, workingSetCount: 3),
            [3, 3, 3])
    }

    func testPerSetValues_AutoregNoneEmpty() {
        XCTAssertEqual(
            Resolver.perSetValues(
                fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
                autoregMode: .none, workingSetCount: 3),
            [])
    }

    // MARK: - One-line summary (Plan card / Edit Plan)

    func testSummary_SingleRPE() {
        XCTAssertEqual(
            Resolver.summary(fields: Fields(rir: nil, rpe: 8), autoregMode: .rpe),
            "RPE 8")
    }

    func testSummary_ProgressionRPE() {
        XCTAssertEqual(
            Resolver.summary(
                fields: Fields(effortModeRaw: "progression", rpeStart: 8, rpeEnd: 10),
                autoregMode: .rpe),
            "RPE 8 → 10")
    }

    func testSummary_PairedFallbackRIROnlyProgressionInRPEMode() {
        XCTAssertEqual(
            Resolver.summary(
                fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
                autoregMode: .rpe),
            "RPE 8 → 10")
    }

    func testSummary_LegacySingleNilModeRIR() {
        XCTAssertEqual(
            Resolver.summary(fields: Fields(rir: 2), autoregMode: .rir),
            "RIR 2")
    }

    func testSummary_ExplicitNoneReturnsNil() {
        XCTAssertNil(
            Resolver.summary(
                fields: Fields(effortModeRaw: "none", rir: 2), autoregMode: .rir))
    }

    func testSummary_AutoregNoneReturnsNil() {
        XCTAssertNil(
            Resolver.summary(
                fields: Fields(effortModeRaw: "single", rir: 2), autoregMode: .none))
    }

    func testEffortMode_Derivation() {
        XCTAssertEqual(Resolver.effortMode(for: Fields(rir: 2)), .single)
        XCTAssertEqual(Resolver.effortMode(for: Fields()), .none)
        XCTAssertEqual(
            Resolver.effortMode(
                for: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0)),
            .progression)
        // Explicit none wins over a present legacy single value.
        XCTAssertEqual(
            Resolver.effortMode(for: Fields(effortModeRaw: "none", rir: 2)), .none)
    }

    // MARK: - Per-row mapping (working-set ordinal)

    func testPerRowLabels_MapsWorkingOrdinalSkippingWarmup() {
        // Warmup row first, then 3 working sets → progression 2 → 0.
        let kinds: [SetKind] = [.warmup, .working, .working, .working]
        let labels = Resolver.perRowLabels(
            setKinds: kinds,
            fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
            autoregMode: .rir)
        XCTAssertEqual(labels, [nil, "RIR 2", "RIR 1", "RIR 0"])
    }

    func testPerRowLabels_WarmupAndDropsetRowsGetNil() {
        // warmup + working + dropset; only the working row gets a label.
        let kinds: [SetKind] = [.warmup, .working, .dropset]
        let labels = Resolver.perRowLabels(
            setKinds: kinds,
            fields: Fields(effortModeRaw: "single", rir: 2),
            autoregMode: .rir)
        XCTAssertEqual(labels, [nil, "RIR 2", nil])
    }

    func testPerRowLabels_SingleRepeatedAcrossWorkingRows() {
        let kinds: [SetKind] = [.working, .working, .working]
        let labels = Resolver.perRowLabels(
            setKinds: kinds, fields: Fields(rir: 2), autoregMode: .rir)
        XCTAssertEqual(labels, ["RIR 2", "RIR 2", "RIR 2"])
    }

    func testPerRowLabels_ProgressionAcrossThreeWorkingRows() {
        let kinds: [SetKind] = [.working, .working, .working]
        let labels = Resolver.perRowLabels(
            setKinds: kinds,
            fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
            autoregMode: .rir)
        XCTAssertEqual(labels, ["RIR 2", "RIR 1", "RIR 0"])
    }

    func testPerRowLabels_PairedRPEFallbackFromRIROnly() {
        // RIR-only snapshot displayed in RPE mode → converted labels.
        let kinds: [SetKind] = [.warmup, .working, .working, .working]
        let labels = Resolver.perRowLabels(
            setKinds: kinds,
            fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 0),
            autoregMode: .rpe)
        XCTAssertEqual(labels, [nil, "RPE 8", "RPE 9", "RPE 10"])
    }

    func testPerRowLabels_AutoregNoneAllNil() {
        let kinds: [SetKind] = [.warmup, .working, .working]
        let labels = Resolver.perRowLabels(
            setKinds: kinds,
            fields: Fields(effortModeRaw: "single", rir: 2),
            autoregMode: .none)
        XCTAssertEqual(labels, [nil, nil, nil])
    }

    func testPerRowLabels_NoEffortAllNil() {
        let kinds: [SetKind] = [.working, .working]
        let labels = Resolver.perRowLabels(
            setKinds: kinds, fields: Fields(), autoregMode: .rir)
        XCTAssertEqual(labels, [nil, nil])
    }

    // MARK: - Snapshot payload overload (snapshot-only path)

    func testPayloadOverloadResolvesFromSnapshot() {
        // Build a payload the way session start does — from a SlotPrescription —
        // then resolve, proving the snapshot-only overload + field extraction.
        let p = SlotPrescription(
            sets: 3, effortModeRaw: "progression",
            rirStart: 2, rirEnd: 0, rpeStart: 8, rpeEnd: 10)
        let payload = PrescriptionSnapshotPayload(from: p, exercise: nil)

        XCTAssertEqual(
            Resolver.perSetLabels(
                payload: payload, autoregMode: .rir, workingSetCount: 3),
            ["RIR 2", "RIR 1", "RIR 0"])
        XCTAssertEqual(
            Resolver.perSetLabels(
                payload: payload, autoregMode: .rpe, workingSetCount: 3),
            ["RPE 8", "RPE 9", "RPE 10"])
    }
}

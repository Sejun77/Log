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

    func testFormattingDropsTrailingZeroAndKeepsHalf() {
        // 2 not 2.0; 1.5 stays 1.5 (progression 2 → 1 over 3 → 2, 1.5, 1).
        let labels = Resolver.perSetLabels(
            fields: Fields(effortModeRaw: "progression", rirStart: 2, rirEnd: 1),
            autoregMode: .rir, workingSetCount: 3)
        XCTAssertEqual(labels, ["RIR 2", "RIR 1.5", "RIR 1"])
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

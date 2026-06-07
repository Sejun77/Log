import XCTest

@testable import Log

/// Slice 2 — tests for the pure tier-4 seeding merge helper
/// `resolvedDraftDefault`, which overlays a Slice 1 last-performance
/// suggestion onto the prescription-default draft tuple.
///
/// `ActiveWorkoutView`'s seeding methods (`tier4Default`,
/// `rehydrateFromWorkoutIfPresent`, `ensureInputsInitializedFromPlan`) are
/// `private` on a SwiftUI `View` and not directly testable, but they delegate
/// the actual reps/weight/duration decision to this pure function, so testing
/// it covers the per-mode prefill rules. The priority chain itself (logged
/// `SetLog` > `ParentDraftStore` draft > guard cache > prefill > prescription)
/// is guaranteed structurally: `tier4Default` is only ever reached in the
/// fallback branches, after the higher tiers have been ruled out.
///
/// Pure — no SwiftData harness needed.
final class ActiveWorkoutPrefillSeedingTests: XCTestCase {

    private typealias Suggestion =
        LastPerformancePrefillService.LastPerformanceSetSuggestion

    // MARK: - No history → prescription passthrough

    func test_noSuggestion_passesPrescriptionThrough() {
        let out = resolvedDraftDefault(
            suggestion: nil,
            prescriptionReps: "8",
            prescriptionWeight: "",
            prescriptionDuration: "",
            isTimeBased: false,
            isBodyweight: false
        )
        XCTAssertEqual(out.reps, "8")
        XCTAssertEqual(out.weight, "")
        XCTAssertEqual(out.duration, "")
    }

    // MARK: - Weighted

    func test_weighted_fillsRepsAndWeight() {
        let s = Suggestion(setIndex: 0, reps: 8, weight: 80, durationSeconds: nil)
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "10",
            prescriptionWeight: "",
            prescriptionDuration: "",
            isTimeBased: false,
            isBodyweight: false
        )
        XCTAssertEqual(out.reps, "8")
        XCTAssertEqual(out.weight, "80")
        XCTAssertEqual(out.duration, "")
    }

    func test_weighted_formatsFractionalWeightLikeRehydration() {
        let s = Suggestion(setIndex: 0, reps: 3, weight: 140.5, durationSeconds: nil)
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "5",
            prescriptionWeight: "",
            prescriptionDuration: "",
            isTimeBased: false,
            isBodyweight: false
        )
        // Matches Units.formatWeight (canonical logged-set rehydration format).
        XCTAssertEqual(out.weight, "140.5")
        XCTAssertEqual(out.weight, Units.formatWeight(140.5))
    }

    func test_weighted_nilRepsFallsBackToPrescription() {
        let s = Suggestion(setIndex: 0, reps: nil, weight: 80, durationSeconds: nil)
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "10",
            prescriptionWeight: "",
            prescriptionDuration: "",
            isTimeBased: false,
            isBodyweight: false
        )
        XCTAssertEqual(out.reps, "10")
        XCTAssertEqual(out.weight, "80")
    }

    func test_weighted_nilWeightFallsBackToPrescription() {
        let s = Suggestion(setIndex: 0, reps: 8, weight: nil, durationSeconds: nil)
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "10",
            prescriptionWeight: "",
            prescriptionDuration: "",
            isTimeBased: false,
            isBodyweight: false
        )
        XCTAssertEqual(out.weight, "")
    }

    // MARK: - Bodyweight

    func test_bodyweight_repsOnly_weightStaysEmpty() {
        // Even if a (legacy) weight is present, bodyweight never injects load.
        let s = Suggestion(setIndex: 0, reps: 12, weight: 70, durationSeconds: nil)
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "15",
            prescriptionWeight: "",
            prescriptionDuration: "",
            isTimeBased: false,
            isBodyweight: true
        )
        XCTAssertEqual(out.reps, "12")
        XCTAssertEqual(out.weight, "")
    }

    // MARK: - Time-based

    func test_timeBased_durationOnly() {
        let s = Suggestion(setIndex: 0, reps: 0, weight: nil, durationSeconds: 75)
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "0",
            prescriptionWeight: "",
            prescriptionDuration: "60",
            isTimeBased: true,
            isBodyweight: false
        )
        XCTAssertEqual(out.duration, "75")
        // reps/weight must keep prescription — never prefilled for time-based.
        XCTAssertEqual(out.reps, "0")
        XCTAssertEqual(out.weight, "")
    }

    func test_timeBased_nilDurationFallsBackToPrescription() {
        let s = Suggestion(setIndex: 0, reps: 0, weight: nil, durationSeconds: nil)
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "0",
            prescriptionWeight: "",
            prescriptionDuration: "60",
            isTimeBased: true,
            isBodyweight: false
        )
        XCTAssertEqual(out.duration, "60")
    }

    // MARK: - Carry-down + merge (set-count mismatch)

    func test_carryDownThenMerge_extraSetUsesLastPrior() {
        let map: [Int: Suggestion] = [
            0: Suggestion(setIndex: 0, reps: 8, weight: 80, durationSeconds: nil),
            1: Suggestion(setIndex: 1, reps: 6, weight: 82, durationSeconds: nil),
        ]
        // Routine grew from 2 → 4 sets; current set index 3 carries last prior.
        let s = LastPerformancePrefillService.suggestion(
            forCurrentSetIndex: 3, from: map
        )
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "10",
            prescriptionWeight: "",
            prescriptionDuration: "",
            isTimeBased: false,
            isBodyweight: false
        )
        XCTAssertEqual(out.reps, "6")
        XCTAssertEqual(out.weight, "82")
    }

    func test_carryDownThenMerge_noHistoryFallsBackToPrescription() {
        let s = LastPerformancePrefillService.suggestion(
            forCurrentSetIndex: 0, from: [:]
        )
        let out = resolvedDraftDefault(
            suggestion: s,
            prescriptionReps: "8",
            prescriptionWeight: "",
            prescriptionDuration: "",
            isTimeBased: false,
            isBodyweight: false
        )
        XCTAssertEqual(out.reps, "8")
        XCTAssertEqual(out.weight, "")
    }
}

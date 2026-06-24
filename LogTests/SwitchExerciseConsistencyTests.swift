import SwiftData
import XCTest

@testable import Log

/// Tests for the Entry #11 "Switch Exercise consistency" slice.
///
/// Two behaviors are covered at the unit level:
///   1. `resolvedSwappedValue` — the pure resolver that decides whether an
///      active-workout slot shows the session-start snapshot value
///      (non-swapped) or the live swapped-in exercise value (swapped). This
///      backs both the Equipment & Setup display and the prefill bodyweight
///      classification.
///   2. `LastPerformancePrefillService` resolution by the swapped-in
///      exercise's id — the same service call `refreshLastPerformancePrefill`
///      makes after a swap, proving the switched-in exercise sources ITS OWN
///      history (parent + dropset) and that `excludedFromPrefill` is honored.
///
/// The end-to-end seeding + overwrite-protection on swap lives in
/// `ActiveWorkoutView` SwiftUI `@State` and is exercised via the manual
/// checklist; the resolution contracts those paths depend on are pinned here.
@MainActor
final class SwitchExerciseConsistencyTests: SwiftDataTestHarness {

    private typealias Suggestion =
        LastPerformancePrefillService.LastPerformanceSetSuggestion

    private let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
    private func day(_ d: Double) -> Date {
        referenceDate.addingTimeInterval(d * 86_400)
    }

    // MARK: - resolvedSwappedValue (equipment / setup resolution)

    func test_resolvedValue_nonSwapped_usesSnapshot() {
        // Item 1: a non-swapped slot keeps the session-start snapshot value,
        // even when a (hypothetical) live value differs.
        let equipment = resolvedSwappedValue(
            isSwapped: false, live: "Dumbbell", snapshot: "Barbell")
        XCTAssertEqual(equipment, "Barbell")

        let setup = resolvedSwappedValue(
            isSwapped: false,
            live: "Live setup",
            snapshot: "Snapshot setup")
        XCTAssertEqual(setup, "Snapshot setup")
    }

    func test_resolvedValue_swapped_usesLive() {
        // Item 2: a swapped slot resolves the live swapped-in value.
        let equipment = resolvedSwappedValue(
            isSwapped: true, live: "Dumbbell", snapshot: "Barbell")
        XCTAssertEqual(equipment, "Dumbbell")

        let setup = resolvedSwappedValue(
            isSwapped: true,
            live: "Live setup",
            snapshot: "Snapshot setup")
        XCTAssertEqual(setup, "Live setup")
    }

    func test_resolvedValue_swapped_nilLiveHidesValue() {
        // When the swapped-in exercise has no equipment/setup, the live value
        // is nil and the section's `trimmedOrNil` will hide it (rather than
        // showing the stale snapshot).
        let equipment: String? = resolvedSwappedValue(
            isSwapped: true, live: nil, snapshot: "Barbell")
        XCTAssertNil(equipment)
    }

    func test_resolvedValue_swapped_bodyweightClassificationFollowsLive() {
        // The same resolver drives prefill's bodyweight detection: swapping a
        // weighted lift (snapshot) for a bodyweight movement (live) must
        // classify as bodyweight so prefill seeds reps only.
        let equipment = resolvedSwappedValue(
            isSwapped: true,
            live: bodyweightEquipment,
            snapshot: "Barbell")
        XCTAssertTrue(isBodyweightEquipment(equipment))

        // And the inverse: swapping bodyweight (snapshot) for weighted (live).
        let weighted = resolvedSwappedValue(
            isSwapped: true,
            live: "Barbell",
            snapshot: bodyweightEquipment)
        XCTAssertFalse(isBodyweightEquipment(weighted))
    }

    // MARK: - Input visibility resolution (Bug 2 regression)
    //
    // `resolvedActiveEquipment` (view) feeds both prefill and the set-row
    // `isBodyweight` flag through `resolvedSwappedValue` + `isBodyweightEquipment`.
    // These pin the resolution contract those call sites depend on; the wiring
    // of that result into `SetEntryRow(isBodyweight:)` is SwiftUI and verified
    // via the manual checklist.

    func test_inputVisibility_bodyweightToBarbell_resolvesNonBodyweight() {
        // Item 1: Bodyweight original (snapshot) → Barbell swapped (live).
        // A swapped slot resolves live equipment → not bodyweight → weight
        // field should be shown.
        let resolved = resolvedSwappedValue(
            isSwapped: true,
            live: "Barbell",
            snapshot: bodyweightEquipment)
        XCTAssertFalse(isBodyweightEquipment(resolved))
    }

    func test_inputVisibility_barbellToBodyweight_resolvesBodyweight() {
        // Item 2: Barbell original (snapshot) → Bodyweight swapped (live).
        // A swapped slot resolves live equipment → bodyweight → weight field
        // should be hidden.
        let resolved = resolvedSwappedValue(
            isSwapped: true,
            live: bodyweightEquipment,
            snapshot: "Barbell")
        XCTAssertTrue(isBodyweightEquipment(resolved))
    }

    func test_inputVisibility_nonSwapped_resolvesFromSnapshot() {
        // Item 3: a non-swapped slot keeps the session-start snapshot
        // classification regardless of any live value.
        let bodyweightSlot = resolvedSwappedValue(
            isSwapped: false,
            live: "Barbell",
            snapshot: bodyweightEquipment)
        XCTAssertTrue(isBodyweightEquipment(bodyweightSlot))

        let weightedSlot = resolvedSwappedValue(
            isSwapped: false,
            live: bodyweightEquipment,
            snapshot: "Barbell")
        XCTAssertFalse(isBodyweightEquipment(weightedSlot))
    }

    // MARK: - Dropset support resolution (stale bodyweight Drop Set)
    //
    // The view's `dropsetSupportedActive(for:)` gate is
    // `!isBodyweightEquipment(resolvedActiveEquipment(for:))`, and
    // `resolvedActiveEquipment` is `resolvedSwappedValue(...)`. Bodyweight
    // exercises do not support Drop Set, so a stale Drop Set technique on a
    // Bodyweight-resolved slot must resolve as UNSUPPORTED — suppressing
    // dropset rendering/logging without mutating the template. These pin that
    // resolution contract; the suppression of the actual SwiftUI dropset rows
    // (which all funnel through `dropsetTechniqueApplying`) is manual-only.

    /// Mirror of the view's `dropsetSupportedActive` rule over already-resolved
    /// equipment, so the contract is unit-testable without the private view.
    private func dropsetSupported(resolvedEquipment: String?) -> Bool {
        !isBodyweightEquipment(resolvedEquipment)
    }

    func test_dropset_nonSwappedBodyweight_unsupported() {
        // Item 1: non-swapped Bodyweight with a stale Drop Set technique.
        let resolved = resolvedSwappedValue(
            isSwapped: false, live: "Barbell", snapshot: bodyweightEquipment)
        XCTAssertFalse(dropsetSupported(resolvedEquipment: resolved))
    }

    func test_dropset_nonSwappedBarbell_supported() {
        // Item 2: non-swapped Barbell with Drop Set.
        let resolved = resolvedSwappedValue(
            isSwapped: false, live: bodyweightEquipment, snapshot: "Barbell")
        XCTAssertTrue(dropsetSupported(resolvedEquipment: resolved))
    }

    func test_dropset_barbellToBodyweightSwap_unsupported() {
        // Item 3: Barbell → Bodyweight keep-plan swap suppresses dropset.
        let resolved = resolvedSwappedValue(
            isSwapped: true, live: bodyweightEquipment, snapshot: "Barbell")
        XCTAssertFalse(dropsetSupported(resolvedEquipment: resolved))
    }

    func test_dropset_bodyweightToBarbellSwap_supported() {
        // Item 4: Bodyweight → Barbell keep-plan swap; dropset can render if
        // the kept plan still contains Drop Set.
        let resolved = resolvedSwappedValue(
            isSwapped: true, live: "Barbell", snapshot: bodyweightEquipment)
        XCTAssertTrue(dropsetSupported(resolvedEquipment: resolved))
    }

    // MARK: - History snapshot equipment/setup resolution (Bug fix)
    //
    // `resolvedSnapshotEquipmentSetup` is the pure resolver `populateSnapshotFields`
    // uses to decide which equipment/setup pair is FROZEN into a finished
    // `WorkoutItem.plannedPrescriptionSnapshot`. History reads Equipment & Setup
    // exclusively from that frozen snapshot, so this resolver's output is exactly
    // what History will display. These pin: no-switch keeps the original
    // snapshot; a switch freezes the swapped-in exercise's live metadata (never
    // the original's), across bodyweight↔weighted swaps; and a nil live value
    // hides the field rather than falling back to the stale original.

    func test_historySnapshot_noSwitch_keepsOriginalSnapshot() {
        // Case 1 (no-switch regression): a non-swapped slot freezes the
        // session-start snapshot values, never the (irrelevant) live values.
        let resolved = resolvedSnapshotEquipmentSetup(
            isSwapped: false,
            liveEquipment: "Dumbbell",
            liveSetup: "Live setup",
            snapshotEquipment: "Barbell",
            snapshotSetup: "Original setup")
        XCTAssertEqual(resolved.equipment, "Barbell")
        XCTAssertEqual(resolved.setupNotes, "Original setup")
    }

    func test_historySnapshot_switch_freezesSwappedInMetadata() {
        // Case 2: A → B switch freezes B's live equipment/setup, and crucially
        // does NOT retain Exercise A's snapshot setup.
        let resolved = resolvedSnapshotEquipmentSetup(
            isSwapped: true,
            liveEquipment: "Cable",
            liveSetup: "B setup notes",
            snapshotEquipment: "Barbell",
            snapshotSetup: "A setup notes")
        XCTAssertEqual(resolved.equipment, "Cable")
        XCTAssertEqual(resolved.setupNotes, "B setup notes")
        XCTAssertNotEqual(resolved.setupNotes, "A setup notes")
    }

    func test_historySnapshot_bodyweightToBarbell_freezesBarbell() {
        // Case 3: Bodyweight original → Barbell swapped-in. History should show
        // the switched-in barbell equipment/setup.
        let resolved = resolvedSnapshotEquipmentSetup(
            isSwapped: true,
            liveEquipment: "Barbell",
            liveSetup: "Rack at pin 12",
            snapshotEquipment: bodyweightEquipment,
            snapshotSetup: nil)
        XCTAssertEqual(resolved.equipment, "Barbell")
        XCTAssertFalse(isBodyweightEquipment(resolved.equipment))
        XCTAssertEqual(resolved.setupNotes, "Rack at pin 12")
    }

    func test_historySnapshot_barbellToBodyweight_freezesBodyweight() {
        // Case 4: Barbell original → Bodyweight swapped-in. History should show
        // the switched-in bodyweight equipment/setup.
        let resolved = resolvedSnapshotEquipmentSetup(
            isSwapped: true,
            liveEquipment: bodyweightEquipment,
            liveSetup: "Parallettes",
            snapshotEquipment: "Barbell",
            snapshotSetup: "Bench press setup")
        XCTAssertEqual(resolved.equipment, bodyweightEquipment)
        XCTAssertTrue(isBodyweightEquipment(resolved.equipment))
        XCTAssertEqual(resolved.setupNotes, "Parallettes")
        XCTAssertNotEqual(resolved.setupNotes, "Bench press setup")
    }

    func test_historySnapshot_switchToBlankMetadata_hidesNotStale() {
        // A swapped-in exercise with no equipment/setup resolves to nil so the
        // History row is HIDDEN — it must never fall back to the original
        // exercise's stale metadata.
        let resolved = resolvedSnapshotEquipmentSetup(
            isSwapped: true,
            liveEquipment: nil,
            liveSetup: nil,
            snapshotEquipment: "Barbell",
            snapshotSetup: "Original setup")
        XCTAssertNil(resolved.equipment)
        XCTAssertNil(resolved.setupNotes)
    }

    // MARK: - Fixtures (mirror LastPerformancePrefillServiceTests)

    @discardableResult
    private func makeWorkout(
        date: Date,
        completed: Bool = true,
        excludedFromPrefill: Bool = false
    ) -> Workout {
        let w = Workout(date: date, items: [])
        if completed { w.completedAt = date.addingTimeInterval(3600) }
        w.excludedFromPrefill = excludedFromPrefill
        context.insert(w)
        return w
    }

    private func makeExercise(_ name: String) -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        return ex
    }

    @discardableResult
    private func addWorking(
        to w: Workout,
        exercise: Exercise,
        reps: Int,
        weight: Double
    ) -> WorkoutItem {
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: reps, weight: weight,
            durationSeconds: nil, subIndex: nil)
        context.insert(log)
        item.setLogs = [log]
        context.insert(item)
        w.items.append(item)
        return item
    }

    @discardableResult
    private func addDrop(
        to w: Workout,
        exercise: Exercise,
        reps: Int,
        weight: Double
    ) -> WorkoutItem {
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        let parent = SetLog(
            indexInExercise: 0, kind: .working, reps: reps, weight: weight,
            durationSeconds: nil, subIndex: nil)
        let drop = SetLog(
            indexInExercise: 0, kind: .working, reps: reps, weight: weight / 2,
            durationSeconds: nil, subIndex: 1)
        context.insert(parent)
        context.insert(drop)
        item.setLogs = [parent, drop]
        context.insert(item)
        w.items.append(item)
        return item
    }

    private func allWorkouts() -> [Workout] {
        (try? context.fetch(FetchDescriptor<Workout>())) ?? []
    }

    // MARK: - Switched-exercise prefill resolution

    func test_switchToB_usesBHistory_notA() {
        // Item 3: after switching A → B, prefill resolves by B's id and must
        // NOT pull Exercise A's last performance.
        let a = makeExercise("Bench")
        let b = makeExercise("Incline Press")

        let wa = makeWorkout(date: day(1))
        addWorking(to: wa, exercise: a, reps: 5, weight: 100)
        let wb = makeWorkout(date: day(2))
        addWorking(to: wb, exercise: b, reps: 8, weight: 60)

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: b.id, in: allWorkouts())
        XCTAssertEqual(map[0]?.reps, 8)
        XCTAssertEqual(map[0]?.weight, 60)
    }

    func test_switchToB_noBHistory_fallsBackToEmpty() {
        // If B has never been performed, the slot's suggestion map is empty so
        // seeding falls back to prescription defaults (normal fallback).
        let a = makeExercise("Bench")
        let b = makeExercise("Brand New Lift")

        let wa = makeWorkout(date: day(1))
        addWorking(to: wa, exercise: a, reps: 5, weight: 100)

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: b.id, in: allWorkouts())
        XCTAssertTrue(map.isEmpty)
    }

    func test_switchToB_skipsExcludedFromPrefillWorkouts() {
        // Item 8: a recovery/deload workout for B (excludedFromPrefill) must be
        // skipped, falling back to B's older included workout.
        let b = makeExercise("Incline Press")

        let included = makeWorkout(date: day(1))
        addWorking(to: included, exercise: b, reps: 8, weight: 60)
        let recovery = makeWorkout(date: day(5), excludedFromPrefill: true)
        addWorking(to: recovery, exercise: b, reps: 3, weight: 20)

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: b.id, in: allWorkouts())
        XCTAssertEqual(map[0]?.reps, 8, "Should use older included, not recovery")
        XCTAssertEqual(map[0]?.weight, 60)
    }

    func test_switchToB_dropPrefillUsesBHistory() {
        // Item 6: dropset prefill after a switch resolves by B's id too.
        let a = makeExercise("Bench")
        let b = makeExercise("Incline Press")

        let wa = makeWorkout(date: day(1))
        addDrop(to: wa, exercise: a, reps: 5, weight: 100)
        let wb = makeWorkout(date: day(2))
        addDrop(to: wb, exercise: b, reps: 8, weight: 60)

        let drops = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: b.id, in: allWorkouts())
        XCTAssertEqual(drops[0]?[1]?.reps, 8)
        XCTAssertEqual(drops[0]?[1]?.weight, 30)
    }

    func test_switchToB_dropPrefillSkipsExcludedFromPrefill() {
        // Item 8 (dropset path): excluded workouts are skipped for drops too.
        let b = makeExercise("Incline Press")

        let included = makeWorkout(date: day(1))
        addDrop(to: included, exercise: b, reps: 8, weight: 60)
        let recovery = makeWorkout(date: day(5), excludedFromPrefill: true)
        addDrop(to: recovery, exercise: b, reps: 3, weight: 20)

        let drops = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: b.id, in: allWorkouts())
        XCTAssertEqual(drops[0]?[1]?.reps, 8)
        XCTAssertEqual(drops[0]?[1]?.weight, 30)
    }
}

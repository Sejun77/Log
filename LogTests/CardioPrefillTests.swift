import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 7 — previous-performance prefill for cardio.
///
/// The product rule this file exists to protect: **a target is a plan, a
/// previous distance is evidence.** The routine's target distance says what you
/// meant to do; the last bout says what you actually did. For the field that
/// records what you are about to do, evidence wins — and the target does not
/// disappear, it stays on the plan card where a plan belongs.
///
/// The second rule, equally load-bearing: **setup metrics prefill, outcome
/// metrics do not.** Distance, incline and resistance are decisions you make
/// again. Average heart rate, HR zone and calories are what your body did
/// during one specific bout, and putting them in an empty field would present a
/// number nobody measured as if it had been.
@MainActor
final class CardioPrefillTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    // MARK: - Fixtures

    private func makeExercise(_ name: String = "Treadmill Run") -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        ex.setTimeBased(true)
        ex.setCardio(true)
        return ex
    }

    @discardableResult
    private func completedWorkout(
        exercise: Exercise,
        completedAt: Date = .now,
        excludedFromPrefill: Bool = false,
        logs: [(index: Int, duration: Int, metrics: CardioMetrics)]
    ) -> Workout {
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        context.insert(item)
        for entry in logs {
            let log = SetLog(
                indexInExercise: entry.index, kind: .working, reps: 0,
                weight: nil, durationSeconds: entry.duration)
            context.insert(log)
            log.applyCardioMetrics(entry.metrics)
            item.setLogs.append(log)
        }
        let workout = Workout(date: completedAt, items: [item])
        workout.completedAt = completedAt
        workout.excludedFromPrefill = excludedFromPrefill
        context.insert(workout)
        return workout
    }

    private func allWorkouts() -> [Workout] {
        (try? context.fetch(FetchDescriptor<Workout>())) ?? []
    }

    private func suggestions(for exercise: Exercise)
        -> [Int: CardioPrefillSuggestion]
    {
        CardioPrefillService.suggestions(
            forExerciseID: exercise.id, in: allWorkouts())
    }

    /// The full bout a smoke test would log: setup metrics *and* outcomes.
    private var fullMetrics: CardioMetrics {
        CardioMetrics(
            distanceMeters: 5_000, distanceUnit: km, avgHeartRate: 142,
            calories: 410, inclinePercent: 3, resistanceLevel: 8, hrZone: .z3)
    }

    private func seeded(
        prefill: CardioPrefillSuggestion?, target: CardioTargetDistance?,
        displayUnit: DistanceUnit = .kilometers
    ) -> CardioEntryDraft? {
        CardioDraftResolver.seededDraft(
            prefill: prefill, target: target, displayUnit: displayUnit)
    }

    private func target(_ text: String, _ unit: DistanceUnit = .kilometers)
        -> CardioTargetDistance?
    { CardioTargetDistance(text: text, unit: unit) }

    // MARK: - 1–5. What prefills

    func testPreviousDistancePrefillsInThePreferredUnit() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 5_000, distanceUnit: km))])

        let suggestion = try XCTUnwrap(suggestions(for: ex)[0])
        XCTAssertEqual(try XCTUnwrap(suggestion.distanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(suggestion.distanceUnit, km)

        let draft = try XCTUnwrap(seeded(prefill: suggestion, target: nil))
        XCTAssertEqual(draft.distance, "5")
        XCTAssertEqual(draft.unit, km)
    }

    /// A previous bout logged in miles prefills **converted** into the current
    /// preference: what is being seeded is an editable field whose unit label
    /// comes from Settings, so restating the old unit would mislabel it. The
    /// completed `SetLog` keeps its own unit.
    func testPreviousDistanceInMilesPrefillsInThePreferredUnit() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [
                (0, 1_800,
                 CardioMetrics(distanceMeters: 3.1 * 1_609.344, distanceUnit: mi))
            ])

        // `seeded` defaults to a km display unit.
        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: ex)[0], target: nil))
        XCTAssertEqual(draft.unit, km)
        XCTAssertEqual(draft.distance, "4.99")

        // Read under a miles preference, it comes back as authored.
        let imperial = try XCTUnwrap(
            seeded(
                prefill: suggestions(for: ex)[0], target: nil,
                displayUnit: mi))
        XCTAssertEqual(imperial.unit, mi)
        XCTAssertEqual(imperial.distance, "3.1")
    }

    func testPreviousInclinePrefills() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(inclinePercent: 3))])

        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: ex)[0], target: nil))
        XCTAssertEqual(draft.incline, "3")
    }

    /// Decline is a negative incline and has to survive the sign.
    func testPreviousDeclinePrefills() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(inclinePercent: -3))])

        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: ex)[0], target: nil))
        XCTAssertEqual(draft.incline, "-3")
    }

    func testPreviousResistancePrefills() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(resistanceLevel: 8))])

        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: ex)[0], target: nil))
        XCTAssertEqual(draft.resistance, "8")
    }

    // MARK: - 6–8. What must never prefill

    func testOutcomeMetricsAreDroppedFromTheSuggestion() throws {
        let ex = makeExercise()
        completedWorkout(exercise: ex, logs: [(0, 1_800, fullMetrics)])

        // The type has no field for them at all — dropped by construction, not
        // by a caller remembering to skip them.
        let suggestion = try XCTUnwrap(suggestions(for: ex)[0])
        XCTAssertEqual(try XCTUnwrap(suggestion.distanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(suggestion.inclinePercent, 3)
        XCTAssertEqual(suggestion.resistanceLevel, 8)
    }

    func testHeartRateZoneAndCaloriesNeverReachTheDraft() throws {
        let ex = makeExercise()
        completedWorkout(exercise: ex, logs: [(0, 1_800, fullMetrics)])

        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: ex)[0], target: nil))
        XCTAssertEqual(draft.avgHeartRate, "", "average HR is an outcome")
        XCTAssertEqual(draft.calories, "", "calories are an outcome")
        XCTAssertNil(draft.hrZone, "HR zone is an outcome")
        // …while the setup metrics did come through.
        XCTAssertEqual(draft.distance, "5")
        XCTAssertEqual(draft.incline, "3")
        XCTAssertEqual(draft.resistance, "8")
    }

    /// The metrics the draft would log carry no outcome values either, so
    /// accepting a prefilled row as-is records only what the user re-confirmed.
    func testLoggingAPrefilledDraftRecordsNoOutcomeMetrics() throws {
        let ex = makeExercise()
        completedWorkout(exercise: ex, logs: [(0, 1_800, fullMetrics)])
        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: ex)[0], target: nil))

        let metrics = draft.metrics
        XCTAssertNil(metrics.avgHeartRate)
        XCTAssertNil(metrics.calories)
        XCTAssertNil(metrics.hrZone)
        XCTAssertEqual(try XCTUnwrap(metrics.distanceMeters), 5_000, accuracy: 0.001)
    }

    // MARK: - 9. Invalid stored values

    func testCorruptStoredMetricsAreIgnoredSafely() throws {
        let ex = makeExercise()
        let item = WorkoutItem(exercise: ex, setLogs: [])
        context.insert(item)
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: 0, weight: nil,
            durationSeconds: 1_800)
        context.insert(log)
        // Hand-edited / corrupt columns, bypassing `applyCardioMetrics`.
        log.distanceMeters = -500
        log.distanceUnitRaw = "kilometres"
        log.resistanceLevel = 9_999
        log.inclinePercent = 400
        item.setLogs.append(log)
        let workout = Workout(date: .now, items: [item])
        workout.completedAt = .now
        context.insert(workout)

        XCTAssertTrue(
            suggestions(for: ex).isEmpty,
            "nothing survives normalization, so the set is not a prefill source")
    }

    /// A duration-only bout is a complete, valid cardio log with nothing to
    /// offer here — it must not stop the search at an older usable workout.
    func testDurationOnlyBoutIsNotAPrefillSource() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex, completedAt: .now.addingTimeInterval(-86_400),
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 5_000, distanceUnit: km))])
        completedWorkout(
            exercise: ex, completedAt: .now, logs: [(0, 1_800, CardioMetrics())])

        let suggestion = try XCTUnwrap(suggestions(for: ex)[0])
        XCTAssertEqual(
            try XCTUnwrap(suggestion.distanceMeters), 5_000, accuracy: 0.001,
            "the older usable bout should be found")
    }

    // MARK: - Eligibility (shared with strength prefill)

    func testUnfinishedWorkoutsAreNotPrefillSources() {
        let ex = makeExercise()
        let item = WorkoutItem(exercise: ex, setLogs: [])
        context.insert(item)
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: 0, weight: nil,
            durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(CardioMetrics(distanceMeters: 5_000))
        item.setLogs.append(log)
        let workout = Workout(date: .now, items: [item])  // no completedAt
        context.insert(workout)

        XCTAssertTrue(suggestions(for: ex).isEmpty)
    }

    func testWorkoutsExcludedFromPrefillAreSkipped() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex, completedAt: .now.addingTimeInterval(-86_400),
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 4_000, distanceUnit: km))])
        completedWorkout(
            exercise: ex, completedAt: .now, excludedFromPrefill: true,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 9_000, distanceUnit: km))])

        let suggestion = try XCTUnwrap(suggestions(for: ex)[0])
        XCTAssertEqual(
            try XCTUnwrap(suggestion.distanceMeters), 4_000, accuracy: 0.001,
            "a deload the user excluded must not become the next baseline")
    }

    func testTheCurrentSessionIsExcluded() {
        let ex = makeExercise()
        let workout = completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 5_000))])

        XCTAssertTrue(
            CardioPrefillService.suggestions(
                forExerciseID: ex.id, in: allWorkouts(), excluding: workout.id
            ).isEmpty)
    }

    func testNewestEligibleWorkoutWins() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex, completedAt: .now.addingTimeInterval(-86_400),
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 4_000, distanceUnit: km))])
        completedWorkout(
            exercise: ex, completedAt: .now,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 6_000, distanceUnit: km))])

        XCTAssertEqual(
            try XCTUnwrap(suggestions(for: ex)[0]?.distanceMeters), 6_000,
            accuracy: 0.001)
    }

    func testWarmupAndDropRowsAreNotPrefillSources() {
        let ex = makeExercise()
        let item = WorkoutItem(exercise: ex, setLogs: [])
        context.insert(item)
        let warmup = SetLog(
            indexInExercise: -1, kind: .warmup, reps: 0, weight: nil,
            durationSeconds: 300)
        context.insert(warmup)
        warmup.applyCardioMetrics(CardioMetrics(distanceMeters: 1_000))
        let drop = SetLog(
            indexInExercise: 0, kind: .working, reps: 0, weight: nil,
            durationSeconds: 60, subIndex: 1)
        context.insert(drop)
        drop.applyCardioMetrics(CardioMetrics(distanceMeters: 500))
        item.setLogs.append(contentsOf: [warmup, drop])
        let workout = Workout(date: .now, items: [item])
        workout.completedAt = .now
        context.insert(workout)

        XCTAssertTrue(suggestions(for: ex).isEmpty)
    }

    /// Carry-down mirrors the strength resolver exactly, so the two prefills
    /// never disagree about which previous set a row corresponds to.
    func testCarryDownMatchesTheStrengthResolver() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [
                (0, 600, CardioMetrics(distanceMeters: 1_000, distanceUnit: km)),
                (1, 600, CardioMetrics(distanceMeters: 2_000, distanceUnit: km)),
            ])
        let map = suggestions(for: ex)

        XCTAssertEqual(
            CardioPrefillService.suggestion(forCurrentSetIndex: 0, from: map)?
                .distanceMeters, 1_000)
        XCTAssertEqual(
            CardioPrefillService.suggestion(forCurrentSetIndex: 5, from: map)?
                .distanceMeters, 2_000,
            "beyond the previous count, carry the top set down")
        XCTAssertNil(
            CardioPrefillService.suggestion(forCurrentSetIndex: 0, from: [:]))
    }

    // MARK: - 10 & 11. Previous performance vs. routine target

    func testPreviousDistanceBeatsTheRoutineTarget() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 4_200, distanceUnit: km))])

        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: ex)[0], target: target("5")))
        XCTAssertEqual(
            draft.distance, "4.2",
            "what you actually did beats what the routine planned")
    }

    func testTargetSeedsTheDistanceOnlyWhenThereIsNoPreviousOne() throws {
        // No previous bout at all.
        let draft = try XCTUnwrap(seeded(prefill: nil, target: target("5")))
        XCTAssertEqual(draft.distance, "5")
    }

    /// The mixed case: last time recorded incline but no distance. Incline
    /// comes from the bout, distance falls through to the target.
    func testPrefillWithoutDistanceStillLetsTheTargetSeedDistance() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(inclinePercent: 2, resistanceLevel: 6))])

        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: ex)[0], target: target("5")))
        XCTAssertEqual(draft.distance, "5")
        XCTAssertEqual(draft.incline, "2")
        XCTAssertEqual(draft.resistance, "6")
    }

    func testNoPrefillAndNoTargetSeedsNothing() {
        XCTAssertNil(seeded(prefill: nil, target: nil))
    }

    /// Prefill never writes the plan — the target stays exactly where it was,
    /// visible on the plan card, whatever the draft shows.
    func testPrefillDoesNotTouchTheSessionTarget() throws {
        var plan = SessionPlan()
        plan.usesDuration = true
        plan.targetDistanceMeters = 5_000
        plan.targetDistanceUnitRaw = "km"
        let before = plan

        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 4_200, distanceUnit: km))])
        _ = seeded(
            prefill: suggestions(for: ex)[0],
            target: plan.targetDistance(displayUnit: km))

        XCTAssertEqual(plan, before)
        XCTAssertTrue(plan.primarySummary(distanceUnit: .kilometers).contains("5 km"))
    }

    // MARK: - 12–14. Draft source precedence

    private func source(
        isLogged: Bool = false, hasUserDraft: Bool = false,
        hasPrefillDistance: Bool = false, hasTarget: Bool = false
    ) -> CardioDraftSource {
        CardioDraftResolver.source(
            isLogged: isLogged, hasUserDraft: hasUserDraft,
            hasPrefillDistance: hasPrefillDistance, hasTarget: hasTarget)
    }

    func testPrecedenceChainIsLoggedThenTypedThenPrefillThenTarget() {
        XCTAssertEqual(
            source(
                isLogged: true, hasUserDraft: true, hasPrefillDistance: true,
                hasTarget: true), .logged)
        XCTAssertEqual(
            source(hasUserDraft: true, hasPrefillDistance: true, hasTarget: true),
            .userTyped)
        XCTAssertEqual(
            source(hasPrefillDistance: true, hasTarget: true),
            .previousPerformance)
        XCTAssertEqual(source(hasTarget: true), .targetSeeded)
        XCTAssertEqual(source(), .empty)
    }

    /// A user who cleared the field has still touched it: the store persists an
    /// empty string, so the draft reads as typed and nothing refills it.
    func testAClearedFieldCountsAsUserTyped() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "CardioPrefillTests.cleared"))
        defaults.removePersistentDomain(forName: "CardioPrefillTests.cleared")
        let store = ParentDraftStore(workoutID: UUID(), defaults: defaults)
        let slotID = UUID()
        store.persist(
            slotID: slotID, setIndex: 0,
            cardio: CardioEntryDraft(unit: km, distance: ""))

        let hasUserDraft =
            store.load(slotID: slotID, setIndex: 0)?.hasCardio ?? false
        XCTAssertTrue(hasUserDraft)
        XCTAssertEqual(
            source(
                hasUserDraft: hasUserDraft, hasPrefillDistance: true,
                hasTarget: true),
            .userTyped,
            "a cleared field must not be refilled by prefill or target")
    }

    // MARK: - 23–27. What a target edit may rewrite

    func testTargetEditMayReplaceOnlyItsOwnSeed() {
        XCTAssertTrue(CardioDraftResolver.targetEditMayReplace(.targetSeeded))
        XCTAssertTrue(
            CardioDraftResolver.targetEditMayReplace(.empty),
            "an empty row has nothing worth protecting")
        XCTAssertFalse(
            CardioDraftResolver.targetEditMayReplace(.previousPerformance),
            "evidence of what you did is not the target's to overwrite")
        XCTAssertFalse(CardioDraftResolver.targetEditMayReplace(.userTyped))
        XCTAssertFalse(CardioDraftResolver.targetEditMayReplace(.logged))
    }

    /// Reproduces `applyCardioDraftSeeding`'s resync branch: only a
    /// target-seeded distance moves when the target changes.
    private func resync(
        draft: CardioEntryDraft, source: CardioDraftSource,
        newTarget: CardioTargetDistance?, prefill: CardioPrefillSuggestion?,
        fallbackUnit: DistanceUnit = .kilometers
    ) -> CardioEntryDraft {
        guard CardioDraftResolver.targetEditMayReplace(source) else {
            return draft
        }
        let seeded = CardioDraftResolver.seededDraft(
            prefill: prefill, target: newTarget, displayUnit: fallbackUnit)
        var updated = draft
        updated.unit = seeded?.unit ?? newTarget?.unit ?? fallbackUnit
        updated.distance = seeded?.distance ?? ""
        return updated
    }

    func testTargetEditUpdatesATargetSeededDraft() {
        let updated = resync(
            draft: CardioEntryDraft(unit: km, distance: "5"),
            source: .targetSeeded, newTarget: target("8"), prefill: nil)
        XCTAssertEqual(updated.distance, "8")
    }

    func testTargetEditDoesNotOverwriteAPrefilledDraft() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 4_200, distanceUnit: km))])

        let updated = resync(
            draft: CardioEntryDraft(unit: km, distance: "4.2"),
            source: .previousPerformance, newTarget: target("8"),
            prefill: suggestions(for: ex)[0])
        XCTAssertEqual(updated.distance, "4.2")
    }

    func testTargetEditDoesNotOverwriteAUserTypedDraft() {
        let updated = resync(
            draft: CardioEntryDraft(unit: km, distance: "3.3"),
            source: .userTyped, newTarget: target("8"), prefill: nil)
        XCTAssertEqual(updated.distance, "3.3")
    }

    func testClearingTheTargetClearsOnlyItsOwnSeed() throws {
        let cleared = resync(
            draft: CardioEntryDraft(unit: km, distance: "5"),
            source: .targetSeeded, newTarget: nil, prefill: nil)
        XCTAssertEqual(cleared.distance, "")

        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 4_200, distanceUnit: km))])
        let kept = resync(
            draft: CardioEntryDraft(unit: km, distance: "4.2"),
            source: .previousPerformance, newTarget: nil,
            prefill: suggestions(for: ex)[0])
        XCTAssertEqual(kept.distance, "4.2")

        let typed = resync(
            draft: CardioEntryDraft(unit: km, distance: "3.3"),
            source: .userTyped, newTarget: nil, prefill: nil)
        XCTAssertEqual(typed.distance, "3.3")
    }

    // MARK: - 21 & 22. Resume agrees with live

    /// The full chain run twice — once as a live session, once as a resume —
    /// must land on identical drafts. Resume restores persisted (typed) drafts
    /// first, then seeds the rest from the same precedence chain.
    func testResumeReproducesTheLiveDraftsExactly() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "CardioPrefillTests.resume"))
        defaults.removePersistentDomain(forName: "CardioPrefillTests.resume")
        let store = ParentDraftStore(workoutID: UUID(), defaults: defaults)
        let slotID = UUID()

        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 4_200, distanceUnit: km, inclinePercent: 3))])
        let prefillMap = suggestions(for: ex)
        let routineTarget = target("5")

        func seedAll(into drafts: inout [Int: CardioEntryDraft], setCount: Int) {
            for i in 0..<setCount where drafts[i] == nil {
                let prefill = CardioPrefillService.suggestion(
                    forCurrentSetIndex: i, from: prefillMap)
                let src = CardioDraftResolver.source(
                    isLogged: false,
                    hasUserDraft: store.load(slotID: slotID, setIndex: i)?
                        .hasCardio ?? false,
                    hasPrefillDistance: prefill?.distanceMeters != nil,
                    hasTarget: routineTarget != nil)
                guard src != .userTyped else { continue }
                drafts[i] = CardioDraftResolver.seededDraft(
                    prefill: prefill, target: routineTarget, displayUnit: km)
            }
        }

        // Live: set 0 prefilled, then the user types over set 1.
        var live: [Int: CardioEntryDraft] = [:]
        seedAll(into: &live, setCount: 2)
        let typed = CardioEntryDraft(unit: km, distance: "6.6")
        live[1] = typed
        store.persist(slotID: slotID, setIndex: 1, cardio: typed)

        // Resume: restore persisted drafts, then seed the rest.
        var resumed: [Int: CardioEntryDraft] = [:]
        for i in 0..<2 {
            if let snapshot = store.load(slotID: slotID, setIndex: i),
                let restored = CardioEntryDraft(snapshot: snapshot, displayUnit: km)
            {
                resumed[i] = restored
            }
        }
        seedAll(into: &resumed, setCount: 2)

        XCTAssertEqual(live[0]?.distance, "4.2")
        XCTAssertEqual(live[0]?.incline, "3")
        XCTAssertEqual(live[1]?.distance, "6.6")
        XCTAssertEqual(resumed[0], live[0])
        XCTAssertEqual(resumed[1], live[1])
    }

    // MARK: - 15–20. Switch interaction

    /// Switching to a cardio exercise sources **that** exercise's history, not
    /// the replaced one's — the ordering bug this slice had to fix in
    /// `swapExercise`, where seeding ran before the prefill was re-pointed.
    func testSwitchingIntoCardioPrefillsFromTheNewExercisesHistory() throws {
        let treadmill = makeExercise("Treadmill Run")
        let rower = makeExercise("Rowing Machine")
        completedWorkout(
            exercise: treadmill,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 5_000, distanceUnit: km))])
        completedWorkout(
            exercise: rower,
            logs: [(0, 1_200, CardioMetrics(distanceMeters: 2_000, distanceUnit: km))])

        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: rower)[0], target: nil))
        XCTAssertEqual(
            draft.distance, "2",
            "the switched-in exercise's own history, never the replaced one's")
    }

    func testSwitchingIntoCardioWithNoHistoryFallsBackToTheTarget() throws {
        let fresh = makeExercise("Stair Climber")
        XCTAssertTrue(suggestions(for: fresh).isEmpty)

        let draft = try XCTUnwrap(
            seeded(prefill: suggestions(for: fresh)[0], target: target("3")))
        XCTAssertEqual(draft.distance, "3")
    }

    /// Slice 6's verdict is unchanged and still decides whether drafts survive
    /// at all; prefill only ever fills what that verdict left empty.
    func testSwitchDraftVerdictIsUnchangedBySlice7() {
        let modes: [TrackingMode] = [.strength, .timedHold, .cardio]
        for old in modes {
            for new in modes {
                for choice in [
                    ExerciseSwitchPlanAdapter.Choice.keepCurrentPlan, .resetPlan,
                ] {
                    let keeps = ExerciseSwitchPlanAdapter.outcome(
                        choice: choice, current: SessionPlan(), oldMode: old,
                        newMode: new,
                        resetSource: .appDefaults(for: new)
                    ).keepCardioDrafts
                    XCTAssertEqual(
                        keeps,
                        choice == .keepCurrentPlan && old == .cardio
                            && new == .cardio,
                        "\(old) → \(new) \(choice)")
                }
            }
        }
    }

    /// A kept cardio → cardio draft is not re-seeded over: seeding only fills
    /// entries that are absent.
    func testKeptDraftsAreNotOverwrittenByPrefill() throws {
        let ex = makeExercise()
        completedWorkout(
            exercise: ex,
            logs: [(0, 1_800, CardioMetrics(distanceMeters: 5_000, distanceUnit: km))])

        var drafts: [Int: CardioEntryDraft] = [
            0: CardioEntryDraft(unit: km, distance: "7.7")
        ]
        // Seeding's fill-only branch.
        for i in 0..<1 where drafts[i] == nil {
            drafts[i] = seeded(prefill: suggestions(for: ex)[i], target: nil)
        }
        XCTAssertEqual(drafts[0]?.distance, "7.7")
    }
}

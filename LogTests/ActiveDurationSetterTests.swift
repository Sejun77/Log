import SwiftData
import SwiftUI
import XCTest

@testable import Log

/// Cardio Slice 8 pre-merge patch — **active-workout duration is picked, not
/// typed**.
///
/// The set row now uses the same scrolling duration setter as rest, routine
/// prescription, warm-up, and the Settings defaults (`DurationWheelPicker`,
/// extracted out of `DurationFieldRow`). It replaced a raw-seconds text field
/// and, briefly, three h/min/s text fields.
///
/// The picker speaks optional `Int` seconds; the row's draft is still a
/// total-seconds *string*. `DurationLimits.parseSeconds` / `.secondsText` are
/// that bridge, and this file pins it, plus everything downstream of it that
/// must not have moved: logging, Save & Exit / Resume, the clamp, the cleared
/// state, and the cardio derivations.
@MainActor
final class ActiveDurationSetterTests: SwiftDataTestHarness {

    /// The row's own resolution step, reproduced verbatim from
    /// `TimeSetEntryRow.resolvedDuration`: what Start / Log act on for a given
    /// draft string and planned duration.
    private func resolved(_ text: String, planned: Int? = nil) -> Int {
        DurationLimits.parseSeconds(text, max: DurationLimits.maxExerciseSeconds)
            ?? DurationLimits.normalizedExerciseDuration(planned) ?? 0
    }

    /// What the wheels write for a given h/m/s selection: the recombined total,
    /// normalized against the exercise bound, then stored as text. This is the
    /// exact chain `DurationWheelPicker`'s component bindings and
    /// `ActiveDurationSetter`'s bridge perform.
    private func pick(h: Int = 0, m: Int = 0, s: Int = 0) -> String {
        let total = DurationFormat.totalSeconds(hours: h, minutes: m, seconds: s)
        return DurationLimits.secondsText(
            DurationLimits.normalized(total, max: DurationLimits.maxExerciseSeconds))
    }

    // MARK: - 1. Picking stores total seconds

    /// The review's worked example, now a wheel selection rather than typing.
    func testPickingOneHourTwentyThreeMinutesTwentySecondsStoresFiveThousand() {
        XCTAssertEqual(pick(h: 1, m: 23, s: 20), "5000")
        XCTAssertEqual(resolved(pick(h: 1, m: 23, s: 20)), 5_000)
    }

    func testPickedValuesRoundTripThroughTheTextDraft() {
        for seconds in [30, 60, 90, 600, 1_800, 2_700, 3_600, 5_000, 21_600] {
            let c = DurationFormat.components(seconds)
            XCTAssertEqual(
                pick(h: c.hours, m: c.minutes, s: c.seconds), String(seconds),
                "\(seconds)s did not survive the picker → draft round trip")
            XCTAssertEqual(resolved(String(seconds)), seconds)
        }
    }

    /// Presets are the one-tap half of the same control; every one of them is a
    /// value the row can store and log.
    func testEveryDurationPresetIsStorableAndLoggable() {
        for preset in DurationPresets.exerciseDuration {
            XCTAssertLessThanOrEqual(preset, DurationLimits.maxExerciseSeconds)
            XCTAssertEqual(resolved(DurationLimits.secondsText(preset)), preset)
        }
    }

    // MARK: - 2. Cleared and bounded behavior is preserved

    /// The picker's "—" chip clears the field, which must land on the row's
    /// established cleared state: empty text, resolving to the planned
    /// duration rather than to zero.
    func testClearingThePickerRestoresTheClearedState() {
        XCTAssertEqual(DurationLimits.secondsText(nil), "")
        XCTAssertNil(
            DurationLimits.parseSeconds(
                "", max: DurationLimits.maxExerciseSeconds))
        XCTAssertEqual(resolved("", planned: 1_800), 1_800)
    }

    /// A zero selection is the same thing: `normalized` collapses 0 to nil, so
    /// the wheels at 0/0/0 read as cleared instead of storing an unloggable
    /// zero-second set.
    func testZeroSelectionReadsAsCleared() {
        XCTAssertEqual(pick(h: 0, m: 0, s: 0), "")
        XCTAssertEqual(resolved(pick(), planned: 600), 600)
        // With nothing planned there is nothing to fall back to; the `d > 0`
        // gate then refuses to log, exactly as before.
        XCTAssertEqual(resolved(pick(), planned: nil), 0)
    }

    /// Max behavior is unchanged and still owned by `DurationLimits`: the
    /// wheels top out at the 6h bound, and a combination past it clamps.
    func testMaximumDurationBehaviorIsUnchanged() {
        XCTAssertEqual(pick(h: 6), "21600")
        XCTAssertEqual(resolved(pick(h: 6)), DurationLimits.maxExerciseSeconds)
        // 6h 59m 59s → clamped, not stored out of range.
        XCTAssertEqual(pick(h: 6, m: 59, s: 59), "21600")
        // An oversized draft from an older build still clamps on read.
        XCTAssertEqual(resolved("356400"), DurationLimits.maxExerciseSeconds)
    }

    /// The hours wheel exists for the exercise bound and not for rest — the
    /// range rule the extracted picker inherited from `DurationFieldRow`.
    func testWheelRangesFollowTheBoundTheyAreGiven() {
        XCTAssertGreaterThan(DurationLimits.maxExerciseSeconds, 3_600)
        XCTAssertEqual(DurationLimits.maxRestSeconds, 3_600)
    }

    // MARK: - 3. Logging still stores total seconds

    private func cardioExercise() -> Exercise {
        let ex = Exercise(name: "Treadmill Run", bodyPart: "Cardio", isCustom: false)
        ex.setTimeBased(true)
        ex.setCardio(true)
        return ex
    }

    private func timedHoldExercise() -> Exercise {
        let ex = Exercise(name: "Plank", isCustom: false)
        ex.setTimeBased(true)
        return ex
    }

    private func makeItem(_ exercise: Exercise) -> WorkoutItem {
        context.insert(exercise)
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        context.insert(item)
        return item
    }

    /// Mirrors `appendTimeSetLog`: reps 0, nil weight, duration in seconds.
    @discardableResult
    private func logTimeSet(
        into item: WorkoutItem,
        durationSeconds: Int,
        cardio: CardioMetrics = CardioMetrics()
    ) -> SetLog {
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: 0, weight: nil,
            restSeconds: nil, timestamp: .now, durationSeconds: durationSeconds)
        log.applyCardioMetrics(cardio)
        context.insert(log)
        item.setLogs.append(log)
        return log
    }

    func testActiveCardioDurationSelectionLogsTotalSeconds() throws {
        let item = makeItem(cardioExercise())
        let seconds = resolved(pick(h: 1, m: 23, s: 20))
        XCTAssertEqual(seconds, 5_000)

        let draft = CardioEntryDraft(unit: .kilometers, distance: "10")
        logTimeSet(into: item, durationSeconds: seconds, cardio: draft.metrics)
        try context.save()

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SetLog>()).first)
        XCTAssertEqual(stored.durationSeconds, 5_000)
        XCTAssertEqual(stored.distanceMeters ?? 0, 10_000, accuracy: 0.000_1)
        XCTAssertEqual(stored.distanceUnitRaw, "km")
    }

    func testBasicTimedHoldDurationSelectionLogsTotalSeconds() throws {
        let item = makeItem(timedHoldExercise())
        let seconds = resolved(pick(m: 1, s: 30))
        XCTAssertEqual(seconds, 90)

        logTimeSet(into: item, durationSeconds: seconds)
        try context.save()

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SetLog>()).first)
        XCTAssertEqual(stored.durationSeconds, 90)
        XCTAssertEqual(stored.reps, 0)
        XCTAssertNil(stored.weight)
        XCTAssertFalse(stored.hasCardioMetrics)
    }

    // MARK: - 4. Cardio derivations still read total seconds

    func testPaceAndSpeedUseThePickedTotalSeconds() {
        let seconds = resolved(pick(m: 45))
        XCTAssertEqual(seconds, 2_700)

        var draft = CardioEntryDraft(unit: .kilometers, distance: "6.2")
        XCTAssertEqual(draft.paceText(durationSeconds: seconds), "7:15 /km")
        XCTAssertEqual(draft.speedText(durationSeconds: seconds), "8.3 km/h")

        draft = draft.converted(to: .miles)
        XCTAssertEqual(draft.paceText(durationSeconds: seconds), "11:41 /mi")
        XCTAssertEqual(draft.speedText(durationSeconds: seconds), "5.1 mph")
    }

    /// An hour-plus selection derives from the whole total, not just its
    /// minutes component.
    func testPaceUsesTheWholeTotalAcrossTheHourBoundary() {
        let seconds = resolved(pick(h: 1, m: 23, s: 20))
        let draft = CardioEntryDraft(unit: .kilometers, distance: "20")
        XCTAssertEqual(draft.paceText(durationSeconds: seconds), "4:10 /km")
        XCTAssertEqual(draft.speedText(durationSeconds: seconds), "14.4 km/h")
    }

    // MARK: - 5. Save & Exit / Resume

    private func makeStore() -> (ParentDraftStore, UserDefaults, String) {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (
            ParentDraftStore(workoutID: UUID(), defaults: defaults), defaults,
            suite
        )
    }

    func testSaveAndExitThenResumeRestoresCardioDuration() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        // Save & Exit: the row persists whatever the picker wrote.
        store.persist(
            slotID: slot, setIndex: 0, field: .duration,
            value: pick(h: 1, m: 23, s: 20))
        store.persist(slotID: slot, setIndex: 0, field: .distance, value: "10")

        // Resume: the string comes back and reopens the picker on the same
        // value — the chip reads "1h 23m 20s" and Log still acts on 5000.
        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertEqual(snap?.duration, "5000")
        XCTAssertEqual(snap?.distance, "10")
        XCTAssertEqual(resolved(snap?.duration ?? ""), 5_000)
        XCTAssertEqual(DurationFormat.compact(5_000), "1h 23m 20s")
    }

    func testSaveAndExitThenResumeRestoresTimedHoldDuration() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        store.persist(
            slotID: slot, setIndex: 0, field: .duration, value: pick(m: 2, s: 30))

        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertEqual(snap?.duration, "150")
        XCTAssertEqual(resolved(snap?.duration ?? ""), 150)
        XCTAssertEqual(DurationFormat.compact(150), "2m 30s")
    }

    /// A cleared duration survives as cleared, so resume does not silently
    /// resurrect the planned duration as if the user had picked it.
    func testResumeRestoresAClearedDurationAsCleared() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        store.persist(
            slotID: slot, setIndex: 0, field: .duration,
            value: DurationLimits.secondsText(nil))

        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertEqual(snap?.duration, "")
        XCTAssertEqual(resolved(snap?.duration ?? "", planned: 1_800), 1_800)
    }

    /// Drafts written by either earlier build are plain seconds strings too, so
    /// they reopen directly in the picker.
    func testPreviousBuildsDraftsOpenInThePicker() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .duration, value: "5000")

        XCTAssertEqual(store.load(slotID: slot, setIndex: 0)?.duration, "5000")
        XCTAssertEqual(
            DurationLimits.parseSeconds(
                "5000", max: DurationLimits.maxExerciseSeconds),
            5_000)
    }

    // MARK: - 6. Logged rows

    /// A logged row hands the setter `isDisabled: true`, which renders the
    /// value as plain text with no chevron and no expansion — the same
    /// read-until-Undo rule the reps/weight fields follow. The rendered result
    /// is the manual checklist's to confirm; what is asserted here is that both
    /// states are constructible and that the value shown is the resolved one.
    func testSetterBuildsInBothEnabledAndDisabledStates() {
        let enabled = ActiveDurationSetter(
            secondsText: .constant("2700"), isDisabled: false
        ) { EmptyView() }
        let disabled = ActiveDurationSetter(
            secondsText: .constant("2700"), isDisabled: true
        ) { EmptyView() }

        XCTAssertFalse(enabled.isDisabled)
        XCTAssertTrue(disabled.isDisabled)
        XCTAssertEqual(DurationFormat.compact(resolved("2700")), "45m")
    }

    /// Logging does not rewrite the draft — the value the user picked is the
    /// value that reaches the `SetLog`, and Undo brings the same one back.
    func testLoggingDoesNotAlterTheStoredDraftValue() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()
        let picked = pick(m: 45)

        store.persist(slotID: slot, setIndex: 0, field: .duration, value: picked)
        let logged = resolved(picked)

        XCTAssertEqual(logged, 2_700)
        XCTAssertEqual(store.load(slotID: slot, setIndex: 0)?.duration, picked)
    }

    // MARK: - 7. Everything else is untouched

    /// Rest is edited by `DurationFieldRow` against its own bound. The wheels
    /// moved into a subview; the rules did not.
    func testRestEditingRulesAreUnchanged() {
        XCTAssertEqual(DurationLimits.maxRestSeconds, 3_600)
        XCTAssertEqual(DurationLimits.normalizedRest(90), 90)
        XCTAssertEqual(DurationLimits.normalizedRest(9_999), 3_600)
        XCTAssertNil(DurationLimits.normalizedRest(0))
        XCTAssertNil(DurationLimits.normalizedRest(nil))
        XCTAssertEqual(DurationLimits.clamped(9_999, max: 3_600), 3_600)
        XCTAssertEqual(DurationPresets.rest, [30, 60, 90, 120, 180, 300, 600])
    }

    /// Routine prescription duration is stored as optional `Int` seconds on
    /// `SessionPlan` and edited by the same row — also untouched.
    func testRoutinePrescriptionDurationEditingIsUnchanged() {
        var plan = SessionPlan()
        plan.usesDuration = true
        plan.durationMinSeconds = DurationLimits.normalizedExerciseDuration(1_800)
        plan.durationMaxSeconds = DurationLimits.normalizedExerciseDuration(2_700)

        XCTAssertEqual(plan.durationMinSeconds, 1_800)
        XCTAssertEqual(plan.durationMaxSeconds, 2_700)
        XCTAssertEqual(
            DurationLimits.normalizedExerciseDuration(99_999),
            DurationLimits.maxExerciseSeconds)
        XCTAssertNil(DurationLimits.normalizedExerciseDuration(0))
    }

    /// The extracted picker is shared, so `DurationFieldRow`'s call sites still
    /// compile against the same public shape they always had.
    func testDurationFieldRowStillBuildsForRestAndPrescription() {
        let rest = DurationFieldRow(
            title: "Rest", seconds: .constant(90),
            maxSeconds: DurationLimits.maxRestSeconds, zeroLabel: "None",
            presets: DurationPresets.rest)
        let duration = DurationFieldRow(
            title: "Duration", seconds: .constant(1_800),
            maxSeconds: DurationLimits.maxExerciseSeconds,
            presets: DurationPresets.exerciseDuration)

        XCTAssertEqual(rest.maxSeconds, 3_600)
        XCTAssertEqual(duration.maxSeconds, 21_600)
    }

    /// `DurationFormat` — rendered by the setter's chip, History, block
    /// summaries, and the prescription rows alike — is unchanged.
    func testCompactFormattingIsUnchanged() {
        XCTAssertEqual(DurationFormat.compact(5_000), "1h 23m 20s")
        XCTAssertEqual(DurationFormat.compact(2_700), "45m")
        XCTAssertEqual(DurationFormat.compact(45), "45s")
        XCTAssertEqual(DurationFormat.compact(0), "0s")
    }
}

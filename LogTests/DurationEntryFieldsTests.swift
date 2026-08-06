import SwiftData
import XCTest

@testable import Log

/// Cardio Slice 8 pre-merge patch — **h / min / s duration entry**.
///
/// The active-workout duration field used to be raw seconds: logging a 1:23:20
/// cardio set meant typing "5000" and checking a formatted echo beside it,
/// which also wrapped on narrow rows. The row now shows three fields, and
/// `DurationFieldParts` is the pure translation between them and the
/// total-seconds string the row has always stored.
///
/// The point of this file is that **only the input surface changed**. Storage,
/// the planned-duration fallback, the 6h clamp, the `d > 0` log gate, draft
/// persistence, and the cardio derivations are all asserted against the exact
/// values they produced before the patch.
@MainActor
final class DurationEntryFieldsTests: SwiftDataTestHarness {

    private typealias Parts = DurationFieldParts.Parts

    /// The row's own resolution step, reproduced verbatim from
    /// `TimeSetEntryRow.resolvedDuration`: what Start / Log would act on for a
    /// given field text and planned duration.
    private func resolved(_ text: String, planned: Int? = nil) -> Int {
        DurationLimits.parseSeconds(text, max: DurationLimits.maxExerciseSeconds)
            ?? DurationLimits.normalizedExerciseDuration(planned) ?? 0
    }

    // MARK: - 1. Total seconds → h / min / s

    /// The worked example from the review: 5000s is 1h 23m 20s.
    func testFiveThousandSecondsSplitsIntoOneHourTwentyThreeMinutesTwentySeconds()
    {
        let parts = DurationFieldParts.parts(fromSecondsText: "5000")
        XCTAssertEqual(parts.hours, "1")
        XCTAssertEqual(parts.minutes, "23")
        XCTAssertEqual(parts.seconds, "20")
    }

    /// Zero-valued components render empty, so a 45-minute set reads "45 min"
    /// rather than "0 h 45 min 0 s".
    func testZeroValuedComponentsRenderEmpty() {
        let parts = DurationFieldParts.parts(fromSecondsText: "2700")
        XCTAssertEqual(parts.hours, "")
        XCTAssertEqual(parts.minutes, "45")
        XCTAssertEqual(parts.seconds, "")
    }

    func testWholeHourFillsOnlyTheHoursField() {
        let parts = DurationFieldParts.parts(fromSecondsText: "3600")
        XCTAssertEqual(parts, Parts(hours: "1", minutes: "", seconds: ""))
    }

    func testShortHoldFillsOnlyTheSecondsField() {
        let parts = DurationFieldParts.parts(fromSecondsText: "45")
        XCTAssertEqual(parts, Parts(hours: "", minutes: "", seconds: "45"))
    }

    // MARK: - 2. h / min / s → total seconds

    func testOneHourTwentyThreeMinutesTwentySecondsRecombinesToFiveThousand() {
        let parts = Parts(hours: "1", minutes: "23", seconds: "20")
        XCTAssertEqual(DurationFieldParts.secondsText(from: parts), "5000")
        XCTAssertEqual(DurationFieldParts.totalSeconds(from: parts), 5_000)
    }

    /// A partially filled group is not an error — the blanks count as zero.
    func testPartiallyFilledFieldsTreatBlanksAsZero() {
        XCTAssertEqual(
            DurationFieldParts.secondsText(
                from: Parts(hours: "", minutes: "45", seconds: "")),
            "2700")
        XCTAssertEqual(
            DurationFieldParts.secondsText(
                from: Parts(hours: "2", minutes: "", seconds: "")),
            "7200")
    }

    /// Round trip in both directions for a spread of real values.
    func testRoundTripIsStableForRealisticDurations() {
        for seconds in [1, 30, 45, 60, 90, 600, 1_800, 2_700, 3_600, 5_000, 21_600]
        {
            let text = String(seconds)
            let parts = DurationFieldParts.parts(fromSecondsText: text)
            XCTAssertEqual(
                DurationFieldParts.secondsText(from: parts), text,
                "\(seconds)s did not survive the h/min/s round trip")
        }
    }

    // MARK: - 3. Empty preserves the old cleared behavior

    /// An empty field used to mean "not entered", which the row resolves to the
    /// planned duration rather than to zero. All three fields empty must mean
    /// exactly that — nothing else in the chain changed.
    func testAllEmptyFieldsProduceTheClearedValue() {
        XCTAssertEqual(DurationFieldParts.secondsText(from: .empty), "")
        XCTAssertNil(DurationFieldParts.totalSeconds(from: .empty))
        XCTAssertNil(
            DurationLimits.parseSeconds(
                "", max: DurationLimits.maxExerciseSeconds))
    }

    func testClearedFieldsFallBackToThePlannedDuration() {
        // Old behavior: empty text → planned duration wins.
        XCTAssertEqual(resolved("", planned: 1_800), 1_800)
        // Same input expressed through the fields.
        let cleared = DurationFieldParts.secondsText(from: .empty)
        XCTAssertEqual(resolved(cleared, planned: 1_800), 1_800)
    }

    func testEmptyStoredValueShowsEmptyFields() {
        XCTAssertEqual(DurationFieldParts.parts(fromSecondsText: ""), .empty)
        XCTAssertEqual(DurationFieldParts.parts(fromSecondsText: "   "), .empty)
    }

    /// A stored value that is not a number cannot be split, and must not
    /// invent one — it shows as cleared, exactly as the old field's
    /// `parseSeconds` treated it.
    func testNonNumericStoredValueShowsEmptyFieldsAndDoesNotCrash() {
        for junk in ["abc", "-", "1.5", "99999999999999999999999999"] {
            XCTAssertEqual(
                DurationFieldParts.parts(fromSecondsText: junk), .empty,
                "\(junk) should read as cleared")
            XCTAssertNil(
                DurationLimits.parseSeconds(
                    junk, max: DurationLimits.maxExerciseSeconds))
        }
    }

    /// Non-numeric text typed / pasted into a *field* counts as zero for that
    /// field and never traps — and since something was entered, the group is
    /// no longer "cleared".
    func testNonNumericFieldTextCountsAsZeroWithoutCrashing() {
        let parts = Parts(hours: "abc", minutes: "", seconds: "")
        XCTAssertEqual(DurationFieldParts.secondsText(from: parts), "0")
        XCTAssertEqual(resolved("0", planned: 1_800), 1_800)
    }

    /// A pasted number far past anything the row can log must not overflow the
    /// `hours * 3600` multiply — each component is bounded before recombining,
    /// and the total still clamps at resolution time as it always did.
    func testHugeFieldInputIsBoundedRatherThanOverflowing() {
        let parts = Parts(
            hours: "9999999", minutes: "9999999", seconds: "9999999")
        let total = try? XCTUnwrap(DurationFieldParts.totalSeconds(from: parts))
        XCTAssertGreaterThan(total ?? 0, 0)
        XCTAssertEqual(
            resolved(DurationFieldParts.secondsText(from: parts)),
            DurationLimits.maxExerciseSeconds)
    }

    /// A paste too long to be an `Int` at all is worth 0 for its field, and
    /// still cannot crash or produce a negative.
    func testUnrepresentableFieldInputCountsAsZero() {
        let parts = Parts(
            hours: "999999999999999999999", minutes: "", seconds: "")
        XCTAssertEqual(DurationFieldParts.secondsText(from: parts), "0")
        XCTAssertEqual(resolved("0", planned: 600), 600)
    }

    /// The field filter is digits-only, so a sign or separator cannot reach
    /// the parser at all.
    func testFieldSanitizerKeepsDigitsOnly() {
        XCTAssertEqual(DurationFieldParts.sanitize("-12"), "12")
        XCTAssertEqual(DurationFieldParts.sanitize("1.5"), "15")
        XCTAssertEqual(DurationFieldParts.sanitize("2h"), "2")
        XCTAssertEqual(DurationFieldParts.sanitize("abc"), "")
    }

    // MARK: - 4. Zero preserves the old zero-duration behavior

    /// Typing "0" in the old field produced a value the row refused to log
    /// (`parseSeconds` resolves 0 to nil, and both buttons gate on `d > 0`).
    /// A zero entered across the new fields must land in the same place.
    func testZeroDurationBehavesExactlyAsBefore() {
        let zeroText = DurationFieldParts.secondsText(
            from: Parts(hours: "0", minutes: "0", seconds: "0"))
        XCTAssertEqual(zeroText, "0")
        XCTAssertNil(
            DurationLimits.parseSeconds(
                zeroText, max: DurationLimits.maxExerciseSeconds))
        // With no planned duration there is nothing to fall back to, so the
        // row resolves to 0 and the `d > 0` gate refuses to log — unchanged.
        XCTAssertEqual(resolved(zeroText, planned: nil), 0)
    }

    func testStoredZeroShowsAsZeroInTheSecondsField() {
        XCTAssertEqual(
            DurationFieldParts.parts(fromSecondsText: "0"),
            Parts(hours: "", minutes: "", seconds: "0"))
    }

    // MARK: - 5. Over-limit preserves the old validation behavior

    /// Old: typing "356400" clamped to the 6h bound at resolution time.
    /// New: 99 h in the hours field produces the same string, so it clamps the
    /// same way. The clamp still lives in `DurationLimits`, not in the fields.
    func testOverLimitEntryClampsExactlyAsTheRawSecondsFieldDid() {
        let text = DurationFieldParts.secondsText(
            from: Parts(hours: "99", minutes: "", seconds: ""))
        XCTAssertEqual(text, "356400")
        XCTAssertEqual(resolved(text), DurationLimits.maxExerciseSeconds)
        XCTAssertEqual(resolved("356400"), resolved(text))
    }

    func testValueAtTheBoundIsNotClamped() {
        let text = DurationFieldParts.secondsText(
            from: Parts(hours: "6", minutes: "", seconds: ""))
        XCTAssertEqual(text, "21600")
        XCTAssertEqual(resolved(text), 21_600)
    }

    // MARK: - 6. Logging still stores total seconds

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

    private func makeItem(_ exercise: Exercise) -> WorkoutItem {
        context.insert(exercise)
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        context.insert(item)
        return item
    }

    /// **1 h 23 min 20 s logs as 5000 seconds**, on the `SetLog`, unchanged.
    func testActiveCardioDurationLogsTotalSeconds() throws {
        let item = makeItem(cardioExercise())
        let entered = Parts(hours: "1", minutes: "23", seconds: "20")
        let seconds = resolved(DurationFieldParts.secondsText(from: entered))
        XCTAssertEqual(seconds, 5_000)

        let draft = CardioEntryDraft(unit: .kilometers, distance: "10")
        logTimeSet(into: item, durationSeconds: seconds, cardio: draft.metrics)
        try context.save()

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SetLog>()).first)
        XCTAssertEqual(stored.durationSeconds, 5_000)
        XCTAssertEqual(stored.distanceMeters ?? 0, 10_000, accuracy: 0.000_1)
    }

    /// The timed hold takes the identical path with no cardio draft.
    func testBasicTimeBasedDurationLogsTotalSeconds() throws {
        let item = makeItem(timedHoldExercise())
        let entered = Parts(hours: "", minutes: "1", seconds: "30")
        let seconds = resolved(DurationFieldParts.secondsText(from: entered))
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

    // MARK: - 7. Cardio derivations still read total seconds

    /// Pace and speed are computed from the *total*, so entering across three
    /// fields must produce the same numbers as the old single field did.
    func testPaceAndSpeedUseTheRecombinedTotalSeconds() {
        let seconds = resolved(
            DurationFieldParts.secondsText(
                from: Parts(hours: "", minutes: "45", seconds: "")))
        XCTAssertEqual(seconds, 2_700)

        var draft = CardioEntryDraft(unit: .kilometers, distance: "6.2")
        XCTAssertEqual(draft.paceText(durationSeconds: seconds), "7:15 /km")
        XCTAssertEqual(draft.speedText(durationSeconds: seconds), "8.3 km/h")

        draft = draft.converted(to: .miles)
        XCTAssertEqual(draft.paceText(durationSeconds: seconds), "11:41 /mi")
        XCTAssertEqual(draft.speedText(durationSeconds: seconds), "5.1 mph")
    }

    // MARK: - 8. Save & Exit / Resume

    /// The draft store still round-trips a plain seconds string — the fields
    /// are rebuilt from it on resume, so what the user typed comes back.

    private func makeStore() -> (ParentDraftStore, UserDefaults, String) {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (ParentDraftStore(workoutID: UUID(), defaults: defaults), defaults, suite)
    }

    func testSaveAndExitThenResumeRestoresCardioDuration() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        // Save & Exit: the row persists the recombined total, as always.
        let typed = Parts(hours: "1", minutes: "23", seconds: "20")
        store.persist(
            slotID: slot, setIndex: 0, field: .duration,
            value: DurationFieldParts.secondsText(from: typed))
        store.persist(slotID: slot, setIndex: 0, field: .distance, value: "10")

        // Resume: the stored string comes back, and re-splits into the fields
        // the user left on screen.
        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertEqual(snap?.duration, "5000")
        XCTAssertEqual(snap?.distance, "10")
        XCTAssertEqual(
            DurationFieldParts.parts(fromSecondsText: snap?.duration ?? ""),
            typed)
        XCTAssertEqual(resolved(snap?.duration ?? ""), 5_000)
    }

    func testSaveAndExitThenResumeRestoresBasicTimeBasedDuration() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        let typed = Parts(hours: "", minutes: "2", seconds: "30")
        store.persist(
            slotID: slot, setIndex: 0, field: .duration,
            value: DurationFieldParts.secondsText(from: typed))

        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertEqual(snap?.duration, "150")
        XCTAssertEqual(
            DurationFieldParts.parts(fromSecondsText: snap?.duration ?? ""),
            typed)
        XCTAssertEqual(resolved(snap?.duration ?? ""), 150)
    }

    /// A cleared field survives as cleared, so resume does not silently
    /// resurrect a planned duration as if the user had typed it.
    func testResumeRestoresAClearedDurationAsCleared() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        store.persist(
            slotID: slot, setIndex: 0, field: .duration,
            value: DurationFieldParts.secondsText(from: .empty))

        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertEqual(snap?.duration, "")
        XCTAssertEqual(
            DurationFieldParts.parts(fromSecondsText: snap?.duration ?? ""),
            .empty)
        XCTAssertEqual(resolved(snap?.duration ?? "", planned: 1_800), 1_800)
    }

    /// A draft written by the pre-patch build is a plain seconds string too,
    /// so it opens straight into the new fields.
    func testPrePatchDraftOpensInTheNewFields() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .duration, value: "5000")

        XCTAssertEqual(
            DurationFieldParts.parts(fromSecondsText: "5000"),
            Parts(hours: "1", minutes: "23", seconds: "20"))
        XCTAssertEqual(store.load(slotID: slot, setIndex: 0)?.duration, "5000")
    }

    // MARK: - 9. Everything else is untouched

    /// Strength rows have no duration field at all; their draft fields are
    /// unchanged and never routed through the h/min/s helpers.
    func testStrengthSetRowDraftsAreUnchanged() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .reps, value: "8")
        store.persist(slotID: slot, setIndex: 0, field: .weight, value: "82.5")

        XCTAssertEqual(
            store.load(slotID: slot, setIndex: 0),
            ParentDraftStore.Snapshot(reps: "8", weight: "82.5", duration: nil))
    }

    /// Rest is edited by `DurationFieldRow` (presets + wheels) against its own
    /// bound, and this patch did not touch either.
    func testRestEditingRulesAreUnchanged() {
        XCTAssertEqual(DurationLimits.maxRestSeconds, 3_600)
        XCTAssertEqual(DurationLimits.normalizedRest(90), 90)
        XCTAssertEqual(DurationLimits.normalizedRest(9_999), 3_600)
        XCTAssertNil(DurationLimits.normalizedRest(0))
        XCTAssertNil(DurationLimits.normalizedRest(nil))
        XCTAssertEqual(DurationLimits.clamped(9_999, max: 3_600), 3_600)
    }

    /// Routine prescription duration is stored as optional `Int` seconds on
    /// `SessionPlan` and edited by the same wheel row — also untouched.
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

    /// The h/min/s split is display-only: `DurationFormat` — which the
    /// prescription rows, History, and the plan summary all render through —
    /// still produces its established strings.
    func testCompactFormattingIsUnchanged() {
        XCTAssertEqual(DurationFormat.compact(5_000), "1h 23m 20s")
        XCTAssertEqual(DurationFormat.compact(2_700), "45m")
        XCTAssertEqual(DurationFormat.compact(45), "45s")
        XCTAssertEqual(DurationFormat.compact(0), "0s")
    }
}

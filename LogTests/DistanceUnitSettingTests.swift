import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 8 — the distance-unit preference as a user-facing
/// setting.
///
/// The rule the whole slice rests on: **the preference is a default for new
/// entries, never a reinterpretation of old ones.** Distance is stored
/// canonically in meters with the authored unit beside it, so a run logged in
/// miles reads in miles forever, whatever Settings says today. Half of this
/// file exists to prove the preference *cannot* reach existing data.
///
/// The persistence and locale-default rules themselves were settled in Slice 1
/// and are pinned by `DistanceUnitPreferenceTests` in `CardioMetricsTests`;
/// this file covers what the Settings control changes — entry defaults — and
/// what it must leave alone.
@MainActor
final class DistanceUnitSettingTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    /// The preference is read from `UserDefaults.standard`, so every test saves
    /// and restores it rather than leaking a unit change into the rest of the
    /// suite.
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(
            forKey: AppSettings.Keys.distanceIsMetric)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(
                savedValue, forKey: AppSettings.Keys.distanceIsMetric)
        } else {
            UserDefaults.standard.removeObject(
                forKey: AppSettings.Keys.distanceIsMetric)
        }
        super.tearDown()
    }

    private func selectUnit(_ unit: DistanceUnit) {
        AppSettings.distanceIsMetric = (unit == .kilometers)
    }

    // MARK: - 1–5. What the control writes and reads

    func testSelectingKilometersPersistsAndResolves() {
        selectUnit(km)
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: AppSettings.Keys.distanceIsMetric))
        XCTAssertEqual(AppSettings.distanceUnit, km)
    }

    func testSelectingMilesPersistsAndResolves() {
        selectUnit(mi)
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: AppSettings.Keys.distanceIsMetric))
        XCTAssertEqual(AppSettings.distanceUnit, mi)
    }

    /// The picker survives a relaunch because it is backed by the same
    /// `UserDefaults` key the accessor reads — asserted by reading the key
    /// directly rather than through the accessor that just wrote it.
    func testThePreferenceSurvivesAFreshRead() {
        selectUnit(mi)
        let raw = UserDefaults.standard.object(
            forKey: AppSettings.Keys.distanceIsMetric) as? Bool
        XCTAssertEqual(raw, false)
        XCTAssertEqual(AppSettings.distanceUnit, mi)
    }

    /// The value the Settings picker must use as its `@AppStorage` default.
    ///
    /// **This does not read `SettingsView`** — an `@AppStorage` default lives
    /// inside a SwiftUI view and is unreachable from a test. What it pins is
    /// the value that default has to be: while the key is unset the app
    /// resolves the preference from the locale, so a picker defaulting to a
    /// hardcoded `true` would show "km" to a US tester whose entry fields were
    /// already defaulting to miles. The view's one-line default is
    /// `AppSettings.defaultDistanceIsMetric()`, which is checkable by reading
    /// it; this test pins the function it must call.
    func testUnsetPreferenceResolvesFromTheLocale() {
        UserDefaults.standard.removeObject(
            forKey: AppSettings.Keys.distanceIsMetric)

        XCTAssertEqual(
            AppSettings.distanceIsMetric,
            AppSettings.defaultDistanceIsMetric(),
            "an unset preference must resolve from the locale, and the "
                + "Settings picker's default must be the same expression")
    }

    func testBothUnitsAreOfferedAndNothingElse() {
        XCTAssertEqual(DistanceUnit.allCases, [.kilometers, .miles])
        XCTAssertEqual(DistanceUnit.allCases.map(\.symbol), ["km", "mi"])
    }

    // MARK: - 6–8. New entries default to the preference

    /// A brand-new active-workout cardio draft, with no prefill and no target.
    func testNewCardioDraftDefaultsToThePreference() {
        for unit in [km, mi] {
            selectUnit(unit)
            XCTAssertEqual(CardioEntryDraft(unit: AppSettings.distanceUnit).unit, unit)
        }
    }

    /// The routine editor's target-distance row seeds its picker from the
    /// preference when the slot has no target of its own.
    func testNewRoutineTargetEntryDefaultsToThePreference() {
        let p = SlotPrescription(usesDuration: true)
        context.insert(p)

        for unit in [km, mi] {
            selectUnit(unit)
            let seeded =
                p.targetDistance(fallbackUnit: AppSettings.distanceUnit)?.unit
                ?? AppSettings.distanceUnit
            XCTAssertEqual(seeded, unit)
        }
    }

    /// Same for the active Edit Plan sheet's row.
    func testNewActiveEditPlanTargetEntryDefaultsToThePreference() {
        var plan = SessionPlan()
        plan.usesDuration = true

        for unit in [km, mi] {
            selectUnit(unit)
            let seeded =
                plan.targetDistance(fallbackUnit: AppSettings.distanceUnit)?.unit
                ?? AppSettings.distanceUnit
            XCTAssertEqual(seeded, unit)
        }
    }

    /// An unparseable stored unit falls back to the preference rather than
    /// dropping the distance — the value is canonical meters, so the number is
    /// right in whichever unit renders it.
    func testUnparseableStoredUnitFallsBackToThePreference() throws {
        let p = SlotPrescription(usesDuration: true)
        context.insert(p)
        p.targetDistanceMeters = 5_000
        p.targetDistanceUnitRaw = "kilometres"

        selectUnit(mi)
        let target = try XCTUnwrap(
            p.targetDistance(fallbackUnit: AppSettings.distanceUnit))
        XCTAssertEqual(target.unit, mi)
        XCTAssertEqual(target.meters, 5_000, accuracy: 0.001)
    }

    // MARK: - 9 & 10. The preference cannot reach stored data

    func testChangingThePreferenceDoesNotRewriteALoggedSetsUnit() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        selectUnit(mi)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: 3.1 * 1_609.344, distanceUnit: mi))
        try context.save()

        selectUnit(km)

        XCTAssertEqual(log.distanceUnitRaw, "mi")
        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), 3.1 * 1_609.344, accuracy: 0.001)
    }

    func testChangingThePreferenceDoesNotRewriteARoutineTargetUnit() throws {
        let p = SlotPrescription(usesDuration: true)
        context.insert(p)
        selectUnit(mi)
        p.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))
        try context.save()

        selectUnit(km)

        XCTAssertEqual(p.targetDistanceUnitRaw, "mi")
        XCTAssertEqual(
            p.targetDistance(fallbackUnit: km)?.unit, mi,
            "the stored unit must win over the preference")
    }

    /// The same guarantee for a frozen session snapshot, which History reads.
    func testChangingThePreferenceDoesNotRewriteASnapshotUnit() throws {
        let source = SlotPrescription(usesDuration: true)
        context.insert(source)
        selectUnit(mi)
        source.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))
        let snapshot = PlannedPrescriptionSnapshot(from: source, exercise: nil)
        context.insert(snapshot)
        try context.save()

        selectUnit(km)

        XCTAssertEqual(snapshot.targetDistanceUnitRaw, "mi")
        XCTAssertEqual(snapshot.targetDistance(fallbackUnit: km)?.unit, mi)
    }

    // MARK: - 11 & 12. Prefill and target seeding keep their own unit

    func testPreviousPerformancePrefillKeepsThePerformedUnit() throws {
        let suggestion = CardioPrefillSuggestion(
            setIndex: 0, distanceMeters: 3.1 * 1_609.344, distanceUnit: mi,
            inclinePercent: nil, resistanceLevel: nil)

        selectUnit(km)
        let draft = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: suggestion, target: nil,
                fallbackUnit: AppSettings.distanceUnit))

        XCTAssertEqual(
            draft.unit, mi,
            "what you ran last time was miles — the preference does not restate it")
        XCTAssertEqual(draft.distance, "3.1")
    }

    func testTargetFallbackKeepsTheTargetUnit() throws {
        selectUnit(km)
        let target = try XCTUnwrap(CardioTargetDistance(text: "3.1", unit: mi))
        let draft = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: nil, target: target,
                fallbackUnit: AppSettings.distanceUnit))

        XCTAssertEqual(draft.unit, mi)
        XCTAssertEqual(draft.distance, "3.1")
    }

    /// With neither source, the preference is what a fresh field starts in.
    func testSeedingWithNeitherSourceUsesThePreference() {
        for unit in [km, mi] {
            selectUnit(unit)
            XCTAssertNil(
                CardioDraftResolver.seededDraft(
                    prefill: nil, target: nil,
                    fallbackUnit: AppSettings.distanceUnit),
                "nothing to seed — the row stays untouched and empty")
            XCTAssertEqual(AppSettings.distanceUnit, unit)
        }
    }

    /// A prefill carrying incline but no distance still lets the *target's*
    /// unit through, not the preference.
    func testMixedPrefillAndTargetKeepsTheTargetUnit() throws {
        let suggestion = CardioPrefillSuggestion(
            setIndex: 0, distanceMeters: nil, distanceUnit: nil,
            inclinePercent: 3, resistanceLevel: nil)

        selectUnit(km)
        let draft = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: suggestion,
                target: CardioTargetDistance(text: "3.1", unit: mi),
                fallbackUnit: AppSettings.distanceUnit))

        XCTAssertEqual(draft.unit, mi)
        XCTAssertEqual(draft.incline, "3")
    }

    // MARK: - 13–15. Display reads the row, not the preference

    func testHistoryRendersTheStoredSetLogUnit() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: 1_609.344, distanceUnit: mi))
        try context.save()

        selectUnit(km)

        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(
                for: log, fallbackUnit: AppSettings.distanceUnit),
            ["1 mi · 30:00 /mi"],
            "a bout logged in miles reads in miles whatever Settings says")
    }

    func testRoutineSummaryRendersTheStoredTargetUnit() throws {
        let ex = Exercise(name: "Treadmill Run", isCustom: true)
        context.insert(ex)
        ex.setTimeBased(true)
        ex.setCardio(true)

        let p = SlotPrescription(usesDuration: true)
        p.sets = 1
        p.durationMaxSeconds = 1_800
        context.insert(p)
        p.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p
        let block = RoutineBlock(
            isSuperset: false, order: 0, restAfterSeconds: nil, exercises: [re])
        context.insert(block)
        try context.save()

        selectUnit(km)

        XCTAssertEqual(
            BlockPrescriptionSummary(
                block: block, fallbackUnit: AppSettings.distanceUnit
            ).subtitle,
            "1 × 1800s · 3.1 mi")
    }

    func testSessionPlanSummaryRendersTheStoredTargetUnit() {
        var plan = SessionPlan()
        plan.sets = 1
        plan.usesDuration = true
        plan.targetDistanceMeters = 1_609.344
        plan.targetDistanceUnitRaw = "mi"

        selectUnit(km)
        XCTAssertTrue(plan.primarySummary.contains("1 mi"))
    }

    /// The pace label follows the unit the row is being read in, so a miles row
    /// says min/mi even while the preference is km.
    func testPaceLabelFollowsTheRowUnitNotThePreference() {
        selectUnit(km)
        XCTAssertEqual(mi.paceFieldLabel, "Pace (min/mi)")
        XCTAssertEqual(km.paceFieldLabel, "Pace (min/km)")

        selectUnit(mi)
        XCTAssertEqual(km.paceFieldLabel, "Pace (min/km)")
    }

    /// End to end: a miles bout logged under a miles preference still reads in
    /// miles — value, unit and pace — after the preference flips to km.
    func testAMilesBoutSurvivesAPreferenceFlipIntact() throws {
        selectUnit(mi)
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: 3.1 * 1_609.344, distanceUnit: mi,
                inclinePercent: 2))
        try context.save()
        let before = CardioHistorySummary.secondaryLines(
            for: log, fallbackUnit: AppSettings.distanceUnit)

        selectUnit(km)
        let after = CardioHistorySummary.secondaryLines(
            for: log, fallbackUnit: AppSettings.distanceUnit)

        XCTAssertEqual(before, after)
        XCTAssertTrue(try XCTUnwrap(after.first).contains("mi"))
    }
}

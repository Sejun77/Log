import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 8 — the distance unit as a **Settings-only**
/// preference.
///
/// The rule the whole slice rests on, as revised before merge: **a target is a
/// plan and has no unit of its own; a performed set is a record and keeps the
/// unit it was run in.** Settings is the single control. Distance is stored
/// canonically in meters throughout, so switching the preference re-expresses
/// every target distance and moves no stored value.
///
/// What this replaced: the slice originally shipped per-target km/mi pickers in
/// the routine prescription editor and the active Edit Plan sheet, which let a
/// routine prescription override the Settings preference — two controls for one
/// concept, with the narrower one winning. Those pickers are gone. Roughly half
/// of this file exists to prove the stored `targetDistanceUnitRaw` they used to
/// write can no longer reach the display path, and the other half to prove the
/// preference still cannot reach *performed* data.
///
/// The persistence and locale-default rules themselves were settled in Slice 1
/// and are pinned by `DistanceUnitPreferenceTests` in `CardioMetricsTests`.
///
/// **On the UI assertions.** `TargetDistanceRow` and `SessionTargetDistanceRow`
/// are `View`s and cannot be instantiated in a unit test, so "the row has no
/// unit picker" is not directly assertable. What is assertable — and what those
/// pickers actually did — is the read path they fed: every target accessor now
/// takes a `displayUnit:` and there is no parameter, stored column, or overload
/// through which a per-target unit could win. Those tests are marked below.
@MainActor
final class DistanceUnitSettingTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    /// 5 km and 3.1 mi in meters — the two canonical values used throughout.
    private let fiveKmInMeters = 5_000.0
    private let threePointOneMilesInMeters = 3.1 * 1_609.344

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

    /// A cardio slot prescription, inserted, with an optional target.
    private func cardioPrescription(
        meters: Double? = nil, unitRaw: String? = nil
    ) -> SlotPrescription {
        let p = SlotPrescription(usesDuration: true)
        p.sets = 1
        p.durationMaxSeconds = 1_800
        context.insert(p)
        p.targetDistanceMeters = meters
        p.targetDistanceUnitRaw = unitRaw
        return p
    }

    /// A one-exercise block wrapping `prescription`, for summary assertions.
    private func block(with prescription: SlotPrescription) throws
        -> RoutineBlock
    {
        let ex = Exercise(name: "Treadmill Run", isCustom: true)
        context.insert(ex)
        ex.setTimeBased(true)
        ex.setCardio(true)

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = prescription

        let b = RoutineBlock(
            isSuperset: false, order: 0, restAfterSeconds: nil, exercises: [re])
        context.insert(b)
        try context.save()
        return b
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

    /// The routine editor's target-distance row seeds from the preference when
    /// the slot has no target of its own.
    func testNewRoutineTargetEntryDefaultsToThePreference() {
        let p = cardioPrescription()

        for unit in [km, mi] {
            selectUnit(unit)
            let seeded =
                p.targetDistance(displayUnit: AppSettings.distanceUnit)?.unit
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
                plan.targetDistance(displayUnit: AppSettings.distanceUnit)?.unit
                ?? AppSettings.distanceUnit
            XCTAssertEqual(seeded, unit)
        }
    }

    // MARK: - Settings is the only distance-unit control
    //
    // Requirements 1, 2, 10 and 11 of the patch: no per-target unit override
    // anywhere on the routine or active-plan target path.

    /// **Requirements 1 and 10.** The routine target read path exposes exactly
    /// one unit input — the caller's `displayUnit:` — and the stored
    /// `targetDistanceUnitRaw` the removed picker used to write cannot override
    /// it, whatever it holds.
    func testRoutineTargetDisplayHasNoPerTargetUnitOverride() throws {
        for raw in ["km", "mi", "kilometres", "", nil] as [String?] {
            let p = cardioPrescription(meters: fiveKmInMeters, unitRaw: raw)

            selectUnit(km)
            let metric = try XCTUnwrap(
                p.targetDistance(displayUnit: AppSettings.distanceUnit))
            XCTAssertEqual(metric.unit, km, "raw \(raw ?? "nil")")
            XCTAssertEqual(metric.displayText, "5 km", "raw \(raw ?? "nil")")

            selectUnit(mi)
            let imperial = try XCTUnwrap(
                p.targetDistance(displayUnit: AppSettings.distanceUnit))
            XCTAssertEqual(imperial.unit, mi, "raw \(raw ?? "nil")")
            XCTAssertEqual(imperial.displayText, "3.11 mi", "raw \(raw ?? "nil")")
        }
    }

    /// **Requirements 2 and 11.** The same guarantee for the active Edit Plan
    /// sheet's target, which reads through `SessionPlan`.
    func testActivePlanTargetDisplayHasNoPerTargetUnitOverride() throws {
        for raw in ["km", "mi", "kilometres", "", nil] as [String?] {
            var plan = SessionPlan()
            plan.usesDuration = true
            plan.targetDistanceMeters = fiveKmInMeters
            plan.targetDistanceUnitRaw = raw

            selectUnit(km)
            let metric = try XCTUnwrap(
                plan.targetDistance(displayUnit: AppSettings.distanceUnit))
            XCTAssertEqual(metric.displayText, "5 km", "raw \(raw ?? "nil")")

            selectUnit(mi)
            let imperial = try XCTUnwrap(
                plan.targetDistance(displayUnit: AppSettings.distanceUnit))
            XCTAssertEqual(imperial.displayText, "3.11 mi", "raw \(raw ?? "nil")")
        }
    }

    /// The frozen snapshot a running workout reads is no different: its
    /// *meters* are frozen, its unit is not.
    func testSnapshotTargetDisplayFollowsThePreference() throws {
        let source = cardioPrescription()
        selectUnit(mi)
        source.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))
        let snapshot = PlannedPrescriptionSnapshot(from: source, exercise: nil)
        context.insert(snapshot)
        try context.save()

        XCTAssertEqual(
            snapshot.targetDistance(displayUnit: mi)?.displayText, "3.1 mi")

        selectUnit(km)
        XCTAssertEqual(
            snapshot.targetDistance(displayUnit: AppSettings.distanceUnit)?
                .displayText,
            "4.99 km")
        XCTAssertEqual(
            try XCTUnwrap(snapshot.targetDistanceMeters),
            threePointOneMilesInMeters, accuracy: 0.001,
            "the frozen distance itself must not move")
    }

    /// **Requirement 3.** Routine target display follows Settings, read through
    /// the resolver the active workout actually uses.
    func testResolvedPlannedTargetFollowsThePreference() throws {
        var plan = SessionPlan()
        plan.usesDuration = true
        plan.targetDistanceMeters = fiveKmInMeters
        plan.targetDistanceUnitRaw = "mi"

        selectUnit(km)
        XCTAssertEqual(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: plan, snapshot: nil,
                displayUnit: AppSettings.distanceUnit)?.displayText,
            "5 km")

        selectUnit(mi)
        XCTAssertEqual(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: plan, snapshot: nil,
                displayUnit: AppSettings.distanceUnit)?.displayText,
            "3.11 mi")
    }

    // MARK: - Changing the preference converts display, not data
    //
    // Requirements 6, 7 and 8.

    /// **Requirement 6.** km → mi converts the displayed target and leaves the
    /// stored meters exactly where they were.
    func testChangingThePreferenceKmToMiConvertsDisplayOnly() throws {
        selectUnit(km)
        let p = cardioPrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "5", unit: km))
        try context.save()

        let storedBefore = try XCTUnwrap(p.targetDistanceMeters)
        XCTAssertEqual(
            p.targetDistance(displayUnit: AppSettings.distanceUnit)?.displayText,
            "5 km")

        selectUnit(mi)

        XCTAssertEqual(
            p.targetDistance(displayUnit: AppSettings.distanceUnit)?.displayText,
            "3.11 mi",
            "the same target must re-read in the new preference")
        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters), storedBefore,
            "the stored meters must not move")
        XCTAssertEqual(try XCTUnwrap(p.targetDistanceMeters), 5_000)
    }

    /// **Requirement 7.** mi → km, the mirror case.
    func testChangingThePreferenceMiToKmConvertsDisplayOnly() throws {
        selectUnit(mi)
        let p = cardioPrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))
        try context.save()

        let storedBefore = try XCTUnwrap(p.targetDistanceMeters)
        XCTAssertEqual(
            p.targetDistance(displayUnit: AppSettings.distanceUnit)?.displayText,
            "3.1 mi")

        selectUnit(km)

        XCTAssertEqual(
            p.targetDistance(displayUnit: AppSettings.distanceUnit)?.displayText,
            "4.99 km")
        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters), storedBefore,
            "the stored meters must not move")
        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters),
            threePointOneMilesInMeters, accuracy: 0.001)
    }

    /// **Requirement 8, the sharp edge.** The displayed value is *rounded*
    /// ("4.99 km" for 4988.9664 m), so re-seeding a field on a preference
    /// change must not write that text back — doing so would round the user's
    /// stored distance every time they toggled a setting in another screen.
    /// The rows re-seed without committing; this pins the invariant that makes
    /// that necessary.
    func testChangingThePreferenceDoesNotRewriteStoredMeters() throws {
        selectUnit(mi)
        let p = cardioPrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))
        try context.save()

        selectUnit(km)
        let reseeded = try XCTUnwrap(
            p.targetDistance(displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(reseeded.valueText, "4.99")

        // What committing the re-seeded text *would* store, had the row done
        // it — deliberately different from what is actually stored.
        let ifRecommitted = try XCTUnwrap(
            CardioTargetDistance(text: try XCTUnwrap(reseeded.valueText), unit: km))
        XCTAssertEqual(ifRecommitted.meters, 4_990, accuracy: 0.001)
        XCTAssertNotEqual(
            try XCTUnwrap(p.targetDistanceMeters), ifRecommitted.meters,
            "a display-only change must never round the stored distance")
        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters),
            threePointOneMilesInMeters, accuracy: 0.001)
    }

    // MARK: - Saving stores canonical meters
    //
    // Requirements 5, 9 and 11 (what gets written).

    /// **Requirement 8 of the behavior list.** A target entered in km stores
    /// meters, and records km as the entry unit for compatibility.
    func testSavingATargetInKilometersStoresCanonicalMeters() throws {
        selectUnit(km)
        let p = cardioPrescription()
        p.applyTargetDistance(
            CardioTargetDistance(text: "5", unit: AppSettings.distanceUnit))
        try context.save()

        XCTAssertEqual(try XCTUnwrap(p.targetDistanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(
            p.targetDistanceUnitRaw, "km",
            "the current Settings unit is what gets written")
    }

    /// **Requirement 9 of the behavior list.** The same in miles — the number
    /// the user typed is converted to meters, not stored as-is.
    func testSavingATargetInMilesStoresCanonicalMeters() throws {
        selectUnit(mi)
        let p = cardioPrescription()
        p.applyTargetDistance(
            CardioTargetDistance(text: "3.1", unit: AppSettings.distanceUnit))
        try context.save()

        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters), threePointOneMilesInMeters,
            accuracy: 0.001)
        XCTAssertNotEqual(
            try XCTUnwrap(p.targetDistanceMeters), 3.1,
            "the typed number is not the stored number")
        XCTAssertEqual(p.targetDistanceUnitRaw, "mi")
    }

    /// The same distance authored under either preference is the same stored
    /// value — which is what makes the preference safe to change at all.
    func testTheSameDistanceStoresIdenticallyUnderEitherPreference() throws {
        selectUnit(km)
        let metric = cardioPrescription()
        metric.applyTargetDistance(
            CardioTargetDistance(text: "1.609344", unit: AppSettings.distanceUnit))

        selectUnit(mi)
        let imperial = cardioPrescription()
        imperial.applyTargetDistance(
            CardioTargetDistance(text: "1", unit: AppSettings.distanceUnit))

        XCTAssertEqual(
            try XCTUnwrap(metric.targetDistanceMeters),
            try XCTUnwrap(imperial.targetDistanceMeters),
            accuracy: 0.01)
    }

    // MARK: - Summaries follow the preference
    //
    // Requirements 4, 12 and 13.

    /// **Requirement 4 / 12.** The routine editor's block subtitle.
    func testRoutineSummaryFollowsThePreference() throws {
        selectUnit(mi)
        let p = cardioPrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))
        let b = try block(with: p)

        XCTAssertEqual(
            BlockPrescriptionSummary(
                block: b, displayUnit: AppSettings.distanceUnit).subtitle,
            "1 × 1800s · 3.1 mi")

        selectUnit(km)

        XCTAssertEqual(
            BlockPrescriptionSummary(
                block: b, displayUnit: AppSettings.distanceUnit).subtitle,
            "1 × 1800s · 4.99 km",
            "the summary must follow Settings, not targetDistanceUnitRaw")
        XCTAssertEqual(
            p.targetDistanceUnitRaw, "mi",
            "…while the stored raw unit is left alone")
    }

    /// The precomputed map the routine editor actually renders from takes the
    /// preference too, so the two paths cannot diverge.
    func testRoutineSummaryMapFollowsThePreference() throws {
        selectUnit(km)
        let p = cardioPrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "5", unit: km))
        let b = try block(with: p)

        selectUnit(mi)
        let map = BlockPrescriptionSummary.map(
            for: [b], displayUnit: AppSettings.distanceUnit)
        XCTAssertEqual(map[b.slotID]?.subtitle, "1 × 1800s · 3.11 mi")
    }

    /// **Requirement 5 / 13.** The active workout's Plan card line.
    func testActivePlanSummaryFollowsThePreference() {
        var plan = SessionPlan()
        plan.sets = 1
        plan.usesDuration = true
        plan.targetDistanceMeters = 1_609.344
        plan.targetDistanceUnitRaw = "mi"

        selectUnit(mi)
        XCTAssertTrue(
            plan.primarySummary(distanceUnit: AppSettings.distanceUnit)
                .contains("1 mi"))

        selectUnit(km)
        let metric = plan.primarySummary(distanceUnit: AppSettings.distanceUnit)
        XCTAssertTrue(
            metric.contains("1.61 km"),
            "expected a km summary, got \"\(metric)\"")
        XCTAssertFalse(metric.contains("mi"))
    }

    // MARK: - Draft seeding
    //
    // Requirements 14 and 15.

    /// **Requirement 12 of the test list.** A target seeded into an untouched
    /// cardio draft arrives in the Settings unit, because the target itself is
    /// read in that unit.
    func testTargetFallbackIntoTheDraftUsesThePreference() throws {
        for unit in [km, mi] {
            selectUnit(unit)
            let p = cardioPrescription(meters: fiveKmInMeters, unitRaw: "mi")
            let target = try XCTUnwrap(
                p.targetDistance(displayUnit: AppSettings.distanceUnit))

            let draft = try XCTUnwrap(
                CardioDraftResolver.seededDraft(
                    prefill: nil, target: target,
                    displayUnit: AppSettings.distanceUnit))

            XCTAssertEqual(
                draft.unit, unit,
                "a target-seeded draft follows Settings, not the stored raw")
        }

        // And the value converts with it.
        selectUnit(mi)
        let p = cardioPrescription(meters: fiveKmInMeters, unitRaw: "km")
        let draft = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: nil,
                target: p.targetDistance(displayUnit: AppSettings.distanceUnit),
                displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(draft.distance, "3.11")
    }

    /// Previous-performance prefill **converts** the previous bout's stored
    /// meters into the current preference.
    ///
    /// This is the second patch's change: what is being seeded is an editable
    /// field whose unit label comes from Settings, so restating the performed
    /// unit would put "3.1" under a "km" label. The `SetLog` the suggestion
    /// came from is not touched, and History still renders it in miles — see
    /// `testHistoryRendersTheStoredSetLogUnit`.
    func testPreviousPerformancePrefillConvertsIntoThePreferredUnit() throws {
        let suggestion = CardioPrefillSuggestion(
            setIndex: 0, distanceMeters: threePointOneMilesInMeters,
            distanceUnit: mi, inclinePercent: nil, resistanceLevel: nil)

        selectUnit(km)
        let metric = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: suggestion, target: nil,
                displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(metric.unit, km)
        XCTAssertEqual(
            metric.distance, "4.99",
            "the stored meters convert; the performed unit does not carry over")

        selectUnit(mi)
        let imperial = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: suggestion, target: nil,
                displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(imperial.unit, mi)
        XCTAssertEqual(imperial.distance, "3.1")
    }

    /// **Requirements 2, 3, 4 and 5 of the second patch.** The performed
    /// distance field itself: a value typed under a preference is parsed in
    /// that preference, stored as canonical meters, and stamped with that
    /// preference as `distanceUnitRaw`.
    func testPerformedDistanceEntryUsesThePreference() throws {
        // Settings km: "5" means 5 km.
        selectUnit(km)
        var draft = CardioEntryDraft(
            unit: AppSettings.distanceUnit, distance: "5")
        XCTAssertEqual(draft.unit, km)

        var log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(draft.metrics)
        try context.save()

        XCTAssertEqual(try XCTUnwrap(log.distanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(log.distanceUnitRaw, "km")

        // Settings mi: the same "5" means 5 miles, and stores as such.
        selectUnit(mi)
        draft = CardioEntryDraft(unit: AppSettings.distanceUnit, distance: "5")
        XCTAssertEqual(draft.unit, mi)

        log = SetLog(
            indexInExercise: 1, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(draft.metrics)
        try context.save()

        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), 5 * 1_609.344, accuracy: 0.001)
        XCTAssertEqual(
            log.distanceUnitRaw, "mi",
            "distanceUnitRaw is stamped from Settings at log time")
    }

    /// **Requirement 1 of the second patch.** The Details row's distance field
    /// has no unit override left to consult.
    ///
    /// `CardioDetailsSection` is a `View` and cannot be instantiated here, so
    /// what is asserted is the contract the removed picker used to mutate:
    /// `CardioEntryDraft.unit` is whatever the caller passes, and every path
    /// that builds a draft — fresh, resumed, prefilled, target-seeded, or
    /// re-read from a logged set — passes the preference and converts to it.
    func testPerformedDistanceHasNoPerFieldUnitOverride() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: fiveKmInMeters, distanceUnit: km))
        try context.save()

        for unit in [km, mi] {
            selectUnit(unit)
            let display = AppSettings.distanceUnit

            XCTAssertEqual(CardioEntryDraft(unit: display).unit, unit)
            XCTAssertEqual(
                CardioEntryDraft(logged: log, displayUnit: display).unit, unit,
                "a logged set re-reads in the preference, not its stored unit")
            XCTAssertEqual(
                CardioDraftResolver.seededDraft(
                    prefill: CardioPrefillSuggestion(
                        setIndex: 0, distanceMeters: fiveKmInMeters,
                        distanceUnit: km, inclinePercent: nil,
                        resistanceLevel: nil),
                    target: nil, displayUnit: display)?.unit,
                unit)
        }

        // …while the stored log keeps what it was logged with.
        XCTAssertEqual(log.distanceUnitRaw, "km")
    }

    /// A prefill carrying incline but no distance falls through to the target,
    /// which means the preference — the prefill has no distance to preserve.
    func testMixedPrefillAndTargetUsesThePreference() throws {
        let suggestion = CardioPrefillSuggestion(
            setIndex: 0, distanceMeters: nil, distanceUnit: nil,
            inclinePercent: 3, resistanceLevel: nil)

        selectUnit(km)
        let draft = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: suggestion,
                target: CardioTargetDistance(
                    meters: threePointOneMilesInMeters,
                    displayUnit: AppSettings.distanceUnit),
                displayUnit: AppSettings.distanceUnit))

        XCTAssertEqual(draft.unit, km)
        XCTAssertEqual(draft.distance, "4.99")
        XCTAssertEqual(draft.incline, "3")
    }

    /// With neither source, the preference is what a fresh field starts in.
    func testSeedingWithNeitherSourceUsesThePreference() {
        for unit in [km, mi] {
            selectUnit(unit)
            XCTAssertNil(
                CardioDraftResolver.seededDraft(
                    prefill: nil, target: nil,
                    displayUnit: AppSettings.distanceUnit),
                "nothing to seed — the row stays untouched and empty")
            XCTAssertEqual(AppSettings.distanceUnit, unit)
        }
    }

    // MARK: - History follows the preference; stored data does not move
    //
    // The third patch: History was the last read path still honouring a stored
    // unit. It now renders in the preference like everything else, while the
    // stored columns stay exactly as logged.

    func testChangingThePreferenceDoesNotRewriteALoggedSetsUnit() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        selectUnit(mi)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: threePointOneMilesInMeters, distanceUnit: mi))
        try context.save()

        selectUnit(km)

        XCTAssertEqual(log.distanceUnitRaw, "mi")
        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), threePointOneMilesInMeters,
            accuracy: 0.001)
    }

    /// **Requirements 1–4 of the third patch.** A row logged in miles reads in
    /// miles under a miles preference and converts to km under a km one —
    /// distance *and* pace together, so the number never disagrees with the
    /// unit beside it.
    func testHistoryDisplayFollowsThePreference() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: 1_609.344, distanceUnit: mi))
        try context.save()

        selectUnit(mi)
        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(
                for: log, displayUnit: AppSettings.distanceUnit),
            ["1 mi · 30:00 /mi"])

        selectUnit(km)
        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(
                for: log, displayUnit: AppSettings.distanceUnit),
            ["1.61 km · 18:38 /km"],
            "an old miles row re-reads in km, pace label included")
    }

    /// The mirror: a km-logged row read under a miles preference.
    func testHistoryConvertsAKilometerRowToMiles() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: fiveKmInMeters, distanceUnit: km))
        try context.save()

        selectUnit(km)
        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(
                for: log, displayUnit: AppSettings.distanceUnit),
            ["5 km · 6:00 /km"])

        selectUnit(mi)
        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(
                for: log, displayUnit: AppSettings.distanceUnit),
            ["3.11 mi · 9:39 /mi"])
    }

    /// **Requirements 6 and 7 of the third patch.** Whatever `distanceUnitRaw`
    /// holds — the other unit, junk, or nothing — History renders in the
    /// preference, because `distanceMeters` is canonical.
    func testHistoryIgnoresStoredDistanceUnitRaw() throws {
        for raw in ["km", "mi", "kilometres", "", nil] as [String?] {
            let log = SetLog(
                indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
            context.insert(log)
            log.distanceMeters = fiveKmInMeters
            log.distanceUnitRaw = raw
            try context.save()

            selectUnit(km)
            XCTAssertEqual(
                CardioHistorySummary.secondaryLines(
                    for: log, displayUnit: AppSettings.distanceUnit),
                ["5 km · 6:00 /km"], "raw \(raw ?? "nil")")

            selectUnit(mi)
            XCTAssertEqual(
                CardioHistorySummary.secondaryLines(
                    for: log, displayUnit: AppSettings.distanceUnit),
                ["3.11 mi · 9:39 /mi"], "raw \(raw ?? "nil")")
        }
    }

    /// The `DistanceUnit` pace label itself is a pure mapping — pinned here
    /// because History's "/km" and "/mi" suffixes and the entry field's
    /// "Pace (min/km)" label must agree about which unit is in play.
    func testPaceLabelFollowsTheUnitItIsAskedFor() {
        selectUnit(km)
        XCTAssertEqual(mi.paceFieldLabel, "Pace (min/mi)")
        XCTAssertEqual(km.paceFieldLabel, "Pace (min/km)")

        selectUnit(mi)
        XCTAssertEqual(km.paceFieldLabel, "Pace (min/km)")
    }

    /// **Requirement 5 of the third patch.** End to end: flipping the
    /// preference changes what a bout *reads as* and nothing about what is
    /// stored. This is the test that would fail if display conversion ever
    /// wrote back.
    func testAPreferenceFlipConvertsDisplayButMovesNoStoredData() throws {
        selectUnit(mi)
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: threePointOneMilesInMeters, distanceUnit: mi,
                inclinePercent: 2))
        try context.save()
        let before = CardioHistorySummary.secondaryLines(
            for: log, displayUnit: AppSettings.distanceUnit)
        XCTAssertEqual(before, ["3.1 mi · 9:41 /mi", "2% incline"])

        selectUnit(km)
        let after = CardioHistorySummary.secondaryLines(
            for: log, displayUnit: AppSettings.distanceUnit)

        XCTAssertEqual(after, ["4.99 km · 6:01 /km", "2% incline"])
        XCTAssertNotEqual(before, after, "the display must follow the flip")

        // …and the stored row is byte-for-byte what it was logged as.
        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), threePointOneMilesInMeters,
            accuracy: 0.001)
        XCTAssertEqual(log.distanceUnitRaw, "mi")
    }

    // MARK: - Live refresh: the preference must be observable
    //
    // The fourth patch. Conversion was already correct, but an open History
    // page kept its old unit until it was rebuilt: `AppSettings.distanceUnit`
    // is a plain `UserDefaults` read, so SwiftUI recorded no dependency on it
    // and never re-ran the body. The views now hold
    // `@AppStorage(AppSettings.Keys.distanceIsMetric)` and derive the unit from
    // it through `AppSettings.distanceUnit(isMetric:)`.

    /// The bridge the fix rests on: the unit a view derives from its
    /// `@AppStorage` `Bool` must be the same unit the rest of the app resolves
    /// globally. A view that re-derived the mapping itself — and got it
    /// backwards — would render confidently wrong text, so the mapping is
    /// asserted rather than assumed.
    func testViewDerivedUnitMatchesTheGlobalResolution() {
        for isMetric in [true, false] {
            AppSettings.distanceIsMetric = isMetric
            XCTAssertEqual(
                AppSettings.distanceUnit(isMetric: isMetric),
                AppSettings.distanceUnit,
                "a view deriving its unit from @AppStorage must land on the "
                    + "same unit as the global accessor")
        }

        XCTAssertEqual(AppSettings.distanceUnit(isMetric: true), km)
        XCTAssertEqual(AppSettings.distanceUnit(isMetric: false), mi)
    }

    /// The `@AppStorage` default each view declares must be the locale-resolved
    /// expression, not a hardcoded `true`.
    ///
    /// Same limitation as `testUnsetPreferenceResolvesFromTheLocale`: a view's
    /// property default is unreachable from a test, so what is pinned is the
    /// value it must be. While the key is unset, a view defaulting to `true`
    /// would render km while the formatter elsewhere resolved miles from the
    /// locale — the two would disagree on the same screen.
    func testUnsetPreferenceRendersTheSameUnitInAViewAsEverywhereElse() {
        UserDefaults.standard.removeObject(
            forKey: AppSettings.Keys.distanceIsMetric)

        XCTAssertEqual(
            AppSettings.distanceUnit(
                isMetric: AppSettings.defaultDistanceIsMetric()),
            AppSettings.distanceUnit)
    }

    /// **Requirement 3.** "Rendering uses the current unit rather than cached
    /// text" is not assertable against `WorkoutDetailView` (a `View`), but the
    /// property that makes caching impossible *is*: the formatter is a pure
    /// function of `(log, displayUnit)`, holding no memo and mutating nothing.
    /// Alternating units on one unchanged `SetLog` must alternate output every
    /// time — which is exactly what an open page does as the preference flips
    /// back and forth.
    func testHistoryFormattingIsPureAndRepeatable() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: fiveKmInMeters, distanceUnit: km))
        try context.save()

        let metric = ["5 km · 6:00 /km"]
        let imperial = ["3.11 mi · 9:39 /mi"]

        // Three full round trips: a cached first render would show up as the
        // second reading of a unit disagreeing with the first.
        for _ in 0..<3 {
            XCTAssertEqual(
                CardioHistorySummary.secondaryLines(for: log, displayUnit: km),
                metric)
            XCTAssertEqual(
                CardioHistorySummary.secondaryLines(for: log, displayUnit: mi),
                imperial)
        }

        // Reading it repeatedly in either unit changed nothing on the row.
        XCTAssertEqual(try XCTUnwrap(log.distanceMeters), fiveKmInMeters)
        XCTAssertEqual(log.distanceUnitRaw, "km")
    }

    /// The same purity for the routine-target and plan-summary formatters,
    /// which the routine editor and the active Plan card re-render from the
    /// same observable preference.
    func testTargetFormattingIsPureAndRepeatable() throws {
        let p = cardioPrescription(meters: fiveKmInMeters, unitRaw: "km")
        let b = try block(with: p)

        var plan = SessionPlan()
        plan.sets = 1
        plan.usesDuration = true
        plan.targetDistanceMeters = fiveKmInMeters

        for _ in 0..<3 {
            XCTAssertEqual(
                BlockPrescriptionSummary(block: b, displayUnit: km).subtitle,
                "1 × 1800s · 5 km")
            XCTAssertEqual(
                BlockPrescriptionSummary(block: b, displayUnit: mi).subtitle,
                "1 × 1800s · 3.11 mi")
            XCTAssertTrue(
                plan.primarySummary(distanceUnit: km).contains("5 km"))
            XCTAssertTrue(
                plan.primarySummary(distanceUnit: mi).contains("3.11 mi"))
        }

        XCTAssertEqual(try XCTUnwrap(p.targetDistanceMeters), fiveKmInMeters)
    }

    // MARK: - Active cardio rows re-express live
    //
    // The fifth patch. Unlike History, `ActiveWorkoutView` was already
    // observing the preference — but the rows render `draft.unit`, which is
    // *state* seeded when the draft was built, so re-rendering changed
    // nothing. `.onChange(of: distanceUnit)` now resyncs the drafts through
    // `CardioEntryDraft.converted(to:)`.

    /// A target-seeded draft follows a later preference change, not just the
    /// preference in force when it was seeded.
    func testTargetSeededDraftReExpressesOnAPreferenceChange() throws {
        selectUnit(km)
        let p = cardioPrescription(meters: fiveKmInMeters, unitRaw: "km")
        let seeded = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: nil,
                target: p.targetDistance(displayUnit: AppSettings.distanceUnit),
                displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(seeded.distance, "5")

        // Settings flips; the view resyncs the draft it is holding.
        selectUnit(mi)
        let resynced = seeded.converted(to: AppSettings.distanceUnit)

        XCTAssertEqual(resynced.unit, mi)
        XCTAssertEqual(resynced.distance, "3.11")
        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters), fiveKmInMeters,
            "the routine target must not be rewritten")
    }

    /// Same for a draft prefilled from a previous bout.
    func testPrefilledDraftReExpressesOnAPreferenceChange() throws {
        let suggestion = CardioPrefillSuggestion(
            setIndex: 0, distanceMeters: fiveKmInMeters, distanceUnit: km,
            inclinePercent: 3, resistanceLevel: nil)

        selectUnit(km)
        let seeded = try XCTUnwrap(
            CardioDraftResolver.seededDraft(
                prefill: suggestion, target: nil,
                displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(seeded.distance, "5")

        selectUnit(mi)
        let resynced = seeded.converted(to: AppSettings.distanceUnit)

        XCTAssertEqual(resynced.distance, "3.11")
        XCTAssertEqual(resynced.unit, mi)
        XCTAssertEqual(resynced.incline, "3", "unitless fields are untouched")
    }

    /// A logged set's read-only row re-expresses too, and doing so cannot reach
    /// the `SetLog` it mirrors.
    func testLoggedRowReExpressesWithoutTouchingTheSetLog() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        selectUnit(km)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: fiveKmInMeters, distanceUnit: km))
        try context.save()

        let shown = CardioEntryDraft(
            logged: log, displayUnit: AppSettings.distanceUnit)
        XCTAssertEqual(shown.distance, "5")

        selectUnit(mi)
        let resynced = shown.converted(to: AppSettings.distanceUnit)

        XCTAssertEqual(resynced.distance, "3.11")
        XCTAssertEqual(resynced.unit, mi)
        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), fiveKmInMeters,
            "the logged distance must not move")
        XCTAssertEqual(log.distanceUnitRaw, "km")
    }

    /// A row the user cleared stays cleared across a preference change — the
    /// resync must not refill it from the target it once came from.
    func testUserClearedDraftStaysEmptyAcrossAPreferenceChange() {
        selectUnit(km)
        let cleared = CardioEntryDraft(unit: AppSettings.distanceUnit)

        selectUnit(mi)
        let resynced = cleared.converted(to: AppSettings.distanceUnit)

        XCTAssertEqual(resynced.distance, "")
        XCTAssertTrue(resynced.isEmpty)
        XCTAssertEqual(resynced.unit, mi)
    }

    /// **Requirements 8, 9 and 11.** The live row and a resumed one agree,
    /// without the preference change having written to `ParentDraftStore`.
    ///
    /// The store keeps the text *and the unit it was typed in*, so resume can
    /// convert exactly as the live resync did. That is what makes it safe for
    /// `resyncCardioDrafts` not to persist: nothing needs rewriting for the
    /// two paths to land in the same place.
    func testLiveResyncAndResumeAgreeWithoutRewritingTheStore() throws {
        let store = ParentDraftStore(
            workoutID: UUID(),
            defaults: try XCTUnwrap(
                UserDefaults(suiteName: "DistanceUnitSettingTests.resync")))
        defer { store.clearAll() }
        let slotID = UUID()

        // Typed under km, persisted as the user typed it.
        selectUnit(km)
        let typed = CardioEntryDraft(
            unit: AppSettings.distanceUnit, distance: "5", avgHeartRate: "142")
        store.persist(slotID: slotID, setIndex: 0, cardio: typed)

        let persisted = try XCTUnwrap(store.load(slotID: slotID, setIndex: 0))
        XCTAssertEqual(persisted.distance, "5")
        XCTAssertEqual(persisted.distanceUnit, "km")

        // Settings flips. The live view resyncs in memory only.
        selectUnit(mi)
        let live = typed.converted(to: AppSettings.distanceUnit)
        XCTAssertEqual(live.distance, "3.11")

        // The store was not rewritten by the preference change.
        let untouched = try XCTUnwrap(store.load(slotID: slotID, setIndex: 0))
        XCTAssertEqual(
            untouched.distance, "5",
            "a display preference change must not rewrite a persisted draft")
        XCTAssertEqual(untouched.distanceUnit, "km")

        // …and resume still lands on the same reading as the live row.
        let resumed = try XCTUnwrap(
            CardioEntryDraft(
                snapshot: untouched, displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(resumed.distance, live.distance)
        XCTAssertEqual(resumed.unit, live.unit)
        XCTAssertEqual(resumed.avgHeartRate, "142")

        // Both express the same canonical distance the user entered.
        XCTAssertEqual(
            try XCTUnwrap(resumed.metrics.distanceMeters), 5_004.972,
            accuracy: 1.0)
    }

    /// The preview, pace and speed all read `draft.unit`, so one resync moves
    /// them together — the four things the row shows cannot disagree.
    func testPreviewPaceAndSpeedAllFollowTheResync() {
        selectUnit(km)
        let metric = CardioEntryDraft(
            unit: AppSettings.distanceUnit, distance: "6.2")
        XCTAssertEqual(metric.summaryText, "6.2 km")
        XCTAssertEqual(metric.paceText(durationSeconds: 2_700), "7:15 /km")
        XCTAssertEqual(metric.speedText(durationSeconds: 2_700), "8.3 km/h")

        selectUnit(mi)
        let imperial = metric.converted(to: AppSettings.distanceUnit)

        XCTAssertEqual(imperial.summaryText, "3.85 mi")
        XCTAssertEqual(imperial.paceText(durationSeconds: 2_700), "11:41 /mi")
        XCTAssertEqual(imperial.speedText(durationSeconds: 2_700), "5.1 mi/h")
    }

    // MARK: - The removed Settings footer

    /// **Requirement 15 of the test list.** The footer explaining the old
    /// "applies to new entries, old data keeps its unit" rule is gone, along
    /// with the rule it described.
    ///
    /// It cannot be asserted against `SettingsView` (a `View`), so this pins
    /// the compiled Korean resource instead, the same way
    /// `KoreanLocalizationTests` does: a key that is still in the catalog
    /// returns its Korean translation, and a removed one falls back to the key
    /// itself. The surviving picker label is asserted alongside it, so a test
    /// that passed because the *bundle* went missing would fail here.
    func testTheSettingsFooterStringIsGone() throws {
        let korean = try XCTUnwrap(
            Bundle(for: Exercise.self).path(forResource: "ko", ofType: "lproj")
                .flatMap(Bundle.init(path:)),
            "the app bundle must carry ko.lproj")

        let removed =
            "Distance unit applies to new cardio entries. Workouts and "
            + "routines keep the unit they were saved in."
        XCTAssertEqual(
            korean.localizedString(forKey: removed, value: removed, table: nil),
            removed,
            "the removed footer must no longer resolve to a translation")

        // The label the Units section still shows: proof the lookup works.
        XCTAssertEqual(
            korean.localizedString(
                forKey: "Distance unit", value: "Distance unit", table: nil),
            "거리 단위",
            "the picker's own label stays localized")
    }
}

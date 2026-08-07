import SwiftData
import XCTest

@testable import Log

/// Structured Cardio Slice 12E — the History **Planned** section.
///
/// Two claims run through every test here, and they are the whole slice:
///
///  1. **History shows what was planned, from the frozen snapshot.** Editing
///     the routine afterwards cannot rewrite an old workout's Planned section,
///     the same snapshot-immutability invariant Equipment & Setup relies on.
///  2. **Planned is not performed.** There is no tick, no checkmark, and no
///     completion state anywhere in the rendered data — the active checklist's
///     ticks are session-scoped draft state that never reached this workout,
///     and the logged result stays the aggregate cardio `SetLog`.
///
/// The rows are built by the pure `CardioPlannedHistory`, which is what makes
/// expansion order, round labelling and the display unit testable at all —
/// they are otherwise buried inside `WorkoutDetailView`.
@MainActor
final class StructuredCardioHistoryTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func segment(
        _ kind: CardioSegmentKind,
        duration: Int? = nil,
        distance: Double? = nil,
        incline: Double? = nil,
        resistance: Double? = nil,
        zone: HRZone? = nil,
        note: String? = nil
    ) throws -> CardioSegment {
        try CardioSegment(
            kind: kind, durationSeconds: duration, distanceMeters: distance,
            inclinePercent: incline, resistanceLevel: resistance,
            hrZone: zone, note: note)
    }

    /// 5 min warm-up → 20 min work @ 5 km → 5 min cool-down.
    private func flatPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.warmUp, duration: 300),
                segment(.work, duration: 1_200, distance: 5_000),
                segment(.coolDown, duration: 300),
            ])
        ])
    }

    /// 5 × (1 min work / 2 min recovery).
    private func repeatedPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [
                    segment(.work, duration: 60),
                    segment(.recovery, duration: 120),
                ],
                repeatCount: 5)
        ])
    }

    /// A frozen snapshot as `populateSnapshotFields` writes one at session
    /// start, carrying the plan the workout was started with.
    @discardableResult
    private func frozenSnapshot(
        plan: CardioSegmentPlan?
    ) -> PlannedPrescriptionSnapshot {
        let source = SlotPrescription()
        source.sets = 1
        source.usesDuration = true
        source.durationMaxSeconds = 1_800
        source.setStructuredCardioPlan(plan)
        context.insert(source)

        let frozen = PlannedPrescriptionSnapshot(from: source, exercise: nil)
        context.insert(frozen)
        return frozen
    }

    // ==================================================
    // MARK: - 1. When the section appears
    // ==================================================

    func testACardioSnapshotWithAPlanExposesIt() throws {
        let frozen = frozenSnapshot(plan: try flatPlan())

        XCTAssertNotNil(
            frozen.structuredCardioPlan,
            "History's visibility gate is exactly this accessor")
        XCTAssertEqual(frozen.structuredCardioPlan?.expandedCount, 3)
    }

    func testACardioSnapshotWithoutAPlanShowsNothing() {
        XCTAssertNil(frozenSnapshot(plan: nil).structuredCardioPlan)
    }

    /// A strength slot cannot author segments, so its snapshot decodes nil and
    /// History adds zero rows — structurally, without asking what tracking mode
    /// the item was.
    func testAStrengthSnapshotShowsNoPlannedSection() {
        let strength = SlotPrescription()
        strength.sets = 3
        strength.repMin = 8
        strength.repMax = 12
        context.insert(strength)

        let frozen = PlannedPrescriptionSnapshot(from: strength, exercise: nil)
        context.insert(frozen)

        XCTAssertNil(frozen.cardioSegmentsData)
        XCTAssertNil(frozen.structuredCardioPlan)
        XCTAssertFalse(CardioRoutineRules.showsCardioSegments(.strength))
    }

    func testATimedHoldSnapshotShowsNoPlannedSection() {
        let hold = SlotPrescription()
        hold.sets = 3
        hold.usesDuration = true
        hold.durationMaxSeconds = 45
        context.insert(hold)

        let frozen = PlannedPrescriptionSnapshot(from: hold, exercise: nil)
        context.insert(frozen)

        XCTAssertNil(frozen.structuredCardioPlan)
        XCTAssertFalse(CardioRoutineRules.showsCardioSegments(.timedHold))
    }

    /// A corrupt column costs the Planned section, never the History row.
    func testCorruptPayloadShowsNoPlannedSectionAndDoesNotThrow() {
        let frozen = frozenSnapshot(plan: nil)
        frozen.cardioSegmentsData = Data("not json at all".utf8)

        XCTAssertNil(frozen.structuredCardioPlan)
    }

    func testAPayloadWhoseSegmentsAllNormalizeAwayShowsNothing() {
        let frozen = frozenSnapshot(plan: nil)
        // One segment, no targets: the decoder drops the segment, then the
        // group, leaving an empty plan — which reads as "no structure".
        frozen.cardioSegmentsData = Data(
            #"{"version":1,"groups":[{"id":"\#(UUID().uuidString)","repeatCount":1,"segments":[{"id":"\#(UUID().uuidString)","kind":"work"}]}]}"#
                .utf8)

        XCTAssertNil(frozen.structuredCardioPlan)
    }

    // ==================================================
    // MARK: - 2. Frozen, not live
    // ==================================================

    /// The headline invariant: edit the routine after the workout, and the old
    /// History still shows what was planned at the time.
    func testEditingTheRoutineAfterwardsDoesNotChangeOldHistory() throws {
        let source = SlotPrescription()
        source.setStructuredCardioPlan(try flatPlan())
        context.insert(source)

        let frozen = PlannedPrescriptionSnapshot(from: source, exercise: nil)
        context.insert(frozen)
        try context.save()

        // …the user reprograms the routine into intervals.
        source.setStructuredCardioPlan(try repeatedPlan())
        try context.save()

        XCTAssertEqual(source.structuredCardioPlan?.expandedCount, 10)
        XCTAssertEqual(
            frozen.structuredCardioPlan?.expandedCount, 3,
            "the completed workout still reports the plan it was started with")
        XCTAssertEqual(
            CardioPlannedHistory.rows(
                for: try XCTUnwrap(frozen.structuredCardioPlan),
                distanceUnit: .kilometers
            ).map(\.kindLabelKey),
            ["Warm-up", "Work", "Cool-down"])
    }

    /// Deleting the routine's plan entirely leaves History intact — `Data` is a
    /// value type, so the snapshot owns its copy.
    func testClearingTheRoutinePlanLeavesTheFrozenPlanIntact() throws {
        let source = SlotPrescription()
        source.setStructuredCardioPlan(try flatPlan())
        context.insert(source)
        let frozen = PlannedPrescriptionSnapshot(from: source, exercise: nil)
        context.insert(frozen)

        source.clearStructuredCardioPlan()

        XCTAssertNil(source.structuredCardioPlan)
        XCTAssertEqual(frozen.structuredCardioPlan?.expandedCount, 3)
    }

    // ==================================================
    // MARK: - 3. Row content
    // ==================================================

    func testRowsExpandInPlannedOrder() throws {
        let rows = CardioPlannedHistory.rows(
            for: try flatPlan(), distanceUnit: .kilometers)

        XCTAssertEqual(
            rows.map(\.kindLabelKey), ["Warm-up", "Work", "Cool-down"])
        XCTAssertEqual(rows.count, 3)
    }

    /// The kind travels as a localization **key**, not a resolved string, so
    /// the Planned section reads in Korean like every other structured-cardio
    /// surface.
    func testRowsCarryTheKindAsALocalizationKey() throws {
        let rows = CardioPlannedHistory.rows(
            for: try flatPlan(), distanceUnit: .kilometers)

        for row in rows {
            XCTAssertTrue(
                CardioSegmentKind.allCases.map(\.label)
                    .contains(row.kindLabelKey),
                "\(row.kindLabelKey) must be one of the four catalog keys")
        }
    }

    func testRowTargetsExcludeTheKindAndListEveryTarget() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(
                    .work, duration: 1_200, distance: 5_000, incline: 1,
                    resistance: 8, zone: .z3)
            ])
        ])

        let row = try XCTUnwrap(
            CardioPlannedHistory.rows(for: plan, distanceUnit: .kilometers)
                .first)

        XCTAssertFalse(
            row.targetText.contains("Work"),
            "the kind is rendered separately, localized")
        XCTAssertTrue(row.targetText.contains("5 km"))
        XCTAssertTrue(row.targetText.contains("1%"))
        XCTAssertTrue(row.targetText.contains("L8"))
        XCTAssertTrue(row.targetText.contains("Z3"))
    }

    func testASegmentNoteIsCarriedOntoItsRow() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.work, duration: 600, note: "Hill repeat")
            ])
        ])

        XCTAssertEqual(
            CardioPlannedHistory.rows(for: plan, distanceUnit: .kilometers)
                .first?.note,
            "Hill repeat")
    }

    // ==================================================
    // MARK: - 4. Repeats
    // ==================================================

    func testRepeatedSegmentsProduceOneRowPerRoundWithRoundLabels() throws {
        let rows = CardioPlannedHistory.rows(
            for: try repeatedPlan(), distanceUnit: .kilometers)

        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(Set(rows.map(\.id)).count, 10, "ids are independent")
        XCTAssertEqual(
            rows.map(\.round), [1, 1, 2, 2, 3, 3, 4, 4, 5, 5])
        XCTAssertTrue(rows.allSatisfy { $0.roundCount == 5 })
        XCTAssertTrue(rows.allSatisfy(\.isRepeated))
        XCTAssertEqual(
            rows.prefix(4).map(\.kindLabelKey),
            ["Work", "Recovery", "Work", "Recovery"],
            "work and recovery alternate — never grouped by kind")
    }

    /// A flat plan shows no round column at all, so the overwhelmingly common
    /// case renders exactly as the design sketched it.
    func testAFlatPlanCarriesNoRoundInformation() throws {
        let rows = CardioPlannedHistory.rows(
            for: try flatPlan(), distanceUnit: .kilometers)

        XCTAssertTrue(rows.allSatisfy { $0.round == nil })
        XCTAssertTrue(rows.allSatisfy { $0.roundCount == nil })
        XCTAssertTrue(rows.allSatisfy { !$0.isRepeated })
    }

    // ==================================================
    // MARK: - 5. Distance unit
    // ==================================================

    func testSegmentDistancesRenderInTheRequestedUnit() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [segment(.work, distance: 5_000)])
        ])

        let metric = try XCTUnwrap(
            CardioPlannedHistory.rows(for: plan, distanceUnit: .kilometers)
                .first)
        let imperial = try XCTUnwrap(
            CardioPlannedHistory.rows(for: plan, distanceUnit: .miles).first)

        XCTAssertTrue(metric.targetText.contains("km"))
        XCTAssertTrue(imperial.targetText.contains("mi"))
        XCTAssertNotEqual(metric.targetText, imperial.targetText)
    }

    /// The section headline follows the same unit, and counts **expanded**
    /// segments — what the athlete was asked to do.
    func testTheSummaryFollowsTheUnitAndCountsExpandedSegments() throws {
        let flat = try flatPlan()
        XCTAssertTrue(
            CardioPlannedHistory.summary(for: flat, distanceUnit: .kilometers)
                .contains("3 segments"))
        XCTAssertTrue(
            CardioPlannedHistory.summary(for: flat, distanceUnit: .miles)
                .contains("mi"))
        XCTAssertTrue(
            CardioPlannedHistory.summary(
                for: try repeatedPlan(), distanceUnit: .kilometers
            ).contains("10 segments"))
    }

    // ==================================================
    // MARK: - 6. Planned is not performed
    // ==================================================

    /// The type that feeds History has no completion state, and there is
    /// nowhere for one to be added by accident — the checklist's ticks are not
    /// part of any workout record.
    func testAPlannedRowCarriesNoCompletionState() throws {
        let row = try XCTUnwrap(
            CardioPlannedHistory.rows(
                for: try flatPlan(), distanceUnit: .kilometers
            ).first)

        // A compile-time assertion in test form: the row's entire surface is
        // plan data. If a `isChecked`/`isCompleted` field is ever added, this
        // equality — built purely from planned values — stops compiling.
        XCTAssertEqual(
            row,
            CardioPlannedSegmentRow(
                id: row.id,
                kindLabelKey: row.kindLabelKey,
                targetText: row.targetText,
                round: row.round,
                roundCount: row.roundCount,
                note: row.note))
    }

    /// Ticks live in their own per-workout `UserDefaults` key and are cleared
    /// on finish, so a completed workout's History has nothing to read even if
    /// it tried.
    func testChecklistTicksAreNotPartOfTheWorkoutRecord() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let workoutID = UUID()
        let slotID = UUID()
        let plan = try flatPlan()
        let store = CardioSegmentCheckStore(
            workoutID: workoutID, defaults: defaults)
        store.save(
            slotID: slotID, checked: Set(plan.expandedSegments().map(\.id)))

        // Finishing the workout drops the whole key (`unlockAndDismiss`).
        store.clearAll()

        XCTAssertTrue(store.loadAll().isEmpty)
        // …and the frozen plan History renders is entirely unaffected by it.
        let frozen = frozenSnapshot(plan: plan)
        XCTAssertEqual(frozen.structuredCardioPlan?.expandedCount, 3)
    }

    /// The aggregate log is still the only record of what happened. A
    /// structured plan adds no `SetLog` and changes no field on one.
    func testTheAggregateSetLogIsUnaffectedByAPlan() throws {
        let workout = Workout(date: .now, routineName: "Cardio", items: [])
        let exercise = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        exercise.isTimeBased = true
        exercise.isCardio = true
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        item.plannedPrescriptionSnapshot = frozenSnapshot(plan: try flatPlan())

        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: 0, weight: nil,
            durationSeconds: 1_800)
        log.distanceMeters = 5_000
        item.setLogs.append(log)
        workout.items.append(item)
        context.insert(exercise)
        context.insert(workout)
        try context.save()

        XCTAssertEqual(
            item.setLogs.count, 1,
            "one bout, one aggregate set — however many segments were planned")
        XCTAssertEqual(item.setLogs.first?.durationSeconds, 1_800)
        XCTAssertEqual(item.setLogs.first?.distanceMeters, 5_000)
        XCTAssertNotNil(item.plannedPrescriptionSnapshot?.structuredCardioPlan)
    }

    /// The existing aggregate row text is byte-identical with and without a
    /// plan — the Planned section is additive, sitting above rows it does not
    /// touch.
    func testTheLoggedRowTextIsUnchangedByAPlan() throws {
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: 0, weight: nil,
            durationSeconds: 1_800)
        log.distanceMeters = 5_000
        context.insert(log)

        let primary = CardioHistorySummary.primaryText(for: log)
        let secondary = CardioHistorySummary.secondaryLines(
            for: log, displayUnit: .kilometers)

        XCTAssertEqual(primary, "1800s")
        XCTAssertFalse(secondary.isEmpty)
        // Nothing about the plan is consulted by either helper — they take a
        // `SetLog` and a unit, and that is the whole input.
        XCTAssertEqual(
            CardioHistorySummary.primaryText(for: log), primary)
        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(
                for: log, displayUnit: .kilometers), secondary)
    }

    // ==================================================
    // MARK: - 7. Bounds
    // ==================================================

    /// However the payload arrived, History cannot be handed an unbounded list.
    func testRowsStayWithinTheExpansionBound() throws {
        let frozen = frozenSnapshot(plan: nil)
        let segments = (0..<3).map { _ in
            #"{"id":"\#(UUID().uuidString)","kind":"work","durationSeconds":60}"#
        }.joined(separator: ",")
        let groups = (0..<5).map { _ in
            #"{"id":"\#(UUID().uuidString)","repeatCount":20,"segments":[\#(segments)]}"#
        }.joined(separator: ",")
        frozen.cardioSegmentsData = Data(
            #"{"version":1,"groups":[\#(groups)]}"#.utf8)

        let plan = try XCTUnwrap(frozen.structuredCardioPlan)
        XCTAssertLessThanOrEqual(
            CardioPlannedHistory.rows(for: plan, distanceUnit: .kilometers)
                .count,
            CardioPlanLimits.maxExpandedSegments)
    }
}

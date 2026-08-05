import XCTest

@testable import Log

/// Cardio Phase 1, Slice 4 — the active-workout entry contract.
///
/// `CardioEntryDraft` is the whole of what the Details section does with user
/// input: it holds raw text while typing, sanitizes keystrokes, and normalizes
/// once at log time. Testing it directly covers what a SwiftUI host test could
/// only cover indirectly — what a field accepts, what it rejects, and exactly
/// what reaches `SetLog`.
final class CardioEntryDraftTests: XCTestCase {

    private let km = DistanceUnit.kilometers

    private func draft(
        unit: DistanceUnit? = nil,
        distance: String = "",
        avgHeartRate: String = "",
        calories: String = "",
        incline: String = "",
        resistance: String = "",
        hrZone: HRZone? = nil
    ) -> CardioEntryDraft {
        CardioEntryDraft(
            unit: unit ?? km, distance: distance, avgHeartRate: avgHeartRate,
            calories: calories, incline: incline, resistance: resistance,
            hrZone: hrZone)
    }

    // MARK: - 1. Empty fields store nil

    func testEmptyDraftProducesNoMetrics() {
        let metrics = draft().metrics

        XCTAssertTrue(metrics.isEmpty)
        XCTAssertNil(metrics.distanceMeters)
        XCTAssertNil(metrics.distanceUnit)
        XCTAssertNil(metrics.avgHeartRate)
        XCTAssertNil(metrics.calories)
        XCTAssertNil(metrics.inclinePercent)
        XCTAssertNil(metrics.resistanceLevel)
        XCTAssertNil(metrics.hrZone)
    }

    func testWhitespaceOnlyFieldsProduceNoMetrics() {
        let metrics = draft(
            distance: "   ", avgHeartRate: " ", calories: "\t",
            incline: " ", resistance: "  "
        ).metrics

        XCTAssertTrue(metrics.isEmpty)
    }

    func testIsEmptyTracksTextNotValidity() {
        XCTAssertTrue(draft().isEmpty)
        // "abc" normalizes to nil but the user *has* typed something.
        XCTAssertFalse(draft(distance: "abc").isEmpty)
        XCTAssertFalse(draft(hrZone: .z2).isEmpty)
    }

    // MARK: - 2. Distance: canonical meters + entry unit

    func testDistanceInKilometersStoresMetersAndUnit() {
        let metrics = draft(unit: .kilometers, distance: "6.2").metrics

        XCTAssertEqual(metrics.distanceMeters ?? 0, 6_200, accuracy: 0.0001)
        XCTAssertEqual(metrics.distanceUnit, .kilometers)
    }

    func testDistanceInMilesStoresMetersAndUnit() {
        let metrics = draft(unit: .miles, distance: "3").metrics

        XCTAssertEqual(metrics.distanceMeters ?? 0, 4_828.032, accuracy: 0.0001)
        XCTAssertEqual(metrics.distanceUnit, .miles)
    }

    /// The unit is only meaningful alongside a distance, so a draft with a unit
    /// but no number must not persist a stray `distanceUnitRaw`.
    func testUnitIsDroppedWhenDistanceIsEmpty() {
        let metrics = draft(unit: .miles, distance: "").metrics

        XCTAssertNil(metrics.distanceMeters)
        XCTAssertNil(metrics.distanceUnit)
    }

    func testInvalidDistanceIsRejected() {
        for text in ["", "abc", "-5", "0", "nan", "inf", "1001"] {
            let metrics = draft(unit: km, distance: text).metrics
            XCTAssertNil(
                metrics.distanceMeters,
                "Distance \"\(text)\" should not be stored")
        }
    }

    // MARK: - 3. Heart rate, calories, resistance

    func testHeartRateAcceptsValidAndRejectsInvalid() {
        XCTAssertEqual(draft(avgHeartRate: "142").metrics.avgHeartRate, 142)
        XCTAssertEqual(draft(avgHeartRate: "20").metrics.avgHeartRate, 20)
        XCTAssertEqual(draft(avgHeartRate: "300").metrics.avgHeartRate, 300)

        for text in ["", "abc", "19", "301", "900", "-40"] {
            XCTAssertNil(
                draft(avgHeartRate: text).metrics.avgHeartRate,
                "Heart rate \"\(text)\" should be rejected")
        }
    }

    func testCaloriesAcceptsValidAndRejectsInvalid() {
        XCTAssertEqual(draft(calories: "410").metrics.calories, 410)
        XCTAssertEqual(draft(calories: "1").metrics.calories, 1)

        for text in ["", "abc", "0", "-10", "100001"] {
            XCTAssertNil(
                draft(calories: text).metrics.calories,
                "Calories \"\(text)\" should be rejected")
        }
    }

    func testResistanceAcceptsValidAndRejectsInvalid() {
        XCTAssertEqual(draft(resistance: "8").metrics.resistanceLevel, 8)
        XCTAssertEqual(draft(resistance: "7.5").metrics.resistanceLevel, 7.5)

        for text in ["", "abc", "0", "-3", "101"] {
            XCTAssertNil(
                draft(resistance: text).metrics.resistanceLevel,
                "Resistance \"\(text)\" should be rejected")
        }
    }

    // MARK: - 4. Incline, including decline

    func testInclineAcceptsPositiveZeroAndNegative() {
        XCTAssertEqual(draft(incline: "4.5").metrics.inclinePercent, 4.5)
        XCTAssertEqual(draft(incline: "0").metrics.inclinePercent, 0)
        XCTAssertEqual(draft(incline: "-3").metrics.inclinePercent, -3)
        XCTAssertEqual(draft(incline: "-30").metrics.inclinePercent, -30)
        XCTAssertEqual(draft(incline: "100").metrics.inclinePercent, 100)
    }

    func testInclineRejectsOutOfRange() {
        for text in ["", "abc", "-31", "101"] {
            XCTAssertNil(
                draft(incline: text).metrics.inclinePercent,
                "Incline \"\(text)\" should be rejected")
        }
    }

    // MARK: - 5. HR zone

    func testHRZoneRoundTripsAndNilIsAllowed() {
        for zone in HRZone.allCases {
            XCTAssertEqual(draft(hrZone: zone).metrics.hrZone, zone)
        }
        XCTAssertNil(draft(hrZone: nil).metrics.hrZone)
    }

    // MARK: - 6. Keystroke sanitizers

    func testSanitizeIntegerKeepsDigitsOnly() {
        XCTAssertEqual(CardioEntryDraft.sanitizeInteger("14a2"), "142")
        XCTAssertEqual(CardioEntryDraft.sanitizeInteger("1.2"), "12")
        XCTAssertEqual(CardioEntryDraft.sanitizeInteger("-40"), "40")
        XCTAssertEqual(CardioEntryDraft.sanitizeInteger(""), "")
    }

    func testSanitizeDecimalKeepsOneSeparator() {
        XCTAssertEqual(CardioEntryDraft.sanitizeDecimal("6.2"), "6.2")
        XCTAssertEqual(CardioEntryDraft.sanitizeDecimal("6.2.5"), "6.25")
        XCTAssertEqual(CardioEntryDraft.sanitizeDecimal("6a.2"), "6.2")
        XCTAssertEqual(CardioEntryDraft.sanitizeDecimal("-6.2"), "6.2")
        // A trailing separator is preserved so "6." can be typed toward "6.2".
        XCTAssertEqual(CardioEntryDraft.sanitizeDecimal("6."), "6.")
    }

    /// Decline is only reachable if the field accepts a leading minus.
    func testSanitizeSignedDecimalKeepsALeadingMinusOnly() {
        XCTAssertEqual(CardioEntryDraft.sanitizeSignedDecimal("-3"), "-3")
        XCTAssertEqual(CardioEntryDraft.sanitizeSignedDecimal("-3.5"), "-3.5")
        XCTAssertEqual(CardioEntryDraft.sanitizeSignedDecimal("3"), "3")
        // A minus anywhere else is dropped — "3-" is not a number.
        XCTAssertEqual(CardioEntryDraft.sanitizeSignedDecimal("3-"), "3")
        XCTAssertEqual(CardioEntryDraft.sanitizeSignedDecimal("--3"), "-3")
    }

    // MARK: - 7. Derived pace and speed

    func testPaceAndSpeedDeriveFromDistanceAndDuration() {
        let d = draft(unit: .kilometers, distance: "6.2")

        XCTAssertEqual(d.paceText(durationSeconds: 2_700), "7:15 /km")
        XCTAssertEqual(d.speedText(durationSeconds: 2_700), "8.3 km/h")
    }

    func testPaceAndSpeedDeriveInMiles() {
        let d = draft(unit: .miles, distance: "3")

        XCTAssertEqual(d.paceText(durationSeconds: 1_500), "8:20 /mi")
        XCTAssertEqual(d.speedText(durationSeconds: 1_500), "7.2 mi/h")
    }

    func testNoDistanceHidesPaceAndSpeed() {
        let d = draft(distance: "")

        XCTAssertNil(d.paceText(durationSeconds: 2_700))
        XCTAssertNil(d.speedText(durationSeconds: 2_700))
    }

    func testMissingOrZeroDurationHidesPaceAndSpeed() {
        let d = draft(distance: "5")

        XCTAssertNil(d.paceText(durationSeconds: nil))
        XCTAssertNil(d.speedText(durationSeconds: nil))
        XCTAssertNil(d.paceText(durationSeconds: 0))
        XCTAssertNil(d.speedText(durationSeconds: 0))
        XCTAssertNil(d.paceText(durationSeconds: -10))
        XCTAssertNil(d.speedText(durationSeconds: -10))
    }

    func testInvalidDistanceHidesPaceAndSpeed() {
        let d = draft(distance: "abc")

        XCTAssertNil(d.paceText(durationSeconds: 2_700))
        XCTAssertNil(d.speedText(durationSeconds: 2_700))
    }

    // MARK: - 8. Collapsed summary

    func testSummaryOmitsDurationAndPace() {
        let d = draft(
            unit: km, distance: "5.2", avgHeartRate: "142", calories: "410")

        XCTAssertEqual(d.summaryText, "5.2 km · 142 bpm · 410 kcal")
    }

    func testSummaryIsNilWhenNothingValidEntered() {
        XCTAssertNil(draft().summaryText)
        XCTAssertNil(draft(distance: "abc", avgHeartRate: "999").summaryText)
    }

    func testSummaryIncludesInclineAndResistance() {
        let d = draft(incline: "-3", resistance: "8", hrZone: .z3)

        XCTAssertEqual(d.summaryText, "-3% incline · level 8 · Z3")
    }

    // MARK: - 9. Persistence bridge

    func testDraftRestoresFromSnapshot() throws {
        let store = ParentDraftStore(
            workoutID: UUID(), defaults: try makeDefaults())
        let slot = UUID()
        let original = draft(
            unit: .miles, distance: "3.1", avgHeartRate: "150",
            calories: "300", incline: "-2", resistance: "6", hrZone: .z4)

        store.persist(slotID: slot, setIndex: 0, cardio: original)

        let snapshot = try XCTUnwrap(store.load(slotID: slot, setIndex: 0))

        // Restored in the *current* preference, not the one the draft was
        // persisted under: the field's label follows Settings, so restoring the
        // old unit would put a number on screen meaning something other than
        // its label. Every typed field survives verbatim.
        let restored = try XCTUnwrap(
            CardioEntryDraft(snapshot: snapshot, displayUnit: km))
        XCTAssertEqual(restored.unit, km)
        XCTAssertEqual(restored.distance, original.distance)
        XCTAssertEqual(restored.avgHeartRate, original.avgHeartRate)
        XCTAssertEqual(restored.calories, original.calories)
        XCTAssertEqual(restored.incline, original.incline)
        XCTAssertEqual(restored.resistance, original.resistance)
        XCTAssertEqual(restored.hrZone, original.hrZone)

        // Under the preference it was written in, it round-trips exactly.
        XCTAssertEqual(
            try XCTUnwrap(
                CardioEntryDraft(snapshot: snapshot, displayUnit: .miles)),
            original)
    }

    /// A strength or timed-hold draft carries no cardio fields, so nothing is
    /// rebuilt for it.
    func testSnapshotWithoutCardioFieldsRestoresNil() {
        let snapshot = ParentDraftStore.Snapshot(
            reps: "8", weight: "60", duration: nil)

        XCTAssertFalse(snapshot.hasCardio)
        XCTAssertNil(CardioEntryDraft(snapshot: snapshot, displayUnit: km))
    }

    func testUnparseablePersistedUnitFallsBackWithoutLosingDistance() {
        let snapshot = ParentDraftStore.Snapshot(
            distance: "5", distanceUnit: "kilometres")
        let restored = CardioEntryDraft(snapshot: snapshot, displayUnit: .miles)

        XCTAssertEqual(restored?.unit, .miles)
        XCTAssertEqual(restored?.distance, "5")
    }

    /// Adding cardio fields must not disturb the pre-Slice-4 layout: a draft
    /// written with only reps/weight/duration still reads back exactly.
    func testLegacyDraftStillLoadsUnchanged() throws {
        let store = ParentDraftStore(
            workoutID: UUID(), defaults: try makeDefaults())
        let slot = UUID()
        store.persist(slotID: slot, setIndex: 2, field: .reps, value: "8")
        store.persist(slotID: slot, setIndex: 2, field: .weight, value: "60")

        let snapshot = try XCTUnwrap(store.load(slotID: slot, setIndex: 2))
        XCTAssertEqual(snapshot.reps, "8")
        XCTAssertEqual(snapshot.weight, "60")
        XCTAssertNil(snapshot.duration)
        XCTAssertFalse(snapshot.hasCardio)
    }

    /// `clear` prefix-matches, so logging a set sweeps the cardio keys too.
    func testClearRemovesCardioFields() throws {
        let store = ParentDraftStore(
            workoutID: UUID(), defaults: try makeDefaults())
        let slot = UUID()
        store.persist(
            slotID: slot, setIndex: 0, cardio: draft(distance: "5"))
        XCTAssertNotNil(store.load(slotID: slot, setIndex: 0))

        store.clear(slotID: slot, setIndex: 0)

        XCTAssertNil(store.load(slotID: slot, setIndex: 0))
    }

    // MARK: - 10. Seeding from a logged set

    func testDraftSeedsFromALoggedCardioSet() {
        let log = SetLog(indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: 5_000, distanceUnit: .kilometers,
                avgHeartRate: 150, calories: 300, inclinePercent: -2.5,
                resistanceLevel: 6, hrZone: .z4))

        // The row is a live entry surface, so it re-expresses the logged
        // distance in the current preference — 5 km reads "3.11" under miles.
        // The `SetLog` itself is untouched; History still renders it in km.
        let seeded = CardioEntryDraft(logged: log, displayUnit: .miles)

        XCTAssertEqual(seeded.unit, .miles)
        XCTAssertEqual(seeded.distance, "3.11")
        XCTAssertEqual(log.distanceUnitRaw, "km")
        XCTAssertEqual(seeded.avgHeartRate, "150")
        XCTAssertEqual(seeded.calories, "300")
        XCTAssertEqual(seeded.incline, "-2.5")
        XCTAssertEqual(seeded.resistance, "6")
        XCTAssertEqual(seeded.hrZone, .z4)
    }

    /// A duration-only cardio set seeds an empty draft — nothing to show.
    func testDraftFromDurationOnlySetIsEmpty() {
        let log = SetLog(indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)

        let seeded = CardioEntryDraft(logged: log, displayUnit: km)

        XCTAssertTrue(seeded.isEmpty)
        XCTAssertEqual(seeded.unit, km)
    }

    // MARK: - Helpers

    /// An isolated `UserDefaults` suite so draft tests never touch the
    /// simulator's shared defaults or each other.
    private func makeDefaults() throws -> UserDefaults {
        let name = "CardioEntryDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

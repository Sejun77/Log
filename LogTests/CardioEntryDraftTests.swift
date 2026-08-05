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

    // MARK: - 8b. Live display-unit conversion
    //
    // What happens to an in-flight row when Settings changes underneath it.
    // The draft holds text, so conversion means parse → convert → reformat,
    // and the interesting cases are the ones where parsing fails.

    /// A clean km draft re-expressed in miles: the underlying distance is
    /// preserved exactly, only its expression changes.
    func testConvertingAValidKilometerDraftToMiles() throws {
        let converted = draft(unit: .kilometers, distance: "5")
            .converted(to: .miles)

        XCTAssertEqual(converted.unit, .miles)
        XCTAssertEqual(converted.distance, "3.11")
        XCTAssertEqual(
            try XCTUnwrap(converted.metrics.distanceMeters), 5_004.972,
            accuracy: 1.0,
            "the same distance, to within the rounding the field displays")
    }

    /// The mirror, and the one that must not lose the value: 3.1 mi → 4.99 km.
    func testConvertingAValidMileDraftToKilometers() throws {
        let original = draft(unit: .miles, distance: "3.1")
        let converted = original.converted(to: .kilometers)

        XCTAssertEqual(converted.unit, .kilometers)
        XCTAssertEqual(converted.distance, "4.99")
        XCTAssertEqual(
            try XCTUnwrap(original.metrics.distanceMeters), 4_988.9664,
            accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(converted.metrics.distanceMeters), 4_990,
            accuracy: 0.001,
            "the displayed value is rounded, so a converted draft carries the "
                + "rounded distance — it is what the user now sees")
    }

    /// Pace and speed are derived from `unit`, so they follow the conversion
    /// without any separate refresh. This is what makes the live preview,
    /// pace row and speed row update together.
    func testConversionUpdatesPaceAndSpeed() {
        let metric = draft(unit: .kilometers, distance: "6.2")
        XCTAssertEqual(metric.paceText(durationSeconds: 2_700), "7:15 /km")
        XCTAssertEqual(metric.speedText(durationSeconds: 2_700), "8.3 km/h")

        let imperial = metric.converted(to: .miles)
        XCTAssertEqual(imperial.distance, "3.85")
        XCTAssertEqual(imperial.paceText(durationSeconds: 2_700), "11:41 /mi")
        XCTAssertEqual(imperial.speedText(durationSeconds: 2_700), "5.1 mi/h")
    }

    /// The collapsed Details label follows too — it is built from `metrics`
    /// and `unit`, both of which the conversion moved.
    func testConversionUpdatesTheCollapsedSummary() {
        let metric = draft(unit: .kilometers, distance: "5", avgHeartRate: "142")
        XCTAssertEqual(metric.summaryText, "5 km · 142 bpm")

        XCTAssertEqual(
            metric.converted(to: .miles).summaryText, "3.11 mi · 142 bpm")
    }

    /// A row the user cleared stays cleared — conversion must not put a number
    /// into an empty field.
    func testConvertingAnEmptyDraftLeavesItEmpty() {
        let converted = draft(unit: .kilometers, distance: "")
            .converted(to: .miles)

        XCTAssertEqual(converted.unit, .miles)
        XCTAssertEqual(converted.distance, "")
        XCTAssertTrue(converted.isEmpty)
    }

    /// Input with no usable number keeps its **exact** keystrokes and changes
    /// only the unit. There is nothing to convert, so converting would mean
    /// inventing a value; every one of these already means "no distance" to
    /// `metrics`, so the preserved text cannot be misread downstream.
    func testConvertingUnparseableDistancePreservesTheRawText() {
        for text in [".", "abc", "0", "1001", "   "] {
            let draftInKm = draft(unit: .kilometers, distance: text)
            XCTAssertNil(
                draftInKm.metrics.distanceMeters,
                "precondition: \"\(text)\" is not a usable distance")

            let converted = draftInKm.converted(to: .miles)
            XCTAssertEqual(
                converted.distance, text,
                "\"\(text)\" must survive a unit change untouched")
            XCTAssertEqual(converted.unit, .miles)
        }
    }

    /// A trailing separator is **not** in that group: `Double("6.")` is 6.0, so
    /// "6." is a usable 6 km and converts like any other number.
    ///
    /// This costs the user their in-progress keystrokes — a field part-way
    /// through "6.25" becomes "3.73" — and that is the deliberate trade. The
    /// alternative leaves "6." sitting under a "mi" label, which restates 6 km
    /// as 6 mi: the silent reinterpretation this slice exists to prevent.
    func testConvertingATrailingSeparatorConvertsTheNumber() {
        let converted = draft(unit: .kilometers, distance: "6.")
            .converted(to: .miles)

        XCTAssertEqual(converted.distance, "3.73")
        XCTAssertEqual(converted.unit, .miles)
    }

    /// Every other field is unitless and must come through a conversion
    /// byte-identical.
    func testConversionTouchesNothingButTheDistance() {
        let original = draft(
            unit: .kilometers, distance: "5", avgHeartRate: "150",
            calories: "300", incline: "-2.5", resistance: "6", hrZone: .z4)
        let converted = original.converted(to: .miles)

        XCTAssertEqual(converted.avgHeartRate, original.avgHeartRate)
        XCTAssertEqual(converted.calories, original.calories)
        XCTAssertEqual(converted.incline, original.incline)
        XCTAssertEqual(converted.resistance, original.resistance)
        XCTAssertEqual(converted.hrZone, original.hrZone)
    }

    /// Converting to the unit it is already in is an identity, so a redundant
    /// resync cannot nudge a rounded value.
    func testConvertingToTheSameUnitIsAnIdentity() {
        let original = draft(unit: .miles, distance: "3.1")
        XCTAssertEqual(original.converted(to: .miles), original)

        // And repeated round trips do not drift further than the first
        // rounding: 3.1 mi → 4.99 km → 3.1 mi.
        XCTAssertEqual(
            original.converted(to: .kilometers).converted(to: .miles).distance,
            "3.1")
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

        // Restored in the current preference, and the distance **converted**
        // into it: the persisted unit says what the text was typed in, so 3.1
        // mi comes back as 4.99 km rather than being relabelled as 4.99— or,
        // worse, left as "3.1" under a km label. This is what makes a resumed
        // session show exactly what the live one showed.
        let restored = try XCTUnwrap(
            CardioEntryDraft(snapshot: snapshot, displayUnit: km))
        XCTAssertEqual(restored.unit, km)
        XCTAssertEqual(restored.distance, "4.99")
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

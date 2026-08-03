import SwiftData
import XCTest

@testable import Log

/// Beta cardio support (Friends & Family Beta, 2026-08-02).
///
/// The product decision for this phase was deliberately narrow: **cardio is a
/// duration-based exercise**, with no structured distance / pace / calorie /
/// heart-rate / incline / resistance fields.
///
/// > **Superseded in part.** Cardio Slice 3 (`SetLogCardioMetricsTests`) added
/// > those fields to `SetLog`, all optional and nil by default. What survives
/// > unchanged — and is what these tests actually guard — is that the *seeded
/// > catalogue* stays duration-based and that a cardio slot is still governed
/// > by the duration rules. Structured metrics are opt-in per set; a beta
/// > cardio log carrying only a duration renders exactly as it always has.
///
/// These tests pin the parts of that decision that are easy to break later:
/// the seeded cardio catalogue stays duration-based, the Cardio body part stays
/// canonical and Korean-localized, and a cardio slot is still governed by the
/// duration rules (no tempo, no Tempo Override).
@MainActor
final class BetaCardioSupportTests: SwiftDataTestHarness {

    private var cardioSeeds: [ExerciseSeed] {
        ExerciseCatalog.v1.filter { $0.bodyPart == "Cardio" }
    }

    // MARK: - 1. Catalogue shape

    func testCardioExercisesAreSeeded() {
        let names = Set(cardioSeeds.map(\.name))
        for expected in [
            "Walking", "Treadmill Run", "Treadmill Walk", "Stationary Bike",
            "Elliptical", "Stair Climber", "Rowing Machine",
        ] {
            XCTAssertTrue(
                names.contains(expected),
                "\(expected) should be part of the seeded cardio catalogue")
        }
    }

    /// The whole beta cardio story rests on this: cardio is logged as time, so
    /// a seeded cardio exercise that defaulted to reps/weight would silently
    /// contradict the user guide.
    func testAllSeededCardioExercisesAreDurationBased() {
        XCTAssertFalse(cardioSeeds.isEmpty)
        for seed in cardioSeeds {
            XCTAssertTrue(
                seed.isTimeBased,
                "\(seed.name) should default to duration-based tracking")
        }
    }

    func testCardioIsACanonicalBodyPart() {
        XCTAssertTrue(
            ExerciseDetailView.canonicalBodyParts.contains("Cardio"),
            "Cardio must stay in the canonical body-part list so seeded cardio "
                + "rows surface as an already-selected picker value")
    }

    /// A new catalogue entry only reaches existing installs if the version
    /// advanced past the v1-era flag.
    func testCatalogVersionAdvancedForTheCardioAddition() {
        XCTAssertGreaterThanOrEqual(ExerciseCatalog.currentVersion, 2)
    }

    // MARK: - 2. Seeding into a store

    func testSeedingInsertsDurationBasedCardioRows() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "BetaCardioSupportTests.seeding"))
        defaults.removePersistentDomain(forName: "BetaCardioSupportTests.seeding")

        ExerciseSeedService.seedIfNeeded(in: context, defaults: defaults)

        let stored = try context.fetch(FetchDescriptor<Exercise>())
        let cardio = stored.filter { $0.bodyPart == "Cardio" }

        XCTAssertEqual(cardio.count, cardioSeeds.count)
        for row in cardio {
            XCTAssertTrue(
                row.isTimeBased,
                "\(row.name) should be inserted as a duration-based exercise")
        }
    }

    // MARK: - 3. Korean localization

    /// Cardio already existed as a body part before this slice; the beta
    /// requirement was that it is visible and localized, not that it is new.
    func testCardioBodyPartLocalizesToKorean() throws {
        let bundle = try XCTUnwrap(
            Bundle(
                path: try XCTUnwrap(
                    Bundle(for: Exercise.self)
                        .path(forResource: "ko", ofType: "lproj"))))
        XCTAssertEqual(
            bundle.localizedString(forKey: "Cardio", value: "Cardio", table: nil),
            "유산소")
    }

    // MARK: - 4. Cardio follows the duration rules

    /// A 45-minute cardio target is exactly the case the old 600s ceiling made
    /// impossible.
    func testCardioSlotHoldsALongDurationTarget() {
        var plan = SessionPlan()
        plan.usesDuration = true
        plan.sets = 1
        plan.durationMaxSeconds =
            DurationLimits.normalizedExerciseDuration(2_700)

        XCTAssertEqual(plan.durationMaxSeconds, 2_700)
        XCTAssertTrue(plan.primarySummary.contains("2700s"))
    }

    /// Tempo describes rep phases, so it stays suppressed for cardio — the same
    /// rule the tempo/Tempo Override cleanup established for duration slots.
    func testCardioSlotNeverShowsTempo() {
        var plan = SessionPlan()
        plan.usesDuration = true
        plan.tempo = "3-1-1-0"  // stale value, e.g. from a switched slot

        XCTAssertNil(plan.effectiveTempo)
        XCTAssertFalse(plan.secondarySummary(effortSummary: nil).contains("Tempo"))
    }

    func testTempoOverrideIsNotAvailableToCardio() {
        let plan = TechniquePlan(order: 0, type: .tempoOverride)
        context.insert(plan)

        XCTAssertTrue(
            compatibleTechniquePlans(
                [plan], isBodyweight: false, usesDuration: true
            ).isEmpty,
            "Tempo Override must stay incompatible with duration-based cardio")
    }

    /// Notes are the beta's answer for distance / speed / incline / resistance
    /// / heart-rate zone, so both note fields have to be usable on a cardio
    /// exercise.
    func testCardioExerciseAcceptsExerciseAndSetupNotes() throws {
        let ex = Exercise(
            name: "Stationary Bike", bodyPart: "Cardio",
            equipmentType: "Machine")
        ex.isTimeBased = true
        ex.notes = "Zone 2, ~90 rpm"
        ex.setupDefaults = "Resistance 8, seat height 5"
        context.insert(ex)
        try context.save()

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Exercise>()).first)
        XCTAssertTrue(stored.isTimeBased)
        XCTAssertEqual(stored.notes, "Zone 2, ~90 rpm")
        XCTAssertEqual(stored.setupDefaults, "Resistance 8, seat height 5")
    }
}

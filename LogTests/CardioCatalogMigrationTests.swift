import SwiftData
import XCTest

@testable import Log

/// Cardio Slice 10 — catalogue v3 and the assisted "mark as cardio" migration.
///
/// Two halves, one story:
///
///  1. **Catalogue v3** teaches the *seeder* about cardio, so a fresh install
///     gets real cardio exercises with no user action. It changes nothing for
///     an existing install: the per-name dedupe still skips every row the user
///     already has, which is exactly why the second half exists.
///  2. **`CardioMigrationService`** finds the pre-cardio rows a v2-era install
///     is left with and offers — never performs — the conversion. Every test
///     below that touches the prompt routes through an isolated `UserDefaults`
///     suite so the flag never leaks into the simulator's global defaults.
@MainActor
final class CardioCatalogMigrationTests: SwiftDataTestHarness {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CardioCatalogMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let suite = suiteName, let d = defaults {
            d.removePersistentDomain(forName: suite)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func seed(_ seeds: [ExerciseSeed]? = nil) {
        if let seeds {
            ExerciseSeedService.seedIfNeeded(
                in: context, seeds: seeds, defaults: defaults)
        } else {
            ExerciseSeedService.seedIfNeeded(in: context, defaults: defaults)
        }
    }

    private func allExercises() throws -> [Exercise] {
        try context.fetch(FetchDescriptor<Exercise>())
    }

    private func stored(_ name: String) throws -> Exercise {
        try XCTUnwrap(
            try allExercises().first { $0.name == name },
            "missing exercise: \(name)")
    }

    /// A pre-cardio Cardio exercise, exactly as a v2-era install holds it:
    /// time-based, filed under Cardio, `isCardio` never set because the field
    /// did not exist when the row was written.
    @discardableResult
    private func legacyCardioExercise(
        name: String = "Treadmill Run",
        bodyPart: String? = "Cardio"
    ) -> Exercise {
        let ex = Exercise(
            name: name, bodyPart: bodyPart, equipmentType: "Machine",
            isCustom: false)
        ex.isTimeBased = true
        context.insert(ex)
        try? context.save()
        return ex
    }

    // MARK: - 1. Catalogue v3 shape

    func testCatalogVersionIsV3() {
        XCTAssertGreaterThanOrEqual(ExerciseCatalog.currentVersion, 3)
    }

    func testEveryCardioSeedIsMarkedCardio() {
        let cardio = ExerciseCatalog.v1.filter { $0.bodyPart == "Cardio" }
        XCTAssertFalse(cardio.isEmpty)
        for entry in cardio {
            XCTAssertTrue(
                entry.isCardio, "\(entry.name) should be a cardio seed")
            XCTAssertTrue(
                entry.isTimeBased,
                "\(entry.name) must stay time-based — cardio implies duration")
        }
    }

    /// The value-level half of the `isCardio ⇒ isTimeBased` invariant: a seed
    /// that asks for cardio without duration is normalized, not stored.
    func testCardioSeedWithoutTimeBasedIsRejectedAtConstruction() {
        let malformed = ExerciseSeed(
            name: "Impossible", bodyPart: "Cardio", isTimeBased: false,
            isCardio: true)
        XCTAssertFalse(malformed.isCardio)
    }

    func testNoNonCardioSeedIsMarkedCardio() {
        for entry in ExerciseCatalog.v1 where entry.bodyPart != "Cardio" {
            XCTAssertFalse(
                entry.isCardio,
                "\(entry.name) is not a Cardio-body-part seed and must not be "
                    + "marked cardio")
        }
    }

    // MARK: - 2. Fresh seed into a store

    func testFreshSeedInsertsCardioRowsAsCardio() throws {
        seed()

        let cardio = try allExercises().filter { $0.bodyPart == "Cardio" }
        XCTAssertFalse(cardio.isEmpty)
        for row in cardio {
            XCTAssertTrue(row.isCardio, "\(row.name) should seed as cardio")
            XCTAssertTrue(
                row.isTimeBased, "\(row.name) should seed as time-based")
            XCTAssertEqual(
                row.trackingMode, .cardio,
                "\(row.name) should resolve to the cardio tracking mode")
        }
    }

    func testFreshSeedKeepsStrengthExercisesStrength() throws {
        seed()

        let bench = try stored("Barbell Bench Press")
        XCTAssertFalse(bench.isTimeBased)
        XCTAssertFalse(bench.isCardio)
        XCTAssertEqual(bench.trackingMode, .strength)
    }

    /// Plank is the case v3 is most likely to get wrong: time-based, but not
    /// cardio. It must stay a timed hold.
    func testFreshSeedKeepsTimedHoldsAsTimedHolds() throws {
        seed()

        let plank = try stored("Plank")
        XCTAssertTrue(plank.isTimeBased)
        XCTAssertFalse(plank.isCardio)
        XCTAssertEqual(plank.trackingMode, .timedHold)
    }

    /// Every seeded row must satisfy the model invariant, whatever the
    /// catalogue says.
    func testSeededRowsNeverHoldTheImpossibleState() throws {
        seed()
        for row in try allExercises() {
            if row.isCardio {
                XCTAssertTrue(
                    row.isTimeBased,
                    "\(row.name) is cardio but not time-based")
            }
        }
    }

    // MARK: - 3. v3 does not disturb existing installs

    /// The v3 bump re-runs the seed pass, and the dedupe must still hold — no
    /// duplicate rows for names the user already has.
    func testV3ReSeedDoesNotDuplicateExistingCatalogNames() throws {
        for entry in ExerciseCatalog.v1 {
            context.insert(Exercise(name: entry.name))
        }
        try context.save()

        seed()

        XCTAssertEqual(try allExercises().count, ExerciseCatalog.v1.count)
    }

    /// The heart of "no silent mutation": a user's own edited row keeps every
    /// field, including `isCardio == false`, after the v3 pass runs over it.
    func testV3ReSeedDoesNotOverwriteUserEditedCardioRow() throws {
        let user = Exercise(
            name: "Treadmill Run", bodyPart: "Cardio",
            notes: "Zone 2 only", equipmentType: "Machine",
            setupDefaults: "Belt speed 8", isCustom: true)
        user.isTimeBased = true
        context.insert(user)
        try context.save()

        seed()

        let matches = try allExercises().filter { $0.name == "Treadmill Run" }
        XCTAssertEqual(matches.count, 1, "no duplicate of the user's row")
        let preserved = try XCTUnwrap(matches.first)
        XCTAssertEqual(preserved.notes, "Zone 2 only")
        XCTAssertEqual(preserved.setupDefaults, "Belt speed 8")
        XCTAssertTrue(preserved.isCustom)
        XCTAssertFalse(
            preserved.isCardio,
            "the seed pass must never flip a user's row to cardio — that is "
                + "the assisted prompt's job")
    }

    // MARK: - 4. Candidate detection

    func testLegacyCardioExerciseIsACandidate() {
        let ex = legacyCardioExercise()
        XCTAssertTrue(CardioMigrationService.isCandidate(ex))
        XCTAssertEqual(CardioMigrationService.candidates(in: context).count, 1)
    }

    func testAlreadyCardioExerciseIsNotACandidate() {
        let ex = legacyCardioExercise()
        ex.setCardio(true)
        XCTAssertFalse(CardioMigrationService.isCandidate(ex))
        XCTAssertTrue(CardioMigrationService.candidates(in: context).isEmpty)
    }

    func testNonTimeBasedCardioExerciseIsNotACandidate() {
        let ex = Exercise(name: "Sled Push", bodyPart: "Cardio")
        context.insert(ex)
        XCTAssertFalse(CardioMigrationService.isCandidate(ex))
        XCTAssertTrue(CardioMigrationService.candidates(in: context).isEmpty)
    }

    /// Plank again, from the other side: a timed hold outside Cardio is never
    /// swept up, because the rule never looks at the name.
    func testTimedHoldOutsideCardioIsNotACandidate() {
        let plank = Exercise(name: "Plank", bodyPart: "Core")
        plank.isTimeBased = true
        context.insert(plank)
        XCTAssertFalse(CardioMigrationService.isCandidate(plank))
        XCTAssertTrue(CardioMigrationService.candidates(in: context).isEmpty)
    }

    /// A cardio-sounding name filed under a strength body part stays put —
    /// nothing is inferred from names in this slice.
    func testCardioNamedExerciseOutsideCardioBodyPartIsNotACandidate() {
        let ex = legacyCardioExercise(name: "Treadmill Run", bodyPart: "Legs")
        XCTAssertFalse(CardioMigrationService.isCandidate(ex))
    }

    func testStrengthExerciseIsNotACandidate() {
        let ex = Exercise(name: "Back Squat", bodyPart: "Quads")
        context.insert(ex)
        XCTAssertFalse(CardioMigrationService.isCandidate(ex))
    }

    func testExerciseWithNoBodyPartIsNotACandidate() {
        let ex = Exercise(name: "Mystery")
        ex.isTimeBased = true
        context.insert(ex)
        XCTAssertFalse(CardioMigrationService.isCandidate(ex))
    }

    /// Legacy rows and CSV imports carry casing / whitespace variants of the
    /// canonical body part, and they are the same exercise to the user.
    func testBodyPartMatchIsTrimmedAndCaseInsensitive() {
        let ex = legacyCardioExercise(name: "Old Bike", bodyPart: " cardio ")
        XCTAssertTrue(CardioMigrationService.isCandidate(ex))
    }

    func testEmptyStoreHasNoCandidates() {
        XCTAssertTrue(CardioMigrationService.candidates(in: context).isEmpty)
        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
    }

    // MARK: - 5. Prompt gating

    /// The four corners of the gate, spelled out. The pre-merge bug was in the
    /// *presentation*, not here, but these pin the contract `BootstrapRoot` now
    /// re-asks on every return to `.active`.
    func testMissingFlagWithCandidatesOffersPrompt() {
        legacyCardioExercise()
        XCTAssertEqual(
            defaults.object(forKey: CardioMigrationService.promptVersionKey)
                as? Int, nil,
            "precondition: the flag is absent")
        XCTAssertTrue(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
    }

    func testMissingFlagWithoutCandidatesDoesNotOfferPrompt() {
        let ex = legacyCardioExercise()
        ex.setCardio(true)
        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
    }

    func testCurrentVersionFlagWithCandidatesDoesNotOfferPrompt() {
        legacyCardioExercise()
        defaults.set(
            ExerciseCatalog.currentVersion,
            forKey: CardioMigrationService.promptVersionKey)

        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
    }

    func testOlderVersionFlagWithCandidatesOffersPrompt() {
        legacyCardioExercise()
        defaults.set(
            ExerciseCatalog.currentVersion - 1,
            forKey: CardioMigrationService.promptVersionKey)

        XCTAssertTrue(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
    }

    /// The offer is a question about the **store**, not about what this launch
    /// happened to do. Here the seed flag is already current, so `seedIfNeeded`
    /// short-circuits and inserts nothing — and the offer still stands.
    func testPromptIsIndependentOfSeedingRunningThisLaunch() throws {
        defaults.set(
            ExerciseCatalog.currentVersion,
            forKey: ExerciseSeedService.seedVersionKey)
        legacyCardioExercise(name: "Old Bike")
        let countBefore = try allExercises().count

        seed()

        XCTAssertEqual(
            try allExercises().count, countBefore,
            "precondition: the seed pass did nothing this launch")
        XCTAssertNil(
            defaults.object(forKey: CardioMigrationService.promptVersionKey),
            "a short-circuited seed pass must not resolve the prompt")
        XCTAssertTrue(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults),
            "the offer must not depend on the seeder having run")
    }

    /// Asking repeatedly — which is what the scene-phase retry does — must not
    /// change the answer or resolve anything by itself.
    func testRepeatedEvaluationIsIdempotentAndWritesNothing() {
        legacyCardioExercise()

        for _ in 0..<5 {
            XCTAssertTrue(
                CardioMigrationService.shouldOfferPrompt(
                    in: context, defaults: defaults))
        }

        XCTAssertNil(
            defaults.object(forKey: CardioMigrationService.promptVersionKey),
            "evaluating the offer must never resolve it — only the user or a "
                + "fresh seed does that")
        XCTAssertEqual(CardioMigrationService.candidates(in: context).count, 1)
    }

    /// Evaluating against an empty store is the launch-path worst case: it must
    /// answer `false` without throwing or crashing.
    func testEvaluationOnEmptyStoreIsSafe() {
        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
        XCTAssertEqual(
            CardioMigrationService.markCandidatesAsCardio(
                in: context, defaults: defaults),
            0)
    }

    /// A fresh install must not prompt — and the reason matters. It is silent
    /// because catalogue v3 seeds cardio rows correctly and the candidate rule
    /// finds nothing, **not** because anything pre-resolved the flag.
    func testFreshInstallSeedNeverPrompts() throws {
        seed()

        XCTAssertTrue(CardioMigrationService.candidates(in: context).isEmpty)
        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
    }

    /// The seeder must not write the prompt flag on any path.
    ///
    /// > **Regression test for the pre-merge bug.** The first cut resolved the
    /// > flag whenever it seeded into an empty store. On device that produced
    /// > `versionGate=BLOCKED promptVersionRaw=3` against a store with seven
    /// > valid candidates: the offer was dead before it was ever asked for.
    func testFreshSeedDoesNotResolveThePromptFlag() throws {
        seed()

        XCTAssertNil(
            defaults.object(forKey: CardioMigrationService.promptVersionKey),
            "only the user resolves the prompt — seeding must not touch it")
    }

    /// The case the bug actually broke: install the new build, *then* import an
    /// old exercise library. Those rows are genuine legacy candidates and must
    /// still be offered.
    func testCandidatesArrivingAfterAFreshSeedAreStillOffered() throws {
        seed()
        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults),
            "precondition: nothing to offer straight after seeding")

        // e.g. an exercise CSV import bringing a pre-cardio row across.
        let imported = legacyCardioExercise(name: "CSV Bike")

        XCTAssertTrue(CardioMigrationService.isCandidate(imported))
        XCTAssertTrue(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults),
            "a candidate that appears after seeding must still be offered")
    }

    /// An upgrading v2-era install is the case the prompt exists for: the
    /// re-seed inserts nothing new and the legacy row stays a candidate.
    func testUpgradingInstallStillPrompts() throws {
        legacyCardioExercise()
        try context.save()

        seed()

        XCTAssertTrue(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults),
            "a store that already had rows is an upgrade, not a fresh install")
    }

    func testNotNowStopsTheNagging() {
        legacyCardioExercise()
        XCTAssertTrue(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))

        CardioMigrationService.resolvePrompt(defaults: defaults)

        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults),
            "the prompt must not reappear on the next launch under the same "
                + "catalogue version")
    }

    func testNotNowConvertsNothing() throws {
        let ex = legacyCardioExercise()
        try context.save()

        CardioMigrationService.resolvePrompt(defaults: defaults)

        XCTAssertFalse(ex.isCardio)
        XCTAssertTrue(ex.isTimeBased)
        XCTAssertEqual(ex.trackingMode, .timedHold)
    }

    /// The flag is a version, not a bool: a later catalogue version may offer
    /// the migration once more to a user who still has candidates.
    func testDismissalIsScopedToTheCatalogVersion() {
        legacyCardioExercise()
        defaults.set(
            ExerciseCatalog.currentVersion - 1,
            forKey: CardioMigrationService.promptVersionKey)

        XCTAssertTrue(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults),
            "a dismissal recorded under an older catalogue version must not "
                + "silence the current one")
    }

    /// Requirement 21: manually converting the candidates in Exercise Detail
    /// takes the prompt away, because the gate reads the store as well as the
    /// flag.
    func testManualConversionRemovesThePrompt() throws {
        let ex = legacyCardioExercise()
        try context.save()
        XCTAssertTrue(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))

        ex.setCardio(true)
        try context.save()

        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
    }

    // MARK: - 6. Conversion

    func testMarkAsCardioConvertsOnlyCandidates() throws {
        let candidate = legacyCardioExercise(name: "Old Treadmill")
        let plank = Exercise(name: "Plank", bodyPart: "Core")
        plank.isTimeBased = true
        let squat = Exercise(name: "Back Squat", bodyPart: "Quads")
        let alreadyCardio = legacyCardioExercise(name: "Rower")
        alreadyCardio.setCardio(true)
        context.insert(plank)
        context.insert(squat)
        try context.save()

        let converted = CardioMigrationService.markCandidatesAsCardio(
            in: context, defaults: defaults)

        XCTAssertEqual(converted, 1)
        XCTAssertEqual(candidate.trackingMode, .cardio)
        XCTAssertEqual(plank.trackingMode, .timedHold)
        XCTAssertEqual(squat.trackingMode, .strength)
        XCTAssertEqual(alreadyCardio.trackingMode, .cardio)
    }

    func testMarkAsCardioResolvesThePrompt() throws {
        legacyCardioExercise()
        try context.save()

        CardioMigrationService.markCandidatesAsCardio(
            in: context, defaults: defaults)

        XCTAssertFalse(
            CardioMigrationService.shouldOfferPrompt(in: context, defaults: defaults))
    }

    /// The conversion writes one field. Everything the user owns — identity,
    /// notes, equipment, setup defaults, ordering, routine slots, and logged
    /// history — has to come through untouched.
    func testMarkAsCardioPreservesUserData() throws {
        let ex = Exercise(
            name: "Treadmill Run", bodyPart: "Cardio",
            notes: "Zone 2, nasal breathing", equipmentType: "Machine",
            setupDefaults: "Belt speed 8, incline 2", isCustom: true)
        ex.isTimeBased = true
        ex.order = 7
        context.insert(ex)

        // A routine slot pointing at it…
        let prescription = SlotPrescription()
        context.insert(prescription)
        let slot = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(slot)
        slot.prescription = prescription
        let slotID = slot.slotID

        // …and a logged bout in History.
        let item = WorkoutItem(exercise: ex, setLogs: [])
        context.insert(item)
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: 0, weight: nil,
            durationSeconds: 1_800)
        context.insert(log)
        item.setLogs.append(log)
        let workout = Workout(date: .now, items: [item])
        workout.completedAt = .now
        context.insert(workout)
        let exID = ex.id
        try context.save()

        let converted = CardioMigrationService.markCandidatesAsCardio(
            in: context, defaults: defaults)
        XCTAssertEqual(converted, 1)

        let after = try stored("Treadmill Run")
        XCTAssertEqual(after.id, exID, "identity is preserved, not recreated")
        XCTAssertEqual(after.bodyPart, "Cardio")
        XCTAssertEqual(after.notes, "Zone 2, nasal breathing")
        XCTAssertEqual(after.equipmentType, "Machine")
        XCTAssertEqual(after.setupDefaults, "Belt speed 8, incline 2")
        XCTAssertEqual(after.order, 7)
        XCTAssertTrue(after.isCustom)
        XCTAssertTrue(after.isTimeBased)
        XCTAssertEqual(after.trackingMode, .cardio)

        // No exercise was added or removed.
        XCTAssertEqual(try allExercises().count, 1)

        // The routine slot still points at the same exercise, same slot ID.
        let slots = try context.fetch(FetchDescriptor<RoutineExercise>())
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.slotID, slotID)
        XCTAssertEqual(slots.first?.exercise?.id, exID)

        // History rows are untouched: still one duration-only working set with
        // no cardio metrics written behind the user's back.
        let logs = try context.fetch(FetchDescriptor<SetLog>())
        XCTAssertEqual(logs.count, 1)
        let storedLog = try XCTUnwrap(logs.first)
        XCTAssertEqual(storedLog.durationSeconds, 1_800)
        XCTAssertEqual(storedLog.reps, 0)
        XCTAssertNil(storedLog.distanceMeters)
        XCTAssertNil(storedLog.avgHeartRate)
        XCTAssertNil(storedLog.calories)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Workout>()).count, 1)
    }
}

import SwiftData
import XCTest

@testable import Log

/// Phase 10-polish-F (2026-05-24) — coverage for `ExerciseSeedService`:
/// first-launch seeding, idempotency under the version flag, the per-name
/// dedupe safety net for when the flag is missing but rows already exist,
/// preservation of user-created rows, deletion durability across a second
/// `seedIfNeeded` call under the same version, and the defensive
/// empty/whitespace-name skip.
///
/// Test isolation:
///   - SwiftData state: inherited from `SwiftDataTestHarness` which spins up
///     a fresh in-memory `ModelContainer` per test.
///   - UserDefaults state: a per-test isolated suite (`UserDefaults(suiteName:)`)
///     created in `setUp` and torn down in `tearDown`, so the seed-version
///     flag never leaks between tests or into the simulator's global
///     defaults. The service is invoked with `defaults:` to route reads /
///     writes through that suite.
@MainActor
final class ExerciseSeedServiceTests: SwiftDataTestHarness {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ExerciseSeedServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Defensive: even though the suite name is unique, clear it before
        // every test so a stuck previous run can't change the outcome.
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

    /// Convenience wrapper that always routes through the isolated suite.
    private func runSeed(_ seeds: [ExerciseSeed]? = nil) {
        if let seeds {
            ExerciseSeedService.seedIfNeeded(
                in: context, seeds: seeds, defaults: defaults
            )
        } else {
            ExerciseSeedService.seedIfNeeded(in: context, defaults: defaults)
        }
    }

    private func allExercises() throws -> [Exercise] {
        try context.fetch(FetchDescriptor<Exercise>())
    }

    // MARK: - 1. Seeds on empty store

    func testSeedsOnEmptyStore() throws {
        XCTAssertEqual(try allExercises().count, 0)

        runSeed()

        let fetched = try allExercises()
        XCTAssertEqual(fetched.count, ExerciseCatalog.v1.count)

        let names = Set(fetched.map(\.name))
        for seed in ExerciseCatalog.v1 {
            XCTAssertTrue(
                names.contains(seed.name),
                "missing seeded exercise: \(seed.name)"
            )
        }
    }

    // MARK: - 2. isCustom == false on every seeded row

    func testSeededRowsHaveIsCustomFalse() throws {
        runSeed()
        let fetched = try allExercises()
        XCTAssertEqual(fetched.count, ExerciseCatalog.v1.count)
        XCTAssertTrue(
            fetched.allSatisfy { $0.isCustom == false },
            "every seeded row should have isCustom == false"
        )
    }

    // MARK: - 3. bodyPart / equipmentType / isTimeBased match catalogue

    func testSeededRowsMatchCatalogFields() throws {
        runSeed()
        let fetched = try allExercises()
        let byName: [String: Exercise] = Dictionary(
            uniqueKeysWithValues: fetched.map { ($0.name, $0) }
        )

        for seed in ExerciseCatalog.v1 {
            guard let ex = byName[seed.name] else {
                XCTFail("missing seeded exercise: \(seed.name)")
                continue
            }
            XCTAssertEqual(
                ex.bodyPart, seed.bodyPart,
                "bodyPart mismatch for \(seed.name)"
            )
            XCTAssertEqual(
                ex.equipmentType, seed.equipmentType,
                "equipmentType mismatch for \(seed.name)"
            )
            XCTAssertEqual(
                ex.isTimeBased, seed.isTimeBased,
                "isTimeBased mismatch for \(seed.name)"
            )
            XCTAssertEqual(
                ex.setupDefaults, seed.setupDefaults,
                "setupDefaults mismatch for \(seed.name)"
            )
        }
    }

    // MARK: - 4. Orders start from 0 and are unique on an empty store

    func testOrdersStartFromZeroAndAreUnique() throws {
        runSeed()
        let fetched = try allExercises()
        let orders = fetched.map(\.order).sorted()

        XCTAssertEqual(orders.first, 0)
        XCTAssertEqual(
            Set(orders).count, orders.count,
            "seeded orders must be unique"
        )
        // Contiguous on empty store: 0..<count.
        XCTAssertEqual(orders, Array(0..<ExerciseCatalog.v1.count))
    }

    // MARK: - 5. Orders append after existing max

    func testOrdersAppendAfterExistingMax() throws {
        let pre1 = Exercise(name: "User 1")
        pre1.order = 5
        let pre2 = Exercise(name: "User 2")
        pre2.order = 9
        context.insert(pre1)
        context.insert(pre2)
        try context.save()

        runSeed()

        let fetched = try allExercises()
        let seededRows = fetched.filter { $0.isCustom == false }
        XCTAssertEqual(seededRows.count, ExerciseCatalog.v1.count)

        let minSeededOrder = seededRows.map(\.order).min()
        XCTAssertEqual(
            minSeededOrder, 10,
            "first seeded row should start at maxExistingOrder + 1"
        )

        let allOrders = fetched.map(\.order)
        XCTAssertEqual(
            Set(allOrders).count, allOrders.count,
            "no order collisions between user rows and seeded rows"
        )
    }

    // MARK: - 6. Second run does not duplicate rows

    func testSecondRunDoesNotDuplicate() throws {
        runSeed()
        let firstCount = try allExercises().count
        XCTAssertEqual(firstCount, ExerciseCatalog.v1.count)

        runSeed()
        let secondCount = try allExercises().count
        XCTAssertEqual(secondCount, firstCount)
    }

    // MARK: - 7. Missing flag + existing names → no duplicates

    func testMissingFlagWithExistingNamesProducesNoDuplicates() throws {
        // Pre-insert every catalogue name manually (e.g. simulating a store
        // that was populated some other way, then the seed-version flag was
        // cleared / lost).
        for seed in ExerciseCatalog.v1 {
            context.insert(Exercise(name: seed.name))
        }
        try context.save()

        // Confirm flag is absent (integer(forKey:) returns 0 when missing).
        XCTAssertEqual(
            defaults.integer(forKey: ExerciseSeedService.seedVersionKey), 0
        )

        runSeed()

        let fetched = try allExercises()
        XCTAssertEqual(
            fetched.count, ExerciseCatalog.v1.count,
            "per-name dedupe should prevent duplicates even with flag absent"
        )
    }

    // MARK: - 8. User-created exercise with same name is not overwritten

    func testExistingUserCreatedExerciseNotOverwritten() throws {
        // Pick a name that's in the catalogue with a specific bodyPart so the
        // collision is unambiguous.
        let targetName = "Barbell Bench Press"
        let user = Exercise(
            name: targetName,
            bodyPart: "Pecs",
            notes: "User notes",
            equipmentType: nil,
            setupDefaults: "Custom setup",
            isCustom: true
        )
        user.order = 0
        context.insert(user)
        try context.save()

        runSeed()

        let fetched = try allExercises()
        let matches = fetched.filter { $0.name == targetName }
        XCTAssertEqual(matches.count, 1, "no duplicate of the user's row")

        let preserved = try XCTUnwrap(matches.first)
        XCTAssertEqual(preserved.bodyPart, "Pecs")
        XCTAssertEqual(preserved.notes, "User notes")
        XCTAssertNil(preserved.equipmentType)
        XCTAssertEqual(preserved.setupDefaults, "Custom setup")
        XCTAssertTrue(preserved.isCustom, "user row must remain isCustom")
    }

    // MARK: - 9. Case-insensitive dedupe

    func testCaseInsensitiveDedupePreventsDuplicate() throws {
        // Lowercase variant of a catalogue entry.
        let user = Exercise(
            name: "barbell bench press",
            bodyPart: "Pecs",
            isCustom: true
        )
        context.insert(user)
        try context.save()

        runSeed()

        let fetched = try allExercises()
        let matches = fetched.filter {
            $0.name.lowercased() == "barbell bench press"
        }
        XCTAssertEqual(
            matches.count, 1,
            "case-insensitive match should suppress the seeded duplicate"
        )
        // The surviving row should be the user's lowercase one.
        XCTAssertEqual(matches.first?.name, "barbell bench press")
        XCTAssertTrue(matches.first?.isCustom ?? false)
    }

    // MARK: - 10. Deleted seeded row stays deleted across relaunches

    func testDeletedSeededRowStaysDeletedAcrossSecondSeed() throws {
        runSeed()

        let initial = try allExercises()
        let target = try XCTUnwrap(initial.first { $0.name == "Pull-Up" })
        context.delete(target)
        try context.save()

        let afterDelete = try allExercises()
        XCTAssertFalse(
            afterDelete.contains { $0.name == "Pull-Up" },
            "row should be gone after delete"
        )

        // Simulate the next launch: same version flag is already persisted,
        // so the seed pass should short-circuit and the deleted row stays
        // gone.
        runSeed()

        let afterSecondSeed = try allExercises()
        XCTAssertFalse(
            afterSecondSeed.contains { $0.name == "Pull-Up" },
            "deleted seeded row must not reappear on second seed under the same version"
        )
        XCTAssertEqual(
            afterSecondSeed.count, ExerciseCatalog.v1.count - 1
        )
    }

    // MARK: - 11. Version flag is set to currentVersion after seeding

    func testVersionFlagSetAfterSeeding() throws {
        XCTAssertEqual(
            defaults.integer(forKey: ExerciseSeedService.seedVersionKey),
            0, "flag should be absent before first seed"
        )

        runSeed()

        XCTAssertEqual(
            defaults.integer(forKey: ExerciseSeedService.seedVersionKey),
            ExerciseCatalog.currentVersion,
            "flag should advance to currentVersion after the pass"
        )
    }

    // MARK: - 11b. Flag advances even when zero inserts occurred

    func testVersionFlagSetEvenWhenAllNamesExist() throws {
        for seed in ExerciseCatalog.v1 {
            context.insert(Exercise(name: seed.name))
        }
        try context.save()

        runSeed()

        XCTAssertEqual(
            defaults.integer(forKey: ExerciseSeedService.seedVersionKey),
            ExerciseCatalog.currentVersion,
            "flag should advance even when every seed was deduped away"
        )
    }

    // MARK: - 12. Empty / whitespace seed names are skipped defensively

    func testEmptyAndWhitespaceSeedNamesAreSkipped() throws {
        let customSeeds: [ExerciseSeed] = [
            ExerciseSeed(name: ""),
            ExerciseSeed(name: "   "),
            ExerciseSeed(name: "\n\t  "),
            ExerciseSeed(name: "Valid Seed", bodyPart: "Chest", equipmentType: "Barbell"),
        ]

        runSeed(customSeeds)

        let fetched = try allExercises()
        XCTAssertEqual(fetched.count, 1, "only the non-blank seed is inserted")
        XCTAssertEqual(fetched.first?.name, "Valid Seed")
        XCTAssertEqual(fetched.first?.bodyPart, "Chest")
        XCTAssertEqual(fetched.first?.equipmentType, "Barbell")
        XCTAssertFalse(fetched.first?.isCustom ?? true)
    }
}

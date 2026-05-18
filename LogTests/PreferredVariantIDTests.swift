import SwiftData
import XCTest

@testable import Log

/// Phase 7 Slice 7.1 — `Routine.preferredVariantID` is the shared variant
/// selection rule used by both the start path (`StartWorkoutFromRoutineView`)
/// and the launch-time backfill (`BootstrapRoot.backfillPhase6B`). Locking it
/// down here protects every downstream consumer that has to resolve a routine
/// to a single canonical variant.
@MainActor
final class PreferredVariantIDTests: SwiftDataTestHarness {

    func testNoVariantsReturnsNil() {
        let routine = Routine(name: "Empty", blocks: [])
        context.insert(routine)

        XCTAssertNil(routine.preferredVariantID)
    }

    func testDefaultByNameWinsOverLowerOrder() {
        let defaultVariant = RoutineVariant(name: "Default", order: 5)
        let earlyVariant = RoutineVariant(name: "Bulk", order: 0)
        let routine = Routine(name: "Mixed", blocks: [])
        context.insert(routine)
        routine.variants = [earlyVariant, defaultVariant]

        XCTAssertEqual(routine.preferredVariantID, defaultVariant.id)
    }

    func testDefaultMatchIsCaseInsensitive() {
        let lowercase = RoutineVariant(name: "default", order: 1)
        let upper = RoutineVariant(name: "DEFAULT", order: 2)
        let other = RoutineVariant(name: "Cut", order: 0)
        let routine = Routine(name: "Casing", blocks: [])
        context.insert(routine)
        routine.variants = [other, upper, lowercase]

        // Whichever wins, the result must be a "Default"-named variant —
        // not the lower-order non-Default sibling.
        let id = try? XCTUnwrap(routine.preferredVariantID)
        XCTAssertTrue(
            id == lowercase.id || id == upper.id,
            "Expected a case-insensitively 'Default' variant to win; got \(String(describing: id))"
        )
    }

    func testLowestOrderWinsWhenNoDefault() {
        let lowOrder = RoutineVariant(name: "Bulk", order: 0)
        let highOrder = RoutineVariant(name: "Cut", order: 5)
        let routine = Routine(name: "Ordered", blocks: [])
        context.insert(routine)
        routine.variants = [highOrder, lowOrder]

        XCTAssertEqual(routine.preferredVariantID, lowOrder.id)
    }

    func testTieOnOrderIsBrokenByName() {
        let bulk = RoutineVariant(name: "Bulk", order: 1)
        let cut = RoutineVariant(name: "Cut", order: 1)
        let routine = Routine(name: "Tied", blocks: [])
        context.insert(routine)
        routine.variants = [cut, bulk]

        // Lexicographically smaller name wins on (order, name) tiebreak.
        XCTAssertEqual(routine.preferredVariantID, bulk.id)
    }
}

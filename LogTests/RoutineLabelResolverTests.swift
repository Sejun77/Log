import SwiftData
import XCTest

@testable import Log

/// Phase 7 Slice 7.2 — `RoutineLabelResolver` was extracted out of
/// `HistoryView.swift` (was file-private) into `Log/Services/` for testing.
/// These tests lock down all four priority branches plus the Default /
/// non-Default formatting rule so future History-display work cannot
/// regress the live label semantics shipped in Phase 6.B Slice C.1.
@MainActor
final class RoutineLabelResolverTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    /// Insert a routine with the given variants. Variants are appended after
    /// insertion so the SwiftData relationship is established the same way it
    /// is at runtime via `routine.variants.append`.
    @discardableResult
    private func makeRoutine(
        name: String, variants: [RoutineVariant] = []
    ) -> Routine {
        let r = Routine(name: name, blocks: [])
        context.insert(r)
        r.variants = variants
        return r
    }

    private func makeWorkout(
        routineName: String? = nil,
        routineID: UUID? = nil,
        routineVariantID: UUID? = nil
    ) -> Workout {
        let w = Workout(
            routineName: routineName,
            routineID: routineID,
            routineVariantID: routineVariantID,
            items: []
        )
        context.insert(w)
        return w
    }

    // MARK: - Priority 1: variantID resolves

    func testVariantIDPointingToDefaultReturnsRoutineNameOnly() {
        let def = RoutineVariant(name: "Default", order: 0)
        let routine = makeRoutine(name: "Push", variants: [def])
        let workout = makeWorkout(routineID: routine.id, routineVariantID: def.id)

        let resolver = RoutineLabelResolver(routines: [routine])

        XCTAssertEqual(resolver.label(for: workout), "Push")
    }

    func testVariantIDPointingToNonDefaultReturnsRoutineDashVariant() {
        let bulk = RoutineVariant(name: "Bulk", order: 0)
        let routine = makeRoutine(name: "Push", variants: [bulk])
        let workout = makeWorkout(routineID: routine.id, routineVariantID: bulk.id)

        let resolver = RoutineLabelResolver(routines: [routine])

        XCTAssertEqual(resolver.label(for: workout), "Push — Bulk")
    }

    func testDefaultMatchIsCaseInsensitive() {
        let def = RoutineVariant(name: "dEfAuLt", order: 0)
        let routine = makeRoutine(name: "Pull", variants: [def])
        let workout = makeWorkout(routineID: routine.id, routineVariantID: def.id)

        let resolver = RoutineLabelResolver(routines: [routine])

        XCTAssertEqual(resolver.label(for: workout), "Pull")
    }

    // MARK: - Priority 2: variantID missing → routineID

    func testNilVariantIDFallsBackToRoutineID() {
        let routine = makeRoutine(name: "Legs")
        let workout = makeWorkout(
            routineID: routine.id,
            routineVariantID: nil
        )

        let resolver = RoutineLabelResolver(routines: [routine])

        XCTAssertEqual(resolver.label(for: workout), "Legs")
    }

    func testOrphanedVariantIDFallsThroughToRoutineID() {
        // workout's variantID points to a variant that no longer exists, but
        // its routineID still resolves — should land on the routine name.
        let routine = makeRoutine(name: "Legs")
        let workout = makeWorkout(
            routineID: routine.id,
            routineVariantID: UUID()  // not in any routine's variants
        )

        let resolver = RoutineLabelResolver(routines: [routine])

        XCTAssertEqual(resolver.label(for: workout), "Legs")
    }

    // MARK: - Priority 3: both id paths miss → frozen snapshot

    func testMissingRoutineIDFallsBackToFrozenRoutineName() {
        // No routine in the resolver matches; only the snapshot is available.
        let workout = makeWorkout(
            routineName: "Old Routine",
            routineID: UUID(),
            routineVariantID: UUID()
        )

        let resolver = RoutineLabelResolver(routines: [])

        XCTAssertEqual(resolver.label(for: workout), "Old Routine")
    }

    // MARK: - Priority 4: nothing resolves → nil

    func testNilRoutineNameReturnsNil() {
        let workout = makeWorkout(
            routineName: nil,
            routineID: nil,
            routineVariantID: nil
        )

        let resolver = RoutineLabelResolver(routines: [])

        XCTAssertNil(resolver.label(for: workout))
    }

    func testEmptyRoutineNameReturnsNil() {
        // Empty snapshot must be treated as "no usable label" so the caller
        // omits the row, matching pre-Slice-C visual behavior.
        let workout = makeWorkout(routineName: "")

        let resolver = RoutineLabelResolver(routines: [])

        XCTAssertNil(resolver.label(for: workout))
    }

    // MARK: - Live label semantics

    func testRoutineRenameFlowsThroughResolverWithoutRebuilding() {
        // The resolver captures the live Routine by reference (via the model
        // object), so reading `routine.name` returns the current value at
        // call time — guards the Slice C.1 "rename updates labels" invariant.
        let def = RoutineVariant(name: "Default", order: 0)
        let routine = makeRoutine(name: "Original", variants: [def])
        let workout = makeWorkout(routineID: routine.id, routineVariantID: def.id)

        let resolver = RoutineLabelResolver(routines: [routine])

        XCTAssertEqual(resolver.label(for: workout), "Original")

        routine.name = "Renamed"
        XCTAssertEqual(resolver.label(for: workout), "Renamed")
    }
}

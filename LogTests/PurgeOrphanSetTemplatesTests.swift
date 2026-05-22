import SwiftData
import XCTest

@testable import Log

/// Phase 9-E2 — `BackfillService.purgeOrphanSetTemplates(in:)` is the
/// defensive bootstrap sweep that deletes `SetTemplate` rows no longer
/// reachable from `RoutineExercise.setTemplates`. Required because the
/// model field deletion in 9-E2 leaves any pre-existing
/// `Exercise.defaultTemplates` child rows unattached after SwiftData's
/// lightweight migration.
@MainActor
final class PurgeOrphanSetTemplatesTests: SwiftDataTestHarness {

    private func makeAttachedSlot(
        templates: [SetTemplate]
    ) -> RoutineExercise {
        let ex = Exercise(name: "Attached", isCustom: true)
        context.insert(ex)
        for t in templates { context.insert(t) }
        let re = RoutineExercise(
            exercise: ex, order: 0, setTemplates: templates
        )
        context.insert(re)
        try? context.save()
        return re
    }

    private func makeOrphan(reps: Int) -> SetTemplate {
        let t = SetTemplate(kind: .working, targetReps: reps)
        context.insert(t)
        return t
    }

    // MARK: - Sweep deletes unattached rows

    func testPurgesUnattachedSetTemplate() {
        // Attached: lives via RoutineExercise.setTemplates.
        let attached = SetTemplate(kind: .working, targetReps: 8)
        _ = makeAttachedSlot(templates: [attached])

        // Orphan: not referenced by any RoutineExercise.
        _ = makeOrphan(reps: 99)

        try? context.save()
        let preCount = (try? context.fetch(FetchDescriptor<SetTemplate>()))?
            .count ?? 0
        XCTAssertEqual(preCount, 2)

        BackfillService.purgeOrphanSetTemplates(in: context)

        let post = (try? context.fetch(FetchDescriptor<SetTemplate>())) ?? []
        XCTAssertEqual(post.count, 1, "orphan row must be deleted")
        XCTAssertEqual(
            post.first?.targetReps, 8,
            "the attached row (reps=8) must survive; the orphan (reps=99) is gone"
        )
    }

    // MARK: - Attached rows survive untouched

    func testDoesNotDeleteSetTemplateReferencedByRoutineExercise() {
        let a = SetTemplate(kind: .working, targetReps: 6)
        let b = SetTemplate(kind: .working, targetReps: 8)
        _ = makeAttachedSlot(templates: [a, b])

        BackfillService.purgeOrphanSetTemplates(in: context)

        let post = (try? context.fetch(FetchDescriptor<SetTemplate>())) ?? []
        XCTAssertEqual(post.count, 2)
        XCTAssertEqual(Set(post.map(\.targetReps)), Set([6, 8]))
    }

    // MARK: - Idempotent second run

    func testIdempotentSecondRunIsNoOp() {
        let attached = SetTemplate(kind: .working, targetReps: 10)
        _ = makeAttachedSlot(templates: [attached])
        _ = makeOrphan(reps: 99)
        try? context.save()

        BackfillService.purgeOrphanSetTemplates(in: context)
        let firstCount = (try? context.fetch(FetchDescriptor<SetTemplate>()))?
            .count ?? 0

        BackfillService.purgeOrphanSetTemplates(in: context)
        let secondCount = (try? context.fetch(FetchDescriptor<SetTemplate>()))?
            .count ?? 0

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1, "second run is a verified no-op")
    }

    // MARK: - Empty store is safe

    func testEmptyStoreIsSafe() {
        // No exercises, no slots, no templates.
        BackfillService.purgeOrphanSetTemplates(in: context)
        let post = (try? context.fetch(FetchDescriptor<SetTemplate>())) ?? []
        XCTAssertTrue(post.isEmpty)
    }
}

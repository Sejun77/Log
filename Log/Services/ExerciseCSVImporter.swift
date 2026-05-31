import Foundation
import SwiftData

/// SwiftData import service for exercise CSV rows (CSV Slice 4,
/// REMAINING_WORK_PLAN.md §3.10). Takes already-parsed / validated
/// `ExerciseCSVRow`s (from `ExerciseCSV.parse`) and inserts only the *new* ones
/// as user data.
///
/// Behavior mirrors `ExerciseSeedService` — match existing rows by trimmed +
/// lowercased `name`, **skip** collisions (never overwrite), append `order`
/// after `max(existing.order)`, and `save()` **once** at the end — but inserts
/// `isCustom = true` (user-imported data, not catalogue seeds) and returns an
/// `ImportReport` instead of advancing a version flag.
///
/// Data-safety (per §3.10): additive-only. Existing `Exercise` rows are never
/// mutated; `Routine` / `Workout` / `WorkoutItem` / history are never touched.
@MainActor
enum ExerciseCSVImporter {

    /// Outcome of an import pass.
    struct ImportReport: Equatable {
        /// Names of newly inserted exercises, in insertion order.
        var insertedNames: [String] = []
        /// Names skipped because they collided (case-insensitively) with an
        /// existing row or an earlier row already inserted in this same batch.
        var skippedDuplicateNames: [String] = []
        /// Rows the parser rejected (only populated via the `ParseReport`
        /// entry point); carried through so callers/UI can surface them.
        var parseRejected: [ExerciseCSV.RejectedRow] = []
        /// Rows the parser skipped — empty rows / in-file duplicate names (only
        /// populated via the `ParseReport` entry point).
        var parseSkipped: [ExerciseCSV.SkippedRow] = []

        var insertedCount: Int { insertedNames.count }
        var skippedDuplicateCount: Int { skippedDuplicateNames.count }
    }

    /// Import the `valid` rows of a `ParseReport`, carrying the parser's
    /// rejected / skipped rows through into the returned `ImportReport` so a
    /// single object describes the whole parse + import outcome.
    @discardableResult
    static func `import`(
        _ report: ExerciseCSV.ParseReport, into ctx: ModelContext
    ) -> ImportReport {
        var result = importRows(report.valid, into: ctx)
        result.parseRejected = report.rejected
        result.parseSkipped = report.skipped
        return result
    }

    /// Insert the new exercises among `rows`. Returns which names were inserted
    /// and which were skipped as duplicates. Saves once iff at least one row was
    /// inserted.
    @discardableResult
    static func importRows(
        _ rows: [ExerciseCSVRow], into ctx: ModelContext
    ) -> ImportReport {
        var report = ImportReport()

        let existing: [Exercise] =
            (try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []

        // Dedupe key set: existing DB names plus anything inserted earlier in
        // this same batch, so two identical names in `rows` can't both insert.
        var seenKeys = Set(existing.map { normalize($0.name) })
        var nextOrder = (existing.map(\.order).max() ?? -1) + 1

        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Defensive: a blank name can't be a valid Exercise (the parser
            // already rejects these, but importRows may be called directly).
            guard !name.isEmpty else { continue }

            let key = name.lowercased()
            guard seenKeys.insert(key).inserted else {
                report.skippedDuplicateNames.append(name)
                continue
            }

            let ex = Exercise(
                name: name,
                bodyPart: row.bodyPart,
                notes: row.notes,
                equipmentType: row.equipmentType,
                setupDefaults: row.setupDefaults,
                isCustom: true
            )
            ex.isTimeBased = row.isTimeBased
            ex.order = nextOrder
            ctx.insert(ex)

            report.insertedNames.append(name)
            nextOrder += 1
        }

        if report.insertedCount > 0 {
            try? ctx.save()
        }
        return report
    }

    /// Trim + lowercase normalization for the dedupe key — identical transform
    /// to `ExerciseSeedService` so the two import paths agree on collisions.
    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

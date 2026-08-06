import Foundation
import SwiftData

/// Phase 10-polish-F seed pass: inserts the built-in exercise catalogue
/// (`ExerciseCatalog.v1`) into the user's store on first launch so new
/// installs do not start with an empty Exercises tab. Idempotent — gated by a
/// monotonically increasing `UserDefaults` integer flag so the pass is a
/// no-op on subsequent launches under the same `currentVersion`.
///
/// Design choices (matching the planning audit, 2026-05-24):
///   - Match existing rows by **trimmed, lowercased `name`** only. A seed
///     whose name collides with any existing row (user-created or otherwise)
///     is skipped, never overwritten — this preserves the "no silent
///     mutation" invariant in CLAUDE.md.
///   - Seeded rows are tagged `isCustom = false`. The field is currently
///     consulted nowhere in production code, but reusing the existing flag
///     leaves the seed origin discoverable without adding a column.
///   - New seeded rows append after `max(existing.order)`, so they show up at
///     the bottom of the manual-sort list rather than rearranging user rows.
///   - Deleted seeded rows stay deleted under the same `currentVersion` (no
///     tombstone tracking in this slice — the version flag alone is the
///     gate). A future version bump that re-includes the same name would
///     reinsert it; the planning audit accepts that trade-off.
///   - The seed-version flag is advanced even when zero inserts occurred
///     (e.g. all seed names already present) so the dedupe scan does not
///     re-run on every launch in that steady state.
@MainActor
enum ExerciseSeedService {
    /// Persistent flag key. Read at the start of `seedIfNeeded` and written
    /// to `currentVersion` after a successful pass. Cleared by
    /// `BootstrapRoot.resetDataForUITests` so UI tests start from a clean
    /// "never seeded" state alongside the in-memory data wipe.
    static let seedVersionKey = "exerciseSeedVersion"

    /// Insert any catalogue entries that are not already present in the
    /// store, then bump the persisted seed-version flag.
    ///
    /// Parameters:
    ///   - ctx: model context to insert into. Saves once at the end if any
    ///     inserts occurred.
    ///   - seeds: catalogue to seed against. Defaults to `ExerciseCatalog.v1`.
    ///     Parameterized so unit tests can drive the dedupe / order / skip
    ///     branches with controlled inputs without touching the shipping
    ///     catalogue.
    ///   - defaults: `UserDefaults` store to gate against. Defaults to
    ///     `.standard`. Parameterized so unit tests can use an isolated
    ///     suite and avoid leaking the flag into the simulator's global
    ///     defaults across tests.
    static func seedIfNeeded(
        in ctx: ModelContext,
        seeds: [ExerciseSeed] = ExerciseCatalog.v1,
        defaults: UserDefaults = .standard
    ) {
        let installedVersion = defaults.integer(forKey: seedVersionKey)
        guard installedVersion < ExerciseCatalog.currentVersion else { return }

        let existing: [Exercise] =
            (try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []

        // Cardio Slice 10 (patched pre-merge): the seeder deliberately does
        // **not** touch `CardioMigrationService`'s prompt flag.
        //
        // It used to resolve the flag when the store was empty at seed time, on
        // the theory that a fresh install seeded by v3 has nothing to migrate.
        // True at that instant, and wrong a moment later: a user who installs
        // and *then* imports their exercise CSV — the documented way to bring a
        // library over — lands genuine legacy Cardio rows in a store whose flag
        // already says "resolved", and the offer they should have been shown is
        // suppressed forever. That is the bug this comment exists to prevent
        // someone reintroducing.
        //
        // Fresh installs stay silent without any flag write, because catalogue
        // v3 seeds cardio rows with `isCardio == true` and the candidate rule
        // therefore finds nothing. The flag is now written only in response to
        // the user ("Not Now" or "Mark as Cardio").

        var existingNameKeys: Set<String> = Set(
            existing.map { normalize($0.name) }
        )
        var nextOrder = (existing.map(\.order).max() ?? -1) + 1
        var insertedCount = 0

        for seed in seeds {
            let trimmed = seed.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { continue }

            let key = trimmed.lowercased()
            guard !existingNameKeys.contains(key) else { continue }

            let ex = Exercise(
                name: seed.name,
                bodyPart: seed.bodyPart,
                equipmentType: seed.equipmentType,
                setupDefaults: seed.setupDefaults,
                isCustom: false
            )
            // Written through the model's invariant-enforcing setters rather
            // than by direct assignment: `setCardio` is a no-op unless the row
            // is already time-based, so a malformed catalogue entry can never
            // produce `isCardio == true && isTimeBased == false` in the store.
            ex.setTimeBased(seed.isTimeBased)
            ex.setCardio(seed.isCardio)
            ex.includesBodyweightInLoad =
                defaultIncludesBodyweightInLoad(equipmentType: seed.equipmentType)
            ex.order = nextOrder
            ctx.insert(ex)

            existingNameKeys.insert(key)
            nextOrder += 1
            insertedCount += 1
        }

        if insertedCount > 0 {
            try? ctx.save()
        }

        defaults.set(ExerciseCatalog.currentVersion, forKey: seedVersionKey)
    }

    /// Trim + lowercase normalization used for the dedupe key. Centralized so
    /// both the existing-names set construction and the per-seed lookup use
    /// the exact same transform — drift here would silently produce duplicate
    /// rows.
    private static func normalize(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

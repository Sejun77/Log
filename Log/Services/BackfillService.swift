import Foundation
import SwiftData

/// Phase 6.B Slice B launch-time backfill, extracted from `BootstrapRoot` so
/// it can be unit-tested in isolation. Behavior is identical to the previous
/// inline `BootstrapRoot.backfillPhase6B()` — the function body is preserved
/// verbatim, only `self.ctx` becomes the `in ctx:` parameter.
@MainActor
enum BackfillService {

    /// Idempotent: for every existing `Workout` whose `routineVariantID` is
    /// nil, resolve a `RoutineVariant` and write its id. Matches by
    /// `routineID` first; falls back to lowercased `routineName` only if the
    /// id can't resolve. Leaves the field nil when no routine can be found,
    /// so the row remains eligible for a future backfill pass if the routine
    /// later reappears. Never overwrites a non-nil `routineVariantID`. Must
    /// run AFTER the routine/variant backfills (e.g. `BootstrapRoot.backfillPhase1`)
    /// so every routine has at least one variant.
    static func backfillRoutineVariantIDs(in ctx: ModelContext) {
        // Fetch unlinked workouts. We filter in Swift rather than via a
        // SwiftData `#Predicate { $0.routineVariantID == nil }` — optional
        // UUID predicates have been historically finicky and the candidate
        // set is small, so an in-memory filter is the safer, equivalent path.
        guard let allWorkouts = try? ctx.fetch(FetchDescriptor<Workout>())
        else { return }
        let candidates = allWorkouts.filter { $0.routineVariantID == nil }
        guard !candidates.isEmpty else { return }

        // Build lookup tables once.
        let routines: [Routine] =
            (try? ctx.fetch(FetchDescriptor<Routine>())) ?? []
        guard !routines.isEmpty else { return }

        let byID: [UUID: Routine] = Dictionary(
            routines.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Name fallback. For duplicate lowercased names, deterministically
        // keep the routine with the lowest `(order, name)` so reruns are
        // stable and not dependent on fetch order.
        let byLowercaseName: [String: Routine] = Dictionary(
            grouping: routines,
            by: { $0.name.lowercased() }
        ).mapValues { group in
            group.sorted { ($0.order, $0.name) < ($1.order, $1.name) }.first!
        }

        // Precompute each routine's preferred variant id so we don't recompute
        // per candidate. Uses the shared rule from `Routine.preferredVariantID`.
        let preferredByRoutineID: [UUID: UUID] =
            routines.reduce(into: [:]) { acc, r in
                if let vid = r.preferredVariantID { acc[r.id] = vid }
            }

        var dirty = false
        for w in candidates {
            var resolved: UUID? = nil

            if let rid = w.routineID,
                let r = byID[rid],
                let vid = preferredByRoutineID[r.id]
            {
                resolved = vid
            } else if let rname = w.routineName?.lowercased(),
                let r = byLowercaseName[rname],
                let vid = preferredByRoutineID[r.id]
            {
                resolved = vid
            }

            if let vid = resolved {
                w.routineVariantID = vid
                dirty = true
            }
        }

        if dirty {
            try? ctx.save()
        }
    }
}

import Foundation
import SwiftData

// MARK: - Safe Relationship Helpers

extension RoutineExercise {
    /// Safely resolves the linked `Exercise`, returning `nil` instead of
    /// crashing when the slot or its target is in a degraded state (nil
    /// relationship, deleted `Exercise`, stale/invalidated `RoutineExercise`).
    ///
    /// The `ctx` parameter is retained for call-site compatibility but is no
    /// longer used to fetch. The previous implementation ran a
    /// `FetchDescriptor<RoutineExercise>` with `#Predicate { $0.id == myID }`.
    /// `RoutineExercise` has no stored `id` attribute — `id` resolves to
    /// `PersistentModel.persistentModelID`, a computed property. SwiftData
    /// must translate a predicate key path into a stored-column name via
    /// `PersistentModel.graph_keyPathToString(keypath:)`; that translation
    /// crashes for `persistentModelID` in optimized (release/TestFlight)
    /// builds, which is exactly the reported Organizer crash. The relationship
    /// can be read directly without any fetch, so we do that behind
    /// invalidation guards.
    ///
    /// Caveat: this guards the states it can observe cheaply (nil relationship,
    /// never-inserted, directly-deleted). It cannot defend against a fully
    /// *invalidated* instance that lingers in a stale cached to-many array
    /// (e.g. a slot cascade-deleted with its `Exercise` but still present in a
    /// block's `exercises` cache) — such an instance reports a non-nil
    /// `modelContext` and `isDeleted == false`, yet any relationship read
    /// fatally traps. Callers that iterate cached relationship arrays must
    /// filter to live slots first; `Routine.isStartable(in:)` shows the
    /// pattern (intersect with the store's live slot IDs, which are safe to
    /// read via `persistentModelID`).
    func safeExercise(in ctx: ModelContext) -> Exercise? {
        // A `RoutineExercise` removed from its context (deleted, or never
        // inserted) reports a nil `modelContext`; touching its relationships
        // in that state is unsafe.
        guard self.modelContext != nil else { return nil }

        // Read the to-one relationship in memory — no predicate, no fetch.
        guard let exercise = self.exercise else { return nil }

        // The linked `Exercise` may have been deleted out from under the
        // slot; a deleted model likewise reports a nil context. Treat it as
        // unresolved rather than handing back a dangling reference.
        guard exercise.modelContext != nil else { return nil }

        return exercise
    }

    private func normalizeOrderIfNeeded(_ templates: [SetTemplate]) -> Bool {
        let n = templates.count
        guard n > 0 else { return false }

        let orders = templates.map(\.order)
        let uniqueCount = Set(orders).count
        let minOrder = orders.min() ?? 0
        let maxOrder = orders.max() ?? 0

        let needsFix =
            (uniqueCount != n) || (minOrder < 0) || (maxOrder != n - 1)
        guard needsFix else { return false }

        let repaired = templates.sorted { a, b in
            if a.kindSortKey != b.kindSortKey {
                return a.kindSortKey < b.kindSortKey
            }
            return a.persistentModelID < b.persistentModelID
        }

        for (i, t) in repaired.enumerated() {
            t.order = i
        }

        return true
    }

    /// Context-safe convenience: `safeExercise(in:)` without an explicit
    /// context, resolving against the slot's own `modelContext`. Kept for
    /// call sites (and tests) that don't already hold a `ModelContext`.
    func safeExercise() -> Exercise? {
        guard let ctx = self.modelContext else { return nil }
        return safeExercise(in: ctx)
    }

    /// Context-aware 2-tier template resolution (Tier 3 removed in
    /// Phase 9-C2). Tier 1 still normalizes duplicate / out-of-range
    /// `setTemplates` orders and persists the fix; the pre-9-C2 Tier 3
    /// arm also normalized `Exercise.defaultTemplates` orders as a side
    /// effect — that fix-up moved to `ExercisesView.normalizeTemplateOrderIfNeeded`
    /// (9-D scope) since the resolver no longer reads `defaultTemplates`.
    /// The `safeExercise(in:)` early-return guard was removed alongside
    /// Tier 3 because Tier 1 + Tier 2 read only `self.setTemplates` /
    /// `self.prescription`, which don't need a fresh fetch of the
    /// `Exercise` relationship.
    func resolvedTemplates(in ctx: ModelContext) -> [SetTemplate] {
        // Tier 1: explicit per-set overrides
        if !setTemplates.isEmpty {
            let didFix = normalizeOrderIfNeeded(setTemplates)
            let sorted = setTemplates.sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                return a.persistentModelID < b.persistentModelID
            }
            if didFix { try? ctx.save() }
            return sorted
        }

        // Tier 2: prescription-generated
        if let p = prescription, p.hasContent {
            return p.generateTemplates()
        }

        return []
    }
}

// MARK: - Routine Startability

extension Routine {
    /// Startability rule shared by `RoutineEditor` (drives the Start button's
    /// disabled state) and its regression tests.
    ///
    /// A routine is startable when **at least one block contains a resolvable
    /// exercise** and **every superset block has a positive
    /// `supersetRoundRestSeconds`**. All degenerate shapes are handled without
    /// crashing:
    /// - a routine with no blocks → `false`
    /// - a block with no exercises → contributes no content
    /// - a slot whose `exercise` is nil or deleted → not counted (via
    ///   `safeExercise(in:)`, which no longer runs a `#Predicate` fetch)
    ///
    /// Extracted from the former `RoutineEditor.routineIsStartable` so the
    /// exact logic that runs in `body` can be exercised directly in tests.
    func isStartable(in ctx: ModelContext) -> Bool {
        // Live slots as committed to the store. A slot cascade-deleted when
        // its `Exercise` was removed can linger as an invalidated instance in
        // a block's cached `exercises` array; reading such an instance's
        // relationships fatally traps. We therefore intersect against the live
        // set before touching any relationship. The fetch is predicate-free
        // (no fragile key-path predicate) and runs once per call, and
        // `persistentModelID` is safe to read even on an invalidated instance.
        let liveSlotIDs: Set<PersistentIdentifier> = Set(
            ((try? ctx.fetch(FetchDescriptor<RoutineExercise>())) ?? [])
                .map(\.persistentModelID)
        )

        var hasAnyContent = false

        for block in blocks {
            let liveSlots = block.exercises.filter {
                liveSlotIDs.contains($0.persistentModelID)
            }

            if liveSlots.contains(where: { re in
                re.safeExercise(in: ctx) != nil
            }) {
                hasAnyContent = true
            }

            if block.isSuperset {
                guard let rr = block.supersetRoundRestSeconds, rr > 0 else {
                    return false
                }
            }
        }

        return hasAnyContent
    }
}

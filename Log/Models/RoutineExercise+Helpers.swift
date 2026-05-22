import Foundation
import SwiftData

// MARK: - Safe Relationship Helpers

extension RoutineExercise {
    func safeExercise(in ctx: ModelContext) -> Exercise? {
        guard self.modelContext != nil else { return nil }
        let myID = self.id
        let descriptor = FetchDescriptor<RoutineExercise>(
            predicate: #Predicate { $0.id == myID }
        )
        return (try? ctx.fetch(descriptor).first)?.exercise
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

import Foundation

/// Ordered, duplicate-capable selection model for the multi-select exercise
/// picker. Stores `Exercise` ids in tap order; the same id may appear more than
/// once (intentional duplicate slots are a supported product behavior — each
/// becomes a distinct `RoutineExercise` with its own `slotID`).
///
/// Pure value type — no SwiftData, no UI, no search state. The picker keeps its
/// search/filter entirely separate, so filtering the visible list can never
/// clear or reorder the selection held here. Mirrors the `RestPlanner` /
/// `RoutineNameValidator` extraction pattern so the rules are unit-testable.
struct ExerciseMultiSelection: Equatable {
    /// Selected exercise ids in tap order; duplicates preserved.
    private(set) var orderedIDs: [UUID] = []

    var isEmpty: Bool { orderedIDs.isEmpty }
    var count: Int { orderedIDs.count }

    /// Append one occurrence of `id` (tap to add; a second tap adds a second
    /// occurrence rather than toggling off).
    mutating func append(_ id: UUID) {
        orderedIDs.append(id)
    }

    /// How many times `id` currently appears in the selection.
    func count(of id: UUID) -> Int {
        orderedIDs.reduce(0) { $0 + ($1 == id ? 1 : 0) }
    }

    /// Remove the entry at `index` in the ordered selection. Out-of-range is a
    /// no-op.
    mutating func remove(at index: Int) {
        guard orderedIDs.indices.contains(index) else { return }
        orderedIDs.remove(at: index)
    }

    /// Remove entries at the given offsets (the `onDelete` path). Implemented
    /// without the SwiftUI `remove(atOffsets:)` extension so the helper depends
    /// only on Foundation.
    mutating func remove(atOffsets offsets: IndexSet) {
        for i in offsets.sorted(by: >) where orderedIDs.indices.contains(i) {
            orderedIDs.remove(at: i)
        }
    }

    mutating func removeAll() {
        orderedIDs.removeAll()
    }

    /// Resolve the ordered id selection to model objects via a lookup table,
    /// preserving tap order and duplicates. Ids with no match are dropped
    /// (cannot happen when every selection came from the supplied library).
    func resolved<Element>(using byID: [UUID: Element]) -> [Element] {
        orderedIDs.compactMap { byID[$0] }
    }
}

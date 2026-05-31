import Foundation

/// Pure reorder helper for the Exercises tab's manual order (Slice A of the
/// send-to-top / send-to-bottom feature). Operates purely on `Exercise.id`
/// identities: takes the current manual-ordered id list plus a target id and
/// returns the reordered id list. Value-in / value-out — no `ModelContext`, no
/// `@Query`, no mutation of any `Exercise`, and no name comparison — so it is
/// unit-testable with literal `UUID` fixtures, mirroring
/// `RoutineNameValidator` / `ExerciseSorter`.
///
/// The caller (UI slice, later) applies the result by walking the returned
/// order and writing contiguous `Exercise.order` values, exactly as the
/// existing `ExercisesView.moveExercises` drag handler already does.
enum ExerciseReorder {
    /// Move `target` to the front, preserving the relative order of every other
    /// id. Returns the input unchanged when `target` is missing, already first,
    /// or the list has fewer than two elements.
    static func sendToTop(_ ids: [UUID], moving target: UUID) -> [UUID] {
        guard ids.contains(target) else { return ids }
        var result = ids.filter { $0 != target }
        result.insert(target, at: 0)
        return result
    }

    /// Move `target` to the end, preserving the relative order of every other
    /// id. Returns the input unchanged when `target` is missing, already last,
    /// or the list has fewer than two elements.
    static func sendToBottom(_ ids: [UUID], moving target: UUID) -> [UUID] {
        guard ids.contains(target) else { return ids }
        var result = ids.filter { $0 != target }
        result.append(target)
        return result
    }

    /// Map each id to its contiguous `0..<count` position — the `Exercise.order`
    /// values the caller should persist after a reorder. Pure; on duplicate ids
    /// the later index wins (callers pass unique `Exercise.id`s).
    static func orderMap(for ids: [UUID]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, id) in ids.enumerated() {
            map[id] = index
        }
        return map
    }
}

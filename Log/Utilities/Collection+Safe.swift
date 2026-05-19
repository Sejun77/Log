import Foundation

/// Phase 11.1 — moved out of `ActiveWorkoutView.swift` for behavior-preserving
/// file decomposition. Bumped from `fileprivate` to module-internal so any
/// future caller in the `Log` module can reuse it without redeclaring.
///
/// Today's only callers are inside `ActiveWorkoutView.swift` (10+ sites
/// against `plan.blocks[safe:]`, `block.exercises[safe:]`,
/// `templates[safe:]`, etc.); behavior is unchanged.
extension Collection {
    subscript(safe i: Index) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

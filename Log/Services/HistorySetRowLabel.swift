import Foundation

// ======================================================
// MARK: - History set-row label
// ======================================================

/// The leading label of a History set row — "1. Working Set", "1. Warm-up Set",
/// "1. Drop Set".
///
/// One rule, no exceptions: **number, then the stored set kind's name.** The
/// label is a function of `SetLog.kind` and `SetLog.indexInExercise` and of
/// nothing else — not the exercise, not its tracking mode, not what the set
/// happens to have recorded. A cardio working set, a plank's working set and a
/// bench press working set are the same kind of thing and read the same way.
///
/// Extracted from `HistoryView` so that rule is assertable without a SwiftUI
/// host.
///
/// This is History only. The active-workout row labels come from
/// `SetKind.activeRowLabel`, which is deliberately different and deliberately
/// untouched: mid-workout the surrounding row already establishes the context,
/// so a `.working` set draws no label at all there.
enum HistorySetRowLabel {

    /// The row label for one logged set.
    static func text(for log: SetLog) -> String {
        "\(number(for: log)). \(log.kind.historyRowLabel)"
    }

    /// The set's display number within its exercise, counting from 1.
    ///
    /// Warmups carry a negative `indexInExercise` (`-(order + 1)`) so they
    /// cannot collide with the 0-based working-set indices; negating it
    /// recovers the warm-up's own 1-based number. Everything else is simply
    /// its index plus one.
    static func number(for log: SetLog) -> Int {
        log.kind == .warmup ? -log.indexInExercise : log.indexInExercise + 1
    }
}

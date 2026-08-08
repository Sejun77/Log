import Foundation

// ======================================================
// MARK: - History set-row label
// ======================================================

/// The leading label of a History set row — "1. Working Set", "1. Cardio Set",
/// "1. Warm-up Set", "1. Drop Set".
///
/// The rule: **number, then the name of what was logged.** The number comes
/// from `SetLog.indexInExercise` and the name from `SetLog.kind`, with one
/// exception — a cardio exercise's `.working` set reads **"Cardio Set"**.
///
/// ### Why cardio is named separately
///
/// A cardio bout is not a set in the strength sense; it is one aggregate entry
/// for the whole effort. Structured cardio already spends the words *Warm-up*,
/// *Work*, *Recovery* and *Cool-down* on the planned segments shown directly
/// above these rows in the Cardio Plan block, so calling the single logged row
/// a "Working Set" invited it to be read as the plan's *Work* segment — as if
/// the other segments had rows of their own somewhere. They do not: the plan is
/// a guide, the Cardio Set is the whole result. Two different vocabularies for
/// two different things, on purpose.
///
/// This is display only. The stored `SetKind` is untouched — a cardio bout is
/// still persisted as `.working`, and no cardio-specific set kinds exist.
///
/// Extracted from `HistoryView` so the rule is assertable without a SwiftUI
/// host.
///
/// This is History only. The active-workout row labels come from
/// `SetKind.activeRowLabel`, which is deliberately different and deliberately
/// untouched: mid-workout the surrounding row already establishes the context,
/// so a `.working` set draws no label at all there — for cardio too.
enum HistorySetRowLabel {

    /// The row label for one logged set.
    ///
    /// - Parameter isCardio: whether the set belongs to a cardio exercise.
    ///   Passed in rather than read off `log` because a `SetLog` does not know
    ///   what it belongs to; `isCardio(_:)` resolves it from the item.
    static func text(for log: SetLog, isCardio: Bool) -> String {
        "\(number(for: log)). \(kindName(for: log, isCardio: isCardio))"
    }

    /// The name part of the label — everything after "1. ".
    static func kindName(for log: SetLog, isCardio: Bool) -> String {
        guard isCardio, log.kind == .working else {
            return log.kind.historyRowLabel
        }
        return NSLocalizedString(
            "Cardio Set",
            comment: "History row label for the single aggregate cardio entry")
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

    /// Whether one History item's rows should read as cardio.
    ///
    /// The live exercise is the answer whenever there is one. When there is not
    /// — History outlives the exercises it records — the item's frozen
    /// prescription snapshot decides: a target distance and a structured cardio
    /// plan are both authorable on a cardio slot and nowhere else, so either
    /// one is proof the bout was cardio when it happened. A cardio bout logged
    /// with duration alone under a since-deleted exercise leaves no such trace
    /// and reads as a working set; that is the honest answer rather than a
    /// guess from what the row happens to have recorded.
    static func isCardio(_ item: WorkoutItem) -> Bool {
        if let exercise = item.exercise {
            return exercise.trackingMode == .cardio
        }
        guard let snapshot = item.plannedPrescriptionSnapshot else {
            return false
        }
        return snapshot.targetDistanceMeters != nil
            || snapshot.structuredCardioPlan != nil
    }
}

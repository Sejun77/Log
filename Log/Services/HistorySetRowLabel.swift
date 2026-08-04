import Foundation

// ======================================================
// MARK: - History set-row label
// ======================================================

/// The leading label of a History set row — "Warmup 1", "1. Working", "1. Set".
///
/// Extracted from `HistoryView` so the one thing the Slice 4 polish patch
/// changes (cardio rows no longer claiming to be *working* sets) is assertable
/// without a SwiftUI host, and so the strength and warm-up spellings it must
/// **not** change are pinned by the same tests.
///
/// This is History only. The active-workout row labels come from
/// `SetKind.activeRowLabel`, which is deliberately untouched: it already
/// renders nothing at all for a `.working` set, so no "Working" text exists
/// there to be misleading.
enum HistorySetRowLabel {

    /// Neutral label for a cardio set.
    ///
    /// "Working" is strength vocabulary. A cardio bout may be a warm-up jog,
    /// the main effort, or a cooldown, and the log does not know which — so the
    /// row should claim nothing beyond the one thing that is certainly true:
    /// it is a set.
    static var neutralCardioLabel: String {
        NSLocalizedString(
            "Set", comment: "History row label for one cardio set")
    }

    /// The row label for one logged set.
    ///
    /// - Parameter isCardio: whether the row's exercise is tracked as cardio.
    ///   Resolved per *item* by `isCardioItem(_:)` rather than per set, so two
    ///   sets of the same exercise can never disagree about their wording.
    static func text(for log: SetLog, isCardio: Bool) -> String {
        // Warmup rows are numbered from a negative `indexInExercise`
        // (`-(order + 1)`) and read the same for every tracking mode.
        guard log.kind != .warmup else {
            return "Warmup \(-log.indexInExercise)"
        }

        let number = log.indexInExercise + 1

        // Cardio never produces dropsets, so one neutral label covers every
        // non-warmup cardio row.
        guard !isCardio else { return "\(number). \(neutralCardioLabel)" }

        // Unchanged: the literal `kindRaw.capitalized` History has always
        // rendered for strength sets and for timed holds ("Working",
        // "Dropset").
        return "\(number). \(log.kindRaw.capitalized)"
    }

    /// Whether a History item's rows should use the cardio label.
    ///
    /// The live `Exercise` is the authority. It is nil only when the exercise
    /// was deleted after the session, in which case the recorded metrics are
    /// the only remaining evidence — read across **all** of the item's sets, so
    /// a duration-only cardio set logged next to one with a distance is still
    /// labelled consistently with it.
    ///
    /// A timed hold reports false either way: it has no cardio metrics to find.
    static func isCardioItem(_ item: WorkoutItem) -> Bool {
        if let exercise = item.exercise {
            return exercise.trackingMode == .cardio
        }
        return item.setLogs.contains { $0.hasCardioMetrics }
    }
}

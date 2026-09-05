import Foundation

// ======================================================
// MARK: - Routine authoring display copy (Build 10 polish)
// ======================================================
//
// Three small, pure pieces of *display* copy pulled out of their views so the
// wording rules are unit-testable without a UI harness. None of them read or
// write a model: each takes values in and returns a string.

// ======================================================
// MARK: - Block detail title (audit M11)
// ======================================================

/// The navigation title for a routine block's Details screen.
///
/// Both detail screens were titled by their *kind* — "Block" and "Superset" —
/// so opening Details for Bench Press landed on a screen that had lost the word
/// "Bench Press" entirely, one tap after the row that named it. The kind is the
/// one thing the user already knows; the exercise is what they came for.
///
/// Rules:
///  - a single-exercise block titles with that exercise's name;
///  - a superset joins its members with `+`, the same way the routine editor's
///    own `blockTitle` already labels the row that pushes this screen, so the
///    two cannot disagree;
///  - a block whose exercises have all been deleted keeps the kind word, which
///    is the only honest thing left to say.
///
/// No truncation is applied. `navigationBarTitleDisplayMode(.inline)` already
/// truncates a long title in the middle, which reads better than an ellipsis
/// this type would have to guess the width for.
enum BlockDetailTitle {

    /// - Parameter exerciseNames: the block's exercises in execution order,
    ///   with deleted slots already dropped by the caller.
    static func title(exerciseNames: [String], isSuperset: Bool) -> String {
        let named = exerciseNames.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !named.isEmpty else {
            return isSuperset
                ? String(localized: "Superset") : String(localized: "Block")
        }
        return named.joined(separator: " + ")
    }
}

// ======================================================
// MARK: - Effort progression labels (audit M7)
// ======================================================

/// Row labels for the two ends of a progression effort target.
///
/// These used to be composed as `String(localized: "Start") + " " + metric`,
/// reusing the app's generic Start/End keys — the same `"End"` whose Korean is
/// `종료`, the word for *terminating* something. A Korean user editing a
/// progression read `종료 RIR`, which says "quit RIR" rather than "the RIR you
/// finish on".
///
/// Each end therefore gets its own key per metric, translated as a phrase
/// rather than assembled from two. Korean uses `시작` / `마지막` — "first" and
/// "last" — which is how a lifter describes the two ends of a ramp, and which
/// leaves the generic `종료` alone for the workout-ending controls that own it.
enum EffortTargetLabels {

    static func start(_ metric: EffortMetric) -> String {
        switch metric {
        case .rir: return String(localized: "Start RIR")
        case .rpe: return String(localized: "Start RPE")
        }
    }

    static func end(_ metric: EffortMetric) -> String {
        switch metric {
        case .rir: return String(localized: "End RIR")
        case .rpe: return String(localized: "End RPE")
        }
    }
}

// ======================================================
// MARK: - Cardio Plan total vs target distance (audit L5)
// ======================================================

/// Whether a cardio slot's segment plan adds up to the distance target sitting
/// beside it.
///
/// The two are independent fields — a 5 km target and a plan whose segments
/// total 3 km are both stored, both valid, and neither one corrects the other.
/// Nothing said so, so a plan could silently describe a different session than
/// the target above it.
///
/// This reports; it never adjusts. Neither value is rewritten, nothing is
/// blocked, and a mismatch is a caption rather than an error — a plan that
/// deliberately covers only part of a longer target is a real thing to author.
enum CardioPlanTargetCheck {

    /// What to render under the plan.
    enum Result: Equatable {
        /// The plan carries no distance at all (a duration-only plan, or no
        /// plan): there is no total to state and nothing to compare.
        case nothingToShow
        /// A segment total, with no target to disagree with — or one it agrees
        /// with.
        case total(String)
        /// A segment total that does not match the target beside it.
        case mismatch(total: String, target: String)
    }

    /// Compare, in the unit the user is reading.
    ///
    /// **Agreement is decided on the rendered text, not the raw meters.** Both
    /// values are shown to one decimal in the display unit, so two distances
    /// that print identically are identical as far as this screen is concerned
    /// — and warning about a difference the user cannot see would be noise.
    /// That also means the comparison can never contradict the two numbers
    /// beside it, whatever rounding the formatter applies.
    static func evaluate(
        targetMeters: Double?,
        segmentTotalMeters: Double?,
        displayUnit: DistanceUnit
    ) -> Result {
        guard
            let totalText = CardioTargetDistance(
                meters: segmentTotalMeters, displayUnit: displayUnit
            )?.displayText
        else { return .nothingToShow }

        guard
            let targetText = CardioTargetDistance(
                meters: targetMeters, displayUnit: displayUnit
            )?.displayText
        else { return .total(totalText) }

        return totalText == targetText
            ? .total(totalText)
            : .mismatch(total: totalText, target: targetText)
    }

    /// "Segment total: 3.0 km".
    static func totalCaption(_ total: String) -> String {
        String(localized: "Segment total: \(total)")
    }

    /// The second line shown only for a mismatch.
    static var mismatchCaption: String {
        String(localized: "Does not match the target distance.")
    }
}

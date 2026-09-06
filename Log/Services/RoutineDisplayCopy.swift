import Foundation

// ======================================================
// MARK: - Routine authoring display copy (Build 10 polish)
// ======================================================
//
// Small, pure pieces of *display* copy and display decisions pulled out of
// their views so the wording rules are unit-testable without a UI harness. None
// of them read or write a model: each takes values in and returns a string or a
// Bool.

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
// MARK: - Block detail member headers (density pass)
// ======================================================

/// Whether a block's Details screen repeats each member's exercise name as a
/// section header above its set rows.
///
/// `BlockDetailTitle` above already titles the screen with the exercise name,
/// so a single-exercise block rendered that name twice within one screen height
/// — once in the navigation bar, once as the header of the only section under
/// it. The header is the copy that goes: the navigation title is always
/// visible, including while scrolled.
///
/// A superset always keeps its headers. There the name is not a repeat of the
/// title (which joins every member with `+`) but the only thing separating one
/// member's sets and prescription from the next, which is the whole structure
/// of that screen. A non-superset block that somehow holds more than one named
/// exercise keeps them for the same reason.
///
/// Display only — this decides what is drawn, never what is stored.
enum BlockDetailMemberHeader {

    /// - Parameter exerciseNames: the block's exercises in execution order,
    ///   with deleted slots already dropped by the caller — the same list
    ///   `BlockDetailTitle.title` is given, so the two decisions are made from
    ///   one input and cannot disagree about what the screen is called.
    static func showsMemberHeaders(
        exerciseNames: [String], isSuperset: Bool
    ) -> Bool {
        if isSuperset { return true }
        let named = exerciseNames.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Exactly one name means the title already says it. Zero named
        // exercises means the title fell back to the kind word ("Block"), so a
        // header is not a repeat of anything and is kept.
        return named.count != 1
    }
}

// ======================================================
// MARK: - Superset detail explanations (density pass)
// ======================================================

/// The three explanations on the superset Details screen, moved off permanent
/// section footers and behind `InfoButton`s in their section headers.
///
/// Held as constants so the view and its tests name the same string instead of
/// two hand-copied literals that can drift — the shape `EffortTargetHelp`
/// already uses. Copy only: nothing here reads, writes or validates anything.
///
/// All three were **explanations of how the screen works**, read once and then
/// occupying three footers' worth of vertical space forever. What deliberately
/// did *not* move: the "Superset needs at least 2 exercises" alert, which is a
/// live constraint fired at the moment it is hit, not a description.
///
/// Every message below is the **verbatim string its footer used**, so each one
/// resolves to the string-catalog key it already had and keeps its existing
/// Korean translation — no key was added, changed or retranslated for this
/// move. All three are `extractionState: manual` in the catalog, so dropping
/// the `Text(...)` literals does not strip them. Changing any literal here
/// without adding the new key is therefore a silent fallback to English, which
/// `KoreanLocalizationTests` guards.
enum SupersetHelp {

    /// Section header the info button sits in, reused as the alert title.
    static let timingTitle = "Timing"

    /// How a round is composed and which rest fires when. The one genuinely
    /// non-obvious rule on the screen: an uneven superset drops its shorter
    /// exercises out of later rounds rather than padding them.
    static let timingMessage =
        "A round runs one set of each exercise that still has sets remaining; "
        + "shorter exercises drop out of the later rounds. Rest after round "
        + "fires between completed rounds. Rest before next block fires after "
        + "the final round, replacing round rest."

    static let bulkSetsTitle = "Set All Exercises"

    /// That the stepper is a shortcut rather than a block-level set count —
    /// the misreading the footer existed to prevent.
    static let bulkSetsMessage =
        "Optional shortcut. Choose a count, then tap Apply to set every "
        + "exercise in this superset to that many sets at once. Adjusting the "
        + "stepper alone changes nothing — each exercise still keeps its own "
        + "set count (edit it in that exercise's section below), so they can "
        + "differ."

    /// The alert title. The section *header* keeps its longer
    /// `"Exercises (drag to reorder)"` wording — that half is an affordance
    /// hint, not an explanation, so it stays on screen; this is the noun the
    /// alert is about.
    static let membershipTitle = "Exercises"

    /// The two membership rules: the floor of two, and that a repeat is legal
    /// and logs independently.
    static let membershipMessage =
        "A superset must keep at least 2 exercises. The same exercise can "
        + "appear more than once — each slot logs independently."

    /// Every title/message pair, so a test can assert the set rather than
    /// three separately and notice one being dropped.
    static let all: [(title: String, message: String)] = [
        (timingTitle, timingMessage),
        (bulkSetsTitle, bulkSetsMessage),
        (membershipTitle, membershipMessage),
    ]
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

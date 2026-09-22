import Foundation

// ======================================================
// MARK: - Duration & rest bounds
// ======================================================

/// Single source of truth for every seconds-valued field the user can edit.
///
/// The app stores duration and rest as `Int` **seconds** everywhere — slot
/// prescription `durationMin/MaxSeconds`, `SessionPlan` rest, `WarmupStep
/// .restSecondsAfter`, logged `SetLog.durationSeconds`, and the Settings
/// defaults. That storage shape is unchanged; this enum only owns the upper
/// bounds and the normalization rules, so a value entered in one editor can
/// never be out of range in another.
///
/// Bounds (Friends & Family Beta feedback, 2026-08-02 — the previous editors
/// capped every seconds field at 600s / 300s, which made long cardio and long
/// rest impossible to enter at all):
///   - `maxExerciseSeconds` = 6h, so a walk / ride / treadmill session fits
///     alongside short holds like Plank, Hollow Hold, or Wall Sit.
///   - `maxRestSeconds` = 60m, covering long rest between heavy singles.
enum DurationLimits {

    /// Upper bound for a duration-based exercise's target or logged duration.
    static let maxExerciseSeconds = 21_600  // 6 hours

    /// Upper bound for any rest field (between sets, after exercise, after a
    /// warm-up step, and the Settings defaults that seed them).
    static let maxRestSeconds = 3_600  // 60 minutes

    /// Canonical form for an **optional** stored seconds value.
    ///
    ///  - `nil` stays `nil` (unset).
    ///  - `<= 0` collapses to `nil`. This preserves the "0 means unset / none"
    ///    convention every stepper binding in the app already used, and means a
    ///    negative value can never be stored.
    ///  - Anything above `upperBound` **clamps** down rather than failing, so a
    ///    value arriving from a routine import or an older build is repaired
    ///    instead of rejected.
    static func normalized(_ seconds: Int?, max upperBound: Int) -> Int? {
        guard let seconds, seconds > 0 else { return nil }
        return Swift.min(seconds, upperBound)
    }

    /// `normalized(_:max:)` at the exercise-duration bound.
    static func normalizedExerciseDuration(_ seconds: Int?) -> Int? {
        normalized(seconds, max: maxExerciseSeconds)
    }

    /// `normalized(_:max:)` at the rest bound.
    static func normalizedRest(_ seconds: Int?) -> Int? {
        normalized(seconds, max: maxRestSeconds)
    }

    /// Non-optional variant for fields whose storage has no "unset" state and
    /// treats 0 as a real value (the Settings defaults, the warm-up sheet's
    /// local `@State`). Negatives floor at 0; values above the bound clamp.
    static func clamped(_ seconds: Int, max upperBound: Int) -> Int {
        Swift.min(Swift.max(0, seconds), upperBound)
    }

    /// Parse a stored seconds **string** — the active workout keeps its
    /// per-set duration draft as text (`inputsByExerciseID`,
    /// `ParentDraftStore`), so it can be empty or, from an older build, a
    /// partial or oversized number.
    ///
    /// Empty / whitespace-only / non-numeric input resolves to `nil` rather
    /// than 0, so a cleared field never logs a zero-second set; the caller
    /// falls back to the planned duration. Valid input goes through
    /// `normalized(_:max:)`, so it is clamped and never negative.
    static func parseSeconds(_ text: String, max upperBound: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed) else { return nil }
        return normalized(value, max: upperBound)
    }

    /// The inverse of `parseSeconds`, for writing a picked value back into that
    /// text draft. `nil` becomes `""` — the cleared state, distinct from "0" —
    /// so a cleared picker and an untouched field resolve identically.
    static func secondsText(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        return String(seconds)
    }
}

// ======================================================
// MARK: - Compact duration formatting
// ======================================================

/// Human-readable rendering of a seconds value, plus the h/m/s decomposition
/// the duration picker's wheels are built from.
///
/// Unit *words* are localized — `"1m 30s"` in English is `"1분 30초"` in
/// Korean — because a duration is read as language, not as notation. This is
/// the app-wide time policy (see `DurationUnitText`), and it is deliberately
/// different from the measurement units (`kg`, `km`, `bpm`), which stay
/// universal. Every surface shares it: editors, wheels, summaries and timers.
/// The three time units, as user-facing text.
///
/// **The single place a duration's unit becomes words.** English keeps its
/// compact letters (`30s`, `5m`, `1h`); Korean spells them (`30초`, `5분`,
/// `1시간`). Time is prose in both languages, unlike a measurement unit —
/// `kg`, `km`, `km/h`, `bpm` and `kcal` stay universal everywhere, and
/// `DistanceUnit.symbol` still documents that rule for them.
///
/// Every duration in the app composes from these three functions, so a tempo
/// stepper, a rest summary, a cardio segment and a picker wheel cannot
/// disagree about what a second is called.
enum DurationUnitText {

    /// `"1h"` → `"1시간"`.
    static func hours(_ value: Int) -> String {
        String(localized: "\(plain(value))h")
    }

    /// `"5m"` → `"5분"`.
    static func minutes(_ value: Int) -> String {
        String(localized: "\(plain(value))m")
    }

    /// `"30s"` → `"30초"`.
    static func seconds(_ value: Int) -> String {
        String(localized: "\(plain(value))s")
    }

    /// The count as bare digits, floored at zero.
    ///
    /// Passed as a **string**, not an `Int`: interpolating an integer into a
    /// `String.LocalizationValue` formats it for the locale, which inserts
    /// digit grouping — a 1800-second cardio bout rendered "1,800s" instead of
    /// the "1800s" History has always shown (a compatibility guarantee
    /// `CardioHistorySummary` documents and its tests assert). A duration is a
    /// clock reading, not a quantity, so it is never grouped. Counts elsewhere
    /// (sets, reps, segments) keep integer interpolation, where grouping is
    /// correct.
    private static func plain(_ value: Int) -> String {
        String(max(0, value))
    }
}

enum DurationFormat {

    /// "45s" · "1m" · "1m 30s" · "1h" · "1h 5m" · "1h 5m 30s". Zero renders as
    /// "0s". Negative input is floored at 0 rather than trapping.
    static func compact(_ seconds: Int) -> String {
        let c = components(seconds)
        var parts: [String] = []
        if c.hours > 0 { parts.append(DurationUnitText.hours(c.hours)) }
        if c.minutes > 0 { parts.append(DurationUnitText.minutes(c.minutes)) }
        if c.seconds > 0 || parts.isEmpty {
            parts.append(DurationUnitText.seconds(c.seconds))
        }
        return parts.joined(separator: " ")
    }

    /// Split a seconds total into wheel components. Negative input floors at 0.
    static func components(_ seconds: Int)
        -> (hours: Int, minutes: Int, seconds: Int)
    {
        let total = Swift.max(0, seconds)
        return (total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Recombine wheel components. Negative components floor at 0, so the
    /// result is always >= 0.
    static func totalSeconds(hours: Int, minutes: Int, seconds: Int) -> Int {
        Swift.max(0, hours) * 3600
            + Swift.max(0, minutes) * 60
            + Swift.max(0, seconds)
    }
}

// ======================================================
// MARK: - Picker presets
// ======================================================

/// Quick-tap values offered above the duration/rest wheels. They exist so a
/// 30-minute cardio target or a 5-minute rest is one tap instead of a long
/// scroll — the beta complaint that motivated this whole change was stepper
/// tap count, not the absence of a maximum.
enum DurationPresets {

    /// Duration targets: short holds through long cardio.
    static let exerciseDuration: [Int] = [
        30, 60, 120, 300, 600, 1_200, 1_800, 2_700, 3_600,
    ]

    /// Rest values: the common between-set range plus long rest.
    static let rest: [Int] = [30, 60, 90, 120, 180, 300, 600]
}

// ======================================================
// MARK: - Duration display (ux/korean-localization-consistency)
// ======================================================

/// The one place a duration becomes **user-facing text**.
///
/// Before this, the same number of seconds reached the screen through a dozen
/// independent literals — `"\(r)s"`, `"\(r)s rest"`, `"Rest: \(r)s"`,
/// `String(format: "%dh %02dm")`, `String(localized: "\(r)s rest")` — so one
/// rest value read "30s rest" on the routine editor and "휴식 30초" on the block
/// summary, and the workout-duration formatter existed twice, verbatim, in two
/// files. Each site also decided for itself whether to localize at all.
///
/// ## Formatting policy
///
/// The split this type encodes, applied everywhere:
///
///  - **Time units are words, so they localize** via `DurationUnitText`:
///    `30s` → `30초`, `1m 30s` → `1분 30초`, `1h 5m` → `1시간 5분`. This is the
///    whole point of routing every duration through one type.
///  - **Measurement units stay universal** — `kg`, `lb`, `km`, `mi`, `m`,
///    `km/h`, `bpm`, `kcal`, plus `%` and `×`. `DistanceUnit.symbol` documents
///    that side of the rule.
///  - **The surrounding words localize too** — "rest" and "duration".
///
/// Every function here is pure and returns a `String` that is already
/// localized, so callers render it with `Text(verbatim:)` (or plain
/// interpolation) and must **not** wrap it in `LocalizedStringKey` — that would
/// look up an already-translated sentence as a key.
enum DurationDisplay {

    /// A bare duration: `"30s"` → `"30초"`.
    static func seconds(_ seconds: Int) -> String {
        DurationUnitText.seconds(seconds)
    }

    /// A duration range, with one unit on the pair: `"30–45s"` → `"30–45초"`.
    static func secondsRange(_ low: Int, _ high: Int) -> String {
        String(
            localized: "\(String(max(0, low)))–\(String(max(0, high)))s")
    }

    /// Decomposed for longer values: `"45s"`, `"1m 30s"`, `"1h 5m"`. Delegates
    /// to `DurationFormat.compact`, which the duration wheels already use, so
    /// an editor and the summary describing it cannot disagree.
    static func compact(_ seconds: Int) -> String {
        DurationFormat.compact(seconds)
    }

    /// Rest as prose: `"30s rest"` → `"휴식 30초"`.
    ///
    /// Takes the already-formatted duration rather than the raw number, so the
    /// unit word and the grouping rule are decided in exactly one place.
    static func rest(_ seconds: Int) -> String {
        String(localized: "\(self.seconds(seconds)) rest")
    }

    /// A labelled duration for a detail row: `"Duration 30s"`.
    static func labeledDuration(_ value: Int) -> String {
        String(localized: "Duration \(seconds(value))")
    }

    /// Elapsed workout time: `"1h 05m"`, or `"5m"` under an hour (never `"0m"`
    /// — a finished workout reads as at least a minute, which is the behavior
    /// `WorkoutRowFormat.duration` has always had).
    ///
    /// The hour form keeps its zero-padded minutes; only the pair's wording is
    /// translated, so English stays byte-identical to the `String(format:)` it
    /// replaces.
    static func elapsed(_ totalSeconds: Int) -> String {
        let total = max(0, totalSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            // The minutes keep their zero padding, so this composes the two
            // unit pieces rather than reusing `DurationUnitText.minutes`.
            let padded = String(format: "%02d", minutes)
            return DurationUnitText.hours(hours) + " "
                + String(localized: "\(padded)m")
        }
        return DurationUnitText.minutes(max(1, minutes))
    }

}

// ======================================================
// MARK: - Active-workout timer labels
// ======================================================

/// The two running-timer labels in the active workout's toolbar.
///
/// **Symbolic keys**, the shape `activeWorkout.back` established: the natural
/// keys `"Duration: %@"` and `"Duration %@"` (the latter belongs to
/// `DurationDisplay.labeledDuration`) generate the same String Catalog symbol,
/// which is a hard build error. Naming these two for where they appear keeps
/// both wordings and reads better in the catalog besides.
///
/// The seconds value comes from `DurationDisplay`, so a running timer names its
/// unit exactly like every other duration — `30s`, or `30초` in Korean.
enum ActiveWorkoutTimerLabel {

    static func duration(_ seconds: Int) -> String {
        String(
            format: NSLocalizedString("activeWorkout.timer.duration", comment: ""),
            DurationDisplay.seconds(seconds))
    }

    static func rest(_ seconds: Int) -> String {
        String(
            format: NSLocalizedString("activeWorkout.timer.rest", comment: ""),
            DurationDisplay.seconds(seconds))
    }
}

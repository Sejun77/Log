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

    /// Parse free-text numeric seconds entry — the active workout's
    /// "Duration (s)" field is a `.numberPad` `TextField`, so it can hold an
    /// empty, partial, or oversized string.
    ///
    /// Empty / whitespace-only / non-numeric input resolves to `nil` rather
    /// than 0, so a half-typed field never logs a zero-second set; the caller
    /// falls back to the planned duration. Valid input goes through
    /// `normalized(_:max:)`, so it is clamped and never negative.
    static func parseSeconds(_ text: String, max upperBound: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed) else { return nil }
        return normalized(value, max: upperBound)
    }
}

// ======================================================
// MARK: - Compact duration formatting
// ======================================================

/// Human-readable rendering of a seconds value, plus the h/m/s decomposition
/// the duration picker's wheels are built from.
///
/// The unit letters are intentionally **untranslated**, matching the bare
/// `"\(seconds)s"` suffix the rest of the app (block summaries, History rows,
/// the plan summary line) already renders in every language. This type is used
/// by the *editors*; existing read-only summaries keep their current format.
enum DurationFormat {

    /// "45s" · "1m" · "1m 30s" · "1h" · "1h 5m" · "1h 5m 30s". Zero renders as
    /// "0s". Negative input is floored at 0 rather than trapping.
    static func compact(_ seconds: Int) -> String {
        let c = components(seconds)
        var parts: [String] = []
        if c.hours > 0 { parts.append("\(c.hours)h") }
        if c.minutes > 0 { parts.append("\(c.minutes)m") }
        if c.seconds > 0 || parts.isEmpty { parts.append("\(c.seconds)s") }
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

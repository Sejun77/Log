import Foundation

// ======================================================
// MARK: - Cardio history summary
// ======================================================

/// Builds the trailing text of a History set row.
///
/// Pure and view-free so the exact rendered string is testable without a
/// SwiftUI host — History's row layout is otherwise deeply nested inside
/// `HistoryView`, where the one behavior that most needs pinning (an old
/// duration-only row rendering *byte-identically* to how it renders today) is
/// unreachable from a test.
///
/// ### The compatibility guarantee
///
/// `text(for:fallbackUnit:)` returns nil unless the set has a positive duration
/// or at least one cardio metric, and when a set has a duration but no metrics
/// it returns exactly `"\(seconds)s"` — the literal string `HistoryView` has
/// always produced. Every pre-Slice-3 row, every timed hold, and every beta
/// cardio log therefore renders unchanged, structurally rather than by
/// coincidence. Strength rows return nil and fall through to the untouched
/// weight/reps path.
///
/// ### Format
///
/// Segments joined by `" · "`, in a fixed order, with **absent values omitted
/// entirely** — never a placeholder dash, which would imply the user failed to
/// record something rather than that the field does not apply:
///
///     2700s · 6.2 km · 7:15 /km · 3% incline · level 8 · 142 bpm · Z3 · 410 kcal
///
/// The order runs: what was done (duration, distance, pace), how the machine
/// was set (incline, resistance), then the body's response (heart rate, zone,
/// energy).
enum CardioHistorySummary {

    /// Separator between segments. A middle dot with hair-thin spacing, the
    /// same separator the History header rows already use.
    static let separator = " · "

    // MARK: - Entry point

    /// The full trailing text for one set row, or nil when the set has nothing
    /// duration- or cardio-shaped to show (i.e. a strength set, whose existing
    /// weight/reps rendering is left entirely alone).
    ///
    /// - Parameter fallbackUnit: the unit used to render distance and pace when
    ///   the row's own `distanceUnitRaw` is missing or unparseable. Passed in
    ///   rather than read from `AppSettings` so the formatter stays pure and
    ///   testable; the view passes `AppSettings.distanceUnit`.
    static func text(for log: SetLog, fallbackUnit: DistanceUnit) -> String? {
        let parts = segments(for: log, fallbackUnit: fallbackUnit)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: separator)
    }

    /// The individual segments, in display order. Exposed for tests that assert
    /// on presence/absence without depending on the separator.
    static func segments(for log: SetLog, fallbackUnit: DistanceUnit) -> [String] {
        let metrics = log.cardioMetrics
        let duration = positiveDuration(log.durationSeconds)

        // A set with neither a duration nor a single metric is a strength set.
        guard duration != nil || !metrics.isEmpty else { return [] }

        // The row's own recorded unit wins, so History reads back the way the
        // user typed it. A missing or unparseable value falls back to the
        // current preference — the number is still correct either way, because
        // the distance itself is stored canonically in meters.
        let unit = metrics.distanceUnit ?? fallbackUnit

        var parts: [String] = []

        if let duration {
            parts.append(durationSegment(duration))
        }
        if let distance = distanceSegment(metrics, unit: unit) {
            parts.append(distance)
        }
        // Pace needs both operands; `CardioDerived` returns nil for a missing
        // or non-positive duration, so a distance-only row shows the distance
        // and simply omits the pace.
        if let pace = paceSegment(metrics, durationSeconds: duration, unit: unit) {
            parts.append(pace)
        }
        if let incline = inclineSegment(metrics) {
            parts.append(incline)
        }
        if let resistance = resistanceSegment(metrics) {
            parts.append(resistance)
        }
        if let bpm = metrics.avgHeartRate {
            parts.append("\(bpm) bpm")
        }
        if let zone = metrics.hrZone {
            parts.append(zone.shortLabel)
        }
        if let kcal = metrics.calories {
            parts.append("\(kcal) kcal")
        }
        return parts
    }

    // MARK: - Segments

    /// Exactly the string History has always rendered for a duration. Kept as
    /// its own function so the compatibility guarantee has one obvious place to
    /// be read and reviewed.
    static func durationSegment(_ seconds: Int) -> String { "\(seconds)s" }

    private static func distanceSegment(
        _ metrics: CardioMetrics, unit: DistanceUnit
    ) -> String? {
        guard let value = metrics.distanceValue(in: unit),
            let formatted = CardioDerived.formatDistance(value: value)
        else { return nil }
        return "\(formatted) \(unit.symbol)"
    }

    private static func paceSegment(
        _ metrics: CardioMetrics, durationSeconds: Int?, unit: DistanceUnit
    ) -> String? {
        guard
            let pace = metrics.paceSecondsPerUnit(
                durationSeconds: durationSeconds, in: unit),
            let formatted = CardioDerived.formatPace(secondsPerUnit: pace)
        else { return nil }
        return "\(formatted) /\(unit.symbol)"
    }

    /// Incline carries a localized word because a bare "3%" is ambiguous next
    /// to the other numeric segments. Decline renders with its sign ("-3%
    /// incline") rather than a separate word, keeping one key instead of two.
    private static func inclineSegment(_ metrics: CardioMetrics) -> String? {
        guard let percent = metrics.inclinePercent,
            let formatted = signedNumber(percent)
        else { return nil }
        let label = NSLocalizedString(
            "incline", comment: "History cardio summary: treadmill grade")
        return "\(formatted)% \(label)"
    }

    /// Machine levels are unitless, so the number alone would be meaningless.
    private static func resistanceSegment(_ metrics: CardioMetrics) -> String? {
        guard let level = metrics.resistanceLevel,
            let formatted = CardioDerived.formatDistance(value: level)
        else { return nil }
        let label = NSLocalizedString(
            "level", comment: "History cardio summary: machine resistance level")
        return "\(label) \(formatted)"
    }

    // MARK: - Helpers

    /// A duration is only shown when present and positive — matching the
    /// `dur > 0` gate History has always used.
    private static func positiveDuration(_ seconds: Int?) -> Int? {
        guard let seconds, seconds > 0 else { return nil }
        return seconds
    }

    /// `CardioDerived.formatDistance` rejects negatives (a distance cannot be
    /// negative), but incline can be. Format the magnitude and reattach the
    /// sign rather than widening the shared formatter's contract.
    private static func signedNumber(_ value: Double) -> String? {
        guard value.isFinite,
            let magnitude = CardioDerived.formatDistance(value: abs(value))
        else { return nil }
        return value < 0 ? "-\(magnitude)" : magnitude
    }
}

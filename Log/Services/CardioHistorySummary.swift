import Foundation

// ======================================================
// MARK: - Cardio history summary
// ======================================================

/// Builds the text of a History set row, and the collapsed summary of the
/// active-workout cardio Details section.
///
/// Pure and view-free so the exact rendered strings are testable without a
/// SwiftUI host — History's row layout is otherwise deeply nested inside
/// `HistoryView`, where the one behavior that most needs pinning (an old
/// duration-only row rendering *byte-identically* to how it renders today) is
/// unreachable from a test.
///
/// ### The compatibility guarantee
///
/// `primaryText(for:)` returns nil unless the set has a positive duration, and
/// otherwise returns exactly `"\(seconds)s"` — the literal string `HistoryView`
/// has always produced. `secondaryLines` is empty unless the set carries
/// metrics. So every pre-Slice-3 row, every timed hold, and every beta cardio
/// log renders unchanged, structurally rather than by coincidence, and strength
/// rows fall through to the untouched weight/reps path.
///
/// ### Layout
///
/// The original single-line form packed up to eight segments onto the row's
/// trailing edge, where it wrapped into an unreadable block. Metrics are now
/// **grouped onto secondary lines** under the row, each line one coherent idea:
///
///     2. Working Set                                        2700s
///     6.2 km · 7:15 /km
///     3% incline · level 8
///     142 bpm · Z3 · 410 kcal
///
/// Line 1 is what was covered, line 2 how the machine was set, line 3 the
/// body's response. Absent values are omitted entirely — never a placeholder
/// dash, which would imply the user failed to record something rather than that
/// the field does not apply — and a line with nothing in it does not exist.
enum CardioHistorySummary {

    /// Separator between segments on one line. A middle dot with hair-thin
    /// spacing, the same separator the History header rows already use.
    static let separator = " · "

    /// How many segments the collapsed active-workout summary shows before it
    /// stops. Three fits one line at accessibility text sizes without
    /// truncating; more did not, which is what made the label ellipsize.
    static let collapsedSegmentLimit = 3

    // MARK: - History row

    /// The primary trailing value: the duration, or nil when there is none.
    ///
    /// Deliberately independent of the metrics — a cardio set's duration is the
    /// one required value and stays in the row's primary position whatever else
    /// was recorded, so the eye lands in the same place on every row.
    static func primaryText(for log: SetLog) -> String? {
        positiveDuration(log.durationSeconds).map(durationSegment)
    }

    /// The grouped metric lines rendered under the primary row. Empty for
    /// strength sets, timed holds, and duration-only cardio sets.
    ///
    /// - Parameter displayUnit: the unit distance and pace render in. The row's
    ///   own `distanceUnitRaw` is deliberately **not** consulted: distance is
    ///   stored canonically in meters, so a bout run in miles reads in km the
    ///   moment the user prefers km, and the two never disagree with the pace
    ///   label beside them. Passed in rather than read from `AppSettings` so the
    ///   formatter stays pure and testable; the view passes
    ///   `AppSettings.distanceUnit`.
    static func secondaryLines(
        for log: SetLog, displayUnit: DistanceUnit
    ) -> [String] {
        let metrics = log.cardioMetrics
        guard !metrics.isEmpty else { return [] }

        let unit = displayUnit
        let duration = positiveDuration(log.durationSeconds)

        let groups: [[String]] = [
            // Covered: distance and the pace it implies.
            [
                distanceSegment(metrics, unit: unit),
                paceSegment(metrics, durationSeconds: duration, unit: unit),
            ].compactMap { $0 },
            // Machine setup.
            [
                inclineSegment(metrics),
                resistanceSegment(metrics),
            ].compactMap { $0 },
            // Physiological response, then energy.
            [
                metrics.avgHeartRate.map { "\($0) bpm" },
                metrics.hrZone?.shortLabel,
                metrics.calories.map { "\($0) kcal" },
            ].compactMap { $0 },
        ]

        return groups
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: separator) }
    }

    // MARK: - Collapsed active-workout summary

    /// One-line summary for the collapsed Details disclosure, capped at
    /// `collapsedSegmentLimit` segments.
    ///
    /// Priority is **distance, average heart rate, calories** — the three
    /// numbers people actually glance at to confirm they are logging the right
    /// bout. Incline, resistance and zone only appear to fill a slot none of
    /// those three claimed; pace and speed never appear, because pace has its
    /// own preview row inside the expanded section and duration is already the
    /// row's primary field.
    ///
    /// Returns nil when nothing valid has been entered, so the label shows just
    /// "Details".
    static func collapsedSummary(
        _ metrics: CardioMetrics, displayUnit: DistanceUnit
    ) -> String? {
        let parts = collapsedSegments(metrics, displayUnit: displayUnit)
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// The collapsed summary's segments. Exposed so tests can assert the cap
    /// and the priority order without parsing a joined string.
    static func collapsedSegments(
        _ metrics: CardioMetrics, displayUnit: DistanceUnit
    ) -> [String] {
        let unit = displayUnit
        let preferred: [String?] = [
            distanceSegment(metrics, unit: unit),
            metrics.avgHeartRate.map { "\($0) bpm" },
            metrics.calories.map { "\($0) kcal" },
        ]
        let fallback: [String?] = [
            inclineSegment(metrics),
            resistanceSegment(metrics),
            metrics.hrZone?.shortLabel,
        ]
        return Array(
            (preferred + fallback).compactMap { $0 }
                .prefix(collapsedSegmentLimit))
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

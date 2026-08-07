import Foundation

// ======================================================
// MARK: - Planned structured cardio, for History
// ======================================================

/// One row of the History **Planned** section.
///
/// A description of what was *programmed*, never of what happened. There is no
/// completion flag on this type and there is deliberately nowhere to put one:
/// the active checklist's ticks live in `CardioSegmentCheckStore`
/// (session-scoped `UserDefaults`, cleared when the workout finishes) and are
/// not part of any workout record, so History has nothing to render even if a
/// future row wanted to. See `STRUCTURED_CARDIO_DESIGN.md` §4.4 — a tick is not
/// a measurement, and History must never imply the app observed something it
/// did not.
struct CardioPlannedSegmentRow: Identifiable, Equatable {

    /// The expanded segment's deterministic id (`"<segment uuid>#<round>"`),
    /// used only to key the SwiftUI list. Two rounds of one authored segment
    /// are two rows with two ids.
    let id: String

    /// Localization **key** for the segment kind ("Warm-up", "Work", …), not a
    /// resolved string. `CardioSegmentKind.label` is the single source those
    /// four names come from, and the view renders it through
    /// `LocalizedStringKey` exactly as the routine editor and the active
    /// checklist do — so History reads in Korean too.
    let kindLabelKey: String

    /// The row's **leading** target — what goes on the primary line's trailing
    /// edge, where a logged row puts its duration: "10m", or the first target
    /// the segment does carry when it has no duration.
    ///
    /// Split out so a planned row has the same shape as a logged one: kind on
    /// the left, one headline value on the right, detail underneath. Empty only
    /// for a segment with no targets at all, which construction and decoding
    /// both refuse.
    let primaryTargetText: String

    /// Everything else on one line: the remaining targets **and the note**,
    /// joined with the same separator the logged metric lines use —
    /// "2 km · 0% incline · level 5 · Z1 · Easy".
    ///
    /// The note lives here rather than on a line of its own so a short note
    /// reads as one more piece of metadata instead of a detached fragment, and
    /// a long one wraps inside the same typography instead of switching style
    /// mid-row. Empty when the segment carries nothing but its leading target.
    let secondaryText: String

    /// Round position, present only for a segment in a repeated group. nil for
    /// every plan the 12C editor can author (it pins `repeatCount` to 1), so a
    /// flat plan renders with no round label at all.
    let round: Int?
    let roundCount: Int?

    /// True when this row belongs to a repeat and should show "Round 2/5".
    var isRepeated: Bool { round != nil && roundCount != nil }
}

/// Builds the History Planned section's content from a frozen plan.
///
/// Pure and view-free for the same reason `CardioHistorySummary` is: the rows
/// are otherwise unreachable from a test, buried inside `WorkoutDetailView`,
/// and the properties worth pinning — expansion order, round labelling, and
/// which unit distances render in — are exactly the ones a view test cannot
/// see.
enum CardioPlannedHistory {

    /// The expanded segment rows, in planned order.
    ///
    /// Expansion goes through the pure Slice 12B `expandedSegments()`, so a
    /// repeat is flattened by the same function the active checklist uses and
    /// there is no second implementation to drift. Bounded by construction:
    /// the plan's own initializer and decoder both cap expansion at
    /// `CardioPlanLimits.maxExpandedSegments`, so this cannot return an
    /// unbounded list however the payload arrived.
    ///
    /// - Parameter distanceUnit: the unit distances render in — the caller's
    ///   `AppSettings.distanceUnit`. Taken as a parameter rather than read here
    ///   so a Settings change re-renders History's planned rows the same way it
    ///   re-renders its logged ones (the Slice 8 rule).
    static func rows(
        for plan: CardioSegmentPlan,
        distanceUnit: DistanceUnit
    ) -> [CardioPlannedSegmentRow] {
        plan.expandedSegments().map { resolved in
            let parts = targetParts(
                of: resolved.segment, distanceUnit: distanceUnit)
            // The note is the last piece of metadata, never its own line.
            let detail =
                Array(parts.dropFirst())
                + [resolved.segment.note].compactMap { $0 }

            return CardioPlannedSegmentRow(
                id: resolved.id,
                kindLabelKey: resolved.segment.kind.label,
                primaryTargetText: parts.first ?? "",
                secondaryText: detail.joined(
                    separator: CardioHistorySummary.separator),
                round: resolved.isRepeated ? resolved.round : nil,
                roundCount: resolved.isRepeated ? resolved.roundCount : nil
            )
        }
    }

    /// One planned segment's targets, in the fixed order a row reads them:
    /// duration, distance, incline, resistance, HR zone.
    ///
    /// Deliberately **not** `CardioSegment.shortTargetSummary`, which the
    /// routine editor and the active checklist use. Those two are compact
    /// surfaces where "1%" and "L8" earn their brevity; History sits two rows
    /// above the *logged* metric line, and naming the same quantities
    /// differently there would read as two unrelated things. So incline and
    /// resistance come from `CardioHistorySummary`'s formatters — the single
    /// source of those localized words — and distance and zone use the same
    /// helpers the logged line does.
    ///
    /// Duration keeps the plan's own compact form ("10m") rather than the
    /// logged row's raw `"1800s"`: a *target* of 1800s is not how anyone
    /// programs a session, and the section's own summary already reads "21m".
    private static func targetParts(
        of segment: CardioSegment,
        distanceUnit: DistanceUnit
    ) -> [String] {
        var parts: [String] = []
        if let durationSeconds = segment.durationSeconds {
            parts.append(DurationFormat.compact(durationSeconds))
        }
        if let text = CardioTargetDistance(
            meters: segment.distanceMeters, displayUnit: distanceUnit)?
            .displayText
        {
            parts.append(text)
        }
        if let incline = segment.inclinePercent,
            let text = CardioHistorySummary.inclineText(percent: incline)
        {
            parts.append(text)
        }
        if let resistance = segment.resistanceLevel,
            let text = CardioHistorySummary.resistanceText(level: resistance)
        {
            parts.append(text)
        }
        if let zone = segment.hrZone {
            parts.append(zone.shortLabel)
        }
        return parts
    }

    /// The section's headline: "3 segments · 30m · 5 km".
    ///
    /// Delegates to `CardioSegmentPlan.summary`, so the figure History shows
    /// for a plan is the same one the routine editor and the active checklist
    /// show for it — counted over **expanded** segments, which is what the
    /// athlete was asked to do.
    static func summary(
        for plan: CardioSegmentPlan,
        distanceUnit: DistanceUnit
    ) -> String {
        plan.summary(distanceUnit: distanceUnit)
    }
}

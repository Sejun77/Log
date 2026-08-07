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

    /// The targets without the kind: "20m · 5 km · 1% · Z3". Verbatim, like
    /// every other composed plan summary in the app — assembled from numbers
    /// and units, so there is no whole phrase to translate.
    let targetText: String

    /// Round position, present only for a segment in a repeated group. nil for
    /// every plan the 12C editor can author (it pins `repeatCount` to 1), so a
    /// flat plan renders with no round column at all.
    let round: Int?
    let roundCount: Int?

    /// The author's free text for this segment, if any.
    let note: String?

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
            CardioPlannedSegmentRow(
                id: resolved.id,
                kindLabelKey: resolved.segment.kind.label,
                targetText: resolved.segment.shortTargetSummary(
                    distanceUnit: distanceUnit),
                round: resolved.isRepeated ? resolved.round : nil,
                roundCount: resolved.isRepeated ? resolved.roundCount : nil,
                note: resolved.segment.note
            )
        }
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

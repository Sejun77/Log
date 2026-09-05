import SwiftUI

// MARK: - Structured cardio checklist (Slice 12D)

/// The read-only **Cardio Plan** checklist for a cardio slot that carries a
/// structured segment plan.
///
/// This is a *plan*, not a log. Ticking a segment records nothing: the bout is
/// still logged as one aggregate cardio `SetLog` from the duration and Details
/// fields below, exactly as it was before this slice
/// (`STRUCTURED_CARDIO_DESIGN.md` §2.6). Nothing here gates the Log button,
/// creates a set, or reaches History — the ticks live in session-scoped state
/// (`CardioSegmentCheckStore`) and are gone when the workout finishes.
///
/// Rendered only for cardio slots whose resolved plan has segments; strength
/// slots, timed holds, and unstructured cardio slots never construct it, so
/// "no new UI for everyone else" is structural rather than a matter of testing
/// every path.
///
/// **Read-only except for the ticks.** Editing segment targets mid-workout is
/// deliberately not offered here: the active screen is the highest-risk screen
/// in the app, and mid-workout plan edits already have a home in
/// `EditSessionPlanSheet`. See §4.3 of the design.
struct CardioSegmentChecklistSection: View {

    /// The resolved plan for this slot — session plan first, frozen snapshot
    /// second (`SessionPlanResolver.plannedCardioSegments`). Already known
    /// non-empty by the caller.
    let plan: CardioSegmentPlan

    /// Unit for every distance shown here. Passed in rather than read from
    /// `AppSettings`, so this view has no hidden dependency and the Slice 8
    /// live-unit-change rule keeps working: the parent holds the `@AppStorage`.
    let distanceUnit: DistanceUnit

    /// The ticked `ResolvedCardioSegment.id`s. Writing through the binding is
    /// what persists them — the parent owns the store.
    @Binding var checkedIDs: Set<String>

    /// Expanded by default, unlike the design's §4.3 sketch. This is its own
    /// List section above the Sets section rather than an inline row, so a long
    /// plan scrolls instead of pushing the duration field and Log button off
    /// screen — which was the reason the sketch wanted it collapsed. A
    /// checklist you must open before every tick is worse than one you scroll
    /// past, and the summary row below collapses it for anyone who disagrees.
    @State private var isExpanded = true

    /// Computed once per render rather than per row.
    private var segments: [ResolvedCardioSegment] { plan.expandedSegments() }

    var body: some View {
        Section {
            summaryRow
            if isExpanded {
                // Bounded by construction: `expandedSegments()` can never
                // exceed `CardioPlanLimits.maxExpandedSegments` (60), because
                // both the initializer and the decoder enforce it. So this
                // ForEach has a hard ceiling without one being imposed here.
                ForEach(segments) { resolved in
                    row(for: resolved)
                }
            }
        } header: {
            Text("Cardio Plan")
        } footer: {
            // The audit's M2, and a reversal of the note that stood here: a
            // footer was refused because "ticks are not saved to your history"
            // is a sentence about the app's internals, on the one screen a user
            // is not reading. That objection was about the *sentence*, and it
            // still holds — this is four words, scanned rather than read, and
            // it answers the question a tick actually raises: did that count as
            // logging something? It did not. The bout is still logged once,
            // from the duration and Details fields below.
            //
            // Behaviour is untouched: the ticks remain session-scoped state in
            // `CardioSegmentCheckStore`, which is still the only writer and
            // still cannot reach a `SetLog` or History.
            Text("Checklist only — not saved as results.")
                .font(.dsCaption)
        }
    }

    // MARK: - Rows

    /// Headline + disclosure. The plan summary is verbatim, like every other
    /// composed plan summary in the app (`SessionPlan.primarySummary`, the
    /// routine editor's segment footer): it is assembled from numbers and
    /// units, so there is no whole phrase to translate.
    private var summaryRow: some View {
        Button {
            // Toggled inside an animation-free transaction for the same reason
            // `CardioDetailsSection` does: an animated height change inside a
            // List row drags the surrounding rows with it, and this section
            // sits directly above the logging controls.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isExpanded.toggle() }
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(plan.summary(distanceUnit: distanceUnit))
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
                Spacer(minLength: DSSpacing.sm)
                // Progress, not a result: how far down their own list the user
                // has ticked. Digits and a slash, so nothing to localize.
                Text(verbatim: "\(tickedCount)/\(segments.count)")
                    .font(.dsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(nil, value: isExpanded)
    }

    /// One expanded segment. The whole row is the tap target — a bare checkbox
    /// glyph is a small thing to hit mid-bout, which §15.4 of the design flags
    /// as the open usability question.
    private func row(for resolved: ResolvedCardioSegment) -> some View {
        let isChecked = checkedIDs.contains(resolved.id)
        return Button {
            toggle(resolved.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Image(
                    systemName: isChecked
                        ? "checkmark.circle.fill" : "circle"
                )
                .font(.dsBody)
                .foregroundStyle(isChecked ? Color.green : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DSSpacing.sm) {
                        Text(LocalizedStringKey(resolved.segment.kind.label))
                            .font(.dsBody)
                            .foregroundStyle(.primary)
                        // Only for a repeated group, so a flat plan — every
                        // plan today, until the 12F interval editor ships —
                        // renders exactly as it would without repeats.
                        if resolved.isRepeated {
                            Text(
                                "Round \(resolved.round)/\(resolved.roundCount)"
                            )
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    // Targets only; the kind is the line above. Verbatim, for
                    // the same reason as the summary.
                    Text(
                        resolved.segment.shortTargetSummary(
                            distanceUnit: distanceUnit)
                    )
                    .font(.dsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let note = resolved.segment.note {
                        Text(note)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - State

    /// Counted against the live expanded list rather than `checkedIDs.count`,
    /// so an orphan id left over from an edited or replaced plan cannot inflate
    /// the progress figure.
    private var tickedCount: Int {
        segments.reduce(0) { $0 + (checkedIDs.contains($1.id) ? 1 : 0) }
    }

    /// Toggles exactly one occurrence. Ids are
    /// `"<segment uuid>#<round>"`, so ticking round 1 of a repeat leaves round
    /// 2 untouched, and reordering the plan carries a tick with its segment
    /// instead of leaving it on whatever moved into that position.
    private func toggle(_ id: String) {
        if checkedIDs.contains(id) {
            checkedIDs.remove(id)
        } else {
            checkedIDs.insert(id)
        }
    }
}

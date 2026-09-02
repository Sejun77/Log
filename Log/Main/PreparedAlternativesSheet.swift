import SwiftUI

// ======================================================
// MARK: - Prepared Alternatives sheet (Phase F1)
// ======================================================

/// The first screen of a switch when the slot has prepared alternatives.
///
/// A sheet rather than the existing `confirmationDialog`, for the reason §8.1
/// gives: a dialog is a stack of button titles, and an alternative needs a
/// name, a prescription summary, a usage note and a disabled state to be worth
/// tapping. The dialog stays exactly as it is for the path that still ends in
/// it — `Choose another exercise…` opens today's picker, which still asks
/// Keep / Reset.
///
/// **This sheet only appears when the slot has something to offer.** A slot
/// with no enabled, resolvable, not-already-current alternative goes straight
/// to the picker, exactly as it did before this phase.
struct PreparedAlternativesSheet: View {

    /// The exercise currently in the slot — the thing being switched *from*.
    let currentExerciseName: String
    let offers: [PreparedAlternativeOffer]
    /// Unit for a cardio alternative's distance in the summary line.
    let distanceUnit: DistanceUnit
    /// App-wide autoreg metric, so the summary's effort segment matches every
    /// other summary in the app. Nil (autoreg off) omits it.
    let effortMetric: EffortMetric?

    let onPick: (SlotAlternative) -> Void
    let onChooseAnother: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(offers) { offer in
                        Button {
                            dismiss()
                            onPick(offer.alternative)
                        } label: {
                            row(for: offer)
                        }
                        .buttonStyle(.plain)
                        // A deleted exercise cannot be switched to, but the
                        // row still says so rather than vanishing (§8.7).
                        .disabled(!offer.isAvailable)
                    }
                } header: {
                    // M13 — the sheet is titled by the *action* now, so the
                    // exercise being replaced moves here, where it reads as
                    // context for the rows underneath rather than as the
                    // screen's name. `textCase(nil)` keeps a proper-noun
                    // exercise name out of header capitalization.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prepared Alternatives")
                        Text("Replacing \(currentExerciseName)")
                            .textCase(nil)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onChooseAnother()
                    } label: {
                        Label(
                            "Choose another exercise…",
                            systemImage: "magnifyingglass")
                    }
                } header: {
                    Text("Other Options")
                }
            }
            // M13 — named for what this screen does. It used to be titled
            // with the current exercise's name, which read as "you are looking
            // at Bench Press" rather than "you are switching away from it".
            .navigationTitle("Switch Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for offer: PreparedAlternativeOffer) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(offer.exerciseName)
                .lineLimit(1)
                .foregroundStyle(offer.isAvailable ? .primary : .secondary)

            if offer.isAvailable {
                Text(
                    SlotAlternativeSummary.subtitle(
                        for: offer.alternative,
                        effortMetric: effortMetric,
                        displayUnit: distanceUnit)
                )
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            } else {
                Text("Exercise unavailable")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }

            // The "why/when to use this" note, shown only when the user wrote
            // one — this is the line that makes a prepared alternative
            // choosable at a glance mid-set.
            if offer.isAvailable, let note = offer.note {
                Text(note)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

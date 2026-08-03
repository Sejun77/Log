import SwiftUI

// MARK: - Optional cardio metrics for one active-workout set

/// The collapsed **Details** disclosure under a cardio set row.
///
/// Everything here is optional. The row above it logs on duration alone, and
/// this section starts collapsed, so the primary cardio flow — type seconds,
/// tap Log — is exactly as many taps as it was before Slice 4. A user who never
/// opens Details never sees a cardio field.
///
/// Rendered only when the slot's exercise is `.cardio`; timed holds and
/// strength sets never construct it.
struct CardioDetailsSection: View {
    @FocusState private var focused: Field?
    private enum Field {
        case distance, heartRate, calories, incline, resistance
    }

    @Binding var draft: CardioEntryDraft

    /// The duration the row would log right now, used only to derive the live
    /// pace/speed preview. Zero means "not enough to derive", not an error.
    let durationSeconds: Int

    /// Mirrors the primary row: once a set is logged its fields are read-only
    /// and the way to change it is Undo, then re-log.
    let isLogged: Bool

    @State private var isExpanded = false

    /// Derived once per render rather than three times inside `body`.
    private var pace: String? { draft.paceText(durationSeconds: durationSeconds) }
    private var speed: String? { draft.speedText(durationSeconds: durationSeconds) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                distanceRow
                heartRateRow
                zoneRow
                caloriesRow
                inclineRow
                resistanceRow
                derivedRow
            }
            .padding(.top, DSSpacing.xs)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Text("Details")
                    .font(.dsBodySecondary)
                // Collapsed summary of what has been entered, so a user who
                // filled the fields on a previous set can confirm this one at a
                // glance without expanding.
                if let summary = draft.summaryText {
                    Text(summary)
                        .font(.dsCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .disclosureGroupStyle(.automatic)
    }

    // MARK: - Field rows

    private var distanceRow: some View {
        LabeledField(label: "Distance") {
            TextField("0.0", text: distanceBinding)
                .font(.dsBody.monospacedDigit())
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .disabled(isLogged)
                .focused($focused, equals: .distance)

            // The unit is per-set, seeded from the Settings preference. Storage
            // is canonical meters either way, so switching it re-reads the same
            // distance rather than converting the typed number.
            Picker("Unit", selection: unitBinding) {
                ForEach(DistanceUnit.allCases, id: \.self) { unit in
                    Text(unit.symbol).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .disabled(isLogged)
        }
    }

    private var heartRateRow: some View {
        LabeledField(label: "Average Heart Rate") {
            TextField("0", text: intBinding(\.avgHeartRate))
                .font(.dsBody.monospacedDigit())
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .disabled(isLogged)
                .focused($focused, equals: .heartRate)
            Text("bpm")
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
        }
    }

    private var zoneRow: some View {
        LabeledField(label: "Heart-Rate Zone") {
            Picker("Heart-Rate Zone", selection: $draft.hrZone) {
                Text("None").tag(HRZone?.none)
                ForEach(HRZone.allCases, id: \.self) { zone in
                    Text(zone.shortLabel).tag(HRZone?.some(zone))
                }
            }
            .pickerStyle(.menu)
            .disabled(isLogged)
        }
    }

    private var caloriesRow: some View {
        LabeledField(label: "Calories") {
            TextField("0", text: intBinding(\.calories))
                .font(.dsBody.monospacedDigit())
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .disabled(isLogged)
                .focused($focused, equals: .calories)
            Text("kcal")
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
        }
    }

    private var inclineRow: some View {
        LabeledField(label: "Incline / Decline") {
            // `.numbersAndPunctuation` rather than `.decimalPad`: the decimal
            // pad has no minus key, which would make treadmill decline
            // unreachable even though the model accepts it down to -30%.
            TextField("0", text: signedBinding(\.incline))
                .font(.dsBody.monospacedDigit())
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .disabled(isLogged)
                .focused($focused, equals: .incline)
            Text("%")
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
        }
    }

    private var resistanceRow: some View {
        LabeledField(label: "Resistance") {
            TextField("0", text: decimalBinding(\.resistance))
                .font(.dsBody.monospacedDigit())
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .disabled(isLogged)
                .focused($focused, equals: .resistance)
        }
    }

    /// Pace and speed are derived, never stored, and never shown as a
    /// placeholder — the rows simply do not exist until both a distance and a
    /// positive duration are present.
    @ViewBuilder
    private var derivedRow: some View {
        if pace != nil || speed != nil {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                if let pace {
                    LabeledField(label: "Pace") {
                        Text(pace)
                            .font(.dsBody.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let speed {
                    LabeledField(label: "Speed") {
                        Text(speed)
                            .font(.dsBody.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    /// Each binding sanitizes on the way in (so nonsense cannot be typed) and
    /// hands the whole draft back to the parent, which persists it. Validation
    /// proper happens at log time in `CardioEntryDraft.metrics`.

    private var distanceBinding: Binding<String> {
        Binding(
            get: { draft.distance },
            set: { draft.distance = CardioEntryDraft.sanitizeDecimal($0) }
        )
    }

    private var unitBinding: Binding<DistanceUnit> {
        Binding(get: { draft.unit }, set: { draft.unit = $0 })
    }

    private func intBinding(
        _ keyPath: WritableKeyPath<CardioEntryDraft, String>
    ) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { draft[keyPath: keyPath] = CardioEntryDraft.sanitizeInteger($0) }
        )
    }

    private func decimalBinding(
        _ keyPath: WritableKeyPath<CardioEntryDraft, String>
    ) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { draft[keyPath: keyPath] = CardioEntryDraft.sanitizeDecimal($0) }
        )
    }

    private func signedBinding(
        _ keyPath: WritableKeyPath<CardioEntryDraft, String>
    ) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: {
                draft[keyPath: keyPath] = CardioEntryDraft.sanitizeSignedDecimal($0)
            }
        )
    }
}

// MARK: - Row scaffold

/// One label + control line. Keeps the seven rows above visually identical
/// without repeating the same `HStack` and font modifiers seven times.
private struct LabeledField<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text(label)
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
            Spacer(minLength: DSSpacing.sm)
            content
        }
    }
}

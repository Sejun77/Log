import SwiftUI

// MARK: - Optional cardio metrics for one active-workout set

/// The collapsed **Details** disclosure under a cardio set row.
///
/// Everything here is optional. The row above it logs on duration alone, and
/// this section starts collapsed, so the primary cardio flow — set the
/// duration, tap Log — is exactly as many taps as it was before Slice 4. A user
/// who never opens Details never sees a cardio field.
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

    /// Every value control is the same width and every row ends with a
    /// fixed-width unit suffix, so the fields line up in one column instead of
    /// stepping left and right as the suffix ("bpm" / "kcal" / "%" / none)
    /// changes width.
    private static let controlWidth: CGFloat = 96
    fileprivate static let suffixWidth: CGFloat = 34

    /// Derived once per render rather than three times inside `body`.
    private var pace: String? { draft.paceText(durationSeconds: durationSeconds) }
    private var speed: String? { draft.speedText(durationSeconds: durationSeconds) }

    var body: some View {
        // A plain button + conditional section rather than `DisclosureGroup`.
        // `DisclosureGroup` animates its own expansion, and inside a List row
        // that animation re-lays out the whole row: the set label, duration
        // field, Start and Log buttons all slid vertically while the section
        // opened. Toggling inside a transaction with animations disabled makes
        // the section appear and disappear in one frame, which keeps the
        // primary logging controls perfectly still. No animation beats an
        // awkward one here — the row is a data-entry surface, not a showcase.
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isExpanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    distanceRow
                    heartRateRow
                    zoneRow
                    caloriesRow
                    inclineRow
                    resistanceRow
                    derivedRow
                }
            }
        }
        // Belt and braces: also opt the subtree out of any animation an
        // enclosing List or navigation transition might try to apply to the
        // height change.
        .animation(nil, value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "chevron.right")
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                // Rotating a fixed-size glyph keeps the header's height
                // constant, so the chevron cannot nudge the rows around it.
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Text("Details")
                .font(.dsBodySecondary)
            Spacer(minLength: DSSpacing.sm)
            // Collapsed summary of what has been entered, so a user who filled
            // the fields on a previous set can confirm this one at a glance
            // without expanding. Capped at three segments by the formatter, so
            // it fits on one line instead of ellipsizing.
            if let summary = draft.summaryText {
                Text(summary)
                    .font(.dsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Field rows

    private var distanceRow: some View {
        LabeledField(label: "Distance") {
            TextField("0.0", text: distanceBinding)
                .font(.dsBody.monospacedDigit())
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.controlWidth)
                .disabled(isLogged)
                .focused($focused, equals: .distance)

            // A label, not a control: the distance unit is chosen in Settings
            // and nowhere else, so this row reads exactly like Calories or
            // Incline. Storage is canonical meters, so the preference decides
            // how the number is written and read, never what it means.
            UnitSuffix(verbatim: draft.unit.symbol)
        }
    }

    private var heartRateRow: some View {
        LabeledField(label: "Average Heart Rate") {
            TextField("0", text: intBinding(\.avgHeartRate))
                .font(.dsBody.monospacedDigit())
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.controlWidth)
                .disabled(isLogged)
                .focused($focused, equals: .heartRate)
            UnitSuffix("bpm")
        }
    }

    private var zoneRow: some View {
        LabeledField(label: "Heart-Rate Zone") {
            // `.labelsHidden()` because `LabeledField` already renders the
            // label — a `.menu` picker draws its own title otherwise, which
            // printed "Heart-Rate Zone" twice on the same line.
            Picker("Heart-Rate Zone", selection: $draft.hrZone) {
                Text("None").tag(HRZone?.none)
                ForEach(HRZone.allCases, id: \.self) { zone in
                    Text(zone.shortLabel).tag(HRZone?.some(zone))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(isLogged)
            .frame(width: Self.controlWidth, alignment: .trailing)
            UnitSuffix()
        }
    }

    private var caloriesRow: some View {
        LabeledField(label: "Calories") {
            TextField("0", text: intBinding(\.calories))
                .font(.dsBody.monospacedDigit())
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.controlWidth)
                .disabled(isLogged)
                .focused($focused, equals: .calories)
            UnitSuffix("kcal")
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
                .frame(width: Self.controlWidth)
                .disabled(isLogged)
                .focused($focused, equals: .incline)
            UnitSuffix("%")
        }
    }

    private var resistanceRow: some View {
        LabeledField(label: "Resistance") {
            TextField("0", text: decimalBinding(\.resistance))
                .font(.dsBody.monospacedDigit())
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.controlWidth)
                .disabled(isLogged)
                .focused($focused, equals: .resistance)
            UnitSuffix()
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
                    // The label carries the unit ("Pace (min/km)") because the
                    // value's "/km" suffix alone does not tell a first-time
                    // user what the number in front of it measures.
                    LabeledField(resolvedLabel: draft.unit.paceFieldLabel) {
                        Text(pace)
                            .font(.dsBody.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(
                                width: Self.controlWidth, alignment: .trailing)
                        UnitSuffix()
                    }
                }
                if let speed {
                    LabeledField(label: "Speed") {
                        Text(speed)
                            .font(.dsBody.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(
                                width: Self.controlWidth, alignment: .trailing)
                        UnitSuffix()
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

/// Fixed-width trailing unit label. Present even when empty, so a unitless
/// field (Resistance) keeps its control in the same column as the others.
private struct UnitSuffix: View {
    private let label: Text

    init(_ text: LocalizedStringKey? = nil) {
        label = text.map { Text($0) } ?? Text(verbatim: "")
    }

    /// Untranslated variant, for a unit symbol resolved at runtime ("km" /
    /// "mi"). These stay in the source language like `kg` / `lb` / `s`, so they
    /// must not go through a catalog lookup.
    init(verbatim text: String) { label = Text(verbatim: text) }

    var body: some View {
        label
            .font(.dsBodySecondary)
            .foregroundStyle(.secondary)
            .frame(width: CardioDetailsSection.suffixWidth, alignment: .leading)
    }
}

// MARK: - Row scaffold

/// One label + control line. Keeps the seven rows above visually identical
/// without repeating the same `HStack` and font modifiers seven times.
private struct LabeledField<Content: View>: View {
    private let label: Text
    private let content: Content

    /// Static label, localized at render time by `Text` as everywhere else.
    init(label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.label = Text(label)
        self.content = content()
    }

    /// Label that was already resolved through `NSLocalizedString` — used by
    /// the pace row, whose key depends on the row's distance unit and so
    /// cannot be a compile-time `LocalizedStringKey`.
    init(resolvedLabel: String, @ViewBuilder content: () -> Content) {
        self.label = Text(resolvedLabel)
        self.content = content()
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            label
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
            Spacer(minLength: DSSpacing.sm)
            content
        }
    }
}

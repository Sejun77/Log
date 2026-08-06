import SwiftUI

// ======================================================
// MARK: - Duration / rest field row
// ======================================================

/// Form row for a seconds-valued field (exercise duration, rest between sets,
/// rest after exercise, warm-up rest, Settings rest defaults).
///
/// Replaces the fixed-step `Stepper`s these fields used to render. A stepper
/// bounded at 600s and stepping 15s needs 120 taps to reach 30 minutes, which
/// is what the Friends & Family Beta reported; this row instead offers
///
///   1. a **preset strip** — one tap for the common values, and
///   2. an **h/m/s wheel picker** — a scroll or two for anything else,
///
/// with the current value always shown on the collapsed row. The hours wheel
/// is only rendered when `maxSeconds` is above an hour, so a rest field shows
/// two wheels (minutes 0…60, seconds) and a duration field shows three.
///
/// Storage is unchanged: the binding is optional `Int` seconds, where `nil`
/// (and any value <= 0) means "unset", exactly as the steppers stored it. Every
/// write goes through `DurationLimits.normalized(_:max:)`, so the row can never
/// produce a negative value or one above `maxSeconds`.
struct DurationFieldRow: View {

    /// Row title. Localized through the string catalog, matching the label
    /// handling of the steppers this replaces.
    let title: String

    /// Stored seconds. `nil` = unset; writes are normalized and clamped.
    @Binding var seconds: Int?

    /// Upper bound — `DurationLimits.maxExerciseSeconds` or `.maxRestSeconds`.
    let maxSeconds: Int

    /// Value label shown when the field is unset. Localized; the call sites use
    /// "None" for rest (which reads "no rest") and "—" for duration.
    var zeroLabel: String = "—"

    /// Quick-tap values. Any preset above `maxSeconds` is dropped.
    var presets: [Int] = []

    @State private var isExpanded = false

    // MARK: Body

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(LocalizedStringKey(title))
                    .foregroundStyle(.primary)
                Spacer()
                valueText
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isExpanded {
            DurationWheelPicker(
                seconds: $seconds,
                maxSeconds: maxSeconds,
                zeroLabel: zeroLabel,
                presets: presets,
                accessibilityTitle: title)
        }
    }

    private var valueText: Text {
        guard let seconds, seconds > 0 else {
            return Text(LocalizedStringKey(zeroLabel))
        }
        return Text(DurationFormat.compact(seconds))
    }
}

// ======================================================
// MARK: - The scrolling duration setter itself
// ======================================================

/// The preset strip + h/m/s wheels, with no row chrome around them.
///
/// Extracted out of `DurationFieldRow` unchanged so the *active workout* set
/// row can offer the same control without inheriting a Form row's title,
/// chevron, and full-width tap target. `DurationFieldRow` still renders it in
/// exactly the same place it used to render these views inline, so rest,
/// routine prescription, warm-up, and Settings editing are untouched — this is
/// a move, not a redesign.
///
/// Storage contract is the row's: optional `Int` seconds where `nil` (and any
/// value <= 0) means "unset", and every write goes through
/// `DurationLimits.normalized(_:max:)` so the value can never be negative or
/// above `maxSeconds`.
struct DurationWheelPicker: View {

    /// Stored seconds. `nil` = unset; writes are normalized and clamped.
    @Binding var seconds: Int?

    /// Upper bound — `DurationLimits.maxExerciseSeconds` or `.maxRestSeconds`.
    let maxSeconds: Int

    /// Label for the "clear it" preset chip. Localized.
    var zeroLabel: String = "—"

    /// Quick-tap values. Any preset above `maxSeconds` is dropped.
    var presets: [Int] = []

    /// Title the wheels report to VoiceOver (their visible labels are hidden).
    var accessibilityTitle: String

    // MARK: Derived ranges

    /// Hours only make sense past a one-hour bound; at exactly an hour the
    /// minutes wheel covers the whole range (0…60) more directly.
    private var showsHours: Bool { maxSeconds > 3_600 }

    private var hourRange: [Int] { Array(0...(maxSeconds / 3_600)) }

    private var minuteRange: [Int] {
        showsHours ? Array(0...59) : Array(0...(maxSeconds / 60))
    }

    private var secondRange: [Int] { Array(0...59) }

    private var visiblePresets: [Int] { presets.filter { $0 <= maxSeconds } }

    var body: some View {
        if !visiblePresets.isEmpty {
            presetStrip
        }
        wheels
    }

    // MARK: Presets

    /// Horizontally scrolling chips. Includes a leading "None" chip so the
    /// field can be cleared without scrolling three wheels back to zero — the
    /// stepper's 0 position.
    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.sm) {
                presetChip(label: Text(LocalizedStringKey(zeroLabel)), value: nil)
                ForEach(visiblePresets, id: \.self) { value in
                    presetChip(
                        label: Text(DurationFormat.compact(value)), value: value)
                }
            }
            .padding(.vertical, DSSpacing.xs)
        }
    }

    private func presetChip(label: Text, value: Int?) -> some View {
        let isSelected = (seconds ?? 0) == (value ?? 0)
        return Button {
            seconds = DurationLimits.normalized(value, max: maxSeconds)
        } label: {
            label
                .font(.dsCaption)
                .monospacedDigit()
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs)
                .background(
                    Capsule().fill(
                        isSelected
                            ? DSColor.accent.opacity(0.18)
                            : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(isSelected ? DSColor.accent : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Wheels

    private var wheels: some View {
        HStack(spacing: 0) {
            if showsHours {
                wheel(values: hourRange, unit: "h", binding: hoursBinding)
            }
            wheel(values: minuteRange, unit: "m", binding: minutesBinding)
            wheel(values: secondRange, unit: "s", binding: secondsBinding)
        }
        .frame(height: 120)
        .clipped()
    }

    /// One wheel column. The unit letters match `DurationFormat.compact`, which
    /// keeps them untranslated for the same reason the app's existing `"\(x)s"`
    /// suffixes are untranslated.
    private func wheel(values: [Int], unit: String, binding: Binding<Int>)
        -> some View
    {
        Picker(selection: binding) {
            ForEach(values, id: \.self) { v in
                Text("\(v)\(unit)").monospacedDigit().tag(v)
            }
        } label: {
            Text(LocalizedStringKey(accessibilityTitle))
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    // MARK: Component bindings

    /// Each wheel reads its slice of the current total and writes back the
    /// recombined, normalized total. Because the write is clamped, choosing a
    /// combination past `maxSeconds` (e.g. 6h + 30m at a 6h bound) settles on
    /// the bound rather than storing an out-of-range value.
    private func componentBinding(
        _ part: WritableKeyPath<DurationComponents, Int>
    ) -> Binding<Int> {
        Binding(
            get: { DurationComponents(seconds ?? 0)[keyPath: part] },
            set: { newValue in
                var c = DurationComponents(seconds ?? 0)
                c[keyPath: part] = newValue
                seconds = DurationLimits.normalized(c.total, max: maxSeconds)
            }
        )
    }

    private var hoursBinding: Binding<Int> { componentBinding(\.hours) }
    private var minutesBinding: Binding<Int> { componentBinding(\.minutes) }
    private var secondsBinding: Binding<Int> { componentBinding(\.seconds) }
}

/// Mutable h/m/s view over a seconds total, so the three wheel bindings can be
/// expressed as one key-path-driven helper.
private struct DurationComponents {
    var hours: Int
    var minutes: Int
    var seconds: Int

    init(_ total: Int) {
        let c = DurationFormat.components(total)
        hours = c.hours
        minutes = c.minutes
        seconds = c.seconds
    }

    var total: Int {
        DurationFormat.totalSeconds(
            hours: hours, minutes: minutes, seconds: seconds)
    }
}

// ======================================================
// MARK: - Non-optional convenience
// ======================================================

/// `DurationFieldRow` for a field stored as a plain `Int` with no "unset"
/// state — the Settings rest defaults and the warm-up sheet's local state,
/// where 0 is a real value meaning "no rest".
struct DurationFieldRowInt: View {
    let title: String
    @Binding var seconds: Int
    let maxSeconds: Int
    var zeroLabel: String = "None"
    var presets: [Int] = []

    var body: some View {
        DurationFieldRow(
            title: title,
            seconds: Binding(
                get: { seconds > 0 ? seconds : nil },
                set: {
                    seconds = DurationLimits.clamped($0 ?? 0, max: maxSeconds)
                }
            ),
            maxSeconds: maxSeconds,
            zeroLabel: zeroLabel,
            presets: presets
        )
    }
}

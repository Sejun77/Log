import SwiftUI

// ======================================================
// MARK: - Active-workout duration entry
// ======================================================

/// The duration control on an active-workout set row: a compact value chip that
/// opens the app's **scrolling duration setter** — the same preset strip and
/// h/m/s wheels (`DurationWheelPicker`) that rest, routine prescription,
/// warm-up, and the Settings defaults already use.
///
/// It replaces two earlier attempts at the same field: raw seconds ("5000" with
/// a formatted echo beside it), and three h/min/s text fields. Both made the
/// user type a number in a row whose whole job is to be tapped through between
/// sets, and neither matched the setter every other duration in the app is
/// edited with. There is now one duration-editing gesture in the product.
///
/// **Storage is unchanged.** The binding is still the same total-seconds
/// *string* the row has always held (`inputsByExerciseID`, `ParentDraftStore`,
/// and `DurationLimits.parseSeconds` are untouched), so Save & Exit, Resume,
/// the planned-duration fallback, the 6h clamp, and the `d > 0` log gate all
/// behave exactly as before. This view only bridges that string to the picker's
/// optional `Int`.
///
/// The row's Start / Log buttons are passed in as `trailing` rather than being
/// laid out by the caller, so this view can own the expansion: the buttons stay
/// on the chip's line and keep their exact position and tap targets, and the
/// wheels open *below* them instead of displacing them.
struct ActiveDurationSetter<Trailing: View>: View {

    /// Total seconds, as digits. Empty means "not entered" — the row falls back
    /// to the planned duration, exactly as it always has.
    @Binding var secondsText: String

    /// Mirrors the rest of the row: a logged set is read-only until Undo, so
    /// the chip renders as a plain value and cannot be expanded.
    var isDisabled: Bool = false

    /// The row's action buttons (Start / Log, or Undo).
    @ViewBuilder var trailing: Trailing

    @State private var isExpanded = false

    /// The picker's contract is optional `Int` seconds; the row's is a digit
    /// string. `parseSeconds` is the same resolution the row's buttons use, so
    /// the chip can never show a value the Log button would not act on, and
    /// clearing the picker writes back "" — the row's established cleared
    /// state, which falls back to the planned duration.
    private var seconds: Binding<Int?> {
        Binding(
            get: {
                DurationLimits.parseSeconds(
                    secondsText, max: DurationLimits.maxExerciseSeconds)
            },
            set: { secondsText = DurationLimits.secondsText($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: 12) {
                chip
                Spacer(minLength: 8)
                trailing
            }
            .frame(minWidth: 80)

            // Collapsing on log rather than merely disabling: an open picker
            // under a finished set is dead weight in a list the user is
            // scrolling through.
            if isExpanded, !isDisabled {
                DurationWheelPicker(
                    seconds: seconds,
                    maxSeconds: DurationLimits.maxExerciseSeconds,
                    zeroLabel: "—",
                    presets: DurationPresets.exerciseDuration,
                    accessibilityTitle: "Duration")
            }
        }
        .onChange(of: isDisabled) { _, nowDisabled in
            if nowDisabled { isExpanded = false }
        }
    }

    // MARK: - Collapsed chip

    /// Shows what would be logged ("45m", "1h 23m 20s", or "—" when cleared).
    /// Tapping it opens the setter — the same disclosure gesture as the Details
    /// section below it, animation-free for the same reason: an animated
    /// expansion inside a List row slides the whole row, including the Log
    /// button the user is aiming at.
    @ViewBuilder
    private var chip: some View {
        if isDisabled {
            chipLabel
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Duration"))
                .accessibilityValue(valueText)
        } else {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isExpanded.toggle() }
            } label: {
                chipLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Duration"))
            .accessibilityValue(valueText)
        }
    }

    private var chipLabel: some View {
        HStack(spacing: DSSpacing.xs) {
            valueText
                .font(.dsBody.monospacedDigit())
            if !isDisabled {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .contentShape(Rectangle())
    }

    private var valueText: Text {
        guard let value = seconds.wrappedValue else { return Text(verbatim: "—") }
        return Text(DurationFormat.compact(value))
    }
}

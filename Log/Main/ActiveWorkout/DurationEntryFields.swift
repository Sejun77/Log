import SwiftUI

// ======================================================
// MARK: - Active-workout h / min / s duration entry
// ======================================================

/// The duration control on an active-workout set row: three narrow numeric
/// fields reading `[ 1 ] h  [ 23 ] min  [ 20 ] s`.
///
/// It replaces a single raw-seconds field that required typing "5000" and then
/// reading a formatted echo beside it to check the typo — a preview that also
/// wrapped on narrow rows once the value passed an hour.
///
/// **Storage is unchanged.** The binding is still the same total-seconds
/// *string* the row has always held (`inputsByExerciseID`, `ParentDraftStore`,
/// and `DurationLimits.parseSeconds` are all untouched), so Save & Exit,
/// Resume, the planned-duration fallback, the 6h clamp, and the `d > 0` log
/// gate all behave exactly as before. This view only splits that string across
/// three fields and reassembles it, via the pure `DurationFieldParts` helpers.
///
/// Shared by cardio sets and timed holds (both render through
/// `TimeSetEntryRow`), so the two can never diverge. It is deliberately *not*
/// used for rest, routine prescriptions, or warm-up steps: those edit an
/// optional `Int` through `DurationFieldRow`'s presets + wheels and are out of
/// scope here.
struct DurationEntryFields: View {

    /// Total seconds, as digits. Empty means "not entered" — the caller falls
    /// back to the planned duration, exactly as with the old single field.
    @Binding var secondsText: String

    /// Mirrors the rest of the row: a logged set is read-only until Undo.
    var isDisabled: Bool = false

    @FocusState private var focused: Part?
    private enum Part { case hours, minutes, seconds }

    /// Field text is local state so a partially typed value ("1 h", nothing
    /// else yet) survives re-render without being normalized under the cursor.
    /// `secondsText` stays the source of truth: it is rewritten on every edit,
    /// and re-read whenever it changes underneath us (resume, Edit Plan, a
    /// unit/prefill reseed).
    @State private var parts: DurationFieldParts.Parts = .empty

    /// Sized for the two digits minutes and seconds can hold (hours needs one),
    /// with the fields kept equal so the group does not jitter as values
    /// change. The whole control, unit letters included, comes in under the
    /// 120pt field *plus* the formatted echo it replaces, which is what let the
    /// old row wrap beside Start and Log on a 375pt phone.
    private static let fieldWidth: CGFloat = 38

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            field(
                part: \.hours,
                focus: .hours,
                unit: "h",
                accessibility: "Hours")
            field(
                part: \.minutes,
                focus: .minutes,
                unit: "min",
                accessibility: "Minutes")
            field(
                part: \.seconds,
                focus: .seconds,
                unit: "s",
                accessibility: "Seconds")
        }
        .onAppear { syncFromBinding() }
        .onChange(of: secondsText) { _, _ in syncFromBinding() }
    }

    /// One numeric field plus its unit letter. The letters are `verbatim` for
    /// the same reason `DurationFormat`'s are: the app renders bare unit
    /// suffixes (`kg` / `lb` / `s`) untranslated in every language. The
    /// accessibility label carries the localized word instead, since "h" alone
    /// is not something VoiceOver can usefully read.
    private func field(
        part: WritableKeyPath<DurationFieldParts.Parts, String>,
        focus: Part,
        unit: String,
        accessibility: LocalizedStringKey
    ) -> some View {
        HStack(spacing: DSSpacing.xs) {
            TextField("0", text: binding(part))
                .font(.dsBody.monospacedDigit())
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.fieldWidth)
                .disabled(isDisabled)
                .focused($focused, equals: focus)
                .accessibilityLabel(Text(accessibility))
            Text(verbatim: unit)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    // MARK: - Binding plumbing

    /// Sanitizes to digits on the way in (a paste cannot smuggle letters or a
    /// sign past the number pad), then writes the recombined total back.
    private func binding(
        _ part: WritableKeyPath<DurationFieldParts.Parts, String>
    ) -> Binding<String> {
        Binding(
            get: { parts[keyPath: part] },
            set: { newValue in
                var updated = parts
                updated[keyPath: part] = DurationFieldParts.sanitize(newValue)
                parts = updated
                let text = DurationFieldParts.secondsText(from: updated)
                if text != secondsText { secondsText = text }
            }
        )
    }

    /// Re-derive the fields from the stored value — but only when the two
    /// actually disagree. Without that guard, our own write would bounce back
    /// through `onChange` and re-split the fields mid-typing, clearing a "0"
    /// the user had just entered.
    private func syncFromBinding() {
        guard DurationFieldParts.secondsText(from: parts) != secondsText else {
            return
        }
        parts = DurationFieldParts.parts(fromSecondsText: secondsText)
    }
}

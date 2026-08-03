import SwiftUI

// MARK: - Edit Session Plan Sheet

struct EditSessionPlanSheet: View {
    @Binding var plan: SessionPlan
    /// Immutable session-snapshot effort fields for this slot (nil when the
    /// slot had no prescription). Drives whether the Intensity section offers
    /// an editable single override or a read-only progression/none summary —
    /// never read from the live routine template.
    var snapshotEffort: WorkoutEffortTargetResolver.Fields? = nil
    /// Cardio Slice 4 patch: hides the Intensity section. RIR is "reps in
    /// reserve" and the app's effort control is a single combined RIR/RPE
    /// field, so there is nothing in that section a cardio bout can answer —
    /// tempo is already hidden for duration slots. The underlying
    /// `plan.rir` / `plan.rpe` values are left untouched, so a slot switched
    /// back to a strength exercise still has its targets. Defaults to false,
    /// so every existing construction site is unaffected.
    var isCardio: Bool = false
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    /// Effort mode of the session snapshot (`.none` when there's no snapshot).
    private var snapshotEffortMode: EffortMode {
        snapshotEffort.map { WorkoutEffortTargetResolver.effortMode(for: $0) }
            ?? .none
    }

    var body: some View {
        NavigationStack {
            Form {
                // Duration/rest use `DurationFieldRow` (preset strip + h/m/s
                // wheels) to match the routine prescription editor; the 6h /
                // 60m bounds are far past what a fixed-step stepper can reach.
                if plan.usesDuration {
                    Section("Duration") {
                        durationRow("Min", keyPath: \.durationMinSeconds)
                        durationRow("Max", keyPath: \.durationMaxSeconds)
                    }
                } else {
                    Section("Reps") {
                        intStepperRow("Min", keyPath: \.repMin, range: 0...50)
                        intStepperRow("Max", keyPath: \.repMax, range: 0...50)
                    }
                }

                Section("Sets & Rest") {
                    intStepperRow("Sets", keyPath: \.sets, range: 0...20)
                    restRow("Rest between sets", keyPath: \.restSecondsBetweenSets)
                    restRow("Rest after exercise", keyPath: \.restSecondsAfterExercise)
                }

                // Cardio has neither an effort control nor a tempo, so the
                // whole section is omitted rather than left as an empty header.
                if !isCardio {
                    Section("Intensity") {
                        effortContent
                        // Tempo describes rep phases, so it is neither shown
                        // nor editable for a duration-based slot. Effort
                        // (RIR/RPE) stays for strength and timed holds — it
                        // applies to both of those tracking types.
                        if !plan.usesDuration {
                            TempoEditorView(tempo: $plan.tempo)
                        }
                    }
                }

                Section("Notes") {
                    TextField(
                        "Slot notes", text: optionalString(\.slotNotes),
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The Notes field is multiline (axis: .vertical) — Return inserts
                // a newline, so a keyboard-integrated dismiss is needed. The
                // top-bar Close stays: it dismisses the whole sheet, not the
                // keyboard.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    KeyboardDismissButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Effort (mode-aware)

    /// Intensity controls gated on the app autoreg metric AND the snapshot's
    /// effort mode:
    ///  - autoreg `.none` → nothing.
    ///  - Single → editable single RIR/RPE override (v1 in-session behavior).
    ///  - Progression → read-only resolved summary (`"RPE 8 → 10"`) + note;
    ///    no fake single stepper. In-session progression editing is deferred.
    ///  - None → read-only "None" (no stale single stepper).
    @ViewBuilder
    private var effortContent: some View {
        switch autoregMode {
        case .none:
            EmptyView()
        case .rir, .rpe:
            switch snapshotEffortMode {
            case .single:
                if autoregMode == .rir {
                    doubleStepperRow("RIR", active: $plan.rir, paired: $plan.rpe,
                                     range: 0...5, step: 0.5) { 10 - $0 }
                } else {
                    doubleStepperRow("RPE", active: $plan.rpe, paired: $plan.rir,
                                     range: 5...10, step: 0.5) { 10 - $0 }
                }
            case .progression:
                effortReadOnlyRow(snapshotSummary ?? "—")
                Text("Progression editing during workout is not available yet.")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            case .none:
                effortReadOnlyRow("None")
            }
        }
    }

    /// Snapshot effort summary in the current autoreg metric (paired fallback).
    private var snapshotSummary: String? {
        snapshotEffort.flatMap {
            WorkoutEffortTargetResolver.summary(fields: $0, autoregMode: autoregMode)
        }
    }

    private func effortReadOnlyRow(_ value: String) -> some View {
        HStack {
            Text("Effort")
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    // MARK: - Field Rows

    /// Exercise-duration field (6h bound), normalized by the row.
    private func durationRow(
        _ label: String, keyPath: WritableKeyPath<SessionPlan, Int?>
    ) -> some View {
        DurationFieldRow(
            title: label,
            seconds: secondsBinding(keyPath),
            maxSeconds: DurationLimits.maxExerciseSeconds,
            presets: DurationPresets.exerciseDuration
        )
    }

    /// Rest field (60m bound). `zeroLabel` keeps the stepper's "no rest"
    /// wording for an unset value.
    private func restRow(
        _ label: String, keyPath: WritableKeyPath<SessionPlan, Int?>
    ) -> some View {
        DurationFieldRow(
            title: label,
            seconds: secondsBinding(keyPath),
            maxSeconds: DurationLimits.maxRestSeconds,
            zeroLabel: "None",
            presets: DurationPresets.rest
        )
    }

    private func secondsBinding(_ keyPath: WritableKeyPath<SessionPlan, Int?>)
        -> Binding<Int?>
    {
        Binding(
            get: { plan[keyPath: keyPath] },
            set: { plan[keyPath: keyPath] = $0 }
        )
    }

    /// Stepper for a bounded optional-Int field on SessionPlan.
    /// 0 maps to nil (unset); stepping up from 0 begins at `range.lowerBound` + `step`.
    private func intStepperRow(
        _ label: String,
        keyPath: WritableKeyPath<SessionPlan, Int?>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String? = nil,
        zeroLabel: String = "—"
    ) -> some View {
        let current = plan[keyPath: keyPath] ?? 0
        let valStr = current == 0 ? zeroLabel : (unit.map { "\(current)\($0)" } ?? "\(current)")
        let title = NSLocalizedString(label, comment: "")
        return Stepper(
            "\(title): \(valStr)",
            value: Binding(
                get: { plan[keyPath: keyPath] ?? 0 },
                set: { plan[keyPath: keyPath] = $0 == 0 ? nil : $0 }
            ),
            in: range,
            step: step
        )
    }

    /// Stepper for an optional-Double intensity field that keeps its paired counterpart in sync.
    /// On write: stores the active value and updates `paired` via `convert` (or nil if clearing).
    /// On display: shows `active` if stored; otherwise derives from `paired` via `convert`.
    private func doubleStepperRow(
        _ label: String,
        active: Binding<Double?>,
        paired: Binding<Double?>,
        range: ClosedRange<Double>,
        step: Double,
        convert: @escaping (Double) -> Double
    ) -> some View {
        let sentinel = range.lowerBound - step
        let displayValue = active.wrappedValue ?? paired.wrappedValue.map(convert)
        let formatted: (Double) -> String = { v in
            v.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(v)) : String(format: "%.1f", v)
        }
        return Stepper(
            "\(label): \(displayValue.map(formatted) ?? "—")",
            value: Binding(
                get: {
                    if let v = active.wrappedValue { return v }
                    if let pv = paired.wrappedValue { return convert(pv) }
                    return sentinel
                },
                set: { newVal in
                    let stored: Double? = newVal < range.lowerBound ? nil : newVal
                    active.wrappedValue = stored
                    paired.wrappedValue = stored.map(convert)
                }
            ),
            in: sentinel...range.upperBound,
            step: step
        )
    }

    // MARK: - Binding Helpers

    private func optionalString(_ kp: WritableKeyPath<SessionPlan, String?>)
        -> Binding<String>
    {
        Binding(
            get: { plan[keyPath: kp] ?? "" },
            set: { plan[keyPath: kp] = $0.isEmpty ? nil : $0 }
        )
    }
}

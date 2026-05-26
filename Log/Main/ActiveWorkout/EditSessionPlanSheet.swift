import SwiftUI

// MARK: - Edit Session Plan Sheet

struct EditSessionPlanSheet: View {
    @Binding var plan: SessionPlan
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    var body: some View {
        NavigationStack {
            Form {
                if plan.usesDuration {
                    Section("Duration") {
                        intStepperRow("Min", keyPath: \.durationMinSeconds, range: 0...600, step: 15, unit: "s")
                        intStepperRow("Max", keyPath: \.durationMaxSeconds, range: 0...600, step: 15, unit: "s")
                    }
                } else {
                    Section("Reps") {
                        intStepperRow("Min", keyPath: \.repMin, range: 0...50)
                        intStepperRow("Max", keyPath: \.repMax, range: 0...50)
                    }
                }

                Section("Sets & Rest") {
                    intStepperRow("Sets", keyPath: \.sets, range: 0...20)
                    intStepperRow("Rest between sets", keyPath: \.restSecondsBetweenSets, range: 0...600, step: 15, unit: "s", zeroLabel: "none")
                    intStepperRow("Rest after exercise", keyPath: \.restSecondsAfterExercise, range: 0...600, step: 15, unit: "s", zeroLabel: "none")
                }

                Section("Intensity") {
                    switch autoregMode {
                    case .rir:
                        doubleStepperRow("RIR", active: $plan.rir, paired: $plan.rpe,
                                         range: 0...5, step: 0.5) { 10 - $0 }
                    case .rpe:
                        doubleStepperRow("RPE", active: $plan.rpe, paired: $plan.rir,
                                         range: 5...10, step: 0.5) { 10 - $0 }
                    case .none:
                        EmptyView()
                    }
                    TempoEditorView(tempo: $plan.tempo)
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

    // MARK: - Field Rows

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
        return Stepper(
            "\(label): \(valStr)",
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

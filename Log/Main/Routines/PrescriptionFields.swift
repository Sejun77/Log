import SwiftData
import SwiftUI

// MARK: - Default Prescription Factory

@discardableResult
func makeDefaultPrescription(
    isTimeBased: Bool,
    in ctx: ModelContext
) -> SlotPrescription {
    let p = SlotPrescription()
    p.usesDuration = isTimeBased
    p.sets = AppSettings.defaultSets
    if !isTimeBased {
        p.repMin = AppSettings.defaultRepMin
        p.repMax = AppSettings.defaultRepMax
    }
    p.restSecondsBetweenSets = AppSettings.defaultRestBetweenSets
    if AppSettings.defaultRestAfterExercise > 0 {
        p.restSecondsAfterExercise = AppSettings.defaultRestAfterExercise
    }
    switch AppSettings.autoregMode {
    case .rir: p.rir = AppSettings.defaultRIR
    case .rpe: p.rpe = AppSettings.defaultRPE
    case .none: break
    }
    ctx.insert(p)
    return p
}

// MARK: - Prescription Editor (Phase 3.5)

struct SlotPrescriptionSection: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var re: RoutineExercise
    let isTimeBased: Bool
    var hideRestFields: Bool = false
    var hideSetsField: Bool = false
    /// Phase 5.2 — when true (routine is in use by an active workout),
    /// the Section's content is non-interactive but still visible /
    /// scrollable. Applied to the Section itself so the parent List's
    /// scroll gesture stays intact.
    var isLocked: Bool = false

    /// Drives the gated keyboard checkmark for the multiline slot-notes field.
    /// Each rendered section has its own focus state, so when several sections
    /// share one detail screen only the focused one shows the accessory.
    @FocusState private var slotNotesFocused: Bool

    var body: some View {
        Section {
            if !re.setTemplates.isEmpty {
                Label(
                    "Custom set templates override prescription.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let prescription = re.prescription {
                PrescriptionFields(
                    prescription: prescription,
                    isTimeBased: isTimeBased,
                    hideRestFields: hideRestFields,
                    hideSetsField: hideSetsField
                )

                // Phase 3.5: Warmup scheme navigation
                NavigationLink {
                    WarmupSchemeEditor(prescription: prescription)
                } label: {
                    HStack {
                        Text("Warmup")
                        Spacer()
                        let count = prescription.warmupScheme?.steps.count ?? 0
                        if count > 0 {
                            Text("\(count) step\(count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Phase 3.5: Technique plans navigation
                NavigationLink {
                    TechniquePlanEditor(prescription: prescription)
                } label: {
                    HStack {
                        Text("Techniques")
                        Spacer()
                        let count = prescription.techniquePlans.count
                        if count > 0 {
                            Text("\(count) technique\(count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            TextField("Slot notes", text: slotNotesBinding, axis: .vertical)
                .lineLimit(1...4)
                .focused($slotNotesFocused)
                .toolbar {
                    // Slot notes is multiline (axis: .vertical) — Return inserts
                    // a newline, so it needs a keyboard-integrated dismiss. Gated
                    // on this field's own focus so it never shows a redundant
                    // accessory for the rest of the prescription editor (all
                    // Steppers) or for sibling slot sections on the same screen.
                    ToolbarItemGroup(placement: .keyboard) {
                        if slotNotesFocused {
                            Spacer()
                            KeyboardDismissButton()
                        }
                    }
                }
        } header: {
            Text("Prescription")
        }
        // Section-level disable: cascades to PrescriptionFields,
        // Warmup / Techniques navigation links, and the slot-notes
        // TextField, leaving the parent List's scroll behavior alone.
        .disabled(isLocked)
        .onAppear(perform: ensurePrescription)
    }

    private var slotNotesBinding: Binding<String> {
        Binding(
            get: { re.templateNotes ?? "" },
            set: { re.templateNotes = $0.isEmpty ? nil : $0 }
        )
    }

    private func ensurePrescription() {
        if re.prescription == nil {
            re.prescription = makeDefaultPrescription(isTimeBased: isTimeBased, in: ctx)
            try? ctx.save()
        } else if let p = re.prescription, p.usesDuration != isTimeBased {
            p.usesDuration = isTimeBased
        }
    }
}

private struct PrescriptionFields: View {
    @Bindable var prescription: SlotPrescription
    let isTimeBased: Bool
    var hideRestFields: Bool = false
    var hideSetsField: Bool = false

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    var body: some View {
        if !hideSetsField {
            optionalIntStepper("Sets", keyPath: \.sets, range: 0...20)
        }

        if isTimeBased {
            optionalIntStepper("Duration min", keyPath: \.durationMinSeconds, range: 0...600, step: 15, unit: "s")
            optionalIntStepper("Duration max", keyPath: \.durationMaxSeconds, range: 0...600, step: 15, unit: "s")
        } else {
            optionalIntStepper("Rep min", keyPath: \.repMin, range: 0...50)
            optionalIntStepper("Rep max", keyPath: \.repMax, range: 0...50)
        }

        if !hideRestFields {
            optionalIntStepper("Rest between sets", keyPath: \.restSecondsBetweenSets, range: 0...600, step: 15, unit: "s", zeroLabel: "none")
            optionalIntStepper("Rest after exercise", keyPath: \.restSecondsAfterExercise, range: 0...600, step: 15, unit: "s", zeroLabel: "none")
        }

        switch autoregMode {
        case .rir:
            doubleStepperRow("RIR", active: $prescription.rir, paired: $prescription.rpe,
                             range: 0...5, step: 0.5) { 10 - $0 }
        case .rpe:
            doubleStepperRow("RPE", active: $prescription.rpe, paired: $prescription.rir,
                             range: 5...10, step: 0.5) { 10 - $0 }
        case .none:
            EmptyView()
        }

        TempoEditorView(tempo: $prescription.tempo)
    }

    private func optionalIntStepper(
        _ label: String,
        keyPath: ReferenceWritableKeyPath<SlotPrescription, Int?>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String? = nil,
        zeroLabel: String = "—"
    ) -> some View {
        let current = prescription[keyPath: keyPath] ?? 0
        let valStr = current == 0 ? zeroLabel : (unit.map { "\(current)\($0)" } ?? "\(current)")
        return Stepper(
            "\(label): \(valStr)",
            value: Binding(
                get: { prescription[keyPath: keyPath] ?? 0 },
                set: { prescription[keyPath: keyPath] = $0 == 0 ? nil : $0 }
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
}

// MARK: - Tempo Editor

struct TempoEditorView: View {
    @Binding var tempo: String?

    @State private var eccentric: Int = 0
    @State private var stretchPause: Int = 0
    @State private var concentric: Int = 0
    @State private var squeezePause: Int = 0

    var body: some View {
        Stepper("Eccentric: \(label(eccentric))", value: $eccentric, in: 0...10)
            .onAppear { parseTempo() }
            .onChange(of: eccentric) { serializeTempo() }
        Stepper("Stretch pause: \(label(stretchPause))", value: $stretchPause, in: 0...10)
            .onChange(of: stretchPause) { serializeTempo() }
        Stepper("Concentric: \(label(concentric))", value: $concentric, in: 0...10)
            .onChange(of: concentric) { serializeTempo() }
        Stepper("Squeeze pause: \(label(squeezePause))", value: $squeezePause, in: 0...10)
            .onChange(of: squeezePause) { serializeTempo() }
        Text("Tempo = eccentric – stretch pause – concentric – squeeze pause")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func label(_ v: Int) -> String { v == 0 ? "—" : "\(v)s" }

    private func parseTempo() {
        guard let t = tempo, !t.isEmpty else {
            eccentric = 0; stretchPause = 0; concentric = 0; squeezePause = 0
            return
        }
        let parts = t.split(separator: "-").compactMap { Int($0) }
        eccentric    = parts.count > 0 ? parts[0] : 0
        stretchPause = parts.count > 1 ? parts[1] : 0
        concentric   = parts.count > 2 ? parts[2] : 0
        squeezePause = parts.count > 3 ? parts[3] : 0
    }

    private func serializeTempo() {
        let vals = [eccentric, stretchPause, concentric, squeezePause]
        tempo = vals.allSatisfy({ $0 == 0 }) ? nil
              : vals.map(String.init).joined(separator: "-")
    }
}

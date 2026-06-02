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

        effortSection

        TempoEditorView(tempo: $prescription.tempo)
    }

    // MARK: - Effort target mode (Slice D)

    /// Effort controls, gated on the app-wide autoreg metric. `.none` shows
    /// nothing; `.rir`/`.rpe` show a mode picker (None / Single / Progression)
    /// plus the matching value steppers. Single stores into `rir`/`rpe`;
    /// Progression stores into `rir(Start|End)` / `rpe(Start|End)`. Both keep
    /// the opposite metric mirrored via `10 - x`, matching the prior behavior.
    @ViewBuilder
    private var effortSection: some View {
        switch autoregMode {
        case .rir:
            effortControls(
                label: "RIR", metric: .rir, paths: Self.rirPaths,
                range: 0...5, defaultValue: AppSettings.defaultRIR)
        case .rpe:
            effortControls(
                label: "RPE", metric: .rpe, paths: Self.rpePaths,
                range: 5...10, defaultValue: AppSettings.defaultRPE)
        case .none:
            EmptyView()
        }
    }

    /// Active/paired key paths for one metric. The "paired" set is the opposite
    /// metric, kept mirrored (`10 - x`) so switching the app autoreg mode later
    /// surfaces a sensible converted value — exactly as the single stepper did.
    private struct EffortKeyPaths {
        let single, start, end: ReferenceWritableKeyPath<SlotPrescription, Double?>
        let pairedSingle, pairedStart, pairedEnd:
            ReferenceWritableKeyPath<SlotPrescription, Double?>
    }

    private static let rirPaths = EffortKeyPaths(
        single: \.rir, start: \.rirStart, end: \.rirEnd,
        pairedSingle: \.rpe, pairedStart: \.rpeStart, pairedEnd: \.rpeEnd)
    private static let rpePaths = EffortKeyPaths(
        single: \.rpe, start: \.rpeStart, end: \.rpeEnd,
        pairedSingle: \.rir, pairedStart: \.rirStart, pairedEnd: \.rirEnd)

    @ViewBuilder
    private func effortControls(
        label: String, metric: EffortMetric, paths: EffortKeyPaths,
        range: ClosedRange<Double>, defaultValue: Double
    ) -> some View {
        Picker(
            "Effort",
            selection: Binding(
                get: { prescription.effortMode },
                set: {
                    applyEffortMode($0, paths: paths, defaultValue: defaultValue)
                }
            )
        ) {
            Text("None").tag(EffortMode.none)
            Text("Single").tag(EffortMode.single)
            Text("Progression").tag(EffortMode.progression)
        }

        switch prescription.effortMode {
        case .none:
            EmptyView()
        case .single:
            doubleStepperRow(
                label, active: doubleBinding(paths.single),
                paired: doubleBinding(paths.pairedSingle),
                range: range, step: 0.5) { 10 - $0 }
        case .progression:
            doubleStepperRow(
                "Start \(label)", active: doubleBinding(paths.start),
                paired: doubleBinding(paths.pairedStart),
                range: range, step: 0.5) { 10 - $0 }
            doubleStepperRow(
                "End \(label)", active: doubleBinding(paths.end),
                paired: doubleBinding(paths.pairedEnd),
                range: range, step: 0.5) { 10 - $0 }
            effortPreview(paths: paths)
        }
    }

    /// Live "Set targets: 2 · 1 · 0" preview from the resolver. Hidden when
    /// there are no usable targets (no sets / missing endpoints).
    @ViewBuilder
    private func effortPreview(paths: EffortKeyPaths) -> some View {
        let values = EffortTargetResolver.resolve(
            mode: .progression, single: nil,
            start: prescription[keyPath: paths.start],
            end: prescription[keyPath: paths.end],
            setCount: max(0, prescription.sets ?? 0))
        if !values.isEmpty {
            Text(
                "Set targets: "
                    + values.map(EffortTargetResolver.format)
                        .joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func doubleBinding(
        _ kp: ReferenceWritableKeyPath<SlotPrescription, Double?>
    ) -> Binding<Double?> {
        Binding(
            get: { prescription[keyPath: kp] },
            set: { prescription[keyPath: kp] = $0 }
        )
    }

    /// Apply a mode change with non-destructive seeding:
    ///  - → None: keep stored values; the mode flag suppresses display.
    ///  - → Single: if the single value is nil, seed from the start value
    ///    (Progression → Single) else the AppSettings default.
    ///  - → Progression: seed nil start/end from the current single value
    ///    (or the default), so a fresh ramp starts flat at the single target.
    /// The opposite metric is mirrored (`10 - x`) on every seed.
    private func applyEffortMode(
        _ newMode: EffortMode, paths: EffortKeyPaths, defaultValue: Double
    ) {
        let convert: (Double) -> Double = { 10 - $0 }
        switch newMode {
        case .none:
            break
        case .single:
            if prescription[keyPath: paths.single] == nil {
                let seed = prescription[keyPath: paths.start] ?? defaultValue
                prescription[keyPath: paths.single] = seed
                prescription[keyPath: paths.pairedSingle] = convert(seed)
            }
        case .progression:
            let base = prescription[keyPath: paths.single] ?? defaultValue
            if prescription[keyPath: paths.start] == nil {
                prescription[keyPath: paths.start] = base
                prescription[keyPath: paths.pairedStart] = convert(base)
            }
            if prescription[keyPath: paths.end] == nil {
                prescription[keyPath: paths.end] = base
                prescription[keyPath: paths.pairedEnd] = convert(base)
            }
        }
        prescription.effortModeRaw = newMode.rawValue
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

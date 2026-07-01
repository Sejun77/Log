import SwiftUI

// MARK: - UI for a single set entry

struct SetEntryRow: View {
    @FocusState private var focusedField: Field?
    private enum Field { case reps, weight }

    let index: Int
    let template: PlanSetTemplate
    let isLogged: Bool
    let canLog: Bool
    /// Resolved per-set effort target label (e.g. "RIR 2"); nil = none shown.
    var effortTarget: String?
    /// When true the exercise is bodyweight: the weight field, "×" separator,
    /// and kg/lb label are hidden and logged sets save a nil weight.
    var isBodyweight: Bool = false
    @Binding var reps: String
    @Binding var weight: String
    var onLog: (Int, Double?) -> Void
    var onUndo: () -> Void

    init(
        index: Int,
        template: PlanSetTemplate,
        isLogged: Bool,
        canLog: Bool,
        effortTarget: String? = nil,
        isBodyweight: Bool = false,
        reps: Binding<String>,
        weight: Binding<String>,
        onLog: @escaping (Int, Double?) -> Void,
        onUndo: @escaping () -> Void
    ) {
        self.index = index
        self.template = template
        self.isLogged = isLogged
        self.canLog = canLog
        self.effortTarget = effortTarget
        self.isBodyweight = isBodyweight
        self._reps = reps
        self._weight = weight
        self.onLog = onLog
        self.onUndo = onUndo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(index)")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                if let kindLabel = template.kind.activeRowLabel {
                    Text(kindLabel)
                        .font(.dsBody.weight(.semibold))
                }
                if isLogged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(
                        .green
                    )
                }
                Spacer()
                if let effortTarget {
                    Text(effortTarget)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                TextField("Reps", text: $reps)
                    .font(.dsBody.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .disabled(isLogged)
                    .focused($focusedField, equals: .reps)

                // Bodyweight exercises log reps only — hide the "×" separator,
                // weight field, and unit label.
                if !isBodyweight {
                    Text("×").foregroundStyle(.secondary).fixedSize()

                    // "0.0" placeholder signals decimal entry (the .decimalPad's
                    // "." key is easy to miss). It's the stable discoverability cue
                    // for working-set weight — a section footer caption was tried
                    // but jumped with the keyboard on first focus, so it was dropped.
                    TextField("0.0", text: $weight)
                        .font(.dsBody.monospacedDigit())
                        // Weight supports fractional plates (e.g. 2.5 kg) — decimal
                        // pad. Reps above stays `.numberPad` (integer-only).
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .disabled(isLogged)
                        .focused($focusedField, equals: .weight)

                    Text(Units.weightIsKg ? "kg" : "lb")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Spacer(minLength: 8)

                if isLogged {
                    Button("Undo") { onUndo() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Log") {
                        let r = Int(reps) ?? template.targetReps
                        let w = isBodyweight ? nil : Double(weight)
                        onLog(r, w)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(DSColor.textInverse)
                    .disabled(!canLog)
                }
            }
            .frame(minWidth: 80)
        }
    }
}

// MARK: - UI for a single time-based set entry

struct TimeSetEntryRow: View {
    @FocusState private var focused: Field?
    private enum Field { case duration }

    let index: Int
    let template: PlanSetTemplate
    let isLogged: Bool
    let canLog: Bool
    /// Resolved per-set effort target label (e.g. "RIR 2"); nil = none shown.
    var effortTarget: String? = nil
    @Binding var duration: String
    var onStart: (Int) -> Void
    var onLog: (Int) -> Void
    var onUndo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(index)")
                    .font(.dsCaption)
                if let kindLabel = template.kind.activeRowLabel {
                    Text(kindLabel)
                        .font(.dsBody.weight(.semibold))
                }
                if isLogged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(
                        .green
                    )
                }
                Spacer()
                if let effortTarget {
                    Text(effortTarget)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                TextField("Duration (s)", text: $duration)
                    .font(.dsBody.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .disabled(isLogged)
                    .focused($focused, equals: .duration)

                Spacer(minLength: 8)

                if isLogged {
                    Button("Undo") { onUndo() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Start") {
                        let d = Int(duration) ?? (template.durationSeconds ?? 0)
                        guard d > 0 else { return }
                        onStart(d)  // just runs the set timer/overlay
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canLog)

                    Button("Log") {
                        let d = Int(duration) ?? (template.durationSeconds ?? 0)
                        guard d > 0 else { return }
                        onLog(d)  // persist + trigger rest
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(DSColor.textInverse)
                    .disabled(!canLog)
                }
            }
            .frame(minWidth: 80)
        }
    }
}

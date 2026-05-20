import SwiftUI

// MARK: - UI for a single set entry

struct SetEntryRow: View {
    @FocusState private var focusedField: Field?
    private enum Field { case reps, weight }

    let index: Int
    let template: PlanSetTemplate
    let isLogged: Bool
    let canLog: Bool
    @Binding var reps: String
    @Binding var weight: String
    var onLog: (Int, Int?) -> Void
    var onUndo: () -> Void

    init(
        index: Int,
        template: PlanSetTemplate,
        isLogged: Bool,
        canLog: Bool,
        reps: Binding<String>,
        weight: Binding<String>,
        onLog: @escaping (Int, Int?) -> Void,
        onUndo: @escaping () -> Void
    ) {
        self.index = index
        self.template = template
        self.isLogged = isLogged
        self.canLog = canLog
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
                Text(template.kind.rawValue.capitalized)
                    .font(.dsBody.weight(.semibold))
                if isLogged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(
                        .green
                    )
                }
                Spacer()
            }

            HStack(spacing: 12) {
                TextField("Reps", text: $reps)
                    .font(.dsBody.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .disabled(isLogged)
                    .focused($focusedField, equals: .reps)

                Text("×").foregroundStyle(.secondary).fixedSize()

                TextField("Wt", text: $weight)
                    .font(.dsBody.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .disabled(isLogged)
                    .focused($focusedField, equals: .weight)

                Text(Units.weightIsKg ? "kg" : "lb")
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Spacer(minLength: 8)

                if isLogged {
                    Button("Undo") { onUndo() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Log") {
                        let r = Int(reps) ?? template.targetReps
                        let w = Int(weight)
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
    @Binding var duration: String
    var onStart: (Int) -> Void
    var onLog: (Int) -> Void
    var onUndo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(index)")
                    .font(.dsCaption)
                Text(template.kind.rawValue.capitalized)
                    .font(.dsBody.weight(.semibold))
                if isLogged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(
                        .green
                    )
                }
                Spacer()
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

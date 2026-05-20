import SwiftUI

// MARK: - Drop sub-row (shown under a working set when a Dropset technique applies)

struct DropLogRow: View {
    @FocusState private var focused: Field?
    private enum Field { case reps, weight }

    let dropNumber: Int
    let isLogged: Bool
    let canLog: Bool
    @Binding var reps: String
    @Binding var weight: String
    var onLog: (Int, Double?) -> Void
    var onUndo: () -> Void
    /// Non-nil when the weight was manually overridden and a suggestion can be computed.
    /// Tapping resets the field to the auto-suggested value.
    var onResetWeight: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                Text("Drop \(dropNumber)")
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isLogged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
                    .focused($focused, equals: .reps)

                Text("×").foregroundStyle(.secondary).fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Wt", text: $weight)
                        .font(.dsBody.monospacedDigit())
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .disabled(isLogged)
                        .focused($focused, equals: .weight)
                    if let reset = onResetWeight {
                        Button("↩ suggest") { reset() }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                    }
                }

                Text(Units.weightIsKg ? "kg" : "lb")
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Spacer(minLength: 8)

                if isLogged {
                    Button("Undo") { onUndo() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Log Drop") {
                        let r = Int(reps) ?? 0
                        let w = Double(weight)
                        onLog(r, w)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(DSColor.textInverse)
                    .disabled(!canLog)
                }
            }
            .frame(minWidth: 80)
        }
        .padding(.leading, 20)
    }
}

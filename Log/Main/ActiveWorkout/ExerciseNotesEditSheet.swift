import SwiftData
import SwiftUI

// MARK: - Exercise Notes Edit Sheet (active workout)

/// Focused editor for the global Exercise.notes field, presented from the read-only
/// "Exercise Notes" section in the active workout. Writes through to the live
/// Exercise (@Bindable). Save is triggered on "Done"; cancel discards in-flight
/// edits by reverting the @Bindable surface to its original value before dismiss.
/// This sheet is the only place in the active workout where Exercise.notes can be
/// edited — the in-list display below Session Notes stays read-only.
struct ExerciseNotesEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Bindable var exercise: Exercise

    @State private var originalNotes: String?
    @State private var didCapture = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Notes…",
                        text: Binding(
                            get: { exercise.notes ?? "" },
                            set: { newVal in
                                let trimmed = newVal.trimmingCharacters(
                                    in: .whitespacesAndNewlines)
                                exercise.notes = trimmed.isEmpty ? nil : newVal
                            }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                    .textInputAutocapitalization(.sentences)
                } header: {
                    Text("Exercise Notes")
                } footer: {
                    Text("These notes are saved to the exercise and reused across routines and workouts.")
                }
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        exercise.notes = originalNotes
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? ctx.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !didCapture {
                    originalNotes = exercise.notes
                    didCapture = true
                }
            }
        }
    }
}

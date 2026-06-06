import SwiftData
import SwiftUI

// MARK: - Exercise Notes Edit Sheet (active workout)

/// Focused editor for the global Exercise.notes field, presented from the read-only
/// "Exercise Notes" section in the active workout. Edits a local `draft` @State so
/// typing never writes to SwiftData per keystroke (which would invalidate the
/// large parent `ActiveWorkoutView` body that reads the same live `Exercise.notes`).
/// "Done" commits the normalized draft to `Exercise.notes` and saves; "Cancel"
/// simply dismisses, leaving the model untouched. This sheet is the only place in
/// the active workout where Exercise.notes can be edited — the in-list display
/// below Session Notes stays read-only.
struct ExerciseNotesEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Bindable var exercise: Exercise

    @State private var draft: String = ""
    @State private var didSeed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notes…", text: $draft, axis: .vertical)
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
                        // Draft is local; nothing was written to the model.
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let normalized = normalizedOptionalNote(draft)
                        if exercise.notes != normalized {
                            exercise.notes = normalized
                        }
                        try? ctx.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !didSeed {
                    draft = exercise.notes ?? ""
                    didSeed = true
                }
            }
        }
    }
}

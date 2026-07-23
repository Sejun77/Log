import SwiftData
import SwiftUI

// MARK: - Setup Notes Edit Sheet (active workout)

/// Focused editor for the global Exercise.setupDefaults field, presented from
/// the "Equipment & Setup" section in the active workout. Mirrors
/// `ExerciseNotesEditSheet`: edits a local `draft` @State so typing never
/// writes to SwiftData per keystroke (which would invalidate the large parent
/// `ActiveWorkoutView` body that reads the same live `Exercise.setupDefaults`).
/// "Done" commits the normalized draft to `Exercise.setupDefaults` and saves;
/// "Cancel" simply dismisses, leaving the model untouched.
///
/// Done writes two layers:
///  * the exercise **definition** (`Exercise.setupDefaults`), so future
///    sessions snapshot the corrected value at their own start;
///  * via `onCommit`, the **current** session's snapshots
///    (`applyActiveSetupNotesEdit`), so this workout's finished History
///    records the setup notes actually used/corrected while training.
/// Cancel invokes neither. Past (finished) workouts are never touched —
/// their snapshot rows are frozen and no edit path reaches them.
struct SetupNotesEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Bindable var exercise: Exercise

    /// Called on Done with the normalized new value, after
    /// `Exercise.setupDefaults` was updated and before save/dismiss. The
    /// active workout propagates the edit into the current session's
    /// snapshots here. Never called on Cancel.
    var onCommit: ((String?) -> Void)? = nil

    @State private var draft: String = ""
    @State private var didSeed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Setup defaults — e.g. seat height 4, cable at shoulder",
                        text: $draft, axis: .vertical
                    )
                    .lineLimit(3...10)
                    .textInputAutocapitalization(.sentences)
                } header: {
                    // "Setup" (existing key) rather than "Setup Notes": a
                    // "Setup Notes" catalog key would generate the same
                    // Swift string symbol as the existing "Setup & Notes"
                    // key, which fails GenerateStringSymbols.
                    Text("Setup")
                } footer: {
                    Text("Setup notes are saved to the exercise and reused across routines and workouts.")
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
                        if exercise.setupDefaults != normalized {
                            exercise.setupDefaults = normalized
                        }
                        onCommit?(normalized)
                        try? ctx.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !didSeed {
                    draft = exercise.setupDefaults ?? ""
                    didSeed = true
                }
            }
        }
    }
}

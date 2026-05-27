import SwiftData
import SwiftUI

// MARK: - Exercise Picker (single)

struct ExercisePickerSingle: View {
    let exercises: [Exercise]
    var onPick: (Exercise?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [Exercise] {
        guard !search.isEmpty else { return exercises }
        return exercises.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { ex in
                Button(ex.name) {
                    onPick(ex)
                    dismiss()
                }
            }
            .searchable(text: $search, prompt: "Search")
            .navigationTitle("Pick Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onPick(nil)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Exercise Multi-Picker (ordered, duplicate-capable)

/// Multi-select exercise picker. Tapping a row appends the exercise to an
/// ordered selection (tap again to add a second instance); a "Selected"
/// summary shows the running list in order with swipe-to-remove. Confirm adds
/// the selection in tap order. Search filters only the visible library list and
/// never disturbs the selection. Shared by all routine-editor add surfaces
/// (Slice A: normal-block "Add Exercise"; Slice B: new-superset creation and
/// existing-superset "Add Exercise").
struct ExerciseMultiPicker: View {
    let exercises: [Exercise]
    let onConfirm: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection = ExerciseMultiSelection()

    private var byID: [UUID: Exercise] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var filtered: [Exercise] {
        let key = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return exercises }
        return exercises.filter {
            $0.name.localizedCaseInsensitiveContains(key)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !selection.isEmpty {
                    Section("Selected (\(selection.count))") {
                        ForEach(Array(selection.orderedIDs.enumerated()), id: \.offset) {
                            idx, id in
                            HStack {
                                Text("\(idx + 1).")
                                    .foregroundStyle(.secondary)
                                Text(byID[id]?.name ?? "—")
                            }
                        }
                        .onDelete { offsets in
                            selection.remove(atOffsets: offsets)
                        }
                    }
                }

                Section("Exercises") {
                    ForEach(filtered, id: \.id) { ex in
                        Button {
                            selection.append(ex.id)
                        } label: {
                            HStack {
                                Text(ex.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                let c = selection.count(of: ex.id)
                                if c > 0 {
                                    Text("×\(c)")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .navigationTitle("Add Exercises")
            .searchable(
                text: $search,
                placement: .navigationBarDrawer,
                prompt: "Search"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selection.count))") {
                        onConfirm(selection.resolved(using: byID))
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }
}

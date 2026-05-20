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

// MARK: - Superset Picker

struct SupersetPicker: View {
    let exercises: [Exercise]
    let onDone: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var picked = Set<UUID>()
    @State private var refSetCount: Int? = nil  // first pick establishes the count

    private var filtered: [Exercise] {
        let key = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return exercises }
        return exercises.filter {
            $0.name.localizedCaseInsensitiveContains(key)
        }
    }

    private func setCount(for ex: Exercise) -> Int {
        let n = ex.defaultTemplates.filter { $0.kind == .working }.count
        return n > 0 ? n : AppSettings.defaultSets
    }

    private func isCompatible(_ ex: Exercise) -> Bool {
        guard let ref = refSetCount else { return true }
        return setCount(for: ex) == ref
    }

    private func togglePick(_ ex: Exercise) {
        let id = ex.id
        if picked.contains(id) {
            picked.remove(id)
            if picked.isEmpty { refSetCount = nil }
        } else {
            if let ref = refSetCount {
                guard setCount(for: ex) == ref else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    return
                }
                picked.insert(id)
            } else {
                let c = setCount(for: ex)
                guard c > 0 else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    return
                }
                refSetCount = c
                picked.insert(id)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercises") {
                    ForEach(filtered, id: \.id) { ex in
                        let count = setCount(for: ex)
                        let compatible =
                            isCompatible(ex) || picked.contains(ex.id)
                        HStack {
                            Text(ex.name)
                            Spacer()
                            Text("×\(count)")
                                .foregroundStyle(.secondary)
                            if picked.contains(ex.id) {
                                Image(systemName: "checkmark")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { togglePick(ex) }
                        .opacity(compatible ? 1.0 : 0.45)
                    }
                }

                if let ref = refSetCount {
                    Section {
                        Text(
                            "All selected exercises must have **exactly \(ref)** working sets."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Pick Exercises")
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
                    Button("Done") {
                        let pickedList = exercises.filter {
                            picked.contains($0.id)
                        }
                        onDone(pickedList)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}

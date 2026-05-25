import SwiftData
import SwiftUI

// MARK: - Warmup Editor

// WarmupSchemeEditor: add/remove/edit warmup steps for a SlotPrescription
struct WarmupSchemeEditor: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var prescription: SlotPrescription
    @State private var showAddStep = false
    /// Non-nil drives the "Delete Warmup Step?" confirmation alert. Set
    /// by the per-row swipe Delete button (a roleless `.swipeActions`
    /// `Button`, tinted red) without mutating; the actual
    /// `deleteSteps(at:)` call lives inside the alert's destructive
    /// button (wrapped in `withAnimation`). See the glitch rationale on
    /// `BodyPartPicker.pendingSharedRemoval`: a `.onDelete` handler or a
    /// `role: .destructive` swipe button assumes mutation and animates a
    /// row-collapse on tap before springing back, so edit-mode delete is
    /// intentionally dropped — `EditButton` still drives reordering via
    /// `.onMove`.
    @State private var pendingDeleteOffsets: IndexSet? = nil

    private var sortedSteps: [WarmupStep] {
        (prescription.warmupScheme?.steps ?? []).sorted { $0.order < $1.order }
    }

    var body: some View {
        List {
            schemeSummarySection
            stepsSection
        }
        .navigationTitle("Warmup")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button { showAddStep = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddStep) {
            WarmupStepEditSheet(onSave: { kind, reps, pct, rest, note, weight in
                addStep(kind: kind, reps: reps, pct: pct, rest: rest, note: note, weight: weight)
            })
        }
        .alert(
            "Delete Warmup Step?",
            isPresented: Binding(
                get: { pendingDeleteOffsets != nil },
                set: { if !$0 { pendingDeleteOffsets = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDeleteOffsets = nil
            }
            Button("Delete", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    withAnimation {
                        deleteSteps(at: offsets)
                    }
                }
                pendingDeleteOffsets = nil
            }
        } message: {
            Text("This warmup step will be removed from this slot.")
        }
    }

    private var schemeSummarySection: some View {
        Section {
            let count = prescription.warmupScheme?.steps.count ?? 0
            if count == 0 {
                Text("No warmup steps. Tap + to add one.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Warmup Steps")
        }
    }

    private var stepsSection: some View {
        Section {
            ForEach(sortedSteps) { step in
                WarmupStepRow(step: step)
                    .swipeActions(allowsFullSwipe: false) {
                        Button {
                            if let idx = sortedSteps.firstIndex(where: {
                                $0.id == step.id
                            }) {
                                pendingDeleteOffsets = IndexSet(integer: idx)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
            }
            .onMove(perform: moveSteps)
        }
    }

    private func addStep(kind: WarmupStepKind, reps: Int?, pct: Double?, rest: Int?, note: String?, weight: Double?) {
        let scheme: WarmupScheme
        if let existing = prescription.warmupScheme {
            scheme = existing
        } else {
            let s = WarmupScheme(name: "Warmup")
            ctx.insert(s)
            prescription.warmupScheme = s
            scheme = s
        }
        let nextOrder = (scheme.steps.map(\.order).max() ?? -1) + 1
        let step = WarmupStep(order: nextOrder, kind: kind, reps: reps,
                              percentOfWorking: pct, restSecondsAfter: rest, note: note, weight: weight)
        ctx.insert(step)
        scheme.steps.append(step)
        try? ctx.save()
    }

    private func deleteSteps(at offsets: IndexSet) {
        guard let scheme = prescription.warmupScheme else { return }
        let sorted = sortedSteps
        for i in offsets {
            let step = sorted[i]
            scheme.steps.removeAll { $0.id == step.id }
            ctx.delete(step)
        }
        renumber(scheme.steps)
        try? ctx.save()
    }

    private func moveSteps(from source: IndexSet, to destination: Int) {
        guard let scheme = prescription.warmupScheme else { return }
        var sorted = sortedSteps
        sorted.move(fromOffsets: source, toOffset: destination)
        renumber(sorted)
        try? ctx.save()
    }

    private func renumber(_ steps: [WarmupStep]) {
        for (i, s) in steps.enumerated() { s.order = i }
    }
}

// Row displaying a single warmup step in the WarmupSchemeEditor list.
private struct WarmupStepRow: View {
    @Bindable var step: WarmupStep
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(step.kind == .percentage ? "% of Working" :
                     step.kind == .fixedReps  ? "Fixed Weight" : "Note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let r = step.restSecondsAfter, r > 0 {
                    Text("\(r)s rest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if step.kind == .percentage {
                if let pct = step.percentOfWorking {
                    let repsStr = step.reps.map { " × \($0) reps" } ?? ""
                    Text("\(Int(pct * 100))%\(repsStr)")
                        .font(.dsBody)
                }
            } else if step.kind == .fixedReps {
                let unit = Units.weightIsKg ? "kg" : "lb"
                let weightStr: String? = step.weight.map {
                    $0.truncatingRemainder(dividingBy: 1) == 0
                        ? "\(Int($0)) \(unit)"
                        : String(format: "%.1f \(unit)", $0)
                }
                let repsStr: String? = step.reps.map { "\($0) reps" }
                let parts = [weightStr, repsStr].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " × "))
                        .font(.dsBody)
                }
            }
            if let note = step.note, !note.isEmpty {
                Text(note)
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// Sheet for creating a new warmup step.
private struct WarmupStepEditSheet: View {
    var onSave: (WarmupStepKind, Int?, Double?, Int?, String?, Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: WarmupStepKind = .fixedReps
    @State private var reps: Int = 5
    @State private var pct: Int = 50       // displayed as whole %, stored as fraction on save
    @State private var rest: Int = 0       // seconds; 0 = no rest
    @State private var weightText = ""     // optional; free-form for decimal precision
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Kind", selection: $kind) {
                        Text("Fixed Weight").tag(WarmupStepKind.fixedReps)
                        Text("% of Working").tag(WarmupStepKind.percentage)
                        Text("Note Only").tag(WarmupStepKind.noteOnly)
                    }
                    .pickerStyle(.segmented)
                }

                if kind == .fixedReps {
                    Section("Weight (\(Units.weightIsKg ? "kg" : "lb"), optional)") {
                        TextField("e.g. 60", text: $weightText)
                            .keyboardType(.decimalPad)
                    }
                }

                if kind == .percentage {
                    Section {
                        Stepper("\(pct)% of working weight", value: $pct, in: 10...100, step: 5)
                    } header: {
                        Text("Percent of Working Weight")
                    }
                }

                if kind != .noteOnly {
                    Section {
                        Stepper(reps == 1 ? "1 rep" : "\(reps) reps", value: $reps, in: 1...30)
                    } header: {
                        Text("Reps")
                    }
                }

                Section {
                    Stepper(
                        rest == 0 ? "No rest" : "\(rest)s rest",
                        value: $rest,
                        in: 0...300,
                        step: 15
                    )
                } header: {
                    Text("Rest After (optional)")
                }

                Section("Note (optional)") {
                    TextField("Optional cue", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .navigationTitle("Add Warmup Step")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let repsVal: Int?    = kind != .noteOnly ? reps : nil
                        let pctVal: Double?  = kind == .percentage ? Double(pct) / 100.0 : nil
                        let restVal: Int?    = rest > 0 ? rest : nil
                        let weightVal: Double? = kind == .fixedReps ? Double(weightText) : nil
                        let noteVal = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(kind, repsVal, pctVal, restVal, noteVal.isEmpty ? nil : noteVal, weightVal)
                        dismiss()
                    }
                }
            }
        }
    }
}

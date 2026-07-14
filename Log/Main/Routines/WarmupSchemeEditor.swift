import SwiftData
import SwiftUI

// MARK: - Warmup Editor

// WarmupSchemeEditor: add/remove/edit warmup steps for a SlotPrescription
struct WarmupSchemeEditor: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var prescription: SlotPrescription
    /// True when the parent exercise is bodyweight: the kind picker drops
    /// "% of Working" and the per-step weight field is hidden (steps save a
    /// nil weight). Defaults false so non-bodyweight behavior is unchanged.
    var isBodyweight: Bool = false
    @State private var showAddStep = false
    /// Non-nil drives the edit sheet (`.sheet(item:)`). Set by a row tap; the
    /// same `WarmupStepEditSheet` is reused in edit mode and writes changes
    /// back to this exact step via `updateStep` — order is never touched.
    @State private var editingStep: WarmupStep? = nil
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
            WarmupStepEditSheet(isBodyweight: isBodyweight, onSave: { kind, reps, pct, rest, note, weight in
                addStep(kind: kind, reps: reps, pct: pct, rest: rest, note: note, weight: weight)
            })
        }
        .sheet(item: $editingStep) { step in
            WarmupStepEditSheet(existing: step, isBodyweight: isBodyweight, onSave: { kind, reps, pct, rest, note, weight in
                updateStep(step, kind: kind, reps: reps, pct: pct, rest: rest, note: note, weight: weight)
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
                Button {
                    editingStep = step
                } label: {
                    WarmupStepRow(step: step)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
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
        // Reassign the whole relationship array instead of `scheme.steps.append`.
        // An in-place append on a SwiftData to-many relationship does not
        // reliably fire the Observation change notification, so the editor's
        // `@Bindable prescription` body did not re-read `warmupScheme.steps` —
        // the new row only appeared after popping and re-pushing the editor.
        // A full setter assignment guarantees SwiftUI observes the change and
        // renders the new step immediately. Order/persistence are unchanged.
        scheme.steps = scheme.steps + [step]
        try? ctx.save()
    }

    /// Writes edited values back to an existing step (edit mode). Only the
    /// passed step is mutated — `order` is intentionally left untouched so
    /// reordering stays the sole owner of position. The kind-conditional
    /// nil-ing happens in the sheet, so stale fields clear when kind changes.
    private func updateStep(_ step: WarmupStep, kind: WarmupStepKind, reps: Int?, pct: Double?, rest: Int?, note: String?, weight: Double?) {
        step.kind = kind
        step.reps = reps
        step.percentOfWorking = pct
        step.restSecondsAfter = rest
        step.note = note
        step.weight = weight
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
        // Renumber the *sorted* remaining steps, not the raw relationship
        // array: `scheme.steps` ordering is not guaranteed to match `order`,
        // so renumbering it directly could swap surviving rows. Re-sorting by
        // `order` first preserves their relative order before reindexing.
        renumber(sortedSteps)
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
                Text(LocalizedStringKey(
                    step.kind == .percentage ? "% of Working" :
                    step.kind == .fixedReps  ? "Fixed Weight" : "Note"))
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
                    "\(Units.formatWeight($0)) \(unit)"
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

// Dual-mode sheet for creating or editing a warmup step. `existing == nil`
// is Add mode ("Add Warmup Step" / "Add"); a non-nil `existing` is Edit mode
// ("Edit Warmup Step" / "Save"), seeding fields from that step. Either way the
// `onSave` callback delivers the resolved values — the caller decides whether
// to create a new step or write back to the existing one.
private struct WarmupStepEditSheet: View {
    var existing: WarmupStep? = nil
    var isBodyweight: Bool = false
    var onSave: (WarmupStepKind, Int?, Double?, Int?, String?, Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: WarmupStepKind
    @State private var reps: Int
    @State private var pct: Int            // displayed as whole %, stored as fraction on save
    @State private var rest: Int           // seconds; 0 = no rest
    @State private var weightText: String  // optional; free-form for decimal precision
    @State private var note: String

    private var isEditing: Bool { existing != nil }

    /// Kinds offered in the picker, narrowed for bodyweight but always
    /// including the existing step's kind so an edit never orphans the selection.
    private var availableKinds: [WarmupStepKind] {
        warmupKinds(isBodyweight: isBodyweight, currentKind: existing?.kind)
    }

    /// Picker label: `.fixedReps` reads "Reps" for bodyweight (weight hidden),
    /// "Fixed Weight" otherwise.
    private func kindLabel(_ k: WarmupStepKind) -> String {
        switch k {
        case .fixedReps:  return isBodyweight ? NSLocalizedString("Reps", comment: "") : NSLocalizedString("Fixed Weight", comment: "")
        case .percentage: return NSLocalizedString("% of Working", comment: "")
        case .noteOnly:   return NSLocalizedString("Note Only", comment: "")
        }
    }

    /// Weight is only entered for non-bodyweight `.fixedReps` steps.
    private var showsWeightField: Bool { kind == .fixedReps && !isBodyweight }

    init(
        existing: WarmupStep? = nil,
        isBodyweight: Bool = false,
        onSave: @escaping (WarmupStepKind, Int?, Double?, Int?, String?, Double?) -> Void
    ) {
        self.existing = existing
        self.isBodyweight = isBodyweight
        self.onSave = onSave
        _kind = State(initialValue: existing?.kind ?? .fixedReps)
        _reps = State(initialValue: existing?.reps ?? 5)
        _pct = State(initialValue: existing?.percentOfWorking.map { Int(($0 * 100).rounded()) } ?? 50)
        _rest = State(initialValue: existing?.restSecondsAfter ?? 0)
        _weightText = State(initialValue: Self.weightSeed(existing?.weight))
        _note = State(initialValue: existing?.note ?? "")
    }

    /// Parse-safe seed string for the weight field: integral values drop the
    /// decimal ("60"), fractional keep it ("60.5"). `String(Double)` never
    /// emits grouping separators, so `Double(weightText)` round-trips it.
    private static func weightSeed(_ weight: Double?) -> String {
        guard let weight else { return "" }
        return weight == weight.rounded() ? String(Int(weight)) : String(weight)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Kind", selection: $kind) {
                        ForEach(availableKinds, id: \.self) { k in
                            Text(kindLabel(k)).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if showsWeightField {
                    Section {
                        // Decimal example in the placeholder + footer caption
                        // signal decimal entry (the .decimalPad's "." key is
                        // easy to miss). Consistent with the active-workout
                        // weight fields.
                        TextField("e.g. 60.5", text: $weightText)
                            .keyboardType(.decimalPad)
                    } header: {
                        Text("Weight (\(Units.weightIsKg ? "kg" : "lb"), optional)")
                    } footer: {
                        Text("Weight accepts decimals (e.g. 2.5).")
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
                        rest == 0 ? LocalizedStringKey("No rest") : "\(rest)s rest",
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
            .navigationTitle(isEditing ? "Edit Warmup Step" : "Add Warmup Step")
            .toolbar {
                // Weight (.decimalPad) has no Return key and the optional Note
                // (axis: .vertical) inserts a newline on Return, so both need a
                // keyboard-integrated dismiss. The top-bar Cancel/Save below stay:
                // they commit / discard the modal, a separate concern.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    KeyboardDismissButton()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        let repsVal: Int?    = kind != .noteOnly ? reps : nil
                        let pctVal: Double?  = kind == .percentage ? Double(pct) / 100.0 : nil
                        let restVal: Int?    = rest > 0 ? rest : nil
                        let weightVal: Double? = warmupSavedWeight(
                            kind: kind, isBodyweight: isBodyweight, weightText: weightText)
                        let noteVal = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(kind, repsVal, pctVal, restVal, noteVal.isEmpty ? nil : noteVal, weightVal)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Bodyweight warm-up rules (pure helpers)

/// Warm-up step kinds offered in the kind picker.
///
/// - Non-bodyweight: all kinds (`.fixedReps` = "Fixed Weight", `.percentage`,
///   `.noteOnly`).
/// - Bodyweight: `.percentage` is dropped (% of working weight is meaningless
///   without a working weight), leaving `.fixedReps` (shown as "Reps") and
///   `.noteOnly`.
/// - Edit safety: when editing a legacy step whose `currentKind` would
///   otherwise be hidden (e.g. a bodyweight exercise with an old `.percentage`
///   step), that kind is appended so the `Picker` selection never orphans.
///
/// Order is stable and there are never duplicates.
func warmupKinds(isBodyweight: Bool, currentKind: WarmupStepKind? = nil) -> [WarmupStepKind] {
    guard isBodyweight else {
        return [.fixedReps, .percentage, .noteOnly]
    }
    var kinds: [WarmupStepKind] = [.fixedReps, .noteOnly]
    if let currentKind, !kinds.contains(currentKind) {
        kinds.append(currentKind)
    }
    return kinds
}

/// Resolved weight to persist for a warm-up step. Only non-bodyweight
/// `.fixedReps` steps carry a weight; percentage, note-only, and **all**
/// bodyweight steps save nil (so editing a legacy weighted `.fixedReps` step on
/// a bodyweight exercise clears its weight on save).
func warmupSavedWeight(kind: WarmupStepKind, isBodyweight: Bool, weightText: String) -> Double? {
    guard kind == .fixedReps, !isBodyweight else { return nil }
    return Double(weightText)
}

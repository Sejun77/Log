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
    /// True when the parent exercise is tracked as cardio, which hides the same
    /// weight-based options for the same reason — there is no working weight to
    /// base them on. Defaults false, so strength and timed-hold slots are
    /// unaffected.
    var isCardio: Bool = false
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
            WarmupStepEditSheet(isBodyweight: isBodyweight, isCardio: isCardio, onSave: { kind, reps, pct, rest, note, weight in
                addStep(kind: kind, reps: reps, pct: pct, rest: rest, note: note, weight: weight)
            })
        }
        .sheet(item: $editingStep) { step in
            WarmupStepEditSheet(existing: step, isBodyweight: isBodyweight, isCardio: isCardio, onSave: { kind, reps, pct, rest, note, weight in
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
                    WarmupStepRow(
                        step: step,
                        isBodyweight: isBodyweight,
                        isCardio: isCardio)
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

    /// The store this editor writes into: **the one the edited prescription
    /// already lives in**, not whatever `@Environment(\.modelContext)` resolves
    /// to.
    ///
    /// For every routine slot the two are the same object, so ordinary warm-up
    /// editing is unchanged. They differ for the scratch slot the Alternative
    /// Exercises detail editor binds this editor to, which lives in
    /// `AlternativeDraftStore`'s own in-memory container: writing there through
    /// the environment created the scheme in the *app's* store and then related
    /// it to a model from another container, which SwiftData traps on. See
    /// `WarmupSchemeAuthoring` for the full crash note.
    private var writeContext: ModelContext {
        WarmupSchemeAuthoring.writeContext(for: prescription, fallback: ctx)
    }

    private func addStep(kind: WarmupStepKind, reps: Int?, pct: Double?, rest: Int?, note: String?, weight: Double?) {
        WarmupSchemeAuthoring.addStep(
            to: prescription,
            kind: kind,
            reps: reps,
            percentOfWorking: pct,
            restSecondsAfter: rest,
            note: note,
            weight: weight,
            fallbackContext: ctx)
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
        try? writeContext.save()
    }

    private func deleteSteps(at offsets: IndexSet) {
        guard let scheme = prescription.warmupScheme else { return }
        let ctx = writeContext
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
        try? writeContext.save()
    }

    private func renumber(_ steps: [WarmupStep]) {
        for (i, s) in steps.enumerated() { s.order = i }
    }
}

// Row displaying a single warmup step in the WarmupSchemeEditor list.
private struct WarmupStepRow: View {
    @Bindable var step: WarmupStep
    /// Same two flags the edit sheet takes, so the row's kind caption is
    /// resolved by `warmupKindLabel` and cannot contradict the picker the row
    /// opens — a cardio step must never be captioned "Fixed Weight".
    var isBodyweight: Bool = false
    var isCardio: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                // `.noteOnly` keeps its shorter row caption ("Note"); only the
                // weight-dependent `.fixedReps` / `.percentage` wording is
                // taken from the shared label rule.
                Text(step.kind == .noteOnly
                    ? NSLocalizedString("Note", comment: "")
                    : warmupKindLabel(
                        step.kind,
                        isBodyweight: isBodyweight,
                        isCardio: isCardio))
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
    var isCardio: Bool = false
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
        warmupKinds(
            isBodyweight: isBodyweight,
            isCardio: isCardio,
            currentKind: existing?.kind)
    }

    /// Picker label: `.fixedReps` reads "Reps" when the weight field is hidden
    /// (bodyweight or cardio), "Fixed Weight" otherwise.
    private func kindLabel(_ k: WarmupStepKind) -> String {
        warmupKindLabel(k, isBodyweight: isBodyweight, isCardio: isCardio)
    }

    /// Weight is only entered for weight-bearing `.fixedReps` steps.
    private var showsWeightField: Bool {
        kind == .fixedReps
            && !warmupHidesWeight(isBodyweight: isBodyweight, isCardio: isCardio)
    }

    init(
        existing: WarmupStep? = nil,
        isBodyweight: Bool = false,
        isCardio: Bool = false,
        onSave: @escaping (WarmupStepKind, Int?, Double?, Int?, String?, Double?) -> Void
    ) {
        self.existing = existing
        self.isBodyweight = isBodyweight
        self.isCardio = isCardio
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
                        // The "e.g. 60.5" placeholder already signals decimal
                        // entry (the .decimalPad's "." key is easy to miss),
                        // consistent with the active-workout weight fields, so no
                        // separate footer caption is needed.
                        TextField("e.g. 60.5", text: $weightText)
                            .keyboardType(.decimalPad)
                    } header: {
                        Text("Weight (\(Units.weightIsKg ? "kg" : "lb"), optional)")
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
                    // Same 60m bound and picker as every other rest field, so
                    // a warm-up rest is not capped lower than the working-set
                    // rest it precedes.
                    DurationFieldRowInt(
                        title: "Rest",
                        seconds: $rest,
                        maxSeconds: DurationLimits.maxRestSeconds,
                        zeroLabel: "No rest",
                        presets: DurationPresets.rest
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
                            kind: kind, isBodyweight: isBodyweight,
                            isCardio: isCardio, weightText: weightText)
                        let noteVal = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(kind, repsVal, pctVal, restVal, noteVal.isEmpty ? nil : noteVal, weightVal)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Weightless warm-up rules (pure helpers)

/// Whether the exercise has no working weight for a warm-up step to be based
/// on, so the two weight-based options are meaningless for it.
///
/// Two unrelated reasons land on the same rule:
/// - **bodyweight** — there is no external load to take a percentage of, and no
///   number to enter (Slice 1);
/// - **cardio** — "50% of working weight" and "60 kg × 5" describe nothing a
///   treadmill or a rower can do (Slice 4 polish).
///
/// Basic duration exercises (timed holds such as Plank) are deliberately *not*
/// included: their warm-up options are unchanged by this rule and still include
/// the weight-based kinds, exactly as before.
func warmupHidesWeight(isBodyweight: Bool, isCardio: Bool) -> Bool {
    isBodyweight || isCardio
}

/// Warm-up step kinds offered in the kind picker.
///
/// - Weight-bearing (the default): all kinds (`.fixedReps` = "Fixed Weight",
///   `.percentage` = "% of Working", `.noteOnly`).
/// - Weightless (bodyweight or cardio, see `warmupHidesWeight`): `.percentage`
///   is dropped entirely and `.fixedReps` loses its weight field and reads
///   "Reps", so neither "Fixed Weight" nor "% of Working" is offered.
/// - Edit safety: when editing a legacy step whose `currentKind` would
///   otherwise be hidden (e.g. a cardio exercise carrying an old `.percentage`
///   step), that kind is appended so the `Picker` selection never orphans.
///
/// Order is stable and there are never duplicates.
func warmupKinds(
    isBodyweight: Bool,
    isCardio: Bool = false,
    currentKind: WarmupStepKind? = nil
) -> [WarmupStepKind] {
    guard warmupHidesWeight(isBodyweight: isBodyweight, isCardio: isCardio) else {
        return [.fixedReps, .percentage, .noteOnly]
    }
    var kinds: [WarmupStepKind] = [.fixedReps, .noteOnly]
    if let currentKind, !kinds.contains(currentKind) {
        kinds.append(currentKind)
    }
    return kinds
}

/// Localized picker / row label for a warm-up step kind.
///
/// `.fixedReps` is the one kind whose meaning depends on the exercise: with a
/// weight field it is "Fixed Weight", without one it is just "Reps". Shared by
/// the edit sheet's picker and the step row so the two can never disagree —
/// a cardio step must not be listed as "Reps" in one place and "Fixed Weight"
/// in the other.
func warmupKindLabel(
    _ kind: WarmupStepKind, isBodyweight: Bool, isCardio: Bool = false
) -> String {
    switch kind {
    case .fixedReps:
        return warmupHidesWeight(isBodyweight: isBodyweight, isCardio: isCardio)
            ? NSLocalizedString("Reps", comment: "")
            : NSLocalizedString("Fixed Weight", comment: "")
    case .percentage: return NSLocalizedString("% of Working", comment: "")
    case .noteOnly:   return NSLocalizedString("Note Only", comment: "")
    }
}

/// Resolved weight to persist for a warm-up step. Only weight-bearing
/// `.fixedReps` steps carry a weight; percentage, note-only, and **all**
/// bodyweight / cardio steps save nil (so editing a legacy weighted
/// `.fixedReps` step on such an exercise clears its weight on save).
func warmupSavedWeight(
    kind: WarmupStepKind,
    isBodyweight: Bool,
    isCardio: Bool = false,
    weightText: String
) -> Double? {
    guard kind == .fixedReps,
        !warmupHidesWeight(isBodyweight: isBodyweight, isCardio: isCardio)
    else { return nil }
    return Double(weightText)
}

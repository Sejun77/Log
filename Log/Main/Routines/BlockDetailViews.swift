import SwiftData
import SwiftUI

// MARK: - Routine Block Detail

struct RoutineBlockDetailView: View {
    @Environment(\.modelContext) private var ctx
    let block: RoutineBlock
    /// Phase 5.2 — plumbed from `RoutinesView.blockRowView(for:)` so
    /// per-exercise prescription edits (sets, reps, rest, autoreg,
    /// warmup, techniques, slot notes) are disabled while the routine
    /// is in use by an active workout. The "In use" chip on the block
    /// row already communicates the lock state to the user.
    var isRoutineLocked: Bool = false

    var body: some View {
        List {
            ForEach(block.exercises.sorted { $0.order < $1.order }) { re in
                if let ex = re.safeExercise(in: ctx) {
                    Section(header: Text(ex.name)) {
                        let templates = re.resolvedTemplates(in: ctx)
                        ForEach(templates.indices, id: \.self) { i in
                            let t = templates[i]
                            HStack {
                                Text("\(i + 1). \(t.kindRaw.capitalized)")
                                Spacer()

                                if ex.isTimeBased {
                                    Text(
                                        "Duration \((t.durationSeconds ?? 0))s"
                                    )
                                    .monospacedDigit()
                                    if let rest = t.restSecondsAfter, rest > 0 {
                                        Text("· \(rest)s")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("Reps \(t.targetReps)")
                                        .monospacedDigit()
                                    if let rest = t.restSecondsAfter, rest > 0 {
                                        Text("· \(rest)s")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    if let w = t.targetWeight, w > 0 {
                                        let unit =
                                            Units.weightIsKg ? "kg" : "lb"
                                        Text("· \(Units.formatWeight(w)) \(unit)")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    SlotPrescriptionSection(
                        re: re,
                        isTimeBased: ex.isTimeBased,
                        isLocked: isRoutineLocked
                    )
                }
            }
        }
        // Phase 5.2 — Section-level `.disabled` on the prescription
        // rows (inside `SlotPrescriptionSection`) handles the lock.
        // Body-level `.disabled` is intentionally NOT used here because
        // it blocks the List's scroll gesture on iOS.
        .navigationTitle("Block")
    }
}

// MARK: - Superset Block Detail

/// Detail for a Superset block:
/// - "Rest after round" is editable here (removed from block list)
/// - Lists sets for each exercise with reps & weight (no per-set rest inputs)
struct SupersetDetailNoRest: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var block: RoutineBlock

    /// Phase 5.2 — plumbed from `RoutinesView.blockRowView(for:)` so the
    /// Add Exercise button + delete affordance can share the same lock
    /// behavior as the routine-level Add Exercise / Add Superset buttons.
    let isRoutineLocked: Bool
    /// Full library exercise list — passed down so `ExercisePickerSingle`
    /// can be presented from this sheet without re-querying SwiftData.
    let allExercises: [Exercise]

    /// Locally-tracked displayed value for the "Sets per exercise" Stepper.
    /// Seeded lazily from the max of child prescriptions on first read, and updated
    /// explicitly on user edits. Backing this with @State (rather than a computed
    /// property over `block.exercises[i].prescription?.sets`) is required because
    /// SwiftUI's observation on `@Bindable var block` does not fire for mutations
    /// to properties of nested @Model instances (SlotPrescription.sets), so a
    /// purely-computed display value would not refresh the Stepper label after
    /// the user pressed +/-.
    @State private var displayedSets: Int? = nil

    @State private var showAddExerciseSheet = false
    @State private var showMinExerciseAlert = false
    /// Non-nil drives the "Remove Exercise from Superset?" confirmation
    /// alert. Set by the per-row swipe Delete button (a roleless
    /// `.swipeActions` `Button`, tinted red) routed through
    /// `removeExercise(at:)`, which keeps the existing routine-lock +
    /// min-2 guards so the confirm prompt only appears for deletions
    /// that would actually proceed. The real deletion (formerly the
    /// body of `removeExercise`) now lives in
    /// `performRemoveExercise(at:)` and runs inside `withAnimation`
    /// from the alert's destructive button. Edit-mode `.onDelete` is
    /// intentionally not wired (it would animate a row-collapse before
    /// confirmation); `EditButton` still drives reordering via `.onMove`.
    @State private var pendingDeleteOffsets: IndexSet? = nil

    private func templates(for re: RoutineExercise) -> [SetTemplate] {
        re.resolvedTemplates(in: ctx)
    }

    /// Current value shown in the Stepper label and used as its binding getter.
    /// Reads from `@State` once seeded; otherwise falls back to the max across
    /// child prescriptions (mismatched legacy data is shown as the max so nothing
    /// gets silently truncated). No mutation here — legacy data is normalized
    /// only when the user explicitly changes the Stepper.
    private var currentSetsValue: Int {
        if let d = displayedSets { return d }
        return block.exercises.compactMap { $0.prescription?.sets }.max() ?? 0
    }

    private func applySetsToAllExercises(_ newValue: Int) {
        displayedSets = newValue
        for re in block.exercises {
            re.prescription?.sets = newValue > 0 ? newValue : nil
        }
        try? ctx.save()
    }

    private func moveExercises(from offsets: IndexSet, to newOffset: Int) {
        var sorted = block.exercises.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: offsets, toOffset: newOffset)
        for (i, re) in sorted.enumerated() {
            re.order = i
        }
        try? ctx.save()
    }

    /// Phase 5.2 — append a new `RoutineExercise` slot to this superset.
    /// The new slot inherits the superset's shared "Sets per exercise"
    /// value so adding doesn't disturb the block-wide invariant. Duplicate
    /// `Exercise` references are intentionally allowed: per-slot identity
    /// is `RoutineExercise.slotID` (unique per slot), so two slots of the
    /// same Exercise log and persist independently.
    private func addExercise(_ ex: Exercise) {
        let nextOrder = (block.exercises.map(\.order).max() ?? -1) + 1
        let re = RoutineExercise(
            exercise: ex, order: nextOrder, setTemplates: [])
        ctx.insert(re)
        let p = makeDefaultPrescription(isTimeBased: ex.isTimeBased, in: ctx)
        // Coerce the new slot's sets to the block's shared value so the
        // shared Stepper invariant holds without an extra user touch.
        // `currentSetsValue == 0` means no child prescription has a `sets`
        // value yet (legacy or freshly-created block) — fall back to the
        // app default so the new slot still gets a sane value.
        let sharedSets = currentSetsValue > 0
            ? currentSetsValue
            : AppSettings.defaultSets
        p.sets = sharedSets
        re.prescription = p
        block.exercises.append(re)
        try? ctx.save()
    }

    /// Phase 5.2 — remove `RoutineExercise` slot(s) from this superset.
    /// Guard rails (in priority order):
    ///   1. If the routine is locked by an active workout, refuse.
    ///   2. If the removal would drop the superset below 2 exercises,
    ///      surface the min-exercises alert and refuse.
    /// On success: drop the removed slot(s) **from the parent's
    /// `@Relationship` array first**, then `ctx.delete` them (cascades
    /// the attached `SlotPrescription`), and renormalize the survivors'
    /// `order` to 0…N-1 so the active-workout `sorted { $0.order < $1.order }`
    /// lookup never develops gaps.
    ///
    /// The explicit `block.exercises = survivors` is **load-bearing**:
    /// `ctx.delete(re)` alone leaves a tombstone reference in the parent
    /// relationship array. `RoutinesView.normalizeRoutineModel` then
    /// iterates `b.exercises`, finds `re.safeExercise(in: ctx) == nil`
    /// on the tombstone, and (for supersets) cascades `ctx.delete(b)`,
    /// taking the entire block with it. Detaching here keeps the parent
    /// array consistent with the persistent store.
    /// Slice B (deletion-confirmation, 2026-05-24): existing routine-lock
    /// + min-2 guards run BEFORE the confirmation alert is shown so the
    /// user never sees a confirm prompt that would then be rejected. On
    /// guard pass the offsets are stashed in `pendingDeleteOffsets` and
    /// the alert renders; the actual deletion happens in
    /// `performRemoveExercise(at:)` (called inside `withAnimation`
    /// from the alert's destructive button).
    private func removeExercise(at offsets: IndexSet) {
        guard !isRoutineLocked else { return }
        let sorted = block.exercises.sorted { $0.order < $1.order }
        let remaining = sorted.count - offsets.count
        if remaining < 2 {
            showMinExerciseAlert = true
            return
        }
        pendingDeleteOffsets = offsets
    }

    /// Post-confirmation deletion (extracted from the pre-Slice-B
    /// `removeExercise` body so the guards in `removeExercise(at:)`
    /// stay the single gate before any state writes).
    private func performRemoveExercise(at offsets: IndexSet) {
        let sorted = block.exercises.sorted { $0.order < $1.order }
        let removed = offsets.map { sorted[$0] }
        var survivors = sorted
        survivors.remove(atOffsets: offsets)
        // Detach from the parent FIRST so the @Relationship array no
        // longer references the soon-to-be-deleted children.
        block.exercises = survivors
        for re in removed { ctx.delete(re) }
        for (i, re) in survivors.enumerated() { re.order = i }
        try? ctx.save()
    }

    /// Renders the deletion confirmation's message body for the current
    /// `pendingDeleteOffsets`. Single-row swipe (the common case) shows
    /// the exercise name; multi-row edit-mode batch delete falls back to
    /// a count-based message.
    private func deletionMessage(for offsets: IndexSet?) -> String {
        guard let offsets, !offsets.isEmpty else { return "" }
        let sorted = block.exercises.sorted { $0.order < $1.order }
        let names = offsets.compactMap { idx -> String? in
            guard idx < sorted.count else { return nil }
            return sorted[idx].safeExercise(in: ctx)?.name
        }
        if offsets.count == 1, let n = names.first {
            return "\u{201C}\(n)\u{201D} will be removed from this superset. The slot's prescription, warmup, and technique plans will be deleted."
        }
        let n = max(offsets.count, names.count)
        return "\(n) exercises will be removed from this superset. Their prescriptions, warmups, and technique plans will be deleted."
    }

    var body: some View {
        List {
            Section {
                Stepper(
                    currentSetsValue == 0
                        ? "Sets per exercise: —"
                        : "Sets per exercise: \(currentSetsValue)",
                    value: Binding(
                        get: { currentSetsValue },
                        set: { applySetsToAllExercises($0) }
                    ),
                    in: 0...20,
                    step: 1
                )
                .disabled(isRoutineLocked)
                Stepper(
                    (block.supersetRoundRestSeconds.map { "Rest after round: \($0)s" })
                        ?? "Rest after round: none",
                    value: Binding(
                        get: { block.supersetRoundRestSeconds ?? 0 },
                        set: { block.supersetRoundRestSeconds = $0 > 0 ? $0 : nil }
                    ),
                    in: 0...300,
                    step: 15
                )
                .disabled(isRoutineLocked)
                Stepper(
                    (block.restAfterSeconds.map { "Rest before next block: \($0)s" })
                        ?? "Rest before next block: none",
                    value: Binding(
                        get: { block.restAfterSeconds ?? 0 },
                        set: { block.restAfterSeconds = $0 > 0 ? $0 : nil }
                    ),
                    in: 0...600,
                    step: 15
                )
                .disabled(isRoutineLocked)
            } header: {
                Text("Timing")
            } footer: {
                Text("Sets per exercise applies to every exercise in this superset (one round = one set per exercise). Rest after round fires between completed rounds. Rest before next block fires after the final round, replacing round rest.")
            }

            Section {
                Button {
                    showAddExerciseSheet = true
                } label: {
                    Label("Add Exercise", systemImage: "plus.circle")
                }
                .disabled(isRoutineLocked)

                ForEach(block.exercises.sorted { $0.order < $1.order }) { re in
                    if let ex = re.safeExercise(in: ctx) {
                        HStack {
                            Text(ex.name)
                            Spacer()
                            Text("\(re.prescription?.sets ?? 0) sets")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            if !isRoutineLocked {
                                Button {
                                    let sorted = block.exercises.sorted {
                                        $0.order < $1.order
                                    }
                                    if let idx = sorted.firstIndex(where: {
                                        $0.id == re.id
                                    }) {
                                        removeExercise(
                                            at: IndexSet(integer: idx)
                                        )
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
                .onMove(perform: moveExercises)
                .moveDisabled(isRoutineLocked)
            } header: {
                Text("Exercises (drag to reorder)")
            } footer: {
                Text("A superset must keep at least 2 exercises. The same exercise can appear more than once — each slot logs independently.")
            }

            ForEach(block.exercises.sorted { $0.order < $1.order }) { re in
                if let ex = re.safeExercise(in: ctx) {
                    Section(header: Text(ex.name)) {
                        let templates = templates(for: re).filter {
                            $0.kind == .working || $0.kind == .dropset
                                || $0.kind == .warmup
                        }

                        if templates.isEmpty {
                            Text("No sets").foregroundStyle(.secondary)
                        } else {
                            ForEach(templates.indices, id: \.self) { i in
                                let t = templates[i]
                                HStack {
                                    Text("\(i + 1). \(t.kindRaw.capitalized)")
                                    Spacer()

                                    if ex.isTimeBased {
                                        Text(
                                            "Duration \((t.durationSeconds ?? 0))s"
                                        )
                                        .monospacedDigit()
                                    } else {
                                        Text("Reps \(t.targetReps)")
                                            .monospacedDigit()
                                        if let w = t.targetWeight, w > 0 {
                                            let unit =
                                                Units.weightIsKg ? "kg" : "lb"
                                            Text(
                                                "· \(Units.formatWeight(w)) \(unit)"
                                            )
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    SlotPrescriptionSection(
                        re: re,
                        isTimeBased: ex.isTimeBased,
                        hideRestFields: true,
                        hideSetsField: true,
                        isLocked: isRoutineLocked
                    )
                }
            }
        }
        // Phase 5.2 — mutation surfaces are disabled individually below
        // (the 3 timing Steppers, Add Exercise button, swipe-delete,
        // inline reorder handles, EditButton, and the per-exercise
        // `SlotPrescriptionSection`s). The body itself is NOT wrapped
        // in `.disabled(isRoutineLocked)` because doing so blocks the
        // List's scroll gesture on iOS — the user must still be able
        // to scroll to read the locked routine's contents.
        .navigationTitle("Superset")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(isRoutineLocked)
            }
        }
        .sheet(isPresented: $showAddExerciseSheet) {
            ExercisePickerSingle(exercises: allExercises) { picked in
                if let ex = picked { addExercise(ex) }
            }
        }
        .alert(
            "Superset needs at least 2 exercises",
            isPresented: $showMinExerciseAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A superset must keep at least 2 exercises. To remove this superset entirely, delete the block from the routine's Blocks list.")
        }
        .alert(
            "Remove Exercise from Superset?",
            isPresented: Binding(
                get: { pendingDeleteOffsets != nil },
                set: { if !$0 { pendingDeleteOffsets = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDeleteOffsets = nil
            }
            Button("Remove", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    withAnimation {
                        performRemoveExercise(at: offsets)
                    }
                }
                pendingDeleteOffsets = nil
            }
        } message: {
            Text(deletionMessage(for: pendingDeleteOffsets))
        }
    }
}

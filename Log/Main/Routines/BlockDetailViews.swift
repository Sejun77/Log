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
        // Scrolling dismisses the multiline slot-notes keyboard;
        // `.interactively` matches the note-heavy routine-editor lists.
        .scrollDismissesKeyboard(.interactively)
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

    /// Draft value for the explicit "Set All Exercises" bulk control. Exercises
    /// in a superset may have **different** set counts (each is authored
    /// independently in its own Prescription section below). This draft is a
    /// staging value only — adjusting the stepper does **not** touch any child;
    /// the counts change only when the user taps "Apply to all exercises"
    /// (`RoutineBlockBuilder.applySetCountToAll`). Seeded once from the current
    /// max child count on first appear.
    @State private var bulkSetsDraft: Int = 0
    @State private var bulkDraftSeeded = false

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

    /// The max set count across child prescriptions — used to seed both the
    /// "Set All Exercises" draft and the default count for newly-added slots
    /// (`addExercises`). The max is shown so mismatched/uneven data is never
    /// silently truncated. Read-only; no mutation.
    private var currentSetsValue: Int {
        block.exercises.compactMap { $0.prescription?.sets }.max() ?? 0
    }

    /// Seed the bulk draft once from the current data. Idempotent per view
    /// lifetime so re-renders (e.g. after a per-slot edit) don't clobber a
    /// value the user is mid-adjusting.
    private func seedBulkDraftIfNeeded() {
        guard !bulkDraftSeeded else { return }
        bulkDraftSeeded = true
        bulkSetsDraft = currentSetsValue > 0
            ? currentSetsValue
            : AppSettings.defaultSets
    }

    /// Explicit bulk apply, invoked only by the "Apply to all exercises"
    /// button. Delegates to the tested `RoutineBlockBuilder.applySetCountToAll`.
    private func applyBulkSetCount() {
        guard !isRoutineLocked else { return }
        RoutineBlockBuilder.applySetCountToAll(
            bulkSetsDraft, in: block, ctx: ctx)
    }

    private func moveExercises(from offsets: IndexSet, to newOffset: Int) {
        var sorted = block.exercises.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: offsets, toOffset: newOffset)
        for (i, re) in sorted.enumerated() {
            re.order = i
        }
        try? ctx.save()
    }

    /// Phase 5.2 / Multi-select Slice B — append one or more `RoutineExercise`
    /// slots to this superset, in tap-selection order. Each new slot is seeded
    /// with a sensible default set count — the current "Set all to" value
    /// (`currentSetsValue`, the max across existing children), falling back to
    /// `AppSettings.defaultSets` when that is 0 — but the user can then edit
    /// each slot's count independently (uneven supersets are allowed).
    /// Duplicate `Exercise` references are intentionally
    /// allowed: per-slot identity is `RoutineExercise.slotID` (unique per slot),
    /// so two slots of the same Exercise log and persist independently. Existing
    /// slots are not mutated. Delegates to the tested `RoutineBlockBuilder`. The
    /// lock guard is defense-in-depth — the "Add Exercise" button is already
    /// `.disabled(isRoutineLocked)`.
    private func addExercises(_ exercises: [Exercise]) {
        guard !isRoutineLocked else { return }
        RoutineBlockBuilder.addExercisesToSuperset(
            exercises, to: block, sharedSets: currentSetsValue, in: ctx)
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
        // Bounds-guard the offsets, then resolve to slot objects and delegate
        // the detach-first delete + order renormalize to the tested
        // `RoutineBlockBuilder.removeExercises` (no `#Predicate`/fetch).
        let removed = offsets.compactMap { $0 < sorted.count ? sorted[$0] : nil }
        RoutineBlockBuilder.removeExercises(removed, from: block, in: ctx)
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

    /// A superset must keep at least 2 exercises (the min-two invariant
    /// enforced in `removeExercise(at:)`). When the block is already at the
    /// minimum, the per-child remove swipe action renders greyed + disabled so
    /// the constraint reads from the affordance itself instead of only after a
    /// tap. Removal becomes available (red) again once a third child exists.
    private var canRemoveChild: Bool {
        block.exercises.count > 2
    }

    var body: some View {
        List {
            Section {
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
                Text("A round runs one set of each exercise that still has sets remaining; shorter exercises drop out of the later rounds. Rest after round fires between completed rounds. Rest before next block fires after the final round, replacing round rest.")
            }

            Section {
                Stepper(
                    "Sets: \(bulkSetsDraft)",
                    value: $bulkSetsDraft,
                    in: 0...20,
                    step: 1
                )
                .monospacedDigit()
                .disabled(isRoutineLocked)
                Button {
                    applyBulkSetCount()
                } label: {
                    Label("Apply to all exercises", systemImage: "equal.circle")
                }
                .disabled(isRoutineLocked)
            } header: {
                Text("Set All Exercises")
            } footer: {
                Text("Optional shortcut. Choose a count, then tap Apply to set every exercise in this superset to that many sets at once. Adjusting the stepper alone changes nothing — each exercise still keeps its own set count (edit it in that exercise's section below), so they can differ.")
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
                            // Bind the nested prescription directly so the count
                            // refreshes immediately when the per-exercise sets
                            // field below changes. Observation on the parent's
                            // `@Bindable var block` does not fire for nested
                            // @Model (SlotPrescription.sets) mutations, so a
                            // plain `re.prescription?.sets` read here would stay
                            // stale until the view was reopened.
                            if let prescription = re.prescription {
                                SupersetSetCountLabel(prescription: prescription)
                            } else {
                                Text("0 sets")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
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
                                .tint(canRemoveChild ? .red : .gray)
                                .disabled(!canRemoveChild)
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
                        hideSetsField: false,
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
        // Scrolling dismisses the multiline slot-notes keyboard;
        // `.interactively` matches the note-heavy routine-editor lists.
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: seedBulkDraftIfNeeded)
        .navigationTitle("Superset")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(isRoutineLocked)
            }
        }
        .sheet(isPresented: $showAddExerciseSheet) {
            ExerciseMultiPicker(exercises: allExercises) { picked in
                addExercises(picked)
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

/// Trailing "N sets" label for a superset exercise row. Holding the
/// `SlotPrescription` as `@Bindable` ties this small view's invalidation to
/// that nested @Model, so the count updates the instant the per-exercise sets
/// field changes — without reopening the superset detail or forcing a save.
private struct SupersetSetCountLabel: View {
    @Bindable var prescription: SlotPrescription

    var body: some View {
        Text("\(prescription.sets ?? 0) sets")
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

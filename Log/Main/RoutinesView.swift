import SwiftData
import SwiftUI

// MARK: - Routines List

struct RoutinesView: View {
    @Binding var resumeNavigationTrigger: Bool

    @Environment(\.modelContext) private var ctx
    @Query(sort: [SortDescriptor(\Routine.order), SortDescriptor(\Routine.name)])
    private var routines: [Routine]

    @State private var newName = ""
    @State private var dupAlert = false
    @State private var dup = ""
    @FocusState private var focusNewRoutine: Bool
    /// Value-based navigation target. A row tap sets this *after* clearing the
    /// add-field focus, so cleanup commits before the push — see the row Button.
    @State private var selectedRoutineID: UUID? = nil

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared
    @State private var showLockedRoutineAlert = false
    @State private var lockedRoutineName = ""

    @State private var showDeleteRoutineAlert = false
    @State private var pendingDeleteRoutine: Routine? = nil
    @State private var routineDeleteMessage = "This will delete the routine."

    @State private var navigateToActiveWorkout = false

    init(resumeNavigationTrigger: Binding<Bool> = .constant(false)) {
        self._resumeNavigationTrigger = resumeNavigationTrigger
    }

    var body: some View {
        NavigationStack {
            List {
                activeSessionSection
                createRoutineSection
                savedRoutinesSection
            }
            .navigationTitle("Routines")
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 56)
            .listRowSpacing(8)
            .scrollContentBackground(.hidden)
            .background(DSColor.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                }
                // No `.keyboard` Done button: the single-line name field commits
                // and dismisses via its return key (.submitLabel(.done) +
                // .onSubmit below), so an external accessory button is redundant.
            }
            .alert("Delete Routine", isPresented: $showDeleteRoutineAlert) {
                Button("Cancel", role: .cancel) {
                    pendingDeleteRoutine = nil
                }
                Button("Delete", role: .destructive) {
                    guard let r = pendingDeleteRoutine else { return }
                    withAnimation {
                        ctx.delete(r)
                        try? ctx.save()
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(
                        .success
                    )
                    pendingDeleteRoutine = nil
                }
            } message: {
                Text(routineDeleteMessage)
            }
            .alert(
                "Routine is currently in use",
                isPresented: $showLockedRoutineAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    "You can\u{2019}t delete \u{201C}\(lockedRoutineName)\u{201D} while a workout using it is active."
                )
            }
            .navigationDestination(isPresented: $navigateToActiveWorkout) {
                if let plan = activeGuard.activePlan {
                    ActiveWorkoutView(plan: plan)
                }
            }
            .onChange(of: resumeNavigationTrigger) { _, trigger in
                if trigger, activeGuard.activePlan != nil {
                    navigateToActiveWorkout = true
                    resumeNavigationTrigger = false
                }
            }
            .onAppear { backfillRoutineOrderIfNeeded() }
            // Push the editor via value-based navigation so the row Button can
            // resign the add-field focus *before* the push commits. `.onDisappear`
            // proved insufficient — it doesn't reliably fire on a NavigationStack
            // push, so the keyboard was restored on pop. Looking the routine up
            // by id keeps navigation tolerant of a row deleted out from under it.
            .navigationDestination(item: $selectedRoutineID) { id in
                if let routine = routines.first(where: { $0.id == id }) {
                    RoutineEditor(routine: routine)
                }
            }
            // Belt-and-suspenders for the tab-switch path (which does fire
            // onDisappear): drop add-field focus so a focused field doesn't
            // linger on revisit. The typed `newName` draft is preserved.
            .onDisappear { focusNewRoutine = false }
        }
    }

    // MARK: - Sections

    private var activeSessionSection: some View {
        Group {
            if let plan = activeGuard.activePlan {
                Section {
                    Button {
                        navigateToActiveWorkout = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .imageScale(.large)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Resume workout")
                                    .font(.dsBody.weight(.semibold))
                                Text(plan.routineName)
                                    .font(.dsBodySecondary)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            LockBadge()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .tint(.primary)
                } header: {
                    DSSectionHeader(
                        title: "Active Session",
                        systemImage: "play.circle.fill"
                    )
                }
            }
        }
    }

    private var createRoutineSection: some View {
        Section {
            HStack {
                TextField("e.g., Upper A", text: $newName)
                    .font(.dsBody)
                    .focused($focusNewRoutine)
                    .submitLabel(.done)
                    .onSubmit {
                        addRoutine()
                        focusNewRoutine = false
                    }
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                Button("Add") { addRoutine() }
                    .font(.dsBodySecondary.weight(.semibold))
                    .alert(
                        "Routine already exists",
                        isPresented: $dupAlert
                    ) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("“\(dup)” already exists.")
                    }
            }
        } header: {
            DSSectionHeader(
                title: "Create Routine",
                systemImage: "plus.circle"
            )
        }
    }

    private var savedRoutinesSection: some View {
        // Build the slot/superset summaries once per render (keyed by id) so
        // each row reads its subtitle from the map instead of re-scanning
        // `routine.blocks` in its own `body` — same once-per-render discipline
        // as History's `RoutineLabelResolver`.
        let summaries = RoutineSummary.map(for: routines)
        return Section {
            if routines.isEmpty {
                Text("No routines yet. Create one above.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(routines) { r in
                    // A `Button` (not a `NavigationLink`) so the tap handler can
                    // resign the add-field focus *before* setting the navigation
                    // target — the editor then pushes with no lingering keyboard.
                    // Chevron added manually to keep the disclosure look.
                    Button {
                        focusNewRoutine = false
                        selectedRoutineID = r.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name)
                                    .font(.dsBody)
                                Text(
                                    (summaries[r.id]
                                        ?? RoutineSummary(routine: r)).subtitle
                                )
                                .font(.dsBodySecondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            }
                            Spacer(minLength: 12)
                            if activeGuard.isRoutineLocked(r.id) {
                                LockBadge()
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(allowsFullSwipe: false) {
                        if activeGuard.isRoutineLocked(r.id) {
                            Button {
                                lockedRoutineName = r.name
                                showLockedRoutineAlert = true
                            } label: {
                                Label("In use", systemImage: "lock.fill")
                            }
                            .tint(.gray)
                        } else {
                            Button {
                                pendingDeleteRoutine = r
                                routineDeleteMessage = routineImpactMessage(r)
                                showDeleteRoutineAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        // Non-destructive duplicate — always available, even
                        // while the routine is in use by an active workout
                        // (`RoutineDuplicator.duplicate` only reads the source).
                        // Blue tint keeps gray reserved for blocked/in-use and
                        // red for destructive.
                        Button {
                            duplicateRoutine(r)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .tint(.blue)
                    }
                }
                .onMove(perform: moveRoutines)
                .onDelete(perform: deleteRoutinesFromEdit)
            }
        } header: {
            DSSectionHeader(
                title: "Saved Routines",
                systemImage: "list.bullet"
            )
        }
    }

    // MARK: - Helpers

    /// Edit-mode delete path for the Routines list. Routes through the same
    /// safety as swipe-to-delete: locked routines surface the "in use" alert,
    /// non-locked routines queue the existing confirmation dialog.
    private func deleteRoutinesFromEdit(at offsets: IndexSet) {
        guard let first = offsets.first, first < routines.count else { return }
        let r = routines[first]
        if activeGuard.isRoutineLocked(r.id) {
            lockedRoutineName = r.name
            showLockedRoutineAlert = true
            return
        }
        pendingDeleteRoutine = r
        routineDeleteMessage = routineImpactMessage(r)
        showDeleteRoutineAlert = true
    }

    /// Non-destructive duplicate. Deep-copies the routine graph via the tested
    /// `RoutineDuplicator` service; the new routine gets a unique "… copy" name
    /// and a trailing `order`, so it appears at the end of the list once the
    /// `@Query` refreshes. Allowed regardless of lock state (read-only on the
    /// source). Does not auto-navigate into the new routine.
    private func duplicateRoutine(_ r: Routine) {
        withAnimation {
            RoutineDuplicator.duplicate(r, among: routines, in: ctx)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func routineImpactMessage(_ r: Routine) -> String {
        let blocks = r.blocks.count
        let supersetBlocks = r.blocks.filter { $0.isSuperset }.count
        return """
            Delete “\(r.name)”? This will remove \(blocks) block\(blocks == 1 ? "" : "s") (\(supersetBlocks) superset), and all of their exercise references. This cannot be undone.
            """
    }

    private func addRoutine() {
        let t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        let exists = routines.contains {
            $0.name.caseInsensitiveCompare(t) == .orderedSame
        }

        if exists {
            dup = t
            dupAlert = true
            return
        }

        let r = Routine(name: t, blocks: [])
        r.order = (routines.map(\.order).max() ?? -1) + 1
        ctx.insert(r)
        try? ctx.save()
        newName = ""
    }

    /// Reorder handler for the top-level Saved Routines list. Persists the new
    /// display order by rewriting `Routine.order` on every routine to match the
    /// post-move sequence.
    private func moveRoutines(from offsets: IndexSet, to newOffset: Int) {
        var sorted = routines
        sorted.move(fromOffsets: offsets, toOffset: newOffset)
        for (i, r) in sorted.enumerated() {
            r.order = i
        }
        try? ctx.save()
    }

    /// One-shot normalization for legacy data: if every routine has order 0
    /// (or the order values collide), rewrite them based on the current
    /// `routines` query order (which is `[order, name]` ascending — i.e.,
    /// effectively alphabetical when all orders are 0). Idempotent; no-op once
    /// orders are unique. Runs on `.onAppear`.
    private func backfillRoutineOrderIfNeeded() {
        guard routines.count > 1 else { return }
        let allZero = routines.allSatisfy { $0.order == 0 }
        let hasDuplicates = Set(routines.map(\.order)).count != routines.count
        guard allZero || hasDuplicates else { return }
        for (i, r) in routines.enumerated() {
            r.order = i
        }
        try? ctx.save()
    }
}

// MARK: - Decomposed subviews (Phase 11.2 / 11.3 / 11.5)
//
// Pickers          → Log/Main/Routines/ExercisePickers.swift
// Warmup editor    → Log/Main/Routines/WarmupSchemeEditor.swift
// Prescription UI  → Log/Main/Routines/PrescriptionFields.swift
//                    (`SlotPrescriptionSection`, `PrescriptionFields`,
//                     `TempoEditorView`, `makeDefaultPrescription`)
// Technique editor → Log/Main/Routines/TechniquePlanEditor.swift
//                    (`TechniquePlanEditor`, `TechniquePlanRow`,
//                     `TechniqueTypePickerSheet`, `TechniqueParamEditView`)
// Block detail     → Log/Main/Routines/BlockDetailViews.swift
//                    (`RoutineBlockDetailView`, `SupersetDetailNoRest`)
// Routine editor   → Log/Main/Routines/RoutineEditor.swift
//                    (`RoutineEditor` + its nested `DeletePrompt`
//                     and all private routine-editing helpers)
// Model helpers    → Log/Models/RoutineExercise+Helpers.swift
//                    (`safeExercise(in:)`, `resolvedTemplates(in:)`)
//
// `BlockRow` is module-internal so `RoutineEditor.blockRowView(for:)` —
// now in `Log/Main/Routines/RoutineEditor.swift` (Phase 11.5) — can
// instantiate it across files. `LockBadge` intentionally stays
// file-private here (Phase 11.3 deferral): `ExercisesView.swift` already
// declares a file-private `LockBadge` with `.font(.dsCaption.weight(.semibold))`,
// and Swift treats top-level type names as module-wide regardless of access
// level, so promoting this `LockBadge` to default-internal would collide.
// The two badges are visually distinct by design (different caption sizes)
// and must not be merged without a redesign decision. `BlockRow.body`
// references `LockBadge()` and resolves it within this file, where the
// private declaration lives — that lookup works regardless of where
// `BlockRow` is instantiated from.

// MARK: - Block Row & Lock Badge

struct BlockRow: View {
    let title: String
    /// Optional read-only prescription glance line shown under the title
    /// (e.g. "3 × 8–12 · 90s rest" / "Superset · 3 exercises · 3 sets").
    /// Additive with a `nil` default so existing call sites are unaffected.
    var subtitle: String? = nil
    let details: () -> AnyView
    var locked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .font(.headline)
                Spacer(minLength: 8)
                if locked { LockBadge() }
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack {
                Spacer()
                NavigationLink("Details", destination: details())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        #if DEBUG
            .probe("BlockRow.Row")
        #endif
    }
}

private struct LockBadge: View {
    var body: some View {
        Label("In use", systemImage: "lock.fill")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Exercise currently in use")
    }
}


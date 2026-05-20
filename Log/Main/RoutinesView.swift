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
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusNewRoutine = false
                        addRoutine()
                    }
                }
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
                    .onSubmit { addRoutine() }
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
        Section {
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
                    NavigationLink(
                        destination: RoutineEditor(routine: r)
                    ) {
                        HStack {
                            Text(r.name)
                                .font(.dsBody)
                            Spacer(minLength: 12)
                            if activeGuard.isRoutineLocked(r.id) {
                                LockBadge()
                            }
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        if activeGuard.isRoutineLocked(r.id) {
                            Button {
                                lockedRoutineName = r.name
                                showLockedRoutineAlert = true
                            } label: {
                                Label("In use", systemImage: "lock.fill")
                            }
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

// MARK: - Routine Editor

struct RoutineEditor: View {
    // MARK: - Nested Types

    private struct DeletePrompt: Identifiable {
        let id = UUID()
        let blockID: PersistentIdentifier
        let title: String
    }

    // MARK: - Environment & Data

    @Environment(\.modelContext) private var ctx
    @Query(sort: \Exercise.name) private var allExercises: [Exercise]
    @Bindable var routine: Routine

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    // MARK: - State

    @State private var deletePrompt: DeletePrompt?
    @State private var showAddExercise = false
    @State private var showAddSuperset = false
    @State private var showSupersetCountAlert = false
    @State private var supersetCountMessage = ""

    @State private var showLockedBlockAlert = false
    @State private var blockedBlocks: [String] = []

    @State private var showOverrideActiveAlert = false
    @State private var startLinkActive = false

    // MARK: - Computed

    private var sortedBlocks: [RoutineBlock] {
        routine.blocks.sorted { $0.order < $1.order }
    }

    // MARK: - Body

    var body: some View {
        Form {
            addSection()
            blocksContent()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(routine.name)
        .navigationDestination(isPresented: $startLinkActive) {
            StartWorkoutFromRoutineView(routine: routine)
        }
        .toolbar {
            // Top-right: Edit (reorder blocks) + Start
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button {
                    if let plan = activeGuard.activePlan,
                        plan.routineID != routine.id
                    {
                        // A different routine is already active → confirm override
                        showOverrideActiveAlert = true
                    } else {
                        // No active session, or same routine → just start
                        startLinkActive = true
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("startWorkoutFromEditor")
                .disabled(!routineIsStartable(routine))
            }

        }
        .alert(
            "A workout is already in progress",
            isPresented: $showOverrideActiveAlert
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Start New", role: .destructive) {
                endActiveSessionIfAny()
                startLinkActive = true
            }
        } message: {
            Text("Starting this routine will end your current workout.")
        }
        .alert(
            "Superset requires matching set counts",
            isPresented: $showSupersetCountAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(supersetCountMessage)
        }
        .alert(
            "Can't delete while an active workout is using it",
            isPresented: $showLockedBlockAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockedBlocks.joined(separator: "\n"))
        }
        .alert(
            "Delete Block",
            isPresented: Binding(
                get: { deletePrompt != nil },
                set: { if !$0 { deletePrompt = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deletePrompt = nil }
            Button("Delete", role: .destructive) {
                guard let id = deletePrompt?.blockID else { return }
                deletePrompt = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    deleteBlockSafely(id: id)
                }
            }
        } message: {
            Text(
                "Delete “\(deletePrompt?.title ?? "")”? This cannot be undone."
            )
        }
        .sheet(isPresented: $showAddExercise) {
            ExercisePickerSingle(exercises: allExercises) { ex in
                if let ex {
                    appendBlock(
                        isSuperset: false,
                        exercises: [ex],
                        restAfter: nil
                    )
                }
            }
        }
        .sheet(isPresented: $showAddSuperset) {
            SupersetPicker(exercises: allExercises) { picked in
                if !picked.isEmpty {
                    appendBlock(
                        isSuperset: true,
                        exercises: picked,
                        restAfter: nil
                    )
                }
            }
        }
        .onAppear(perform: normalizeRoutineModel)
    }

    // MARK: - Sections

    @ViewBuilder
    private func addSection() -> some View {
        Section("Add") {
            Button("Add Exercise") { showAddExercise = true }
                .disabled(activeGuard.isRoutineLocked(routine.id))

            Button("Add Superset") { showAddSuperset = true }
                .disabled(activeGuard.isRoutineLocked(routine.id))
        }
    }

    @ViewBuilder
    private func blocksContent() -> some View {
        if routine.blocks.isEmpty {
            emptyBlocksSection()
        } else {
            blocksSection()
        }
    }

    @ViewBuilder
    private func emptyBlocksSection() -> some View {
        Section("Blocks") {
            Text("Add an exercise or a superset.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func blocksSection() -> some View {
        Section("Blocks") {
            ForEach(sortedBlocks, id: \.id) { block in
                blockRowView(for: block)
                    .swipeActions(allowsFullSwipe: false) {
                        blockSwipeActions(for: block)
                    }

                if blockIsInvalidSuperset(block) {
                    Text("⚠️ Tap Details to set Rest after round")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 8)
                }
            }
            .onMove(perform: moveBlocks)
            .onDelete(perform: deleteBlocksFromEdit)
            .moveDisabled(activeGuard.isRoutineLocked(routine.id))
        }
    }

    /// Edit-mode delete path for the Blocks section. Routes through the same
    /// safety as swipe-to-delete: locked blocks surface the "in use" alert,
    /// non-locked blocks queue the existing confirmation dialog.
    private func deleteBlocksFromEdit(at offsets: IndexSet) {
        let blocks = sortedBlocks
        guard let first = offsets.first, first < blocks.count else { return }
        let block = blocks[first]
        if blockContainsLockedExercise(block, guard: activeGuard) {
            blockedBlocks = [blockTitle(block)]
            showLockedBlockAlert = true
            return
        }
        deletePrompt = DeletePrompt(
            blockID: block.id,
            title: blockTitle(block)
        )
    }

    // MARK: - Block Rows & Actions

    private func blockRowView(for block: RoutineBlock) -> some View {
        let isLocked = blockContainsLockedExercise(block, guard: activeGuard)
        let routineLocked = activeGuard.isRoutineLocked(routine.id)

        return BlockRow(
            title: blockTitle(block),
            details: {
                if block.isSuperset {
                    return AnyView(
                        SupersetDetailNoRest(
                            block: block,
                            isRoutineLocked: routineLocked,
                            allExercises: allExercises
                        )
                    )
                } else {
                    return AnyView(
                        RoutineBlockDetailView(
                            block: block,
                            isRoutineLocked: routineLocked
                        )
                    )
                }
            },
            locked: isLocked
        )
    }

    @ViewBuilder
    private func blockSwipeActions(for block: RoutineBlock) -> some View {
        if blockContainsLockedExercise(block, guard: activeGuard) {
            Button {
                blockedBlocks = [blockTitle(block)]
                showLockedBlockAlert = true
            } label: {
                Label("In use", systemImage: "lock.fill")
            }
            .tint(.gray)
        } else {
            Button {
                deletePrompt = DeletePrompt(
                    blockID: block.id,
                    title: blockTitle(block)
                )
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func moveBlocks(from offsets: IndexSet, to newOffset: Int) {
        guard !activeGuard.isRoutineLocked(routine.id) else { return }

        var sorted = routine.blocks.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: offsets, toOffset: newOffset)

        for (i, blk) in sorted.enumerated() {
            if let real = routine.blocks.first(where: { $0.id == blk.id }) {
                real.order = i
            }
        }
        try? ctx.save()
    }

    // MARK: - Model Normalization / Validation

    private func normalizeRoutineModel() {
        // Clean orphaned RoutineExercise objects
        for b in Array(routine.blocks) {
            for re in Array(b.exercises) {
                if re.safeExercise(in: ctx) == nil {
                    ctx.delete(re)
                }
            }
        }
        try? ctx.save()

        // Normalize supersets and non-supersets
        for b in Array(routine.blocks) {
            if b.isSuperset {
                if b.exercises.contains(where: { re in
                    re.safeExercise(in: ctx) == nil
                }) {
                    ctx.delete(b)
                    continue
                }
            } else {
                for re in Array(b.exercises) {
                    guard let ex = re.safeExercise(in: ctx) else {
                        ctx.delete(re)
                        continue
                    }

                    // Clear overrides if they exactly match defaults
                    let a = re.setTemplates.sorted { lhs, rhs in
                        if lhs.order != rhs.order {
                            return lhs.order < rhs.order
                        }
                        return lhs.persistentModelID < rhs.persistentModelID
                    }
                    let d = ex.defaultTemplates.sorted { lhs, rhs in
                        if lhs.order != rhs.order {
                            return lhs.order < rhs.order
                        }
                        return lhs.persistentModelID < rhs.persistentModelID
                    }

                    var isExactCopy = (a.count == d.count)

                    if isExactCopy {
                        for i in 0..<a.count {
                            if a[i].kind != d[i].kind {
                                isExactCopy = false
                                break
                            }
                            if a[i].targetReps != d[i].targetReps {
                                isExactCopy = false
                                break
                            }

                            let aw = a[i].targetWeight ?? 0
                            let dw = d[i].targetWeight ?? 0
                            if aw != dw {
                                isExactCopy = false
                                break
                            }

                            let ar = a[i].restSecondsAfter ?? 0
                            let dr = d[i].restSecondsAfter ?? 0
                            if ar != dr {
                                isExactCopy = false
                                break
                            }

                            let ad = a[i].durationSeconds ?? 0
                            let dd = d[i].durationSeconds ?? 0
                            if ad != dd {
                                isExactCopy = false
                                break
                            }
                        }
                    }

                    if isExactCopy && !re.setTemplates.isEmpty {
                        re.setTemplates.removeAll()
                    }
                }

                let sortedRE = b.exercises.sorted { $0.order < $1.order }
                for (i, re) in sortedRE.enumerated() {
                    re.order = i
                }
            }
        }

        // Renumber blocks
        let sortedBlocks = routine.blocks.sorted { $0.order < $1.order }
        for (i, blk) in sortedBlocks.enumerated() {
            blk.order = i
        }

        try? ctx.save()
    }

    // MARK: - Logic Helpers

    private func routineIsStartable(_ r: Routine) -> Bool {
        var hasAnyContent = false

        for block in r.blocks {
            if block.exercises.contains(where: { re in
                re.safeExercise(in: ctx) != nil
            }) {
                hasAnyContent = true
            }

            if block.isSuperset {
                guard let rr = block.supersetRoundRestSeconds, rr > 0 else {
                    return false
                }
            }
        }
        return hasAnyContent
    }

    private func blockIsInvalidSuperset(_ b: RoutineBlock) -> Bool {
        b.isSuperset && ((b.supersetRoundRestSeconds ?? 0) <= 0)
    }

    private func blockTitle(_ b: RoutineBlock) -> String {
        let names = b.exercises
            .sorted { $0.order < $1.order }
            .compactMap { re in re.safeExercise(in: ctx)?.name }

        return names.isEmpty
            ? "Deleted exercise"
            : names.joined(separator: " + ")
    }

    private func blockContainsLockedExercise(
        _ block: RoutineBlock,
        guard g: ActiveWorkoutGuard
    ) -> Bool {
        block.exercises.contains { re in
            if let ex = re.safeExercise(in: ctx) {
                return g.isLocked(ex.id)
            }
            return false
        }
    }


    private func endActiveSessionIfAny() {
        // Preserve the active workout (non-destructive override).
        if let id = activeGuard.activeWorkoutID {
            let d = FetchDescriptor<Workout>(
                predicate: #Predicate { $0.id == id }
            )
            if let w = try? ctx.fetch(d).first {
                w.completedAt = Date()
            }
        }

        // Clear persisted AppState
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)

        // Cancel rest notification + clear UserDefaults before resetting AppState,
        // while we still have the IDs needed to reconstruct the stable ID.
        var notificationIDs: [String] = []
        if let wID = activeGuard.activeWorkoutID,
            let slotID = appState.activeRestSlotID
        {
            notificationIDs.append(
                RestTimer.stableNotificationID(
                    workoutID: wID, slotID: slotID
                )
            )
        }
        RestTimer.clearPersistedStateAndNotifications(
            cancelNotificationIDs: notificationIDs
        )

        appState.workoutState = .idle
        appState.activeWorkoutID = nil
        appState.activeWorkoutStartedAt = nil
        appState.activeRestEndsAt = nil
        appState.activeRestSlotID = nil
        try? ctx.save()

        activeGuard.endSession()
    }

    @MainActor
    private func deleteBlockSafely(id: PersistentIdentifier) {
        if let idx = routine.blocks.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                _ = routine.blocks.remove(at: idx)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let d = FetchDescriptor<RoutineBlock>(
                predicate: #Predicate { $0.id == id }
            )
            if let toDelete = try? ctx.fetch(d).first {
                for re in Array(toDelete.exercises) { ctx.delete(re) }
                ctx.delete(toDelete)
            }

            let sorted = routine.blocks.sorted { $0.order < $1.order }
            for (i, blk) in sorted.enumerated() { blk.order = i }
            try? ctx.save()

            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func appendBlock(
        isSuperset: Bool,
        exercises: [Exercise],
        restAfter: Int?
    ) {
        if isSuperset {
            // Resolved count: prefer defaultTemplates, fall back to AppSettings.defaultSets
            let counts = exercises.map { ex -> Int in
                let n = ex.defaultTemplates.filter { $0.kind == .working }.count
                return n > 0 ? n : AppSettings.defaultSets
            }
            if let first = counts.first, counts.allSatisfy({ $0 == first }) {
                // OK
            } else {
                supersetCountMessage =
                    "Selected exercises have working set counts: \(counts.map(String.init).joined(separator: ", ")). All must match."
                showSupersetCountAlert = true
                return
            }
        }

        let nextOrder = (routine.blocks.map(\.order).max() ?? -1) + 1
        let res: [RoutineExercise] = exercises.enumerated().map { idx, ex in
            let re = RoutineExercise(exercise: ex, order: idx, setTemplates: [])
            ctx.insert(re)
            re.prescription = makeDefaultPrescription(isTimeBased: ex.isTimeBased, in: ctx)
            return re
        }

        let block = RoutineBlock(
            isSuperset: isSuperset,
            order: nextOrder,
            restAfterSeconds: restAfter,
            exercises: res
        )
        ctx.insert(block)
        routine.blocks.append(block)
        try? ctx.save()
    }
}

// MARK: - Decomposed subviews (Phase 11.2 + 11.3)
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
// Model helpers    → Log/Models/RoutineExercise+Helpers.swift
//                    (`safeExercise(in:)`, `resolvedTemplates(in:)`)
//
// `BlockRow` + `LockBadge` intentionally remain in this file (Phase 11.3):
// `ExercisesView.swift` already declares a file-private `LockBadge` with a
// different `.font(.dsCaption.weight(.semibold))` style. Swift disallows two
// top-level types with the same name in a module regardless of access level
// (the file-private modifier does not remove the name from module-wide
// lookup), so promoting `LockBadge` to default-internal would collide. The
// two badges are visually distinct by design and must not be merged without
// a redesign decision — see report.

// MARK: - Block Row & Lock Badge

private struct BlockRow: View {
    let title: String
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


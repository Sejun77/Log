import SwiftData
import SwiftUI

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

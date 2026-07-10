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
    // RoutineEditor owns these `@Query` values *and* is a navigation push source
    // (the "Details" block links + the `$startLinkActive` Start destination).
    // That is the same shape that froze `ExerciseDetailView` (see its `usage`
    // comment): a `@Query` invalidation re-rendering the link's source mid-push,
    // re-faulting a relationship graph during the transition, deadlocked the main
    // thread. It is safe here today only because `body` does no heavy work on
    // these queries — `allExercises` is a light name-sort and `allRoutines` is
    // read off-`body` in `commitRename`. Do NOT add heavy relationship traversal
    // or save-on-read work over these queries directly in `body`. If query-heavy
    // UI is ever needed, move it into a pure helper / value snapshot (cf.
    // `ExerciseRoutineUsage`) or a host wrapper that owns the `@Query` (cf.
    // `ExerciseDetailHost`), keeping the scan off this push-source view.
    @Query(sort: \Exercise.name) private var allExercises: [Exercise]
    @Query private var allRoutines: [Routine]
    @Bindable var routine: Routine

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    // App-wide autoreg metric drives which effort target (RIR/RPE) the block
    // row subtitle shows; `.none` maps to `nil` → no effort suffix (Slice C).
    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var effortMetric: EffortMetric? {
        switch AutoregMode(rawValue: autoregModeRaw) ?? .rir {
        case .rir: return .rir
        case .rpe: return .rpe
        case .none: return nil
        }
    }

    // MARK: - State

    @State private var deletePrompt: DeletePrompt?
    @State private var showAddExercise = false
    @State private var showAddSuperset = false
    // Phase 9-B1 removed the superset working-set-count gate (the
    // alert it drove is gone too). Pre-9-A the gate read
    // `Exercise.defaultTemplates.filter { .working }.count`; post-9-A
    // every new slot gets `makeDefaultPrescription`'s AppSettings-derived
    // `sets`, so the only honest replacement value (at the moment a
    // superset is being created, before any RoutineExercise exists for
    // the candidates) is `AppSettings.defaultSets` uniformly. That makes
    // the matching-counts check trivially true for every selection —
    // i.e. an authoring guardrail loss the 9-A.5 audit acknowledged and
    // accepted, not a correctness regression.

    @State private var showLockedBlockAlert = false
    @State private var blockedBlocks: [String] = []

    @State private var showOverrideActiveAlert = false
    @State private var startLinkActive = false

    /// Bumped whenever a block's pushed Details view disappears (i.e. the user
    /// returns to the editor). Mutating this `@State` invalidates the editor
    /// body so each `blockRowView` recomputes `BlockPrescriptionSummary` and
    /// the subtitle reflects any sets/reps/rest edit made in the detail. This
    /// is a deliberate view-lifecycle trigger — NOT a nested-`@Model`
    /// observation hack — because edits to a grandchild `SlotPrescription`
    /// property are not reliably observed by `@Bindable var routine` (the same
    /// nested-@Model limitation `SupersetDetailNoRest` works around by binding
    /// each child `SlotPrescription` directly in `SupersetSetCountLabel`).
    @State private var blockSummaryRefresh = 0

    // Routine rename (Slice A). `nameDraft` is the editable buffer; the model's
    // `routine.name` is only written on a validated commit, so empty/duplicate
    // input can revert the field without ever touching persisted state.
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var showDupAlert = false
    @State private var dupName = ""

    // MARK: - Computed

    private var sortedBlocks: [RoutineBlock] {
        routine.blocks.sorted { $0.order < $1.order }
    }

    // MARK: - Body

    var body: some View {
        Form {
            routineDetailsSection()
            addSection()
            blocksContent()
        }
        .scrollDismissesKeyboard(.interactively)
        // First body pass can render block subtitles before the to-one
        // `SlotPrescription` faults are fully realized (the same grandchild
        // observation gap `blockSummaryRefresh` works around on return from a
        // detail). Bump once on appear so a legacy prescription's effort
        // (e.g. rir = 2, effortModeRaw == nil → "RIR 2") shows immediately
        // without the user having to open/edit the slot first.
        .onAppear { blockSummaryRefresh &+= 1 }
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
            ExerciseMultiPicker(exercises: allExercises) { picked in
                addExercisesAsBlocks(picked)
            }
        }
        .sheet(isPresented: $showAddSuperset) {
            ExerciseMultiPicker(exercises: allExercises) { picked in
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
        .onAppear { nameDraft = routine.name }
        .alert("Routine already exists", isPresented: $showDupAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(dupName)” already exists.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func routineDetailsSection() -> some View {
        let isLocked = activeGuard.isRoutineLocked(routine.id)
        Section {
            TextField("Routine name", text: $nameDraft)
                .font(.dsBody)
                .focused($nameFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .disabled(isLocked)
                .onSubmit { commitRename() }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitRename() }
                }
        } header: {
            Text("Routine")
        } footer: {
            if isLocked {
                Text("Renaming is disabled while this routine is in use.")
            }
        }
    }

    /// Commit the rename buffer. Trims, reverts on empty/whitespace, rejects a
    /// case-insensitive duplicate of another routine (self excluded by id), and
    /// writes only `Routine.name` on success. Never touches `Workout`
    /// snapshots / IDs or `RoutineVariant`.
    private func commitRename() {
        guard !activeGuard.isRoutineLocked(routine.id) else {
            nameDraft = routine.name
            return
        }
        let otherNames =
            allRoutines
            .filter { $0.id != routine.id }
            .map(\.name)
        switch RoutineNameValidator.validateRename(
            raw: nameDraft,
            previous: routine.name,
            otherNames: otherNames
        ) {
        case .ok(let newName):
            routine.name = newName
            nameDraft = newName
            try? ctx.save()
        case .duplicate(let attempted):
            dupName = attempted
            showDupAlert = true
            nameDraft = routine.name
        case .empty, .unchanged:
            nameDraft = routine.name
        }
    }

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

    private func blocksSection() -> some View {
        // Scan blocks → prescriptions ONCE per body (not per row). Reading
        // `blockSummaryRefresh` here ties the precompute to the recompute
        // trigger so returning from a slot's detail (which bumps it) rebuilds
        // the subtitles — the established workaround for SwiftData not
        // propagating grandchild `SlotPrescription` edits to `@Bindable routine`.
        _ = blockSummaryRefresh
        let summaries = BlockPrescriptionSummary.map(
            for: sortedBlocks, effortMetric: effortMetric
        )
        return Section("Blocks") {
            ForEach(sortedBlocks, id: \.id) { block in
                blockRowWithActions(
                    for: block, summary: summaries[block.slotID]
                )

                if blockIsInvalidSuperset(block) {
                    Label(
                        "Tap Details to set Rest after round",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.dsCaption)
                    .foregroundStyle(.orange)
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

    private func blockRowView(
        for block: RoutineBlock,
        summary: BlockPrescriptionSummary?
    ) -> some View {
        let isLocked = blockContainsLockedExercise(block, guard: activeGuard)
        let routineLocked = activeGuard.isRoutineLocked(routine.id)

        return BlockRow(
            title: blockTitle(block),
            subtitle: summary?.subtitle,
            details: {
                if block.isSuperset {
                    return AnyView(
                        SupersetDetailNoRest(
                            block: block,
                            isRoutineLocked: routineLocked,
                            allExercises: allExercises
                        )
                        // Refresh the row subtitle on return — see
                        // `blockSummaryRefresh`.
                        .onDisappear { blockSummaryRefresh &+= 1 }
                    )
                } else {
                    return AnyView(
                        RoutineBlockDetailView(
                            block: block,
                            isRoutineLocked: routineLocked
                        )
                        .onDisappear { blockSummaryRefresh &+= 1 }
                    )
                }
            },
            locked: isLocked
        )
    }

    /// Block row decorated with its swipe actions and (when the routine is not
    /// locked) a long-press **Duplicate** context menu. The context menu is the
    /// only Duplicate affordance available in Edit mode, where swipe actions are
    /// unreachable — mirroring the Saved Routines list (§2.10). It is applied
    /// conditionally (never an always-on empty menu) so it adds no long-press
    /// gesture while the routine is in use, and the row's "Details"
    /// `NavigationLink` tap is unaffected.
    @ViewBuilder
    private func blockRowWithActions(
        for block: RoutineBlock,
        summary: BlockPrescriptionSummary?
    ) -> some View {
        let row = blockRowView(for: block, summary: summary)
            .swipeActions(allowsFullSwipe: false) {
                blockSwipeActions(for: block)
            }

        if activeGuard.isRoutineLocked(routine.id) {
            row
        } else {
            row.contextMenu {
                Button {
                    duplicateBlock(block)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }
        }
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

        // Non-destructive blue Duplicate, alongside red Delete / gray In-use.
        // Gated by the routine lock because — unlike routine-level duplicate
        // (§2.10), which writes a brand-new routine — this writes a new block
        // into the *current* routine, so it follows the same lock as Add/move.
        if !activeGuard.isRoutineLocked(routine.id) {
            Button {
                duplicateBlock(block)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .tint(.blue)
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

                    // Phase 9-B1: clear Tier 1 overrides if they exactly
                    // match what the slot's prescription (Tier 2) would
                    // generate — was a comparison against
                    // `ex.defaultTemplates` (Tier 3) pre-9-B1. Only runs
                    // when the prescription has content; otherwise we'd
                    // generate against an empty/default prescription and
                    // potentially strip a slot's only template source.
                    if let p = re.prescription, p.hasContent {
                        let a = re.setTemplates.sorted { lhs, rhs in
                            if lhs.order != rhs.order {
                                return lhs.order < rhs.order
                            }
                            return lhs.persistentModelID < rhs.persistentModelID
                        }
                        let g = p.generateTemplates()
                            .sorted { $0.order < $1.order }

                        var isExactCopy = (a.count == g.count)

                        if isExactCopy {
                            for i in 0..<a.count {
                                if a[i].kind != g[i].kind {
                                    isExactCopy = false
                                    break
                                }
                                if a[i].targetReps != g[i].targetReps {
                                    isExactCopy = false
                                    break
                                }

                                let aw = a[i].targetWeight ?? 0
                                let gw = g[i].targetWeight ?? 0
                                if aw != gw {
                                    isExactCopy = false
                                    break
                                }

                                let ar = a[i].restSecondsAfter ?? 0
                                let gr = g[i].restSecondsAfter ?? 0
                                if ar != gr {
                                    isExactCopy = false
                                    break
                                }

                                let ad = a[i].durationSeconds ?? 0
                                let gd = g[i].durationSeconds ?? 0
                                if ad != gd {
                                    isExactCopy = false
                                    break
                                }
                            }
                        }

                        if isExactCopy && !re.setTemplates.isEmpty {
                            re.setTemplates.removeAll()
                        }
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
        // Logic lives on `Routine.isStartable(in:)` so the exact rule that
        // gates the Start button can be regression-tested. It no longer runs
        // any `#Predicate`/fetch (see `RoutineExercise.safeExercise(in:)`),
        // which was the source of the release/TestFlight crash on this path.
        r.isStartable(in: ctx)
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

    /// Multi-select "Add Exercise" (Slice A): add one single-exercise,
    /// non-superset block per picked exercise, in tap order, after the current
    /// max block order. Delegates to `RoutineBlockBuilder` (tested) so existing
    /// blocks are untouched, each new slot gets a unique slotID, and duplicate
    /// picks become distinct slots. Lock is already enforced at the "Add
    /// Exercise" button (the picker can't open while locked); the guard here is
    /// defense-in-depth.
    private func addExercisesAsBlocks(_ exercises: [Exercise]) {
        guard !activeGuard.isRoutineLocked(routine.id) else { return }
        RoutineBlockBuilder.addSingleExerciseBlocks(
            exercises, to: routine, in: ctx)
    }

    /// Non-destructive same-routine block duplicate (Slice 3). Deep-copies the
    /// block via the tested `RoutineBlockBuilder.duplicateBlock` so the copy
    /// lands immediately after the source and later blocks shift down. Gated by
    /// the routine lock (the UI affordances are already hidden while locked; this
    /// guard is defense-in-depth, matching `addExercisesAsBlocks`). A superset
    /// copy keeps its rest-after-round and stays valid.
    private func duplicateBlock(_ block: RoutineBlock) {
        guard !activeGuard.isRoutineLocked(routine.id) else { return }
        withAnimation {
            RoutineBlockBuilder.duplicateBlock(block, in: routine, ctx: ctx)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func appendBlock(
        isSuperset: Bool,
        exercises: [Exercise],
        restAfter: Int?
    ) {
        // Phase 9-B1 removed the superset matching-counts gate that used
        // to read `Exercise.defaultTemplates.filter { .working }.count`;
        // every new slot's prescription is seeded by
        // `makeDefaultPrescription` to AppSettings defaults below, so
        // every superset has uniform counts by construction.

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

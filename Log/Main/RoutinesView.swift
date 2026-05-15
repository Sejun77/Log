import SwiftData
import SwiftUI

// MARK: - Routines List

struct RoutinesView: View {
    @Binding var resumeNavigationTrigger: Bool

    @Environment(\.modelContext) private var ctx
    @Query(sort: \Routine.name) private var routines: [Routine]

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
            }
        } header: {
            DSSectionHeader(
                title: "Saved Routines",
                systemImage: "list.bullet"
            )
        }
    }

    // MARK: - Helpers

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

        ctx.insert(Routine(name: t, blocks: []))
        try? ctx.save()
        newName = ""
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
            .moveDisabled(activeGuard.isRoutineLocked(routine.id))
        }
    }

    // MARK: - Block Rows & Actions

    private func blockRowView(for block: RoutineBlock) -> some View {
        let isLocked = blockContainsLockedExercise(block, guard: activeGuard)

        return BlockRow(
            title: blockTitle(block),
            details: {
                if block.isSuperset {
                    return AnyView(SupersetDetailNoRest(block: block))
                } else {
                    return AnyView(RoutineBlockDetailView(block: block))
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

// MARK: - Default Prescription Factory

@discardableResult
fileprivate func makeDefaultPrescription(
    isTimeBased: Bool,
    in ctx: ModelContext
) -> SlotPrescription {
    let p = SlotPrescription()
    p.usesDuration = isTimeBased
    p.sets = AppSettings.defaultSets
    if !isTimeBased {
        p.repMin = AppSettings.defaultRepMin
        p.repMax = AppSettings.defaultRepMax
    }
    p.restSecondsBetweenSets = AppSettings.defaultRestBetweenSets
    if AppSettings.defaultRestAfterExercise > 0 {
        p.restSecondsAfterExercise = AppSettings.defaultRestAfterExercise
    }
    switch AppSettings.autoregMode {
    case .rir: p.rir = AppSettings.defaultRIR
    case .rpe: p.rpe = AppSettings.defaultRPE
    case .none: break
    }
    ctx.insert(p)
    return p
}

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

private struct SupersetPicker: View {
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

// MARK: - Detail Views

private struct RoutineBlockDetailView: View {
    @Environment(\.modelContext) private var ctx
    let block: RoutineBlock

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
                                        Text("· \(Int(w.rounded())) \(unit)")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    SlotPrescriptionSection(
                        re: re,
                        isTimeBased: ex.isTimeBased
                    )
                }
            }
        }
        .navigationTitle("Block")
    }
}

/// Detail for a Superset block:
/// - "Rest after round" is editable here (removed from block list)
/// - Lists sets for each exercise with reps & weight (no per-set rest inputs)
private struct SupersetDetailNoRest: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var block: RoutineBlock

    /// Locally-tracked displayed value for the "Sets per exercise" Stepper.
    /// Seeded lazily from the max of child prescriptions on first read, and updated
    /// explicitly on user edits. Backing this with @State (rather than a computed
    /// property over `block.exercises[i].prescription?.sets`) is required because
    /// SwiftUI's observation on `@Bindable var block` does not fire for mutations
    /// to properties of nested @Model instances (SlotPrescription.sets), so a
    /// purely-computed display value would not refresh the Stepper label after
    /// the user pressed +/-.
    @State private var displayedSets: Int? = nil

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
            } header: {
                Text("Timing")
            } footer: {
                Text("Sets per exercise applies to every exercise in this superset (one round = one set per exercise). Rest after round fires between completed rounds. Rest before next block fires after the final round, replacing round rest.")
            }

            Section {
                ForEach(block.exercises.sorted { $0.order < $1.order }) { re in
                    if let ex = re.safeExercise(in: ctx) {
                        HStack {
                            Text(ex.name)
                            Spacer()
                            Text("\(re.prescription?.sets ?? 0) sets")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .onMove(perform: moveExercises)
            } header: {
                Text("Exercises (drag to reorder)")
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
                                                "· \(Int(w.rounded())) \(unit)"
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
                        hideSetsField: true
                    )
                }
            }
        }
        .navigationTitle("Superset")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }
}

// MARK: - Warmup & Technique Editors

// WarmupSchemeEditor: add/remove/edit warmup steps for a SlotPrescription
private struct WarmupSchemeEditor: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var prescription: SlotPrescription
    @State private var showAddStep = false

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
            }
            .onDelete(perform: deleteSteps)
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

// Editor for the list of TechniquePlan entries on a SlotPrescription.
private struct TechniquePlanEditor: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var prescription: SlotPrescription
    @State private var showAdd = false
    @State private var addType: TechniqueType = .dropset

    private var sorted: [TechniquePlan] {
        prescription.techniquePlans.sorted { $0.order < $1.order }
    }

    var body: some View {
        List {
            Section {
                if prescription.techniquePlans.isEmpty {
                    Text("No techniques. Tap + to add.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sorted) { plan in
                    NavigationLink {
                        TechniqueParamEditView(
                            plan: plan,
                            siblingTechniques: sorted,
                            setCount: prescription.sets ?? 3
                        )
                    } label: {
                        TechniquePlanRow(plan: plan)
                    }
                }
                .onDelete(perform: deletePlans)
                .onMove(perform: movePlans)
            } header: {
                Text("Techniques")
            }
        }
        .navigationTitle("Techniques")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            TechniqueTypePickerSheet(
                existingTechniques: sorted,
                setCount: prescription.sets ?? 3,
                usesDuration: prescription.usesDuration,
                onPick: { t in addPlan(type: t) }
            )
        }
    }

    private func addPlan(type: TechniqueType) {
        let nextOrder = (prescription.techniquePlans.map(\.order).max() ?? -1) + 1
        let plan: TechniquePlan
        switch type {
        case .dropset:
            plan = TechniquePlan(order: nextOrder, type: type,
                                 dropPercent: 20, dropCount: 1,
                                 dropsetEffortRaw: "amrap")
        case .partialReps:
            plan = TechniquePlan(order: nextOrder, type: type,
                                 reps: 8, partialRangeNote: "top half")
        case .restPause:
            plan = TechniquePlan(order: nextOrder, type: type,
                                 restSeconds: 15, rounds: 2)
        case .cluster:
            plan = TechniquePlan(order: nextOrder, type: type,
                                 reps: 3, restSeconds: 10, rounds: 3)
        default:
            plan = TechniquePlan(order: nextOrder, type: type)
        }
        ctx.insert(plan)
        prescription.techniquePlans.append(plan)
        try? ctx.save()
    }

    private func deletePlans(at offsets: IndexSet) {
        let s = sorted
        for i in offsets {
            let plan = s[i]
            prescription.techniquePlans.removeAll { $0.id == plan.id }
            ctx.delete(plan)
        }
        for (i, p) in sorted.enumerated() { p.order = i }
        try? ctx.save()
    }

    private func movePlans(from source: IndexSet, to destination: Int) {
        var s = sorted
        s.move(fromOffsets: source, toOffset: destination)
        for (i, p) in s.enumerated() { p.order = i }
        try? ctx.save()
    }
}

// A single row summarising one TechniquePlan.
private struct TechniquePlanRow: View {
    @Bindable var plan: TechniquePlan

    private var title: String {
        switch plan.type {
        case .dropset:       return "Drop Set"
        case .partialReps:   return "Partial Reps"
        case .restPause:     return "Rest-Pause"
        case .amrap:         return "AMRAP"
        case .toFailure:     return "To Failure"
        case .cluster:       return "Cluster"
        case .tempoOverride: return "Tempo Override"
        }
    }

    private var detail: String {
        var parts: [String] = []
        let indices = plan.appliesToSetIndices
        if !indices.isEmpty {
            let nums = indices.sorted().map { String($0 + 1) }.joined(separator: ",")
            parts.append(indices.count == 1 ? "set \(nums)" : "sets \(nums)")
        } else if plan.appliesToRaw != "lastWorkingSet" {
            parts.append(plan.appliesTo.displayLabel)
        }
        if let r = plan.rounds,   r > 0  { parts.append("\(r) rounds") }
        if let r = plan.reps,     r > 0  { parts.append("\(r) reps") }
        if let d = plan.dropPercent, d > 0 { parts.append("\(Int(d))% drop") }
        if plan.type == .dropset {
            switch plan.dropsetEffort {
            case .amrap:            parts.append("AMRAP")
            case .fixedReps(let n): parts.append("\(n) reps/drop")
            }
        }
        if let s = plan.restSeconds, s > 0 { parts.append("\(s)s rest") }
        if let n = plan.note, !n.isEmpty  { parts.append(n) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.dsBody)
            if !detail.isEmpty {
                Text(detail)
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// Sheet for picking a technique type when adding a new TechniquePlan.
private struct TechniqueTypePickerSheet: View {
    var existingTechniques: [TechniquePlan]
    /// Working set count from prescription — used for per-index conflict checking.
    var setCount: Int = 3
    /// When true, rep-count-dependent techniques are disabled (not applicable to duration sets).
    var usesDuration: Bool = false
    var onPick: (TechniqueType) -> Void
    @Environment(\.dismiss) private var dismiss

    private let types: [(TechniqueType, String, String)] = [
        (.dropset,       "Drop Set",       "Reduce weight immediately after reaching failure."),
        (.partialReps,   "Partial Reps",   "Continue with partial range of motion after failure."),
        (.restPause,     "Rest-Pause",      "Short intra-set rest, then continue."),
        (.amrap,         "AMRAP",           "As many reps as possible on last set."),
        (.toFailure,     "To Failure",      "Push until technical failure."),
        (.cluster,       "Cluster",         "Intra-set pause clusters."),
        (.tempoOverride, "Tempo Override",  "Override tempo for this exercise."),
    ]

    private let intensityFinishers: Set<TechniqueType> = [.dropset, .amrap, .restPause, .cluster]
    /// Techniques that require a rep count and are not applicable to duration-based prescriptions.
    private let incompatibleForDuration: Set<TechniqueType> = [.dropset, .partialReps, .restPause, .cluster, .amrap]

    /// Effective 0-based indices for an existing technique (uses new field or migrates old).
    private func effectiveIndices(for plan: TechniquePlan) -> Set<Int> {
        let idx = plan.appliesToSetIndices   // computed on TechniquePlan
        if !idx.isEmpty { return idx }
        let n = max(1, setCount)
        switch plan.appliesTo {
        case .lastWorkingSet: return [n - 1]
        case .allWorkingSets: return Set(0..<n)
        case .setNumber(let s): return [s - 1]
        }
    }

    /// Returns a block message if adding `newType` (defaults to last set index)
    /// would create a duplicate or violate conflict rules. Returns nil if allowed.
    private func conflictMessage(for newType: TechniqueType) -> String? {
        // Duration-based prescriptions do not support rep-count-dependent techniques.
        if usesDuration && incompatibleForDuration.contains(newType) {
            return "Not available for duration-based exercises."
        }

        let defaultIdx = max(0, setCount - 1)
        let onDefault = existingTechniques.filter { effectiveIndices(for: $0).contains(defaultIdx) }

        // 1. Duplicate: same type already exists on the last set.
        if onDefault.contains(where: { $0.type == newType }) {
            return "\(newType.displayName) already exists on set \(defaultIdx + 1)."
        }

        guard intensityFinishers.contains(newType) else { return nil }

        // 2. AMRAP ↔ Dropset mutual exclusion.
        if newType == .amrap && onDefault.contains(where: { $0.type == .dropset }) {
            return "Dropset already defines AMRAP/fixed reps; remove it to use AMRAP."
        }
        if newType == .dropset && onDefault.contains(where: { $0.type == .amrap }) {
            return "Remove AMRAP first to add a Dropset."
        }

        // 3. One intensity finisher per set.
        if let other = onDefault.first(where: { intensityFinishers.contains($0.type) }) {
            return "\(other.type.displayName) already on set \(defaultIdx + 1)."
        }

        return nil
    }

    var body: some View {
        NavigationStack {
            List(types, id: \.0) { type, name, desc in
                let conflict = conflictMessage(for: type)
                Button {
                    guard conflict == nil else { return }
                    onPick(type)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.dsBody)
                            .foregroundStyle(conflict != nil ? Color.secondary : Color.primary)
                        Text(conflict ?? desc)
                            .font(.dsBodySecondary)
                            .foregroundStyle(conflict != nil ? Color.red.opacity(0.75) : Color.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .disabled(conflict != nil)
            }
            .navigationTitle("Add Technique")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// Edit parameters of an existing TechniquePlan (pushed via NavigationLink).
private struct TechniqueParamEditView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var plan: TechniquePlan
    /// All techniques on the same prescription (including self), for conflict detection.
    var siblingTechniques: [TechniquePlan] = []
    /// Working set count from the prescription (used for per-set-index UI and conflict checks).
    var setCount: Int = 3

    private let intensityFinishers: Set<TechniqueType> = [.dropset, .amrap, .restPause, .cluster]

    /// Transient error shown when a set-index toggle is blocked by a conflict.
    @State private var appliesToErrorMsg: String? = nil
    /// Transient error shown when a Dropset effort change is immediately reverted.
    @State private var effortErrorMsg: String? = nil

    // MARK: - Conflict helpers (per-index)

    /// Effective 0-based indices for a sibling technique (new field or migrated from old).
    private func effectiveIndices(for p: TechniquePlan) -> Set<Int> {
        let idx = p.appliesToSetIndices
        if !idx.isEmpty { return idx }
        let n = max(1, setCount)
        switch p.appliesTo {
        case .lastWorkingSet: return [n - 1]
        case .allWorkingSets: return Set(0..<n)
        case .setNumber(let s): return [s - 1]
        }
    }

    /// Current resolved indices for the plan being edited.
    private var currentIndices: Set<Int> {
        let idx = plan.appliesToSetIndices
        if !idx.isEmpty { return idx }
        let n = max(1, setCount)
        switch plan.appliesTo {
        case .lastWorkingSet: return [n - 1]
        case .allWorkingSets: return Set(0..<n)
        case .setNumber(let s): return [s - 1]
        }
    }

    /// Returns a conflict message if toggling `idx` on (adding it) would break rules.
    private func conflictForAdding(idx: Int) -> String? {
        let sibs = siblingTechniques.filter { $0.persistentModelID != plan.persistentModelID }
        let sibsOnIdx = sibs.filter { effectiveIndices(for: $0).contains(idx) }

        // Duplicate type on same index.
        if sibsOnIdx.contains(where: { $0.type == plan.type }) {
            return "\(plan.type.displayName) already on set \(idx + 1)."
        }
        guard intensityFinishers.contains(plan.type) else { return nil }
        // AMRAP ↔ Dropset mutual exclusion.
        if plan.type == .amrap, sibsOnIdx.contains(where: { $0.type == .dropset }) {
            return "Dropset on set \(idx + 1); can't also add AMRAP."
        }
        if plan.type == .dropset, sibsOnIdx.contains(where: { $0.type == .amrap }) {
            return "AMRAP on set \(idx + 1); remove it to add Dropset."
        }
        // One intensity finisher per set.
        if let other = sibsOnIdx.first(where: { intensityFinishers.contains($0.type) }) {
            return "\(other.type.displayName) already on set \(idx + 1)."
        }
        return nil
    }

    /// Returns a message if switching Dropset effort to `effortRaw` is blocked.
    private func conflictForEffort(_ effortRaw: String) -> String? {
        guard plan.type == .dropset, effortRaw == "fixedReps" else { return nil }
        let planIndices = currentIndices
        let amrapOverlap = siblingTechniques.contains {
            $0.persistentModelID != plan.persistentModelID
                && $0.type == .amrap
                && !effectiveIndices(for: $0).isDisjoint(with: planIndices)
        }
        return amrapOverlap ? "AMRAP exists on an overlapping set; can't use fixed reps." : nil
    }

    var body: some View {
        Form {
            appliesToSection
            techniqueParamSection
        }
        .navigationTitle(typeName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: plan.dropPercent)              { try? ctx.save() }
        .onChange(of: plan.dropCount)                { try? ctx.save() }
        .onChange(of: plan.rounds)                   { try? ctx.save() }
        .onChange(of: plan.restSeconds)              { try? ctx.save() }
        .onChange(of: plan.reps)                     { try? ctx.save() }
        .onChange(of: plan.partialRangeNote)         { try? ctx.save() }
        .onChange(of: plan.note)                     { try? ctx.save() }
        .onChange(of: plan.appliesToRaw)             { try? ctx.save() }
        .onChange(of: plan.appliesToSetNumber)       { try? ctx.save() }
        .onChange(of: plan.appliesToSetIndicesRaw)   { try? ctx.save() }
        .onChange(of: plan.dropsetEffortRaw)         { try? ctx.save() }
        .onChange(of: plan.dropsetEffortReps)        { try? ctx.save() }
    }

    // MARK: - Applies-To multi-select section

    @ViewBuilder
    private var appliesToSection: some View {
        let n = max(1, setCount)
        let indices = currentIndices
        Section {
            // Quick-action row
            HStack(spacing: 0) {
                Button("All") {
                    applyIndices(Set(0..<n))
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 20)
                Button("Last") {
                    applyIndices([n - 1])
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 20)
                Button("Clear") {
                    applyIndices([])
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 2)

            // Per-set checkboxes
            ForEach(0..<n, id: \.self) { idx in
                let selected = indices.contains(idx)
                let conflict = selected ? nil : conflictForAdding(idx: idx)
                Button {
                    if let msg = conflict {
                        appliesToErrorMsg = msg
                        return
                    }
                    var next = indices
                    if selected { next.remove(idx) } else { next.insert(idx) }
                    applyIndices(next)
                } label: {
                    HStack {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color(UIColor.secondaryLabel))
                        Text("Set \(idx + 1)")
                            .foregroundStyle(conflict != nil ? .secondary : .primary)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(conflict != nil && !selected)
            }

            if let msg = appliesToErrorMsg {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.85))
            }
        } header: {
            Text("Applies to Sets")
        }
    }

    private func applyIndices(_ indices: Set<Int>) {
        plan.appliesToSetIndices = indices   // writes appliesToSetIndicesRaw via setter
        appliesToErrorMsg = nil
    }

    private var typeName: String {
        switch plan.type {
        case .dropset:       return "Drop Set"
        case .partialReps:   return "Partial Reps"
        case .restPause:     return "Rest-Pause"
        case .amrap:         return "AMRAP"
        case .toFailure:     return "To Failure"
        case .cluster:       return "Cluster"
        case .tempoOverride: return "Tempo Override"
        }
    }

    @ViewBuilder
    private var techniqueParamSection: some View {
        switch plan.type {
        case .dropset:
            Section("Drop Set") {
                Stepper(
                    "Drops: \(plan.dropCount ?? 1)",
                    value: Binding(
                        get: { plan.dropCount ?? 1 },
                        set: { plan.dropCount = $0 }
                    ),
                    in: 1...10
                )
                Stepper(
                    "Weight reduction: \(Int(plan.dropPercent ?? 20))%",
                    value: Binding(
                        get: { Int(plan.dropPercent ?? 20) },
                        set: { plan.dropPercent = Double($0) }
                    ),
                    in: 5...50,
                    step: 5
                )
                Stepper(
                    "Rest between drops: \(plan.restSeconds ?? 0)s",
                    value: Binding(
                        get: { plan.restSeconds ?? 0 },
                        set: { plan.restSeconds = $0 > 0 ? $0 : nil }
                    ),
                    in: 0...120,
                    step: 5
                )
            }
            Section("Effort Mode") {
                Picker("Effort", selection: Binding(
                    get: { plan.dropsetEffortRaw ?? "amrap" },
                    set: { v in
                        let prev = plan.dropsetEffortRaw
                        plan.dropsetEffortRaw = v
                        if v != "fixedReps" { plan.dropsetEffortReps = nil }
                        if let msg = conflictForEffort(v) {
                            plan.dropsetEffortRaw = prev
                            effortErrorMsg = msg
                        } else {
                            effortErrorMsg = nil
                        }
                    }
                )) {
                    Text("AMRAP").tag("amrap")
                    Text("Fixed reps").tag("fixedReps")
                }
                .pickerStyle(.segmented)
                if (plan.dropsetEffortRaw ?? "amrap") == "fixedReps" {
                    Stepper(
                        "Reps per drop: \(plan.dropsetEffortReps ?? 8)",
                        value: Binding(
                            get: { plan.dropsetEffortReps ?? 8 },
                            set: { plan.dropsetEffortReps = $0 }
                        ),
                        in: 1...30
                    )
                }
                if let msg = effortErrorMsg {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }
            }

        case .restPause:
            Section("Rest-Pause") {
                Stepper(
                    "Rounds: \(plan.rounds ?? 2)",
                    value: Binding(
                        get: { plan.rounds ?? 2 },
                        set: { plan.rounds = $0 }
                    ),
                    in: 1...10
                )
                Stepper(
                    "Rest: \(plan.restSeconds ?? 15)s",
                    value: Binding(
                        get: { plan.restSeconds ?? 15 },
                        set: { plan.restSeconds = $0 }
                    ),
                    in: 5...120,
                    step: 5
                )
            }

        case .cluster:
            Section("Cluster") {
                Stepper(
                    "Reps per cluster: \(plan.reps ?? 3)",
                    value: Binding(
                        get: { plan.reps ?? 3 },
                        set: { plan.reps = $0 }
                    ),
                    in: 1...20
                )
                Stepper(
                    "Clusters: \(plan.rounds ?? 3)",
                    value: Binding(
                        get: { plan.rounds ?? 3 },
                        set: { plan.rounds = $0 }
                    ),
                    in: 1...10
                )
                Stepper(
                    "Rest between clusters: \(plan.restSeconds ?? 10)s",
                    value: Binding(
                        get: { plan.restSeconds ?? 10 },
                        set: { plan.restSeconds = $0 }
                    ),
                    in: 5...120,
                    step: 5
                )
            }

        case .partialReps:
            Section("Partial Reps") {
                TextField("Range note (e.g. top half)", text: Binding(
                    get: { plan.partialRangeNote ?? "" },
                    set: { plan.partialRangeNote = $0.isEmpty ? nil : $0 }
                ))
                Stepper(
                    "Partial reps: \(plan.reps ?? 5)",
                    value: Binding(
                        get: { plan.reps ?? 5 },
                        set: { plan.reps = $0 }
                    ),
                    in: 1...30
                )
            }

        case .tempoOverride:
            Section("Tempo Override") {
                TextField("Tempo (e.g. 3-1-3-0)", text: Binding(
                    get: { plan.note ?? "" },
                    set: { plan.note = $0.isEmpty ? nil : $0 }
                ))
                .keyboardType(.numbersAndPunctuation)
                Text("Format: eccentric-pause-concentric-pause")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .amrap:
            Section("AMRAP") {
                Text("As many reps as possible on the last set. No additional parameters.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }

        case .toFailure:
            Section("To Failure") {
                Text("Push until technical failure. No additional parameters.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Prescription Editor (Phase 3.5)

private struct SlotPrescriptionSection: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var re: RoutineExercise
    let isTimeBased: Bool
    var hideRestFields: Bool = false
    var hideSetsField: Bool = false

    var body: some View {
        Section {
            if !re.setTemplates.isEmpty {
                Label(
                    "Custom set templates override prescription.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let prescription = re.prescription {
                PrescriptionFields(
                    prescription: prescription,
                    isTimeBased: isTimeBased,
                    hideRestFields: hideRestFields,
                    hideSetsField: hideSetsField
                )

                // Phase 3.5: Warmup scheme navigation
                NavigationLink {
                    WarmupSchemeEditor(prescription: prescription)
                } label: {
                    HStack {
                        Text("Warmup")
                        Spacer()
                        let count = prescription.warmupScheme?.steps.count ?? 0
                        if count > 0 {
                            Text("\(count) step\(count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Phase 3.5: Technique plans navigation
                NavigationLink {
                    TechniquePlanEditor(prescription: prescription)
                } label: {
                    HStack {
                        Text("Techniques")
                        Spacer()
                        let count = prescription.techniquePlans.count
                        if count > 0 {
                            Text("\(count) technique\(count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            TextField("Slot notes", text: slotNotesBinding, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("Prescription")
        }
        .onAppear(perform: ensurePrescription)
    }

    private var slotNotesBinding: Binding<String> {
        Binding(
            get: { re.templateNotes ?? "" },
            set: { re.templateNotes = $0.isEmpty ? nil : $0 }
        )
    }

    private func ensurePrescription() {
        if re.prescription == nil {
            re.prescription = makeDefaultPrescription(isTimeBased: isTimeBased, in: ctx)
            try? ctx.save()
        } else if let p = re.prescription, p.usesDuration != isTimeBased {
            p.usesDuration = isTimeBased
        }
    }
}

private struct PrescriptionFields: View {
    @Bindable var prescription: SlotPrescription
    let isTimeBased: Bool
    var hideRestFields: Bool = false
    var hideSetsField: Bool = false

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    var body: some View {
        if !hideSetsField {
            optionalIntStepper("Sets", keyPath: \.sets, range: 0...20)
        }

        if isTimeBased {
            optionalIntStepper("Duration min", keyPath: \.durationMinSeconds, range: 0...600, step: 15, unit: "s")
            optionalIntStepper("Duration max", keyPath: \.durationMaxSeconds, range: 0...600, step: 15, unit: "s")
        } else {
            optionalIntStepper("Rep min", keyPath: \.repMin, range: 0...50)
            optionalIntStepper("Rep max", keyPath: \.repMax, range: 0...50)
        }

        if !hideRestFields {
            optionalIntStepper("Rest between sets", keyPath: \.restSecondsBetweenSets, range: 0...600, step: 15, unit: "s", zeroLabel: "none")
            optionalIntStepper("Rest after exercise", keyPath: \.restSecondsAfterExercise, range: 0...600, step: 15, unit: "s", zeroLabel: "none")
        }

        switch autoregMode {
        case .rir:
            doubleStepperRow("RIR", active: $prescription.rir, paired: $prescription.rpe,
                             range: 0...5, step: 0.5) { 10 - $0 }
        case .rpe:
            doubleStepperRow("RPE", active: $prescription.rpe, paired: $prescription.rir,
                             range: 5...10, step: 0.5) { 10 - $0 }
        case .none:
            EmptyView()
        }

        TempoEditorView(tempo: $prescription.tempo)
    }

    private func optionalIntStepper(
        _ label: String,
        keyPath: ReferenceWritableKeyPath<SlotPrescription, Int?>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String? = nil,
        zeroLabel: String = "—"
    ) -> some View {
        let current = prescription[keyPath: keyPath] ?? 0
        let valStr = current == 0 ? zeroLabel : (unit.map { "\(current)\($0)" } ?? "\(current)")
        return Stepper(
            "\(label): \(valStr)",
            value: Binding(
                get: { prescription[keyPath: keyPath] ?? 0 },
                set: { prescription[keyPath: keyPath] = $0 == 0 ? nil : $0 }
            ),
            in: range,
            step: step
        )
    }

    /// Stepper for an optional-Double intensity field that keeps its paired counterpart in sync.
    /// On write: stores the active value and updates `paired` via `convert` (or nil if clearing).
    /// On display: shows `active` if stored; otherwise derives from `paired` via `convert`.
    private func doubleStepperRow(
        _ label: String,
        active: Binding<Double?>,
        paired: Binding<Double?>,
        range: ClosedRange<Double>,
        step: Double,
        convert: @escaping (Double) -> Double
    ) -> some View {
        let sentinel = range.lowerBound - step
        let displayValue = active.wrappedValue ?? paired.wrappedValue.map(convert)
        let formatted: (Double) -> String = { v in
            v.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(v)) : String(format: "%.1f", v)
        }
        return Stepper(
            "\(label): \(displayValue.map(formatted) ?? "—")",
            value: Binding(
                get: {
                    if let v = active.wrappedValue { return v }
                    if let pv = paired.wrappedValue { return convert(pv) }
                    return sentinel
                },
                set: { newVal in
                    let stored: Double? = newVal < range.lowerBound ? nil : newVal
                    active.wrappedValue = stored
                    paired.wrappedValue = stored.map(convert)
                }
            ),
            in: sentinel...range.upperBound,
            step: step
        )
    }
}

// MARK: - Tempo Editor

struct TempoEditorView: View {
    @Binding var tempo: String?

    @State private var eccentric: Int = 0
    @State private var stretchPause: Int = 0
    @State private var concentric: Int = 0
    @State private var squeezePause: Int = 0

    var body: some View {
        Stepper("Eccentric: \(label(eccentric))", value: $eccentric, in: 0...10)
            .onAppear { parseTempo() }
            .onChange(of: eccentric) { serializeTempo() }
        Stepper("Stretch pause: \(label(stretchPause))", value: $stretchPause, in: 0...10)
            .onChange(of: stretchPause) { serializeTempo() }
        Stepper("Concentric: \(label(concentric))", value: $concentric, in: 0...10)
            .onChange(of: concentric) { serializeTempo() }
        Stepper("Squeeze pause: \(label(squeezePause))", value: $squeezePause, in: 0...10)
            .onChange(of: squeezePause) { serializeTempo() }
        Text("Tempo = eccentric – stretch pause – concentric – squeeze pause")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func label(_ v: Int) -> String { v == 0 ? "—" : "\(v)s" }

    private func parseTempo() {
        guard let t = tempo, !t.isEmpty else {
            eccentric = 0; stretchPause = 0; concentric = 0; squeezePause = 0
            return
        }
        let parts = t.split(separator: "-").compactMap { Int($0) }
        eccentric    = parts.count > 0 ? parts[0] : 0
        stretchPause = parts.count > 1 ? parts[1] : 0
        concentric   = parts.count > 2 ? parts[2] : 0
        squeezePause = parts.count > 3 ? parts[3] : 0
    }

    private func serializeTempo() {
        let vals = [eccentric, stretchPause, concentric, squeezePause]
        tempo = vals.allSatisfy({ $0 == 0 }) ? nil
              : vals.map(String.init).joined(separator: "-")
    }
}

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

// MARK: - Safe Relationship Helpers

extension RoutineExercise {
    func safeExercise(in ctx: ModelContext) -> Exercise? {
        guard self.modelContext != nil else { return nil }
        let myID = self.id
        let descriptor = FetchDescriptor<RoutineExercise>(
            predicate: #Predicate { $0.id == myID }
        )
        return (try? ctx.fetch(descriptor).first)?.exercise
    }

    private func normalizeOrderIfNeeded(_ templates: [SetTemplate]) -> Bool {
        let n = templates.count
        guard n > 0 else { return false }

        let orders = templates.map(\.order)
        let uniqueCount = Set(orders).count
        let minOrder = orders.min() ?? 0
        let maxOrder = orders.max() ?? 0

        let needsFix =
            (uniqueCount != n) || (minOrder < 0) || (maxOrder != n - 1)
        guard needsFix else { return false }

        let repaired = templates.sorted { a, b in
            if a.kindSortKey != b.kindSortKey {
                return a.kindSortKey < b.kindSortKey
            }
            return a.persistentModelID < b.persistentModelID
        }

        for (i, t) in repaired.enumerated() {
            t.order = i
        }

        return true
    }

    func resolvedTemplates(in ctx: ModelContext) -> [SetTemplate] {
        guard let ex = safeExercise(in: ctx) else { return [] }

        // Tier 1: explicit per-set overrides
        if !setTemplates.isEmpty {
            let didFix = normalizeOrderIfNeeded(setTemplates)
            let sorted = setTemplates.sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                return a.persistentModelID < b.persistentModelID
            }
            if didFix { try? ctx.save() }
            return sorted
        }

        // Tier 2: prescription-generated
        if let p = prescription, p.hasContent {
            return p.generateTemplates()
        }

        // Tier 3: exercise defaults
        let didFix = normalizeOrderIfNeeded(ex.defaultTemplates)
        let sorted = ex.defaultTemplates.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.persistentModelID < b.persistentModelID
        }
        if didFix { try? ctx.save() }
        return sorted
    }
}

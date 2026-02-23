import SwiftData
import SwiftUI

// MARK: - Routines List

struct RoutinesView: View {
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
                    "You can’t delete “\(lockedRoutineName)” while a workout using it is active."
                )
            }
        }
    }

    // MARK: - Sections

    private var activeSessionSection: some View {
        Group {
            if let plan = activeGuard.activePlan {
                Section {
                    NavigationLink {
                        ActiveWorkoutView(plan: plan)
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
                        }
                        .padding(.vertical, 2)
                    }
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

    @FocusState private var focusedRestBlockID: PersistentIdentifier?

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
            // Top-right "Start" button
            ToolbarItemGroup(placement: .topBarTrailing) {
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

            // Keyboard "Done" button for rest textfields
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedRestBlockID = nil }
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
                    Text("⚠️ Rest after round required (> 0)")
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
            restText: restBinding(for: block),
            roundRestText: block.isSuperset
                ? roundRestBinding(for: block) : nil,
            details: {
                if block.isSuperset {
                    return AnyView(SupersetDetailNoRest(block: block))
                } else {
                    return AnyView(RoutineBlockDetailView(block: block))
                }
            },
            focusTag: block.id,
            focused: $focusedRestBlockID,
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

    private func restBinding(for block: RoutineBlock) -> Binding<String> {
        Binding<String>(
            get: {
                if let v = block.restAfterSeconds, v != 0 { return String(v) }
                return ""
            },
            set: { input in
                let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty {
                    block.restAfterSeconds = nil
                    return
                }

                if let v = Int(t), v != 0 {
                    block.restAfterSeconds = v
                } else {
                    block.restAfterSeconds = nil
                }
            }
        )
    }

    private func roundRestBinding(for block: RoutineBlock) -> Binding<String> {
        Binding<String>(
            get: {
                if let v = block.supersetRoundRestSeconds, v > 0 {
                    return String(v)
                }
                return ""
            },
            set: { input in
                let digits = input.filter(\.isNumber)
                if let v = Int(digits), v > 0 {
                    block.supersetRoundRestSeconds = v
                } else {
                    block.supersetRoundRestSeconds = nil
                }
            }
        )
    }

    private func endActiveSessionIfAny() {
        if let id = activeGuard.activeWorkoutID {
            let d = FetchDescriptor<Workout>(
                predicate: #Predicate { $0.id == id }
            )
            if let w = try? ctx.fetch(d).first {
                ctx.delete(w)
            }
        }

        // Clear persisted AppState
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
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
            let counts = exercises.map { ex in
                ex.defaultTemplates.filter { $0.kind == .working }.count
            }
            if let first = counts.first, first > 0,
                counts.allSatisfy({ $0 == first })
            {
                // OK
            } else {
                supersetCountMessage =
                    "Selected exercises have working set counts: \(counts.map(String.init).joined(separator: ", ")). All must match and be greater than 0."
                showSupersetCountAlert = true
                return
            }
        }

        let nextOrder = (routine.blocks.map(\.order).max() ?? -1) + 1
        let res: [RoutineExercise] = exercises.enumerated().map { idx, ex in
            let re = RoutineExercise(exercise: ex, order: idx, setTemplates: [])
            ctx.insert(re)
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
        ex.defaultTemplates.filter { $0.kind == .working }.count
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
/// - Displays "Rest after round (s)" as read-only info row
/// - Lists sets for each exercise with reps & weight (no per-set rest inputs)
private struct SupersetDetailNoRest: View {
    @Environment(\.modelContext) private var ctx
    let block: RoutineBlock

    private func templates(for re: RoutineExercise) -> [SetTemplate] {
        re.resolvedTemplates(in: ctx)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Rest after round")
                    Spacer()
                    if let v = block.supersetRoundRestSeconds, v > 0 {
                        Text("\(v)").monospacedDigit()
                        Text("s").foregroundStyle(.secondary)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
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
                        isTimeBased: ex.isTimeBased
                    )
                }
            }
        }
        .navigationTitle("Superset")
    }
}

// MARK: - Prescription Editor

private struct SlotPrescriptionSection: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var re: RoutineExercise
    let isTimeBased: Bool

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
                    isTimeBased: isTimeBased
                )
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
            let p = SlotPrescription()
            p.usesDuration = isTimeBased
            ctx.insert(p)
            re.prescription = p
            try? ctx.save()
        } else if let p = re.prescription, p.usesDuration != isTimeBased {
            p.usesDuration = isTimeBased
        }
    }
}

private struct PrescriptionFields: View {
    @Bindable var prescription: SlotPrescription
    let isTimeBased: Bool

    var body: some View {
        optionalIntRow("Sets", keyPath: \.sets)

        if isTimeBased {
            optionalIntRow("Duration min", keyPath: \.durationMinSeconds, unit: "s")
            optionalIntRow("Duration max", keyPath: \.durationMaxSeconds, unit: "s")
        } else {
            optionalIntRow("Rep min", keyPath: \.repMin)
            optionalIntRow("Rep max", keyPath: \.repMax)
        }

        optionalIntRow("Rest between sets", keyPath: \.restSecondsBetweenSets, unit: "s")

        HStack {
            Text("RIR")
            Spacer()
            TextField("—", text: optionalDoubleString(\.rir))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }

        HStack {
            Text("Tempo")
            Spacer()
            TextField("e.g. 3-1-2-0", text: optionalString(\.tempo))
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
        }
    }

    private func optionalIntRow(
        _ label: String,
        keyPath: ReferenceWritableKeyPath<SlotPrescription, Int?>,
        unit: String? = nil
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: optionalIntString(keyPath))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            if let unit {
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func optionalIntString(
        _ kp: ReferenceWritableKeyPath<SlotPrescription, Int?>
    ) -> Binding<String> {
        Binding(
            get: {
                if let v = prescription[keyPath: kp] { return String(v) }
                return ""
            },
            set: {
                let digits = $0.filter(\.isNumber)
                prescription[keyPath: kp] = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    private func optionalDoubleString(
        _ kp: ReferenceWritableKeyPath<SlotPrescription, Double?>
    ) -> Binding<String> {
        Binding(
            get: {
                if let v = prescription[keyPath: kp] {
                    return v.truncatingRemainder(dividingBy: 1) == 0
                        ? String(Int(v)) : String(v)
                }
                return ""
            },
            set: {
                let cleaned = $0.filter { $0.isNumber || $0 == "." }
                prescription[keyPath: kp] = cleaned.isEmpty ? nil : Double(cleaned)
            }
        )
    }

    private func optionalString(
        _ kp: ReferenceWritableKeyPath<SlotPrescription, String?>
    ) -> Binding<String> {
        Binding(
            get: { prescription[keyPath: kp] ?? "" },
            set: { prescription[keyPath: kp] = $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - Block Row & Lock Badge

private struct BlockRow: View {
    let title: String
    @Binding var restText: String
    var roundRestText: Binding<String>? = nil
    let details: () -> AnyView
    let focusTag: PersistentIdentifier
    let focused: FocusState<PersistentIdentifier?>.Binding
    var locked: Bool = false
    @State private var restDraft: String = ""

    private var timerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rest after block")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    TextField("Rest", text: $restDraft)
                        .onAppear {
                            restDraft = restText
                        }
                        .onChange(of: restText) { _, newValue in
                            if focused.wrappedValue != focusTag {
                                restDraft = newValue
                            }
                        }
                        .onChange(of: restDraft) { _, newValue in
                            let sanitized = sanitizeSignedInt(newValue)

                            if sanitized != newValue {
                                restDraft = sanitized
                                return
                            }

                            if sanitized.isEmpty {
                                restText = ""  // clears model via restBinding
                            } else if sanitized == "-" {
                                return
                            } else if Int(sanitized) != nil {
                                restText = sanitized
                            }
                        }
                        .onSubmit {
                            if restDraft == "-" {
                                restDraft = ""
                                restText = ""
                            }
                        }
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(width: 120, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .focused(focused, equals: focusTag)
                        .submitLabel(.done)
                        #if DEBUG
                            .probe("BlockRow.RestField")
                        #endif

                    Text("s").foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                NavigationLink("Details", destination: details())
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .onChange(of: focused.wrappedValue) { _, newFocus in
                if newFocus != focusTag, restDraft == "-" {
                    restDraft = ""
                    restText = ""
                }
            }
        }
    }

    private var roundTimerRow: some View {
        Group {
            if let rr = roundRestText {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rest after round")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "timer")
                            .foregroundStyle(.secondary)

                        HStack(spacing: 4) {
                            TextField("Rest", text: rr)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 120, alignment: .trailing)
                                .multilineTextAlignment(.trailing)
                                .focused(focused, equals: focusTag)
                                .submitLabel(.done)

                            Text("s").foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sanitizeSignedInt(_ raw: String) -> String {
        if raw == "-" { return "-" }

        var result = ""
        var hasSign = false
        var hasDigit = false

        for (i, ch) in raw.enumerated() {
            if ch == "-" {
                if i == 0 && !hasSign && !hasDigit {
                    result.append(ch)
                    hasSign = true
                }
                continue
            }

            if ch.isNumber {
                result.append(ch)
                hasDigit = true
                continue
            }
        }

        if hasSign {
            result = result.replacingOccurrences(of: "-", with: "")
            return "-" + result
        }
        return result

    }

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

            timerRow
            roundTimerRow
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

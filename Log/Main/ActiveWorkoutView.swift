import ActivityKit
import SwiftData
import SwiftUI
import UserNotifications

@MainActor
final class ActiveWorkoutGuard: ObservableObject {
    static let shared = ActiveWorkoutGuard()

    // Locks
    @Published private(set) var lockedExerciseIDs: Set<UUID> = []
    @Published private(set) var lockedRoutineIDs: Set<UUID> = []

    // Active session (for resume)
    @Published var activePlan: WorkoutPlan?
    @Published var activeWorkoutID: UUID?

    // 🔵 Global session timer (in-memory only)
    @Published var sessionStart: Date?

    // UI/session caches that must survive navigation away/back
    // Exercise.id -> setIndex -> tuple of text fields
    @Published var inputsCache:
        [UUID: [Int: (reps: String, weight: String, duration: String)]] = [:]

    // Exercise.id -> set indexes that are logged (UI checkmarks)
    @Published var loggedCache: [UUID: Set<Int>] = [:]

    // Exercise.id -> session notes edits
    @Published var notesCache: [UUID: String] = [:]

    // Exercises
    func lockExercises<S: Sequence>(_ ids: S) where S.Element == UUID {
        lockedExerciseIDs.formUnion(ids)
    }
    func unlockExercises<S: Sequence>(_ ids: S) where S.Element == UUID {
        lockedExerciseIDs.subtract(ids)
    }
    func isExerciseLocked(_ id: UUID) -> Bool { lockedExerciseIDs.contains(id) }
    func lock<S: Sequence>(_ ids: S) where S.Element == UUID {
        lockExercises(ids)
    }
    func unlock<S: Sequence>(_ ids: S) where S.Element == UUID {
        unlockExercises(ids)
    }
    func isLocked(_ id: UUID) -> Bool { isExerciseLocked(id) }

    // Routines
    func lockRoutine(_ id: UUID) { lockedRoutineIDs.insert(id) }
    func unlockRoutine(_ id: UUID) { lockedRoutineIDs.remove(id) }
    func isRoutineLocked(_ id: UUID) -> Bool { lockedRoutineIDs.contains(id) }

    // Session lifecycle
    func beginSession(plan: WorkoutPlan) {
        activePlan = plan
        // set once; survives view disappear/reappear
        if sessionStart == nil { sessionStart = Date() }
        lockExercises(plan.blocks.flatMap { $0.exercises.map(\.id) })
        lockRoutine(plan.routineID)
    }

    func endSession() {
        if let plan = activePlan {
            // Only routine needs to be explicitly unlocked;
            // exercises are unlocked by clearing the lock set.
            unlockRoutine(plan.routineID)
        }

        // 🔐 Fully clear all exercise locks (including swapped-in ones)
        lockedExerciseIDs.removeAll()

        activePlan = nil
        activeWorkoutID = nil
        sessionStart = nil  // 🔵 reset global timer
        inputsCache.removeAll()
        loggedCache.removeAll()
        notesCache.removeAll()
    }
}

extension Collection {
    fileprivate subscript(safe i: Index) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

struct ActiveWorkoutView: View {
    // Snapshot plan (mutable copy for this view)
    @State private var plan: WorkoutPlan

    init(plan: WorkoutPlan) {
        _plan = State(initialValue: plan)
    }

    @State private var exerciseToSwapIndex: Int? = nil
    @State private var showSwapSheet = false
    @Query(sort: \Exercise.name) private var allExercises: [Exercise]

    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    @State private var workout: Workout?
    @State private var currentBlockIndex = 0
    @State private var currentExerciseIndex = 0
    @State private var showEndConfirm = false
    @State private var showFinishConfirm = false
    @State private var loggedByExercise: [UUID: Set<Int>] = [:]
    @State private var showRestOverlay = false

    @StateObject private var setTimer = RestTimer()
    @State private var showSetOverlay = false

    @StateObject private var rest = RestTimer()

    // Cache created WorkoutItems by Exercise.id during the session
    @State private var itemsByExerciseID: [UUID: WorkoutItem] = [:]

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    @State private var inputsByExerciseID:
        [UUID: [Int: (reps: String, weight: String, duration: String)]] = [:]

    /// Apply session-edited notes only to the *current* exercises in each slot.
    /// Replaced (swapped out) exercises are not touched.
    private func persistExerciseNotesOnlyForCurrentExercises() {
        for block in plan.blocks {
            for planEx in block.exercises {
                let slotID = planEx.id
                let exerciseID = planEx.currentExerciseID
                guard let ex = fetchExercise(by: exerciseID) else { continue }

                if let text = activeGuard.notesCache[slotID] {
                    ex.notes = text.isEmpty ? nil : text
                }
            }
        }
    }

    private func ensureInputsInitializedFromPlan() {
        guard inputsByExerciseID.isEmpty else { return }
        for block in plan.blocks {
            for ex in block.exercises {
                var perSet:
                    [Int: (reps: String, weight: String, duration: String)] =
                        [:]
                for (i, tpl) in ex.templates.enumerated() {
                    perSet[i] = (
                        reps: String(tpl.targetReps),
                        weight: tpl.targetWeight.map { String($0) } ?? "",
                        duration: tpl.durationSeconds.map { String($0) } ?? ""
                    )
                }
                inputsByExerciseID[ex.id] = perSet
            }
        }
        syncToGuardCaches()
    }

    private func rehydrateFromWorkoutIfPresent() {
        guard let w = workout else { return }

        var logged = loggedByExercise
        var inputs = inputsByExerciseID

        for block in plan.blocks {
            for ex in block.exercises {
                let slotID = ex.id
                let exerciseID = ex.currentExerciseID

                // 🔒 Fix 2: if the exercise in this slot was swapped in this session,
                // do NOT pull in logs from the workout (they belong to a different exercise).
                if ex.originalExerciseID != ex.currentExerciseID {
                    continue
                }

                var perSet = inputs[slotID] ?? [:]

                let item = w.items.first(where: {
                    $0.exercise?.id == exerciseID
                })

                if let item = item {
                    let indices = item.setLogs.map(\.indexInExercise)
                    logged[slotID, default: []].formUnion(indices)
                }

                for (i, tpl) in ex.templates.enumerated() {
                    if let cached = activeGuard.inputsCache[slotID]?[i] {
                        perSet[i] = cached
                    } else if let log = item?.setLogs.last(where: {
                        $0.indexInExercise == i
                    }) {
                        let reps = String(max(0, log.reps))
                        let weight =
                            log.weight.map { String(Int($0.rounded())) } ?? ""
                        let duration =
                            log.durationSeconds.map(String.init) ?? ""
                        perSet[i] = (reps, weight, duration)
                    } else {
                        perSet[i] = (
                            reps: String(tpl.targetReps),
                            weight: tpl.targetWeight.map { String($0) } ?? "",
                            duration: tpl.durationSeconds.map { String($0) }
                                ?? ""
                        )
                    }
                }

                inputs[slotID] = perSet
            }
        }

        loggedByExercise = logged
        inputsByExerciseID = inputs
        syncToGuardCaches()
    }

    private func syncFromGuardCachesIfAny() {
        if !activeGuard.inputsCache.isEmpty {
            inputsByExerciseID = activeGuard.inputsCache
        }
        if !activeGuard.loggedCache.isEmpty {
            loggedByExercise = activeGuard.loggedCache
        }
    }

    private func syncToGuardCaches() {
        activeGuard.inputsCache = inputsByExerciseID
        activeGuard.loggedCache = loggedByExercise
    }

    private func inputBindings(
        for exercise: PlanExercise,
        setIndex: Int,
        template: PlanSetTemplate
    ) -> (Binding<String>, Binding<String>) {
        let exID = exercise.id

        func ensureEntry() {
            if inputsByExerciseID[exID] == nil {
                inputsByExerciseID[exID] = [:]
            }
            if inputsByExerciseID[exID]?[setIndex] == nil {
                inputsByExerciseID[exID]?[setIndex] = (
                    reps: String(template.targetReps),
                    weight: template.targetWeight.map { String($0) } ?? "",
                    duration: template.durationSeconds.map { String($0) } ?? ""
                )
            }
        }

        let repsB = Binding<String>(
            get: {
                // ❌ no state mutation here
                inputsByExerciseID[exID]?[setIndex]?.reps
                    ?? String(template.targetReps)
            },
            set: { newVal in
                ensureEntry()
                inputsByExerciseID[exID]?[setIndex]?.reps =
                    newVal.filter(\.isNumber)
                syncToGuardCaches()
            }
        )

        let weightB = Binding<String>(
            get: {
                inputsByExerciseID[exID]?[setIndex]?.weight
                    ?? (template.targetWeight.map { String($0) } ?? "")
            },
            set: { newVal in
                ensureEntry()
                inputsByExerciseID[exID]?[setIndex]?.weight =
                    newVal.filter(\.isNumber)
                syncToGuardCaches()
            }
        )

        return (repsB, weightB)
    }

    private func durationBinding(
        for exercise: PlanExercise,
        setIndex: Int,
        template: PlanSetTemplate
    ) -> Binding<String> {
        let exID = exercise.id

        func ensureEntry() {
            if inputsByExerciseID[exID] == nil {
                inputsByExerciseID[exID] = [:]
            }
            if inputsByExerciseID[exID]?[setIndex] == nil {
                inputsByExerciseID[exID]?[setIndex] = (
                    reps: String(template.targetReps),
                    weight: template.targetWeight.map { String($0) } ?? "",
                    duration: template.durationSeconds.map { String($0) } ?? ""
                )
            }
        }

        return Binding<String>(
            get: {
                inputsByExerciseID[exID]?[setIndex]?.duration
                    ?? (template.durationSeconds.map { String($0) } ?? "")
            },
            set: { newVal in
                ensureEntry()
                inputsByExerciseID[exID]?[setIndex]?.duration =
                    newVal.filter(\.isNumber)
                syncToGuardCaches()
            }
        )
    }

    /// Returns true only if this set is the next one in order.
    /// - For normal blocks: all prior sets in this exercise must be logged.
    /// - For supersets: all prior sets in this exercise, **and all sets of prior exercises
    ///   in the block at this set index**, must be logged.
    private func canLogSet(
        block: PlanBlock,
        exercise: PlanExercise,
        setIndex: Int
    ) -> Bool {
        let logged = loggedByExercise[exercise.id, default: []]
        if logged.contains(setIndex) { return false }

        // 1. Within this exercise: earlier sets must be logged
        for j in 0..<setIndex {
            if !logged.contains(j) { return false }
        }

        // 2. Superset order: prior exercises at this set index must be logged first
        if block.isSuperset {
            guard
                let exIdx = block.exercises.firstIndex(where: {
                    $0.id == exercise.id
                })
            else {
                return false
            }
            for j in 0..<exIdx {
                let prevEx = block.exercises[j]
                if setIndex < prevEx.templates.count {
                    if !loggedByExercise[prevEx.id, default: []].contains(
                        setIndex
                    ) {
                        return false
                    }
                }
            }
        }

        return true
    }

    private func buildSetRow(
        block: PlanBlock,
        exercise: PlanExercise,
        idx: Int,
        template: PlanSetTemplate
    ) -> some View {
        let isLogged = loggedByExercise[exercise.id, default: []].contains(idx)
        let allowed = canLogSet(block: block, exercise: exercise, setIndex: idx)

        if exercise.isTimeBased {
            // TIME-BASED ROW
            let durB = durationBinding(
                for: exercise,
                setIndex: idx,
                template: template
            )

            return AnyView(
                TimeSetEntryRow(
                    index: idx + 1,
                    template: template,
                    isLogged: isLogged,
                    canLog: allowed,
                    duration: durB,
                    onStart: { durationSeconds in
                        setTimer.start(seconds: durationSeconds, mode: .set)
                        showSetOverlay = true
                    },
                    onLog: { durationSeconds in
                        appendTimeSetLog(
                            exerciseID: exercise.id,
                            setIndex: idx,
                            durationSeconds: durationSeconds,
                            kind: template.kind
                        )
                        var s = loggedByExercise[exercise.id, default: []]
                        s.insert(idx)
                        loggedByExercise[exercise.id] = s
                        syncToGuardCaches()

                        if let seconds = restSecondsAfterCurrentLog(
                            setIndex: idx,
                            template: template,
                            block: block,
                            exercise: exercise
                        ) {
                            rest.start(seconds: seconds)
                            showRestOverlay = true
                        } else {
                            rest.stop()
                        }
                        advanceForSupersetAfterLog(setIndex: idx, in: block)
                        UINotificationFeedbackGenerator().notificationOccurred(
                            .success
                        )
                    },
                    onUndo: {
                        undoSetLog(exerciseID: exercise.id, setIndex: idx)
                        var s = loggedByExercise[exercise.id, default: []]
                        s.remove(idx)
                        syncToGuardCaches()
                        loggedByExercise[exercise.id] = s
                        // Do not affect rest timer here; behavior mirrors reps/weight undo
                        UINotificationFeedbackGenerator().notificationOccurred(
                            .warning
                        )
                    }
                )
            )
        } else {
            // REPS/WEIGHT ROW (unchanged)
            let (repsB, weightB) = inputBindings(
                for: exercise,
                setIndex: idx,
                template: template
            )

            return AnyView(
                SetEntryRow(
                    index: idx + 1,
                    template: template,
                    isLogged: isLogged,
                    canLog: allowed,
                    reps: repsB,
                    weight: weightB,
                    onLog: { reps, weight in
                        appendSetLog(
                            exerciseID: exercise.id,
                            setIndex: idx,
                            reps: reps,
                            weight: weight,
                            kind: template.kind
                        )
                        var s = loggedByExercise[exercise.id, default: []]
                        s.insert(idx)
                        loggedByExercise[exercise.id] = s
                        syncToGuardCaches()

                        if let seconds = restSecondsAfterCurrentLog(
                            setIndex: idx,
                            template: template,
                            block: block,
                            exercise: exercise
                        ) {
                            rest.start(seconds: seconds)
                            showRestOverlay = true
                        } else {
                            rest.stop()
                        }
                        advanceForSupersetAfterLog(setIndex: idx, in: block)
                        UINotificationFeedbackGenerator().notificationOccurred(
                            .success
                        )
                    },
                    onUndo: {
                        undoSetLog(exerciseID: exercise.id, setIndex: idx)
                        rest.stop()
                        var s = loggedByExercise[exercise.id, default: []]
                        s.remove(idx)
                        loggedByExercise[exercise.id] = s
                        syncToGuardCaches()
                        UINotificationFeedbackGenerator().notificationOccurred(
                            .warning
                        )
                    }
                )
            )
        }
    }

    private func unlockAndDismiss() {
        // Fully terminate timers for this workout
        rest.stop()
        setTimer.stop()

        // End the Live Activity (force remove widget)
        rest.endLiveActivityForWorkout()

        // Clear session locks and dismiss screen
        activeGuard.endSession()
        dismiss()
    }

    @State private var now = Date()
    private let sessionTicker =
        Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()

    private var sessionElapsedString: String {
        guard let start = activeGuard.sessionStart else { return "00:00" }
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func fetchWorkout(by id: UUID) -> Workout? {
        let d = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
        return (try? ctx.fetch(d))?.first
    }

    private var planExerciseIDs: [UUID] {
        plan.blocks.flatMap { $0.exercises.map(\.id) }
    }

    private var currentBlock: PlanBlock? {
        plan.blocks[safe: currentBlockIndex]
    }
    private var currentExercise: PlanExercise? {
        currentBlock?.exercises[safe: currentExerciseIndex]
    }

    private func blockTitleText(for block: PlanBlock, currentIndex: Int) -> Text
    {
        let sep = block.isSuperset ? " + " : ", "
        var result = Text("")

        for (i, ex) in block.exercises.enumerated() {
            if i > 0 { result = result + Text(sep) }
            if i == currentIndex {
                result = result + Text(ex.name).fontWeight(.bold)
            } else {
                result = result + Text(ex.name)
            }
        }
        return result
    }

    private func notesBinding(for exercise: PlanExercise) -> Binding<String> {
        let slotID = exercise.id
        let exerciseID = exercise.currentExerciseID

        return Binding<String>(
            get: {
                activeGuard.notesCache[slotID]
                    ?? (fetchExercise(by: exerciseID)?.notes ?? "")
            },
            set: { newValue in
                activeGuard.notesCache[slotID] = newValue
            }
        )
    }

    // MARK: - Planned Prescription Display

    /// Compact read-only section showing the planned prescription snapshot
    /// captured at plan creation time (not the live template).
    @ViewBuilder
    private func plannedSection(for exercise: PlanExercise) -> some View {
        let snap = exercise.prescriptionSnapshot
        let notes = exercise.templateNotesSnapshot
        let hasSnap = snap != nil
        let hasNotes = notes != nil && !(notes?.isEmpty ?? true)

        if hasSnap || hasNotes {
            Section("Planned") {
                if let snap {
                    if snap.usesDuration {
                        if let dMin = snap.durationMinSeconds,
                            let dMax = snap.durationMaxSeconds, dMin != dMax
                        {
                            plannedRow("Duration", "\(dMin)–\(dMax)s")
                        } else if let d = snap.durationMaxSeconds
                            ?? snap.durationMinSeconds
                        {
                            plannedRow("Duration", "\(d)s")
                        }
                    } else {
                        if let rMin = snap.repMin, let rMax = snap.repMax,
                            rMin != rMax
                        {
                            plannedRow("Reps", "\(rMin)–\(rMax)")
                        } else if let r = snap.repMax ?? snap.repMin {
                            plannedRow("Reps", "\(r)")
                        }
                    }

                    if let sets = snap.sets {
                        plannedRow("Sets", "\(sets)")
                    }

                    if let rest = snap.restSecondsBetweenSets, rest > 0 {
                        plannedRow("Rest", "\(rest)s")
                    }

                    if let tempo = snap.tempo, !tempo.isEmpty {
                        plannedRow("Tempo", tempo)
                    }

                    if let rir = snap.rir {
                        plannedRow(
                            "RIR",
                            rir.truncatingRemainder(dividingBy: 1) == 0
                                ? "\(Int(rir))" : String(format: "%.1f", rir)
                        )
                    }

                    if let rpe = snap.rpe {
                        plannedRow(
                            "RPE",
                            rpe.truncatingRemainder(dividingBy: 1) == 0
                                ? "\(Int(rpe))" : String(format: "%.1f", rpe)
                        )
                    }
                }

                if let notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func plannedRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - Body

    var body: some View {
        if let block = currentBlock, let exercise = currentExercise {
            VStack(spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.routineName)
                        .font(.dsBody.weight(.semibold))

                    Text(
                        "Block \(currentBlockIndex + 1) of \(plan.blocks.count)"
                    )
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)

                    blockTitleText(
                        for: block,
                        currentIndex: currentExerciseIndex
                    )
                    .font(.dsBody)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                List {
                    // --- Editable notes in workout view ---
                    Section("Notes") {
                        TextField(
                            "Notes",
                            text: notesBinding(for: exercise)
                        )
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                    }

                    Section("Actions") {
                        Button {
                            exerciseToSwapIndex = currentExerciseIndex
                            showSwapSheet = true
                        } label: {
                            Label(
                                "Switch Exercise",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                    }

                    // --- Planned prescription (from snapshot) ---
                    plannedSection(for: exercise)

                    // --- Sets section ---
                    Section {
                        ForEach(
                            Array(exercise.templates.enumerated()),
                            id: \.1.id
                        ) { (idx, t) in
                            buildSetRow(
                                block: block,
                                exercise: exercise,
                                idx: idx,
                                template: t
                            )
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            // progress hint only
                            let loggedCount = loggedByExercise[
                                exercise.id,
                                default: []
                            ].count
                            Text(
                                "Logged \(loggedCount)/\(exercise.templates.count) sets"
                            )
                            .font(.dsBody)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil,
                                from: nil,
                                for: nil
                            )
                        }
                    }
                }

                // Controls
                HStack {
                    Button {
                        prev()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(
                        currentBlockIndex == 0 && currentExerciseIndex == 0
                    )

                    Spacer()

                    Button {
                        next()
                    } label: {
                        if isAtLast(block: block) {
                            Label("Finish", systemImage: "checkmark")
                        } else {
                            Label("Next", systemImage: "chevron.right")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .fullScreenCover(isPresented: $showRestOverlay) {
                RestOverlayScreen(
                    title: "Rest",
                    remaining: rest.remaining,
                    total: rest.total,
                    onClose: { showRestOverlay = false }
                )
            }
            .onChange(of: rest.isRunning) { _, running in
                showRestOverlay = running
            }
            .fullScreenCover(isPresented: $showSetOverlay) {
                // Reuse overlay view; label says "Set"
                RestOverlayScreen(
                    title: "Duration",
                    remaining: setTimer.remaining,
                    total: setTimer.total,
                    onClose: { showSetOverlay = false }
                )
            }
            .onChange(of: setTimer.isRunning) { _, running in
                showSetOverlay = running
                // When the set timer stops (hits zero), auto-complete the current running time-based set.
                if !running {
                    // We don't know which row started it; onStart closure passes onAutoComplete instead.
                    // This onChange ensures overlay hides even if user navigated quickly.
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)  // hide back while in workout
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showEndConfirm = true
                    } label: {
                        Label("End", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                ToolbarItem(placement: .principal) {
                    if setTimer.isRunning {
                        Text("Duration: \(setTimer.remaining)s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if rest.isRunning {
                        Text("Rest: \(rest.remaining)s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(sessionElapsedString)
                        .font(.dsBody.monospacedDigit())
                        .accessibilityIdentifier("sessionElapsedTimer")
                }
            }
            .alert("End workout?", isPresented: $showEndConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("End Workout", role: .destructive) {
                    if let w = workout {
                        ctx.delete(w)
                        try? ctx.save()
                    }
                    unlockAndDismiss()
                }
            }
            .confirmationDialog(
                "Apply changes?",
                isPresented: $showFinishConfirm,
                titleVisibility: .visible
            ) {
                Button("Finish (this workout only)") {
                    finishWorkout(applySwaps: false, applyNotes: false)
                }

                if hasSwapsPending {
                    Button("Finish + Update routine template") {
                        finishWorkout(applySwaps: true, applyNotes: false)
                    }
                }

                if hasNotesPending {
                    Button("Finish + Update exercise notes") {
                        finishWorkout(applySwaps: false, applyNotes: true)
                    }
                }

                if hasSwapsPending && hasNotesPending {
                    Button("Finish + Apply both") {
                        finishWorkout(applySwaps: true, applyNotes: true)
                    }
                }

                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                Task {
                    await AppNotificationService.requestAuthorizationIfNeeded()
                }
                activeGuard.beginSession(plan: plan)
                rest.ensureActivityStartedForSession()
                rest.resumeIfScheduled()
                rest.syncNow()

                // 1) mirror caches (if returning)
                syncFromGuardCachesIfAny()
                // 2) if still empty, seed from plan
                ensureInputsInitializedFromPlan()
                // 3) now rehydrate from existing workout logs (so logged checkmarks & fields match reality)
                rehydrateFromWorkoutIfPresent()

                // Reuse an existing Workout if we have one; else create once
                if let id = activeGuard.activeWorkoutID,
                    let existing = fetchWorkout(by: id)
                {
                    self.workout = existing
                } else if workout == nil {
                    let w = Workout(
                        date: .now,
                        routineName: plan.routineName,
                        items: [],
                        notes: nil
                    )
                    ctx.insert(w)
                    try? ctx.save()
                    workout = w
                    activeGuard.activeWorkoutID = w.id
                }
                // ensure overlay shows if a rest is already running in background
                showRestOverlay = rest.isRunning
            }
            .onReceive(sessionTicker) { now = $0 }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didBecomeActiveNotification
                )
            ) { _ in
                rest.handleLifecycleDidBecomeActive()
                rest.ensureActivityStartedForSession()
                rest.syncNow()
                showRestOverlay = rest.isRunning
            }
            .task {
                await AppNotificationService.requestAuthorizationIfNeeded()
            }
            .sheet(isPresented: $showSwapSheet) {
                if let idx = exerciseToSwapIndex,
                    let block = currentBlock
                {

                    let planEx = block.exercises[idx]

                    ExercisePickerSingle(exercises: allExercises) { picked in
                        if let newEx = picked {
                            swapExercise(planExercise: planEx, with: newEx)
                        }
                        showSwapSheet = false
                        exerciseToSwapIndex = nil
                    }
                }
            }
        } else {
            #if DEBUG
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(
                        .largeTitle
                    )
                    Text("Workout data changed").font(.headline)
                    Text("Some items were removed from the routine.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Exit Workout") { unlockAndDismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .navigationBarBackButtonHidden(true)
            #else
                // In production, just exit cleanly if we ever hit this (should be unreachable).
                Color.clear.onAppear { unlockAndDismiss() }
            #endif
        }
    }

    // MARK: - Navigation

    private func next() {
        let exCount = plan.blocks[safe: currentBlockIndex]?.exercises.count ?? 0
        if currentExerciseIndex < max(0, exCount - 1) {
            currentExerciseIndex += 1
        } else if currentBlockIndex < plan.blocks.count - 1 {
            currentBlockIndex += 1
            currentExerciseIndex = 0
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if hasSwapsPending || hasNotesPending {
                showFinishConfirm = true
            } else {
                finishWorkout(applySwaps: false, applyNotes: false)
            }
        }
    }

    // MARK: - Finish helpers

    private var hasSwapsPending: Bool {
        plan.blocks.flatMap(\.exercises).contains {
            $0.originalExerciseID != $0.currentExerciseID
        }
    }

    private var hasNotesPending: Bool {
        for block in plan.blocks {
            for planEx in block.exercises {
                let slotID = planEx.id
                let exerciseID = planEx.currentExerciseID
                guard let cached = activeGuard.notesCache[slotID] else { continue }
                let current = fetchExercise(by: exerciseID)?.notes
                let cachedNormalized: String? = cached.isEmpty ? nil : cached
                if cachedNormalized != current { return true }
            }
        }
        return false
    }

    private func finishWorkout(applySwaps: Bool, applyNotes: Bool) {
        if applySwaps { applyExerciseSwapsToRoutine() }
        if applyNotes { persistExerciseNotesOnlyForCurrentExercises() }
        try? ctx.save()
        unlockAndDismiss()
    }

    /// Persist exercise defaults based on what was actually logged in this Workout.
    /// Only updates exercises that are still present in the final plan
    /// (by currentExerciseID) so swapped-out exercises are never touched.
    /// Uses the *ordered* templates so set index matches what the user saw/logged.
    private func persistDefaultsOnlyForCurrentExercises() {
        guard let w = workout else { return }

        let activeExerciseIDs = Set(
            plan.blocks.flatMap { $0.exercises.map(\.currentExerciseID) }
        )

        for item in w.items {
            guard let ex = item.exercise else { continue }

            guard activeExerciseIDs.contains(ex.id) else { continue }

            let sortedDefaults = ex.defaultTemplates.sorted {
                $0.order < $1.order
            }

            let logsByIndex = Dictionary(
                grouping: item.setLogs,
                by: { $0.indexInExercise }
            )

            for (idx, logs) in logsByIndex {
                guard idx >= 0 && idx < sortedDefaults.count else { continue }
                guard let last = logs.last else { continue }

                let tpl = sortedDefaults[idx]

                if ex.isTimeBased {
                    if let dur = last.durationSeconds {
                        tpl.durationSeconds = dur
                    }
                } else {
                    tpl.targetReps = max(0, last.reps)
                    tpl.targetWeight = last.weight
                }
            }
        }
    }

    private func swapExercise(planExercise: PlanExercise, with newEx: Exercise)
    {
        // 1) Locate slot
        guard
            let blockIndex = plan.blocks.firstIndex(where: {
                $0.exercises.contains(where: { $0.id == planExercise.id })
            }),
            let exIndex = plan.blocks[blockIndex].exercises.firstIndex(where: {
                $0.id == planExercise.id
            })
        else { return }

        let oldExerciseID = plan.blocks[blockIndex].exercises[exIndex]
            .currentExerciseID

        // 2) New templates from newEx
        let base = newEx.defaultTemplates.sorted { $0.order < $1.order }

        let newTemplates = base.enumerated().map { (i, tpl) in
            PlanSetTemplate(
                id: "\(newEx.id.uuidString)-set\(i)",
                kind: tpl.kind,
                targetReps: tpl.targetReps,
                targetWeight: tpl.targetWeight.map { Int($0.rounded()) },
                restSecondsAfter: tpl.restSecondsAfter,
                durationSeconds: tpl.durationSeconds
            )
        }

        // 3) Replace PlanExercise fields
        plan.blocks[blockIndex].exercises[exIndex].currentExerciseID = newEx.id
        plan.blocks[blockIndex].exercises[exIndex].name = newEx.name
        plan.blocks[blockIndex].exercises[exIndex].templates = newTemplates
        plan.blocks[blockIndex].exercises[exIndex].isTimeBased =
            newEx.isTimeBased

        // 4) Build fresh per-set inputs for this slot from newTemplates
        let slotID = plan.blocks[blockIndex].exercises[exIndex].id

        var perSet: [Int: (reps: String, weight: String, duration: String)] =
            [:]
        for (i, tpl) in newTemplates.enumerated() {
            perSet[i] = (
                reps: String(tpl.targetReps),
                weight: tpl.targetWeight.map { String($0) } ?? "",
                duration: tpl.durationSeconds.map { String($0) } ?? ""
            )
        }

        inputsByExerciseID[slotID] = perSet
        loggedByExercise[slotID] = []

        activeGuard.inputsCache[slotID] = perSet
        activeGuard.loggedCache[slotID] = []
        // If the new exercise already has notes, start from those.
        // Otherwise remove any old cache so the binding falls back to fetchExercise(...)
        if let baseNotes = newEx.notes, !baseNotes.isEmpty {
            activeGuard.notesCache[slotID] = baseNotes
        } else {
            activeGuard.notesCache.removeValue(forKey: slotID)
        }
        syncToGuardCaches()

        // 5) Update locks
        activeGuard.unlockExercises([oldExerciseID])
        activeGuard.lockExercises([newEx.id])

        // 6) Remove any existing WorkoutItem for this slot (replaced exercise)
        if let w = workout, let oldItem = itemsByExerciseID[slotID] {
            if let idx = w.items.firstIndex(where: { $0.id == oldItem.id }) {
                w.items.remove(at: idx)
            }
        }
        itemsByExerciseID[slotID] = nil

        // 7) Create a new clean WorkoutItem for the *new* exercise
        if let w = workout {
            let newItem = WorkoutItem(exercise: newEx, setLogs: [])
            let updatedPlanEx = plan.blocks[blockIndex].exercises[exIndex]
            populateSnapshotFields(on: newItem, from: updatedPlanEx)
            w.items.append(newItem)
            itemsByExerciseID[slotID] = newItem
        }

        try? ctx.save()

        // 8) Keep global plan in guard for resume
        activeGuard.activePlan = plan
    }

    private func applyExerciseSwapsToRoutine() {
        for block in plan.blocks {
            for planEx in block.exercises {
                if planEx.originalExerciseID == planEx.currentExerciseID {
                    continue
                }

                // RoutineExercise fetch
                let routineID = planEx.routineExerciseID
                let reDescriptor = FetchDescriptor<RoutineExercise>(
                    predicate: #Predicate { $0.id == routineID }
                )
                guard let re = try? ctx.fetch(reDescriptor).first else {
                    continue
                }

                // Exercise fetch: MUST bind planEx.currentExerciseID FIRST
                let targetID = planEx.currentExerciseID

                let newExDescriptor = FetchDescriptor<Exercise>(
                    predicate: #Predicate { $0.id == targetID }
                )

                guard let newEx = try? ctx.fetch(newExDescriptor).first else {
                    continue
                }

                re.exercise = newEx
            }
        }

        try? ctx.save()
    }

    private func prev() {
        if currentExerciseIndex > 0 {
            currentExerciseIndex -= 1
        } else if currentBlockIndex > 0 {
            currentBlockIndex -= 1
            let exCount =
                plan.blocks[safe: currentBlockIndex]?.exercises.count ?? 0
            currentExerciseIndex = max(0, exCount - 1)
        }
    }

    // MARK: - Logging

    private func appendSetLog(
        exerciseID slotID: UUID,
        setIndex: Int,
        reps: Int,
        weight: Int?,
        kind: SetKind
    ) {
        guard let workout else { return }

        // Ensure we have a WorkoutItem for this *slot*.
        if itemsByExerciseID[slotID] == nil {
            guard
                let planEx = plan.blocks.flatMap(\.exercises).first(where: {
                    $0.id == slotID
                }),
                let ex = fetchExercise(by: planEx.currentExerciseID)
            else { return }

            let newItem = WorkoutItem(exercise: ex, setLogs: [])
            populateSnapshotFields(on: newItem, from: planEx)
            workout.items.append(newItem)
            itemsByExerciseID[slotID] = newItem
        }

        guard let wi = itemsByExerciseID[slotID] else { return }

        if let j = wi.setLogs.firstIndex(where: {
            $0.indexInExercise == setIndex
        }) {
            wi.setLogs[j].reps = reps
            wi.setLogs[j].weight = weight.map(Double.init)
            wi.setLogs[j].kindRaw = kind.rawValue
            wi.setLogs[j].timestamp = .now
        } else {
            wi.setLogs.append(
                SetLog(
                    indexInExercise: setIndex,
                    kind: kind,
                    reps: reps,
                    weight: weight.map(Double.init)
                )
            )
        }
        try? ctx.save()
    }

    private func appendTimeSetLog(
        exerciseID slotID: UUID,
        setIndex: Int,
        durationSeconds: Int,
        kind: SetKind
    ) {
        guard let workout else { return }

        if itemsByExerciseID[slotID] == nil {
            guard
                let planEx = plan.blocks.flatMap(\.exercises).first(where: {
                    $0.id == slotID
                }),
                let ex = fetchExercise(by: planEx.currentExerciseID)
            else { return }
            let newItem = WorkoutItem(exercise: ex, setLogs: [])
            populateSnapshotFields(on: newItem, from: planEx)
            workout.items.append(newItem)
            itemsByExerciseID[slotID] = newItem
        }

        guard let wi = itemsByExerciseID[slotID] else { return }

        if let j = wi.setLogs.firstIndex(where: {
            $0.indexInExercise == setIndex
        }) {
            wi.setLogs[j].kindRaw = kind.rawValue
            wi.setLogs[j].reps = 0
            wi.setLogs[j].weight = nil
            wi.setLogs[j].durationSeconds = durationSeconds
            wi.setLogs[j].timestamp = .now
        } else {
            wi.setLogs.append(
                SetLog(
                    indexInExercise: setIndex,
                    kind: kind,
                    reps: 0,
                    weight: nil,
                    restSeconds: nil,
                    timestamp: .now,
                    durationSeconds: durationSeconds
                )
            )
        }
        try? ctx.save()
    }

    private func undoSetLog(exerciseID: UUID, setIndex: Int) {
        guard let wi = itemsByExerciseID[exerciseID] else { return }
        if let j = wi.setLogs.lastIndex(where: {
            $0.indexInExercise == setIndex
        }) {
            wi.setLogs.remove(at: j)
            try? ctx.save()
        }
    }

    private func isAtLast(block: PlanBlock) -> Bool {
        currentBlockIndex == plan.blocks.count - 1
            && currentExerciseIndex == max(0, block.exercises.count - 1)
    }

    /// Returns seconds of rest to start now, or nil to skip.
    /// Rules (no defaults used):
    /// • Empty rest (nil) or 0 ⇒ skip.
    /// • Before a dropset ⇒ skip.
    /// • After a dropset ⇒ use the nearest prior WORKING set's explicit rest (if any), else skip.
    /// • Supersets compute rest per “round”: wait until all exercises at this index are logged,
    ///   then apply the same rules; when combining, take the max of the explicit rests found.
    /// • Finally, if this was the *last* set/round of the block, append block.restAfterSeconds (>0) to the computed rest.
    private func restSecondsAfterCurrentLog(
        setIndex idx: Int,
        template t: PlanSetTemplate,
        block: PlanBlock,
        exercise: PlanExercise
    ) -> Int? {

        // Nearest prior WORKING set's explicit rest (>0) or nil if none
        func priorWorkingRest(in templates: [PlanSetTemplate], upTo i: Int)
            -> Int?
        {
            var j = i - 1
            while j >= 0 {
                let prev = templates[j]
                if prev.kind == .working {
                    if let r = prev.restSecondsAfter, r > 0 { return r }
                    return nil
                }
                j -= 1
            }
            return nil
        }

        var restSec: Int? = nil

        if block.isSuperset {
            // Wait for all exercises that HAVE this index to be logged
            for ex in block.exercises {
                if idx >= ex.templates.count { continue }
                if !loggedByExercise[ex.id, default: []].contains(idx) {
                    return nil
                }
            }

            // Base round rest
            if let rr = block.supersetRoundRestSeconds, rr > 0 {
                restSec = rr
            } else {
                let roundHasDrop = block.exercises.contains { ex in
                    idx < ex.templates.count
                        && ex.templates[idx].kind == .dropset
                }

                if roundHasDrop {
                    // After a dropset: derive from prior working round(s); take max of explicit rests
                    var maxSeconds = 0
                    var found = false
                    for ex in block.exercises where idx < ex.templates.count {
                        if let r = priorWorkingRest(in: ex.templates, upTo: idx)
                        {
                            maxSeconds = max(maxSeconds, r)
                            found = true
                        }
                    }
                    restSec = (found && maxSeconds > 0) ? maxSeconds : nil
                } else {
                    // Normal round: explicit rest only (no defaults); combine via max
                    var maxSeconds = 0
                    var found = false
                    for ex in block.exercises where idx < ex.templates.count {
                        if let r = ex.templates[idx].restSecondsAfter, r > 0 {
                            maxSeconds = max(maxSeconds, r)
                            found = true
                        }
                    }
                    // If the *next* round contains any dropset and there IS a next round, skip rest now
                    let hasNextRound = idx < lastRoundIndex(in: block)
                    let nextHasDrop = block.exercises.contains { ex in
                        (idx + 1) < ex.templates.count
                            && ex.templates[idx + 1].kind == .dropset
                    }
                    restSec =
                        (hasNextRound && nextHasDrop)
                        ? nil : ((found && maxSeconds > 0) ? maxSeconds : nil)
                }
            }
        } else {
            // Single exercise block
            if t.kind == .dropset {
                // After dropset: use prior working set's explicit rest (if any)
                if let r = priorWorkingRest(in: exercise.templates, upTo: idx),
                    r > 0
                {
                    restSec = r
                } else {
                    restSec = nil
                }
            } else {
                // Before dropset: skip
                if idx + 1 < exercise.templates.count,
                    exercise.templates[idx + 1].kind == .dropset
                {
                    restSec = nil
                } else if let r = t.restSecondsAfter, r > 0 {
                    restSec = r
                } else {
                    restSec = nil
                }
            }
        }

        // --- Append block rest if this was the final set/round of the block ---
        if let current = currentBlock, current.id == block.id {
            let isLastExerciseOfBlock =
                (currentExerciseIndex == block.exercises.count - 1)
            let isFinal: Bool =
                block.isSuperset
                ? (idx == lastRoundIndex(in: block)) && isLastExerciseOfBlock
                : (idx == exercise.templates.count - 1) && isLastExerciseOfBlock

            if isFinal, let extra = block.restAfterSeconds, extra != 0 {
                if let base = restSec {
                    restSec = max(0, base + extra)
                } else {
                    restSec = max(0, extra)
                }
            }
        }

        // --- Prevent rest after the very last set of the workout ---
        if let currentBlock = currentBlock {
            let isLastBlock = currentBlockIndex == plan.blocks.count - 1
            let isLastExercise =
                currentExerciseIndex == currentBlock.exercises.count - 1
            let isLastSet = idx == exercise.templates.count - 1
            if isLastBlock && isLastExercise && isLastSet {
                return nil
            }
        }

        return restSec
    }

    private func fetchExercise(by id: UUID) -> Exercise? {
        let d = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
        return try? ctx.fetch(d).first
    }

    /// Populate session snapshot fields on a WorkoutItem from its PlanExercise.
    private func populateSnapshotFields(
        on item: WorkoutItem,
        from planEx: PlanExercise
    ) {
        item.routineSlotID = planEx.routineSlotID
        item.templateNotesSnapshot = planEx.templateNotesSnapshot
        if let payload = planEx.prescriptionSnapshot {
            let snapshot = payload.toModel()
            ctx.insert(snapshot)
            item.plannedPrescriptionSnapshot = snapshot
        }
    }

    /// true iff every exercise in the block has logged set index `idx`
    private func allExercisesLogged(setIndex idx: Int, in block: PlanBlock)
        -> Bool
    {
        for ex in block.exercises {
            guard idx < ex.templates.count else { return false }
            if !loggedByExercise[ex.id, default: []].contains(idx) {
                return false
            }
        }
        return true
    }

    /// Assumes your superset safeguard ensures equal set counts across exercises.
    private func lastRoundIndex(in block: PlanBlock) -> Int {
        guard let first = block.exercises.first else { return 0 }
        return max(0, first.templates.count - 1)
    }

    /// Advance focus after logging within a superset.
    /// - Next unlogged exercise in the current round
    /// - If round finished and more rounds remain: wrap to first
    /// - If round finished and it was the last round: **stay** on current exercise
    private func advanceForSupersetAfterLog(
        setIndex idx: Int,
        in block: PlanBlock
    ) {
        guard block.isSuperset else { return }

        // 1) If any exercise hasn't logged this set index yet, go there next.
        let total = block.exercises.count
        var next = currentExerciseIndex
        for _ in 0..<total {
            next = (next + 1) % total
            let ex = block.exercises[next]
            if idx < ex.templates.count,
                !loggedByExercise[ex.id, default: []].contains(idx)
            {
                currentExerciseIndex = next
                return
            }
        }

        // 2) Everyone finished this round.
        guard allExercisesLogged(setIndex: idx, in: block) else { return }

        let lastIdx = lastRoundIndex(in: block)
        if idx < lastIdx {
            // More rounds remain → wrap to first for next round
            currentExerciseIndex = 0
        } else {
            // This was the very last set of the block → do not move focus
            // (stay on the current exercise; rest will start via your existing logic)
        }
    }
}

// MARK: - Full-screen Rest overlay (top-level)

private struct RestOverlayScreen: View {
    let title: String
    let remaining: Int
    let total: Int?  // use Int? so you can pass nil if you ever drop the bar
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 16) {
                Text(title)
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))

                Text("\(remaining)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if let t = total, t > 0 {
                    let done = max(0, min(t, t - remaining))
                    ProgressView(value: Double(done), total: Double(t))
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 240)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .transition(.opacity)
    }
}

// MARK: - UI for a single set entry

private struct SetEntryRow: View {
    @FocusState private var focusedField: Field?
    private enum Field { case reps, weight }

    let index: Int
    let template: PlanSetTemplate
    let isLogged: Bool
    let canLog: Bool
    @Binding var reps: String
    @Binding var weight: String
    var onLog: (Int, Int?) -> Void
    var onUndo: () -> Void

    init(
        index: Int,
        template: PlanSetTemplate,
        isLogged: Bool,
        canLog: Bool,
        reps: Binding<String>,
        weight: Binding<String>,
        onLog: @escaping (Int, Int?) -> Void,
        onUndo: @escaping () -> Void
    ) {
        self.index = index
        self.template = template
        self.isLogged = isLogged
        self.canLog = canLog
        self._reps = reps
        self._weight = weight
        self.onLog = onLog
        self.onUndo = onUndo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(index)")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                Text(template.kind.rawValue.capitalized)
                    .font(.dsBody.weight(.semibold))
                if isLogged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(
                        .green
                    )
                }
                Spacer()
            }

            HStack(spacing: 12) {
                TextField("Reps", text: $reps)
                    .font(.dsBody.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .disabled(isLogged)
                    .focused($focusedField, equals: .reps)

                Text("×").foregroundStyle(.secondary).fixedSize()

                TextField("Wt", text: $weight)
                    .font(.dsBody.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .disabled(isLogged)
                    .focused($focusedField, equals: .weight)

                Text(Units.weightIsKg ? "kg" : "lb")
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Spacer(minLength: 8)

                if isLogged {
                    Button("Undo") { onUndo() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Log") {
                        let r = Int(reps) ?? template.targetReps
                        let w = Int(weight)
                        onLog(r, w)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(DSColor.textInverse)
                    .disabled(!canLog)
                }
            }
            .frame(minWidth: 80)
        }
    }
}

private struct TimeSetEntryRow: View {
    @FocusState private var focused: Field?
    private enum Field { case duration }

    let index: Int
    let template: PlanSetTemplate
    let isLogged: Bool
    let canLog: Bool
    @Binding var duration: String
    var onStart: (Int) -> Void
    var onLog: (Int) -> Void
    var onUndo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(index)")
                    .font(.dsCaption)
                Text(template.kind.rawValue.capitalized)
                    .font(.dsBody.weight(.semibold))
                if isLogged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(
                        .green
                    )
                }
                Spacer()
            }

            HStack(spacing: 12) {
                TextField("Duration (s)", text: $duration)
                    .font(.dsBody.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .disabled(isLogged)
                    .focused($focused, equals: .duration)

                Spacer(minLength: 8)

                if isLogged {
                    Button("Undo") { onUndo() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Start") {
                        let d = Int(duration) ?? (template.durationSeconds ?? 0)
                        guard d > 0 else { return }
                        onStart(d)  // just runs the set timer/overlay
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canLog)

                    Button("Log") {
                        let d = Int(duration) ?? (template.durationSeconds ?? 0)
                        guard d > 0 else { return }
                        onLog(d)  // persist + trigger rest
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(DSColor.textInverse)
                    .disabled(!canLog)
                }
            }
            .frame(minWidth: 80)
        }
    }
}

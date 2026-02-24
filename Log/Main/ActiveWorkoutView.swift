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

// MARK: - Session-scoped editable plan (in-memory only)

struct SessionPlan {
    var sets: Int?
    var repMin: Int?
    var repMax: Int?
    var restSecondsBetweenSets: Int?
    var restSecondsAfterExercise: Int?
    var tempo: String?
    var rir: Double?
    var rpe: Double?
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool = false
    var slotNotes: String?

    /// Line 1: sets + rep range (or duration range)
    var primarySummary: String {
        var parts: [String] = []
        if let s = sets { parts.append("\(s) sets") }
        if usesDuration {
            if let lo = durationMinSeconds, let hi = durationMaxSeconds,
                lo != hi
            {
                parts.append("\(lo)–\(hi)s")
            } else if let d = durationMaxSeconds ?? durationMinSeconds {
                parts.append("\(d)s")
            }
        } else {
            if let lo = repMin, let hi = repMax, lo != hi {
                parts.append("\(lo)–\(hi) reps")
            } else if let r = repMax ?? repMin {
                parts.append("\(r) reps")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Line 2: rest + intensity + tempo
    var secondarySummary: String {
        var parts: [String] = []
        if let r = restSecondsBetweenSets, r > 0 { parts.append("\(r)s rest") }
        if let v = rir {
            let s = v.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(v))" : String(format: "%.1f", v)
            parts.append("RIR \(s)")
        }
        if let v = rpe {
            let s = v.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(v))" : String(format: "%.1f", v)
            parts.append("RPE \(s)")
        }
        if let t = tempo, !t.isEmpty { parts.append("Tempo \(t)") }
        return parts.joined(separator: " · ")
    }

    init() { self.usesDuration = false }

    init(from snapshot: PrescriptionSnapshotPayload, notes: String?) {
        self.sets = snapshot.sets
        self.repMin = snapshot.repMin
        self.repMax = snapshot.repMax
        self.restSecondsBetweenSets = snapshot.restSecondsBetweenSets
        self.restSecondsAfterExercise = snapshot.restSecondsAfterExercise
        self.tempo = snapshot.tempo
        self.rir = snapshot.rir
        self.rpe = snapshot.rpe
        self.durationMinSeconds = snapshot.durationMinSeconds
        self.durationMaxSeconds = snapshot.durationMaxSeconds
        self.usesDuration = snapshot.usesDuration
        self.slotNotes = notes
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
    @State private var pendingSwapNewExercise: Exercise? = nil
    @State private var showSwapPlanChoice = false
    @Query(sort: \Exercise.name) private var allExercises: [Exercise]

    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    @State private var workout: Workout?
    @State private var currentBlockIndex = 0
    @State private var currentExerciseIndex = 0
    @State private var showEndConfirm = false
    @State private var showFinishConfirm = false
    @State private var sessionPlans: [UUID: SessionPlan] = [:]
    @State private var showEditPlanSheet = false
    /// Per-set planned targets captured before opening the edit sheet.
    @State private var preEditRepStrs: [UUID: [Int: String]] = [:]
    @State private var preEditDurStrs: [UUID: [Int: String]] = [:]
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
                let setCount = effectiveSetCount(
                    for: ex, resolvedTemplates: ex.templates)
                for i in 0..<setCount {
                    let tpl =
                        ex.templates[safe: i]
                        ?? defaultTemplate(for: ex, at: i)
                    perSet[i] = (
                        reps: String(plannedRepTarget(for: ex, template: tpl)),
                        weight: tpl.targetWeight.map { String($0) } ?? "",
                        duration: plannedDurationTarget(for: ex, template: tpl)
                            .map { String($0) } ?? ""
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

                let setCount = effectiveSetCount(
                    for: ex, resolvedTemplates: ex.templates)
                for i in 0..<setCount {
                    let tpl =
                        ex.templates[safe: i]
                        ?? defaultTemplate(for: ex, at: i)
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
                            reps: String(
                                plannedRepTarget(for: ex, template: tpl)),
                            weight: tpl.targetWeight.map { String($0) } ?? "",
                            duration: plannedDurationTarget(
                                for: ex, template: tpl)
                                .map { String($0) } ?? ""
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
                    reps: String(
                        plannedRepTarget(for: exercise, template: template)),
                    weight: template.targetWeight.map { String($0) } ?? "",
                    duration: plannedDurationTarget(
                        for: exercise, template: template)
                        .map { String($0) } ?? ""
                )
            }
        }

        let repsB = Binding<String>(
            get: {
                inputsByExerciseID[exID]?[setIndex]?.reps
                    ?? String(
                        plannedRepTarget(for: exercise, template: template))
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
                    reps: String(
                        plannedRepTarget(for: exercise, template: template)),
                    weight: template.targetWeight.map { String($0) } ?? "",
                    duration: plannedDurationTarget(
                        for: exercise, template: template)
                        .map { String($0) } ?? ""
                )
            }
        }

        return Binding<String>(
            get: {
                inputsByExerciseID[exID]?[setIndex]?.duration
                    ?? (plannedDurationTarget(
                        for: exercise, template: template)
                        .map { String($0) } ?? "")
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
                if setIndex < effectiveSetCount(
                    for: prevEx, resolvedTemplates: prevEx.templates)
                {
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
                            startRestWithPersistence(seconds: seconds, slotID: exercise.routineSlotID)
                            showRestOverlay = true
                        } else {
                            rest.stop()
                            clearPersistedRestState()
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
                            startRestWithPersistence(seconds: seconds, slotID: exercise.routineSlotID)
                            showRestOverlay = true
                        } else {
                            rest.stop()
                            clearPersistedRestState()
                        }
                        advanceForSupersetAfterLog(setIndex: idx, in: block)
                        UINotificationFeedbackGenerator().notificationOccurred(
                            .success
                        )
                    },
                    onUndo: {
                        undoSetLog(exerciseID: exercise.id, setIndex: idx)
                        rest.stop()
                        clearPersistedRestState()
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

        // Clear persisted active session state
        updateAppState(to: .idle)

        // Clear session locks and dismiss screen
        activeGuard.endSession()
        dismiss()
    }

    /// Updates the persisted AppState singleton.
    private func updateAppState(to state: WorkoutLifecycleState) {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        appState.workoutState = state

        switch state {
        case .active:
            appState.activeWorkoutID = workout?.id
            appState.activeWorkoutStartedAt = activeGuard.sessionStart
        case .idle, .finished:
            appState.activeWorkoutID = nil
            appState.activeWorkoutStartedAt = nil
            appState.activeRestEndsAt = nil
            appState.activeRestSlotID = nil
        }

        try? ctx.save()
    }

    /// Builds a stable notification ID: "rest.<workoutID>.<slotID>"
    private func restNotificationID(slotID: UUID) -> String {
        let wID = workout?.id.uuidString ?? "unknown"
        return "rest.\(wID).\(slotID.uuidString)"
    }

    /// Persists rest timer state to AppState for cold-restart resume.
    private func persistRestState(endsAt: Date, slotID: UUID) {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        appState.activeRestEndsAt = endsAt
        appState.activeRestSlotID = slotID
        try? ctx.save()
    }

    /// Clears persisted rest state in AppState.
    private func clearPersistedRestState() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        appState.activeRestEndsAt = nil
        appState.activeRestSlotID = nil
        try? ctx.save()
    }

    /// Sets `rest.stableNotificationID` from persisted AppState so that
    /// `rest.resumeIfScheduled()` deduplicates correctly on cold restart.
    private func restoreStableRestID() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        if let slotID = appState.activeRestSlotID {
            rest.stableNotificationID = restNotificationID(slotID: slotID)
        }
    }

    /// Starts a rest timer with stable notification ID and persisted state.
    private func startRestWithPersistence(seconds: Int, slotID: UUID) {
        let stableID = restNotificationID(slotID: slotID)

        // Cancel the OLD slot's notification before overwriting the stable ID.
        // Without this, switching slots would orphan the old notification.
        if let oldID = rest.stableNotificationID, oldID != stableID {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [oldID])
            center.removeDeliveredNotifications(withIdentifiers: [oldID])
        }

        // Compute endsAt before rest.start() so wall-clock is consistent.
        let endsAt = Date().addingTimeInterval(TimeInterval(seconds))

        rest.stableNotificationID = stableID
        rest.start(seconds: seconds, mode: .rest)
        persistRestState(endsAt: endsAt, slotID: slotID)
    }

    /// Restores rest timer from persisted AppState on cold resume.
    /// Only called when `rest.resumeIfScheduled()` did not rehydrate
    /// (e.g. UserDefaults cleared). Exactly one notification is
    /// scheduled via `rest.start()`, which internally cancel+reschedules
    /// using the same `stableNotificationID`.
    private func resumeRestFromAppState() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        guard let endsAt = appState.activeRestEndsAt,
              let slotID = appState.activeRestSlotID
        else { return }

        let stableID = restNotificationID(slotID: slotID)
        let remaining = Int(floor(endsAt.timeIntervalSinceNow))
        if remaining > 0 {
            rest.stableNotificationID = stableID
            rest.start(seconds: remaining, mode: .rest)
            showRestOverlay = true
        } else {
            // Rest already expired — clear persisted state and cancel stale notification
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [stableID])
            center.removeDeliveredNotifications(withIdentifiers: [stableID])
            clearPersistedRestState()
        }
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

    /// Rebuild the in-memory `itemsByExerciseID` cache from the persisted
    /// workout's items. This is critical on resume so that subsequent
    /// `appendSetLog` calls find existing `WorkoutItem` objects instead
    /// of creating duplicates.
    private func rebuildItemsByExerciseID() {
        guard let w = workout else { return }
        let planSlots = plan.blocks.flatMap(\.exercises)
        for item in w.items {
            guard let ex = item.exercise else { continue }
            // Match by routineSlotID first (stable across swaps)
            if let slotID = item.routineSlotID,
               let slot = planSlots.first(where: { $0.routineSlotID == slotID })
            {
                itemsByExerciseID[slot.id] = item
            } else {
                // Fallback: match by exercise ID (pre-snapshot items)
                if let slot = planSlots.first(where: { $0.currentExerciseID == ex.id }) {
                    itemsByExerciseID[slot.id] = item
                }
            }
        }
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

    // MARK: - Session Plan

    private func initializeSessionPlans() {
        for block in plan.blocks {
            for ex in block.exercises {
                let key = ex.routineSlotID
                guard sessionPlans[key] == nil else { continue }
                if let snap = ex.prescriptionSnapshot {
                    sessionPlans[key] = SessionPlan(
                        from: snap, notes: ex.templateNotesSnapshot)
                } else {
                    var p = SessionPlan()
                    p.slotNotes = ex.templateNotesSnapshot
                    sessionPlans[key] = p
                }
            }
        }
    }

    private func sessionPlanBinding(for slotID: UUID)
        -> Binding<SessionPlan>
    {
        Binding(
            get: { sessionPlans[slotID] ?? SessionPlan() },
            set: { sessionPlans[slotID] = $0 }
        )
    }

    /// Compact plan summary row with "Edit Plan" sheet trigger.
    @ViewBuilder
    private func planSummarySection(for exercise: PlanExercise) -> some View {
        let sp = sessionPlans[exercise.routineSlotID] ?? SessionPlan()
        let line1 = sp.primarySummary
        let line2 = sp.secondarySummary
        let notes = sp.slotNotes
        let hasContent =
            !line1.isEmpty || !line2.isEmpty
                || (notes != nil && !(notes?.isEmpty ?? true))

        Section("Plan") {
            Button {
                capturePreEditTargets()
                showEditPlanSheet = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        if hasContent {
                            if !line1.isEmpty {
                                Text(line1)
                                    .font(.dsBody)
                                    .foregroundStyle(.primary)
                            }
                            if !line2.isEmpty {
                                Text(line2)
                                    .font(.dsBodySecondary)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            if let notes, !notes.isEmpty {
                                Text(notes)
                                    .font(.dsCaption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else if exercise.templates.isEmpty {
                            Text(
                                "No templates found — set your plan."
                            )
                            .font(.dsBodySecondary)
                            .foregroundStyle(.orange)
                        } else {
                            Text("No plan")
                                .font(.dsBodySecondary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "pencil.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Planned Target Resolution

    /// Resolve planned rep target: session plan → snapshot → template.
    private func plannedRepTarget(
        for exercise: PlanExercise,
        template: PlanSetTemplate
    ) -> Int {
        if let sp = sessionPlans[exercise.routineSlotID],
            let v = sp.repMax ?? sp.repMin
        { return v }
        if let snap = exercise.prescriptionSnapshot,
            let v = snap.repMax ?? snap.repMin
        { return v }
        return template.targetReps
    }

    /// Resolve planned duration target: session plan → snapshot → template.
    private func plannedDurationTarget(
        for exercise: PlanExercise,
        template: PlanSetTemplate
    ) -> Int? {
        if let sp = sessionPlans[exercise.routineSlotID],
            let v = sp.durationMaxSeconds ?? sp.durationMinSeconds
        { return v }
        if let snap = exercise.prescriptionSnapshot,
            let v = snap.durationMaxSeconds ?? snap.durationMinSeconds
        { return v }
        return template.durationSeconds
    }

    /// Resolve planned rest between sets: session plan → snapshot → nil (fall through to template).
    private func plannedRestBetweenSets(
        for exercise: PlanExercise
    ) -> Int? {
        if let sp = sessionPlans[exercise.routineSlotID],
            let v = sp.restSecondsBetweenSets, v > 0
        { return v }
        if let snap = exercise.prescriptionSnapshot,
            let v = snap.restSecondsBetweenSets, v > 0
        { return v }
        return nil
    }

    /// Effective set count for an exercise, resolving through session plan → snapshot → templates.
    private func effectiveSetCount(
        for ex: PlanExercise,
        resolvedTemplates: [PlanSetTemplate]
    ) -> Int {
        if let sp = sessionPlans[ex.routineSlotID],
            let s = sp.sets, s > 0
        { return s }
        if let snap = ex.prescriptionSnapshot,
            let s = snap.sets, s > 0
        { return s }
        return max(1, resolvedTemplates.count)
    }

    /// Lightweight default template for set indices beyond the resolved templates array.
    private func defaultTemplate(for exercise: PlanExercise, at index: Int)
        -> PlanSetTemplate
    {
        PlanSetTemplate(
            id: "\(exercise.currentExerciseID.uuidString)-extra\(index)",
            kind: .working,
            targetReps: 0,
            targetWeight: nil,
            restSecondsAfter: nil,
            durationSeconds: nil
        )
    }

    /// Snapshot current planned targets per set so we can detect user edits.
    private func capturePreEditTargets() {
        guard let exercise = currentExercise else { return }
        let key = exercise.routineSlotID
        var reps: [Int: String] = [:]
        var durs: [Int: String] = [:]
        let count = effectiveSetCount(
            for: exercise, resolvedTemplates: exercise.templates)
        for i in 0..<count {
            let tpl =
                exercise.templates[safe: i]
                ?? defaultTemplate(for: exercise, at: i)
            reps[i] = String(plannedRepTarget(for: exercise, template: tpl))
            durs[i] = plannedDurationTarget(for: exercise, template: tpl)
                .map(String.init) ?? ""
        }
        preEditRepStrs[key] = reps
        preEditDurStrs[key] = durs
    }

    /// After session plan edit, update input caches for un-modified sets only.
    private func applySessionPlanToInputs() {
        guard let exercise = currentExercise else { return }
        let slotKey = exercise.routineSlotID
        let cacheKey = exercise.id  // inputsByExerciseID key

        let oldReps = preEditRepStrs[slotKey] ?? [:]
        let oldDurs = preEditDurStrs[slotKey] ?? [:]

        let count = effectiveSetCount(
            for: exercise, resolvedTemplates: exercise.templates)
        if inputsByExerciseID[cacheKey] == nil {
            inputsByExerciseID[cacheKey] = [:]
        }
        for i in 0..<count {
            let tpl =
                exercise.templates[safe: i]
                ?? defaultTemplate(for: exercise, at: i)
            let newRep = String(
                plannedRepTarget(for: exercise, template: tpl))
            let newDur = plannedDurationTarget(for: exercise, template: tpl)
                .map(String.init) ?? ""

            if var entry = inputsByExerciseID[cacheKey]?[i] {
                // Update reps if still at old planned target or empty
                if entry.reps == (oldReps[i] ?? "") || entry.reps.isEmpty {
                    entry.reps = newRep
                }
                // Update duration if still at old planned target or empty
                if entry.duration == (oldDurs[i] ?? "") || entry.duration.isEmpty
                {
                    entry.duration = newDur
                }
                inputsByExerciseID[cacheKey]?[i] = entry
            } else {
                // New set from increased set count
                inputsByExerciseID[cacheKey]?[i] = (
                    reps: newRep,
                    weight: tpl.targetWeight.map { String($0) } ?? "",
                    duration: newDur
                )
            }
        }

        syncToGuardCaches()
        preEditRepStrs.removeValue(forKey: slotKey)
        preEditDurStrs.removeValue(forKey: slotKey)
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

                    // --- Plan summary (compact) + edit via sheet ---
                    planSummarySection(for: exercise)

                    // --- Sets section ---
                    Section {
                        let setCount = effectiveSetCount(
                            for: exercise,
                            resolvedTemplates: exercise.templates)
                        ForEach(0..<setCount, id: \.self) { idx in
                            let t =
                                exercise.templates[safe: idx]
                                ?? defaultTemplate(for: exercise, at: idx)
                            buildSetRow(
                                block: block,
                                exercise: exercise,
                                idx: idx,
                                template: t
                            )
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            let setCount = effectiveSetCount(
                                for: exercise,
                                resolvedTemplates: exercise.templates)
                            let loggedCount = loggedByExercise[
                                exercise.id,
                                default: []
                            ].count
                            Text(
                                "Logged \(loggedCount)/\(setCount) sets"
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

                if hasSessionPlanPending {
                    Button("Finish + Update slot prescription") {
                        finishWorkout(
                            applySwaps: false, applyNotes: false,
                            applySlotPrescription: true)
                    }
                }

                // Combined option when multiple categories are pending
                let pendingCount = [
                    hasSwapsPending, hasNotesPending,
                    hasSessionPlanPending,
                ].filter(\.self).count
                if pendingCount >= 2 {
                    Button("Finish + Apply all") {
                        finishWorkout(
                            applySwaps: hasSwapsPending,
                            applyNotes: hasNotesPending,
                            applySlotPrescription: hasSessionPlanPending)
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

                // Bind to existing Workout first (before rehydration reads it)
                if let id = activeGuard.activeWorkoutID,
                    let existing = fetchWorkout(by: id)
                {
                    self.workout = existing
                    rebuildItemsByExerciseID()
                } else if workout == nil {
                    let w = Workout(
                        date: .now,
                        routineName: plan.routineName,
                        routineID: plan.routineID,
                        items: [],
                        notes: nil
                    )
                    ctx.insert(w)
                    try? ctx.save()
                    workout = w
                    activeGuard.activeWorkoutID = w.id
                }

                // Restore the stable notification ID from AppState so that
                // any subsequent rest start (or stop) can cancel the
                // notification from the previous process by its stable ID.
                // resumeIfScheduled() itself does NOT reschedule — it only
                // rehydrates the timer from UserDefaults. The original
                // notification remains pending and fires naturally.
                restoreStableRestID()
                rest.resumeIfScheduled()
                rest.syncNow()

                // 0) initialize session plans from snapshots
                initializeSessionPlans()
                // 1) mirror caches (if returning)
                syncFromGuardCachesIfAny()
                // 2) if still empty, seed from plan
                ensureInputsInitializedFromPlan()
                // 3) now rehydrate from existing workout logs (so logged checkmarks & fields match reality)
                rehydrateFromWorkoutIfPresent()

                // Persist active state for cold-restart resume
                updateAppState(to: .active)

                // On cold resume, restore rest from AppState if UserDefaults
                // didn't already rehydrate it (e.g. UserDefaults cleared).
                if !rest.isRunning {
                    resumeRestFromAppState()
                }

                // ensure overlay shows if a rest is already running in background
                showRestOverlay = rest.isRunning
            }
            .onReceive(sessionTicker) { now = $0 }
            .onChange(of: rest.isRunning) { _, running in
                if !running {
                    clearPersistedRestState()
                }
            }
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
            .sheet(
                isPresented: $showSwapSheet,
                onDismiss: {
                    if pendingSwapNewExercise != nil {
                        showSwapPlanChoice = true
                    }
                }
            ) {
                if let idx = exerciseToSwapIndex,
                    let block = currentBlock
                {
                    let usedIDs = Set(
                        plan.blocks.flatMap(\.exercises)
                            .map(\.currentExerciseID))
                    let filtered = allExercises.filter {
                        !usedIDs.contains($0.id)
                    }

                    ExercisePickerSingle(exercises: filtered) { picked in
                        pendingSwapNewExercise = picked
                        showSwapSheet = false
                        if picked == nil {
                            exerciseToSwapIndex = nil
                        }
                    }
                }
            }
            .confirmationDialog(
                "Session plan for this slot",
                isPresented: $showSwapPlanChoice,
                titleVisibility: .visible
            ) {
                Button("Keep current plan") {
                    performPendingSwap(resetPlan: false)
                }
                Button("Reset plan for this slot") {
                    performPendingSwap(resetPlan: true)
                }
                Button("Cancel", role: .cancel) {
                    pendingSwapNewExercise = nil
                    exerciseToSwapIndex = nil
                }
            }
            .sheet(
                isPresented: $showEditPlanSheet,
                onDismiss: { applySessionPlanToInputs() }
            ) {
                if let exercise = currentExercise {
                    EditSessionPlanSheet(
                        plan: sessionPlanBinding(
                            for: exercise.routineSlotID))
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
            if hasSwapsPending || hasNotesPending || hasSessionPlanPending {
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

    /// True if the SessionPlan for this slot differs from the original snapshot.
    private func isSessionPlanDirty(
        for slotID: UUID,
        in exercise: PlanExercise
    ) -> Bool {
        guard let sp = sessionPlans[slotID] else { return false }

        // Build the "original" SessionPlan from the snapshot
        let original: SessionPlan
        if let snap = exercise.prescriptionSnapshot {
            original = SessionPlan(
                from: snap, notes: exercise.templateNotesSnapshot)
        } else {
            var p = SessionPlan()
            p.slotNotes = exercise.templateNotesSnapshot
            original = p
        }

        // Normalize empty strings to nil for text fields
        func norm(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s
        }

        if sp.sets != original.sets { return true }
        if sp.repMin != original.repMin { return true }
        if sp.repMax != original.repMax { return true }
        if sp.restSecondsBetweenSets != original.restSecondsBetweenSets {
            return true
        }
        if sp.restSecondsAfterExercise != original.restSecondsAfterExercise {
            return true
        }
        if sp.durationMinSeconds != original.durationMinSeconds { return true }
        if sp.durationMaxSeconds != original.durationMaxSeconds { return true }
        if sp.usesDuration != original.usesDuration { return true }
        if sp.rir != original.rir { return true }
        if sp.rpe != original.rpe { return true }
        if norm(sp.tempo) != norm(original.tempo) { return true }
        if norm(sp.slotNotes) != norm(original.slotNotes) { return true }

        return false
    }

    private var hasSessionPlanPending: Bool {
        for block in plan.blocks {
            for ex in block.exercises {
                if isSessionPlanDirty(
                    for: ex.routineSlotID, in: ex)
                { return true }
            }
        }
        return false
    }

    private func finishWorkout(
        applySwaps: Bool,
        applyNotes: Bool,
        applySlotPrescription: Bool = false
    ) {
        if applySwaps { applyExerciseSwapsToRoutine() }
        if applyNotes { persistExerciseNotesOnlyForCurrentExercises() }
        if applySlotPrescription { applySessionPlansToSlotPrescriptions() }

        // Mark the workout as completed (single point of truth for all finish paths).
        workout?.completedAt = Date()

        try? ctx.save()
        unlockAndDismiss()
    }

    /// Write dirty SessionPlan fields back to the corresponding
    /// RoutineExercise.prescription + templateNotes.
    /// Only called when the user explicitly chooses "Update slot prescription".
    private func applySessionPlansToSlotPrescriptions() {
        for block in plan.blocks {
            for ex in block.exercises {
                let slotID = ex.routineSlotID
                guard isSessionPlanDirty(for: slotID, in: ex) else { continue }
                guard let sp = sessionPlans[slotID] else { continue }

                // Fetch the RoutineExercise by slotID
                let descriptor = FetchDescriptor<RoutineExercise>(
                    predicate: #Predicate { $0.slotID == slotID }
                )
                guard let re = try? ctx.fetch(descriptor).first else {
                    continue
                }

                // Ensure prescription exists
                if re.prescription == nil {
                    let p = SlotPrescription()
                    ctx.insert(p)
                    re.prescription = p
                }
                guard let rx = re.prescription else { continue }

                // Copy SessionPlan fields → SlotPrescription
                rx.sets = sp.sets
                rx.repMin = sp.repMin
                rx.repMax = sp.repMax
                rx.restSecondsBetweenSets = sp.restSecondsBetweenSets
                rx.restSecondsAfterExercise = sp.restSecondsAfterExercise
                rx.durationMinSeconds = sp.durationMinSeconds
                rx.durationMaxSeconds = sp.durationMaxSeconds
                rx.usesDuration = sp.usesDuration
                rx.rir = sp.rir
                rx.rpe = sp.rpe
                rx.tempo = sp.tempo?.isEmpty == true ? nil : sp.tempo

                // Copy slotNotes → templateNotes
                re.templateNotes =
                    sp.slotNotes?.isEmpty == true ? nil : sp.slotNotes
            }
        }
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

    /// Execute the deferred swap after the user chose keep/reset plan.
    private func performPendingSwap(resetPlan: Bool) {
        guard let idx = exerciseToSwapIndex,
            let block = currentBlock,
            idx < block.exercises.count,
            let newEx = pendingSwapNewExercise
        else {
            pendingSwapNewExercise = nil
            exerciseToSwapIndex = nil
            return
        }

        let planEx = block.exercises[idx]
        #if DEBUG
        let preSwapPlan = sessionPlans[planEx.routineSlotID]
        let preSwapSnap = planEx.prescriptionSnapshot
        let preSwapNotes = planEx.templateNotesSnapshot
        #endif

        if resetPlan {
            let slotID = planEx.routineSlotID
            sessionPlans[slotID] = SessionPlan()
            // Clear stale snapshot so input rebuild uses new template values
            if let bi = plan.blocks.firstIndex(where: {
                $0.exercises.contains(where: { $0.id == planEx.id })
            }),
                let ei = plan.blocks[bi].exercises.firstIndex(where: {
                    $0.id == planEx.id
                })
            {
                plan.blocks[bi].exercises[ei].prescriptionSnapshot = nil
                plan.blocks[bi].exercises[ei].templateNotesSnapshot = nil
            }
        } else {
            // Keep plan: verify nothing was cleared
            #if DEBUG
            assert(
                sessionPlans[planEx.routineSlotID]?.sets == preSwapPlan?.sets
                    && sessionPlans[planEx.routineSlotID]?.repMin == preSwapPlan?.repMin
                    && sessionPlans[planEx.routineSlotID]?.repMax == preSwapPlan?.repMax,
                "performPendingSwap(resetPlan: false) must not mutate sessionPlans"
            )
            assert(
                planEx.prescriptionSnapshot != nil || preSwapSnap == nil,
                "performPendingSwap(resetPlan: false) must not nil prescriptionSnapshot"
            )
            assert(
                planEx.templateNotesSnapshot == preSwapNotes,
                "performPendingSwap(resetPlan: false) must not clear templateNotesSnapshot"
            )
            #endif
        }

        swapExercise(planExercise: planEx, with: newEx)

        // A) After reset+swap, if the new exercise has no templates and the
        //    (now-empty) session plan has no sets, auto-open the Edit Plan
        //    sheet so the user can immediately set sets/reps/rest.
        if resetPlan, let swapped = currentExercise {
            let sc = effectiveSetCount(
                for: swapped, resolvedTemplates: swapped.templates)
            if sc <= 1 && swapped.templates.isEmpty {
                showEditPlanSheet = true
            }
        }

        pendingSwapNewExercise = nil
        exerciseToSwapIndex = nil
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
        let swappedPlanEx = plan.blocks[blockIndex].exercises[exIndex]

        let swappedCount = effectiveSetCount(
            for: swappedPlanEx, resolvedTemplates: newTemplates)
        var perSet: [Int: (reps: String, weight: String, duration: String)] =
            [:]
        for i in 0..<swappedCount {
            let tpl =
                newTemplates[safe: i]
                ?? defaultTemplate(for: swappedPlanEx, at: i)
            perSet[i] = (
                reps: String(
                    plannedRepTarget(for: swappedPlanEx, template: tpl)),
                weight: tpl.targetWeight.map { String($0) } ?? "",
                duration: plannedDurationTarget(
                    for: swappedPlanEx, template: tpl)
                    .map { String($0) } ?? ""
            )
        }

        inputsByExerciseID[slotID] = perSet
        loggedByExercise[slotID] = []
        // Keep existing session plan for this slot (user edits preserved across swaps).
        // A "Reset plan" option will be added in Phase 5d.

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

        // Nearest prior WORKING set's explicit rest (>0) or nil if none.
        // Clamps starting index to templates bounds for safety with extra sets.
        func priorWorkingRest(in templates: [PlanSetTemplate], upTo i: Int)
            -> Int?
        {
            var j = min(i - 1, templates.count - 1)
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
                let exSetCount = effectiveSetCount(
                    for: ex, resolvedTemplates: ex.templates)
                if idx >= exSetCount { continue }
                if !loggedByExercise[ex.id, default: []].contains(idx) {
                    return nil
                }
            }

            // Base round rest
            if let rr = block.supersetRoundRestSeconds, rr > 0 {
                restSec = rr
            } else {
                let roundHasDrop = block.exercises.contains { ex in
                    let sc = effectiveSetCount(
                        for: ex, resolvedTemplates: ex.templates)
                    return idx < sc
                        && (ex.templates[safe: idx]?.kind ?? .working)
                            == .dropset
                }

                if roundHasDrop {
                    // After a dropset: planned rest → prior working round rest; take max
                    var maxSeconds = 0
                    var found = false
                    for ex in block.exercises where idx < effectiveSetCount(
                        for: ex, resolvedTemplates: ex.templates)
                    {
                        if let r = plannedRestBetweenSets(for: ex)
                            ?? priorWorkingRest(in: ex.templates, upTo: idx),
                            r > 0
                        {
                            maxSeconds = max(maxSeconds, r)
                            found = true
                        }
                    }
                    restSec = (found && maxSeconds > 0) ? maxSeconds : nil
                } else {
                    // Normal round: planned rest → template rest; combine via max
                    var maxSeconds = 0
                    var found = false
                    for ex in block.exercises where idx < effectiveSetCount(
                        for: ex, resolvedTemplates: ex.templates)
                    {
                        if let r = plannedRestBetweenSets(for: ex)
                            ?? ex.templates[safe: idx]?.restSecondsAfter, r > 0
                        {
                            maxSeconds = max(maxSeconds, r)
                            found = true
                        }
                    }
                    // If the *next* round contains any dropset and there IS a next round, skip rest now
                    let hasNextRound = idx < lastRoundIndex(in: block)
                    let nextHasDrop = block.exercises.contains { ex in
                        let sc = effectiveSetCount(
                            for: ex, resolvedTemplates: ex.templates)
                        return (idx + 1) < sc
                            && (ex.templates[safe: idx + 1]?.kind ?? .working)
                                == .dropset
                    }
                    restSec =
                        (hasNextRound && nextHasDrop)
                        ? nil : ((found && maxSeconds > 0) ? maxSeconds : nil)
                }
            }
        } else {
            // Single exercise block
            if t.kind == .dropset {
                // After dropset: planned rest → prior working set's template rest
                if let r = plannedRestBetweenSets(for: exercise)
                    ?? priorWorkingRest(in: exercise.templates, upTo: idx),
                    r > 0
                {
                    restSec = r
                } else {
                    restSec = nil
                }
            } else {
                // Before dropset: skip
                let exSetCount = effectiveSetCount(
                    for: exercise, resolvedTemplates: exercise.templates)
                if idx + 1 < exSetCount,
                    (exercise.templates[safe: idx + 1]?.kind ?? .working)
                        == .dropset
                {
                    restSec = nil
                } else if let r = plannedRestBetweenSets(for: exercise)
                    ?? t.restSecondsAfter, r > 0
                {
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
            let exSetCount = effectiveSetCount(
                for: exercise, resolvedTemplates: exercise.templates)
            let isFinal: Bool =
                block.isSuperset
                ? (idx == lastRoundIndex(in: block)) && isLastExerciseOfBlock
                : (idx == exSetCount - 1) && isLastExerciseOfBlock

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
            let isLastSet =
                idx
                    == effectiveSetCount(
                        for: exercise, resolvedTemplates: exercise.templates)
                    - 1
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
            let sc = effectiveSetCount(
                for: ex, resolvedTemplates: ex.templates)
            guard idx < sc else { return false }
            if !loggedByExercise[ex.id, default: []].contains(idx) {
                return false
            }
        }
        return true
    }

    /// Assumes your superset safeguard ensures equal set counts across exercises.
    private func lastRoundIndex(in block: PlanBlock) -> Int {
        guard let first = block.exercises.first else { return 0 }
        return max(
            0,
            effectiveSetCount(for: first, resolvedTemplates: first.templates)
                - 1)
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
            let sc = effectiveSetCount(
                for: ex, resolvedTemplates: ex.templates)
            if idx < sc,
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

// MARK: - Edit Session Plan Sheet

private struct EditSessionPlanSheet: View {
    @Binding var plan: SessionPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if plan.usesDuration {
                    Section("Duration") {
                        fieldRow("Min (s)", binding: optionalInt(\.durationMinSeconds))
                        fieldRow("Max (s)", binding: optionalInt(\.durationMaxSeconds))
                    }
                } else {
                    Section("Reps") {
                        fieldRow("Min", binding: optionalInt(\.repMin))
                        fieldRow("Max", binding: optionalInt(\.repMax))
                    }
                }

                Section("Sets & Rest") {
                    fieldRow("Sets", binding: optionalInt(\.sets))
                    fieldRow(
                        "Rest between (s)",
                        binding: optionalInt(\.restSecondsBetweenSets))
                    fieldRow(
                        "Rest after (s)",
                        binding: optionalInt(\.restSecondsAfterExercise))
                }

                Section("Intensity") {
                    fieldRow("RIR", binding: optionalDouble(\.rir), decimal: true)
                    fieldRow("RPE", binding: optionalDouble(\.rpe), decimal: true)
                    HStack {
                        Text("Tempo")
                        Spacer()
                        TextField(
                            "—", text: optionalString(\.tempo)
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                    }
                }

                Section("Notes") {
                    TextField(
                        "Slot notes", text: optionalString(\.slotNotes),
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Field Row

    private func fieldRow(
        _ label: String, binding: Binding<String>, decimal: Bool = false
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: binding)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }

    // MARK: - Binding Helpers

    private func optionalInt(_ kp: WritableKeyPath<SessionPlan, Int?>)
        -> Binding<String>
    {
        Binding(
            get: { plan[keyPath: kp].map(String.init) ?? "" },
            set: { plan[keyPath: kp] = Int($0) }
        )
    }

    private func optionalDouble(_ kp: WritableKeyPath<SessionPlan, Double?>)
        -> Binding<String>
    {
        Binding(
            get: {
                guard let v = plan[keyPath: kp] else { return "" }
                return v.truncatingRemainder(dividingBy: 1) == 0
                    ? "\(Int(v))" : String(format: "%.1f", v)
            },
            set: { plan[keyPath: kp] = Double($0) }
        )
    }

    private func optionalString(_ kp: WritableKeyPath<SessionPlan, String?>)
        -> Binding<String>
    {
        Binding(
            get: { plan[keyPath: kp] ?? "" },
            set: { plan[keyPath: kp] = $0.isEmpty ? nil : $0 }
        )
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

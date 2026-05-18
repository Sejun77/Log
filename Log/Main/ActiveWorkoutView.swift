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

struct SessionPlan: Codable {
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

    /// Line 2: rest + intensity (mode-filtered) + tempo.
    /// Shows only the active autoregulation field; falls back to a converted value
    /// from the other field if the active one is nil.
    func secondarySummary(autoregMode: AutoregMode) -> String {
        var parts: [String] = []
        if let r = restSecondsBetweenSets, r > 0 { parts.append("\(r)s rest") }
        let fmt: (Double) -> String = { v in
            v.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(v)) : String(format: "%.1f", v)
        }
        switch autoregMode {
        case .rir:
            let val = rir ?? rpe.map { 10 - $0 }
            if let v = val { parts.append("RIR \(fmt(v))") }
        case .rpe:
            let val = rpe ?? rir.map { 10 - $0 }
            if let v = val { parts.append("RPE \(fmt(v))") }
        case .none:
            break
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
    @State private var showExerciseNotesSheet = false
    /// Per-set planned targets captured before opening the edit sheet.
    @State private var preEditRepStrs: [UUID: [Int: String]] = [:]
    @State private var preEditDurStrs: [UUID: [Int: String]] = [:]
    @State private var loggedByExercise: [UUID: Set<Int>] = [:]
    /// Maps exerciseID → parentSetIndex → Set of logged drop subIndices (1-based).
    @State private var dropsLoggedByExercise: [UUID: [Int: Set<Int>]] = [:]
    /// Reps/weight input buffers for drop rows. Key: "\(exerciseID)_\(parentSetIdx)_\(subIdx)".
    @State private var dropRepsInput: [String: String] = [:]
    @State private var dropWeightInput: [String: String] = [:]
    /// Keys where the user manually typed a weight — treated as authoritative over auto-suggestion.
    @State private var dropWeightUserEdited: Set<String> = []
    @State private var showRestOverlay = false
    /// Technique snapshot tapped for read-only detail; drives the detail sheet.
    @State private var techniqueDetailSnap: TechniquePlanSnapshot? = nil

    @StateObject private var setTimer = RestTimer()
    @State private var showSetOverlay = false

    @StateObject private var rest = RestTimer()

    // Cache created WorkoutItems by Exercise.id during the session
    @State private var itemsByExerciseID: [UUID: WorkoutItem] = [:]

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

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
        guard workout != nil else { return }

        var logged = loggedByExercise
        var inputs = inputsByExerciseID

        for block in plan.blocks {
            for ex in block.exercises {
                let slotID = ex.id

                // 🔒 Fix 2: if the exercise in this slot was swapped in this session,
                // do NOT pull in logs from the workout (they belong to a different exercise).
                if ex.originalExerciseID != ex.currentExerciseID {
                    continue
                }

                var perSet = inputs[slotID] ?? [:]

                // Primary: use pre-built cache (same key as suggestedDropWeight).
                // Fallback: if rebuildItemsByExerciseID missed this item (e.g. exercise
                // relationship still nil at that moment), search workout.items directly
                // by routineSlotID so rehydration is never silently skipped.
                let item: WorkoutItem? = itemsByExerciseID[slotID]
                    ?? workout?.items.first(where: { $0.routineSlotID == ex.routineSlotID })

                if let item = item {
                    // Exclude sub-drops (subIndex != nil) from the main logged-set tracking.
                    let indices = item.setLogs
                        .filter { $0.subIndex == nil }
                        .map(\.indexInExercise)
                    logged[slotID, default: []].formUnion(indices)

                    // Populate drop-logged cache and pre-fill input buffers from persisted drops.
                    var slotDrops = dropsLoggedByExercise[slotID] ?? [:]
                    for log in item.setLogs where log.subIndex != nil {
                        let sub = log.subIndex!
                        slotDrops[log.indexInExercise, default: []].insert(sub)
                        let key = "\(slotID)_\(log.indexInExercise)_\(sub)"
                        dropRepsInput[key] = String(log.reps)
                        let wStr = log.weight.map {
                            $0.truncatingRemainder(dividingBy: 1) == 0
                                ? String(Int($0)) : String($0)
                        } ?? ""
                        dropWeightInput[key] = wStr
                        // Mark as user-edited so the logged weight is shown verbatim
                        // rather than being overwritten by the auto-suggestion.
                        dropWeightUserEdited.insert(key)
                    }
                    dropsLoggedByExercise[slotID] = slotDrops
                }

                let setCount = effectiveSetCount(
                    for: ex, resolvedTemplates: ex.templates)
                for i in 0..<setCount {
                    let tpl =
                        ex.templates[safe: i]
                        ?? defaultTemplate(for: ex, at: i)
                    // Priority order:
                    //   1. Persisted parent SetLog (logged set — field is disabled, log is truth).
                    //   2. Persisted parent draft (UserDefaults) — un-logged user input that
                    //      must survive force-quit/cold resume.
                    //   3. In-memory inputsCache (un-logged draft from prior navigation in
                    //      the same process). NOTE: on cold resume after force-quit this
                    //      cache is empty UNTIL `ensureInputsInitializedFromPlan` seeds it
                    //      with prescription defaults — so the persisted draft must be
                    //      checked BEFORE the cache, otherwise prescription would clobber
                    //      the user's typed value.
                    //   4. Plan prescription default.
                    let parentLog = item?.setLogs.last(where: {
                        $0.indexInExercise == i && $0.subIndex == nil
                    })
                    if let log = parentLog {
                        let reps = String(max(0, log.reps))
                        let weight =
                            log.weight.map { String(Int($0.rounded())) } ?? ""
                        let duration =
                            log.durationSeconds.map(String.init) ?? ""
                        perSet[i] = (reps, weight, duration)
                    } else if let draft = parentDraftStore?.load(
                        slotID: slotID, setIndex: i
                    ) {
                        // Backfill any field absent from the draft with the prescription
                        // default so partially-filled drafts don't blank unrelated fields.
                        let presReps = String(plannedRepTarget(for: ex, template: tpl))
                        let presWeight = tpl.targetWeight.map { String($0) } ?? ""
                        let presDuration = plannedDurationTarget(for: ex, template: tpl)
                            .map { String($0) } ?? ""
                        perSet[i] = (
                            reps: draft.reps ?? presReps,
                            weight: draft.weight ?? presWeight,
                            duration: draft.duration ?? presDuration
                        )
                    } else if let cached = activeGuard.inputsCache[slotID]?[i] {
                        perSet[i] = cached
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
        // Restore any unlogged manual drop-weight drafts persisted to UserDefaults.
        // Must run AFTER logged drops are restored so logged values are not overwritten.
        restoreDropWeightDrafts()
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
                let filtered = newVal.filter(\.isNumber)
                inputsByExerciseID[exID]?[setIndex]?.reps = filtered
                syncToGuardCaches()
                parentDraftStore?.persist(
                    slotID: exID, setIndex: setIndex, field: .reps, value: filtered
                )
            }
        )

        let weightB = Binding<String>(
            get: {
                inputsByExerciseID[exID]?[setIndex]?.weight
                    ?? (template.targetWeight.map { String($0) } ?? "")
            },
            set: { newVal in
                ensureEntry()
                let filtered = newVal.filter(\.isNumber)
                inputsByExerciseID[exID]?[setIndex]?.weight = filtered
                syncToGuardCaches()
                parentDraftStore?.persist(
                    slotID: exID, setIndex: setIndex, field: .weight, value: filtered
                )
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
                let filtered = newVal.filter(\.isNumber)
                inputsByExerciseID[exID]?[setIndex]?.duration = filtered
                syncToGuardCaches()
                parentDraftStore?.persist(
                    slotID: exID, setIndex: setIndex, field: .duration, value: filtered
                )
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

        // 1. Within this exercise: earlier sets must be fully complete
        //    (parent + all configured drops for dropset sets).
        for j in 0..<setIndex {
            if !isWorkingSetComplete(exercise: exercise, setIndex: j) { return false }
        }

        // 2. Superset order: prior exercises at this set index must be complete first
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
                    if !isWorkingSetComplete(exercise: prevEx, setIndex: setIndex) {
                        return false
                    }
                }
            }
        }

        return true
    }

    /// A working set is complete when its parent-set log exists AND — for sets that have
    /// a dropset technique applied — all configured drop sub-logs are also present.
    private func isWorkingSetComplete(
        exercise: PlanExercise,
        setIndex: Int
    ) -> Bool {
        guard loggedByExercise[exercise.id, default: []].contains(setIndex) else {
            return false
        }
        if let snap = dropsetTechniqueApplying(to: setIndex, in: exercise) {
            let required = max(1, snap.dropCount ?? 1)
            let done = dropsLoggedByExercise[exercise.id, default: [:]][setIndex, default: []].count
            return done >= required
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
                        // SetLog is now the source of truth — discard the draft.
                        parentDraftStore?.clear(slotID: exercise.id, setIndex: idx)

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
                        // SetLog is now the source of truth — discard the draft.
                        parentDraftStore?.clear(slotID: exercise.id, setIndex: idx)

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

    // MARK: - Warmup Row

    @ViewBuilder
    private func buildWarmupRow(
        block: PlanBlock,
        exercise: PlanExercise,
        step: WarmupStepSnapshot
    ) -> some View {
        // Warmup SetLogs use negative indexInExercise to avoid collision with working-set indices.
        let logIndex = -(step.order + 1)
        let isLogged = loggedByExercise[exercise.id, default: []].contains(logIndex)
        let restSec = step.restSecondsAfter ?? exercise.prescriptionSnapshot?.restSecondsBetweenSets

        HStack(spacing: 12) {
            Text("W\(step.order + 1)")
                .font(.dsCaption.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(warmupStepDescription(step))
                    .font(.dsBody)
                    .foregroundStyle(isLogged ? .secondary : .primary)
                if let note = step.note, !note.isEmpty,
                   step.kind != .noteOnly
                {
                    Text(note)
                        .font(.dsBodySecondary)
                        .foregroundStyle(.secondary)
                }
                if let r = restSec, r > 0 {
                    Text("\(r)s rest")
                        .font(.dsBodySecondary)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                if isLogged {
                    undoSetLog(exerciseID: exercise.id, setIndex: logIndex)
                    var s = loggedByExercise[exercise.id, default: []]
                    s.remove(logIndex)
                    loggedByExercise[exercise.id] = s
                    syncToGuardCaches()
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    appendSetLog(
                        exerciseID: exercise.id,
                        setIndex: logIndex,
                        reps: step.reps ?? 0,
                        weight: step.weight.map { Int($0.rounded()) },
                        kind: .warmup
                    )
                    var s = loggedByExercise[exercise.id, default: []]
                    s.insert(logIndex)
                    loggedByExercise[exercise.id] = s
                    syncToGuardCaches()
                    if let seconds = restSec, seconds > 0 {
                        startRestWithPersistence(
                            seconds: seconds,
                            slotID: exercise.routineSlotID
                        )
                        showRestOverlay = true
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } label: {
                Image(systemName: isLogged ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isLogged ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .opacity(isLogged ? 0.65 : 1.0)
    }

    private func warmupStepDescription(_ step: WarmupStepSnapshot) -> String {
        switch step.kind {
        case .fixedReps:
            var parts: [String] = []
            if let w = step.weight {
                let unit = Units.weightIsKg ? "kg" : "lb"
                parts.append(w.truncatingRemainder(dividingBy: 1) == 0
                    ? "\(Int(w)) \(unit)"
                    : String(format: "%.1f \(unit)", w))
            }
            if let r = step.reps { parts.append("\(r) reps") }
            return parts.isEmpty ? "Reps" : parts.joined(separator: " × ")
        case .percentage:
            if let pct = step.percentOfWorking {
                let p = Int(pct * 100)
                if let r = step.reps { return "\(p)% × \(r) reps" }
                return "\(p)% of working"
            }
            return "% of working"
        case .noteOnly:
            return step.note ?? "—"
        }
    }

    private func unlockAndDismiss() {
        // Clear persisted drop-weight drafts before workout ID becomes inaccessible
        dropWeightDraftStore?.clearAll()
        // Clear persisted parent working-set drafts as well
        parentDraftStore?.clearAll()

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
            appState.sessionPlansJSON = nil
            appState.activeBlockIndex = nil
            appState.activeExerciseIndex = nil
        }

        try? ctx.save()
    }

    /// Builds a stable notification ID: "rest.<workoutID>.<slotID>"
    private func restNotificationID(slotID: UUID) -> String {
        guard let wID = workout?.id else {
            return "rest.unknown.\(slotID.uuidString)"
        }
        return RestTimer.stableNotificationID(
            workoutID: wID, slotID: slotID
        )
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

    /// Encodes `sessionPlans` to JSON and writes it to AppState.
    private func persistSessionPlans() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        let stringKeyed = Dictionary(
            uniqueKeysWithValues: sessionPlans.map { ($0.key.uuidString, $0.value) }
        )
        appState.sessionPlansJSON =
            (try? JSONEncoder().encode(stringKeyed))
            .flatMap { String(data: $0, encoding: .utf8) }
        try? ctx.save()
    }

    /// Overlays session plans from AppState.sessionPlansJSON onto the current
    /// `sessionPlans` dictionary.  Called after `initializeSessionPlans()` on cold
    /// resume so that in-workout edits survive a process kill.
    /// Stale keys (slot IDs not present in the current plan) are silently ignored.
    private func restoreSessionPlansFromAppState() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        guard let json = appState.sessionPlansJSON,
              let data = json.data(using: .utf8)
        else { return }

        let validSlotIDs = Set(
            plan.blocks.flatMap { $0.exercises.map(\.routineSlotID) }
        )

        if let decoded = try? JSONDecoder().decode(
            [String: SessionPlan].self, from: data
        ) {
            for (keyStr, sp) in decoded {
                guard let slotID = UUID(uuidString: keyStr),
                      validSlotIDs.contains(slotID)
                else { continue }
                sessionPlans[slotID] = sp
            }
        }
    }

    /// Restores `currentBlockIndex` and `currentExerciseIndex` from AppState,
    /// clamping to valid bounds so out-of-range persisted values never crash.
    private func restorePositionFromAppState() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        if let b = appState.activeBlockIndex {
            let clampedBlock = max(0, min(b, plan.blocks.count - 1))
            currentBlockIndex = clampedBlock
            if let e = appState.activeExerciseIndex {
                let exCount = plan.blocks[clampedBlock].exercises.count
                currentExerciseIndex = max(0, min(e, exCount - 1))
            }
        }
    }

    /// Writes the current block/exercise cursor position to AppState.
    private func persistPosition() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        appState.activeBlockIndex = currentBlockIndex
        appState.activeExerciseIndex = currentExerciseIndex
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
            // Primary path: match by routineSlotID — does NOT require the exercise
            // relationship to be loaded. Previously this was gated behind a
            // `guard let ex = item.exercise` which caused the item to be skipped
            // when SwiftData hadn't resolved the relationship yet during onAppear,
            // leaving itemsByExerciseID empty and making rehydration fall back to
            // plan defaults even though logs exist in the persistent store.
            if let slotID = item.routineSlotID,
               let slot = planSlots.first(where: { $0.routineSlotID == slotID })
            {
                itemsByExerciseID[slot.id] = item
            } else if let ex = item.exercise,
                      let slot = planSlots.first(where: { $0.currentExerciseID == ex.id })
            {
                // Fallback: match by exercise ID (pre-snapshot items without routineSlotID)
                itemsByExerciseID[slot.id] = item
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

    /// Binding for session-level Workout.notes.
    /// Reads and writes directly on the active Workout model object.
    /// Sets nil when the trimmed value is empty so the history detail row is suppressed.
    private var workoutNotesBinding: Binding<String> {
        Binding<String>(
            get: { workout?.notes ?? "" },
            set: { newVal in
                workout?.notes = newVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : newVal
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
        let line2 = sp.secondarySummary(autoregMode: autoregMode)
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
                                    .font(.dsBodySecondary)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
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

    /// Resolve planned rest after exercise (used only on the final working set of a non-superset
    /// exercise): session plan → snapshot → nil (falls back to restSecondsBetweenSets).
    private func plannedRestAfterExercise(
        for exercise: PlanExercise
    ) -> Int? {
        if let sp = sessionPlans[exercise.routineSlotID],
            let v = sp.restSecondsAfterExercise, v > 0
        { return v }
        if let snap = exercise.prescriptionSnapshot,
            let v = snap.restSecondsAfterExercise, v > 0
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
                    // --- Session-level workout notes (written to Workout.notes) ---
                    Section("Session Notes") {
                        TextField(
                            "Notes for this session…",
                            text: workoutNotesBinding
                        )
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                    }

                    // --- Exercise-level notes (read-only display of Exercise.notes) ---
                    // Source: live Exercise.notes for the currently-focused exercise.
                    // Inline editing is intentionally disabled to preserve the
                    // no-silent-mutation invariant (Phase 2). Explicit editing is
                    // available via the "Edit Exercise Notes" button below, which
                    // opens a focused sheet that writes through to Exercise.notes.
                    if fetchExercise(by: exercise.currentExerciseID) != nil {
                        Section {
                            if let live = fetchExercise(by: exercise.currentExerciseID),
                                let raw = live.notes,
                                !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            {
                                Text(raw)
                                    .font(.dsBody)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("No notes yet.")
                                    .font(.dsBodySecondary)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                showExerciseNotesSheet = true
                            } label: {
                                Label("Edit Exercise Notes", systemImage: "square.and.pencil")
                            }
                            Text("Saved to this exercise. Editing here affects every routine and workout that uses this exercise.")
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                        } header: {
                            Text("Exercise Notes")
                        }
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

                    // --- Warmup section ---
                    if !exercise.warmupStepsSnapshot.isEmpty {
                        Section {
                            ForEach(exercise.warmupStepsSnapshot, id: \.order) { step in
                                buildWarmupRow(block: block, exercise: exercise, step: step)
                            }
                        } header: {
                            Text("Warmup")
                                .font(.dsBody)
                        }
                    }

                    // --- Sets section ---
                    Section {
                        let setCount = effectiveSetCount(
                            for: exercise,
                            resolvedTemplates: exercise.templates)
                        ForEach(0..<setCount, id: \.self) { idx in
                            let t =
                                exercise.templates[safe: idx]
                                ?? defaultTemplate(for: exercise, at: idx)
                            buildWorkingSetGroup(
                                block: block,
                                exercise: exercise,
                                idx: idx,
                                template: t
                            )
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 6) {
                            let setCount = effectiveSetCount(
                                for: exercise,
                                resolvedTemplates: exercise.templates)
                            // Warmup logs use negative indexInExercise — exclude them from working-set count.
                            let loggedCount = loggedByExercise[
                                exercise.id,
                                default: []
                            ].filter { $0 >= 0 }.count
                            Text(
                                "Logged \(loggedCount)/\(setCount) sets"
                            )
                            .font(.dsBody)

                            // Technique overview — dropsets shown inline in grouped rows; show only non-dropset here.
                            let nonDropsetTechs = exercise.techniquePlansSnapshot.filter { $0.type != .dropset }
                            if !nonDropsetTechs.isEmpty {
                                TechniqueIndicatorRow(labels: nonDropsetTechs.map(\.summaryLabel))
                                    .opacity(0.6)
                            }
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
            .confirmationDialog(
                "End workout?",
                isPresented: $showEndConfirm,
                titleVisibility: .visible
            ) {
                Button("Save & Exit") {
                    workout?.completedAt = Date()
                    try? ctx.save()
                    unlockAndDismiss()
                }
                Button("Discard Workout", role: .destructive) {
                    if let w = workout {
                        ctx.delete(w)
                        try? ctx.save()
                    }
                    unlockAndDismiss()
                }
            } message: {
                Text(
                    "Save keeps all logged sets. Discard deletes the workout permanently."
                )
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
                        routineVariantID: plan.routineVariantID,
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
                // 0a) overlay persisted session plans (cold resume — takes precedence)
                restoreSessionPlansFromAppState()
                // 0b) restore cursor position from AppState (cold resume)
                restorePositionFromAppState()
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
            .onChange(of: currentBlockIndex) { _, _ in persistPosition() }
            .onChange(of: currentExerciseIndex) { _, _ in persistPosition() }
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
                onDismiss: {
                    applySessionPlanToInputs()
                    persistSessionPlans()
                }
            ) {
                if let exercise = currentExercise {
                    EditSessionPlanSheet(
                        plan: sessionPlanBinding(
                            for: exercise.routineSlotID))
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { techniqueDetailSnap != nil },
                    set: { if !$0 { techniqueDetailSnap = nil } }
                )
            ) {
                if let snap = techniqueDetailSnap {
                    TechniqueDetailSheet(snap: snap)
                }
            }
            .sheet(isPresented: $showExerciseNotesSheet) {
                if let ex = currentExercise,
                    let liveEx = fetchExercise(by: ex.currentExerciseID)
                {
                    ExerciseNotesEditSheet(exercise: liveEx)
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
            $0.indexInExercise == setIndex && $0.subIndex == nil
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
            $0.indexInExercise == setIndex && $0.subIndex == nil
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
        // Snapshot the parent SetLog's values into the parent draft BEFORE removing
        // it, so the now-editable field retains those values across force-quit/
        // cold-resume. Without this, a log→undo→force-quit→resume cycle would fall
        // back to prescription because both the SetLog and the draft would be gone.
        // The same logic applies whether the user logged earlier in this session
        // (where the draft would already match) or in a previous session (where the
        // draft was never written and only the SetLog carried the value).
        if let log = wi.setLogs.last(where: {
            $0.indexInExercise == setIndex && $0.subIndex == nil
        }) {
            let repsStr = String(max(0, log.reps))
            let weightStr = log.weight.map { String(Int($0.rounded())) } ?? ""
            parentDraftStore?.persist(
                slotID: exerciseID, setIndex: setIndex, field: .reps, value: repsStr
            )
            parentDraftStore?.persist(
                slotID: exerciseID, setIndex: setIndex, field: .weight, value: weightStr
            )
            if let durationStr = log.durationSeconds.map(String.init) {
                parentDraftStore?.persist(
                    slotID: exerciseID, setIndex: setIndex, field: .duration, value: durationStr
                )
            }
        }
        // Remove parent set log
        if let j = wi.setLogs.lastIndex(where: {
            $0.indexInExercise == setIndex && $0.subIndex == nil
        }) {
            wi.setLogs.remove(at: j)
        }
        // Cascade: remove all drop sub-logs for this parent set
        let loggedSubs = dropsLoggedByExercise[exerciseID]?[setIndex] ?? []
        wi.setLogs.removeAll { $0.indexInExercise == setIndex && $0.subIndex != nil }
        try? ctx.save()
        // Clear drop UI state for each cascaded sub
        for sub in loggedSubs {
            let key = "\(exerciseID)_\(setIndex)_\(sub)"
            dropWeightInput.removeValue(forKey: key)
            dropWeightUserEdited.remove(key)
            dropRepsInput.removeValue(forKey: key)
            dropWeightDraftStore?.clear(slotKey: key)
        }
        // Also clear any UNLOGGED drop drafts under this parent set
        // (e.g. user typed Drop 2 weight but never tapped Log for that drop).
        // Without this, the orphan draft would resurface on next render / cold resume.
        let prefix = "\(exerciseID)_\(setIndex)_"
        for key in dropWeightInput.keys where key.hasPrefix(prefix) {
            dropWeightInput.removeValue(forKey: key)
            dropWeightUserEdited.remove(key)
            dropRepsInput.removeValue(forKey: key)
            dropWeightDraftStore?.clear(slotKey: key)
        }
        dropsLoggedByExercise[exerciseID]?.removeValue(forKey: setIndex)
    }

    // MARK: - Drop Weight Draft Persistence (UserDefaults)
    // Unlogged manual drop-weight edits are @State-only and lost on force
    // quit. `DropWeightDraftStore` persists them per (slotID, parentSetIndex,
    // subIndex) under the workout's UserDefaults key so they survive cold
    // resume. Returns nil before the workout binds, so optional-chained call
    // sites safely no-op at startup (matching prior behavior).

    private var dropWeightDraftStore: DropWeightDraftStore? {
        workout.map { DropWeightDraftStore(workoutID: $0.id) }
    }

    // MARK: - Parent Working-Set Draft Persistence (UserDefaults)
    // Un-logged manual edits to parent reps/weight/duration are @State-only
    // and lost on force quit. `ParentDraftStore` persists them per parent set
    // under the workout's UserDefaults key so they survive cold resume.
    // Returns nil before the workout binds, so optional-chained call sites
    // safely no-op at startup (matching prior behavior).

    private var parentDraftStore: ParentDraftStore? {
        workout.map { ParentDraftStore(workoutID: $0.id) }
    }

    /// Restores unlogged draft weights from UserDefaults into the in-memory buffers.
    /// Only applies to slots NOT already populated by a logged SetLog (i.e. not in dropWeightUserEdited).
    private func restoreDropWeightDrafts() {
        guard let store = dropWeightDraftStore else { return }
        for (slotKey, value) in store.loadAll() {
            guard !dropWeightUserEdited.contains(slotKey) else { continue }
            dropWeightInput[slotKey] = value
            dropWeightUserEdited.insert(slotKey)
        }
    }

    // MARK: - Technique Targeting Helpers

    /// Returns all TechniquePlanSnapshots that apply to `setIndex` in the exercise.
    /// Checks explicit appliesToSetIndices first, then falls back to the old appliesTo enum.
    private func techniquesApplying(
        to setIndex: Int,
        in exercise: PlanExercise
    ) -> [TechniquePlanSnapshot] {
        let templates = exercise.templates
        let setCount = effectiveSetCount(for: exercise, resolvedTemplates: templates)
        let lastWorkingIdx = (0..<setCount).last {
            (templates[safe: $0]?.kind ?? .working) == .working
        } ?? (setCount - 1)

        return exercise.techniquePlansSnapshot.filter { snap in
            let indices = snap.appliesToSetIndices
            if !indices.isEmpty {
                return indices.contains(setIndex)
            }
            switch snap.appliesTo {
            case .lastWorkingSet:
                return setIndex == lastWorkingIdx
            case .allWorkingSets:
                return (templates[safe: setIndex]?.kind ?? .working) == .working
            case .setNumber(let n):
                return setIndex == (n - 1)
            }
        }
    }

    /// Renders compact technique chips for a working set. Tapping a chip opens the detail sheet.
    @ViewBuilder
    private func buildTechniqueChips(
        exercise: PlanExercise,
        setIndex: Int
    ) -> some View {
        let snaps = techniquesApplying(to: setIndex, in: exercise)
        if !snaps.isEmpty {
            SetTechniqueChipsRow(techniques: snaps) { snap in
                techniqueDetailSnap = snap
            }
        }
    }

    // MARK: - Dropset Sub-logging

    /// Returns the first Dropset TechniquePlanSnapshot that applies to `setIndex`
    /// in the given exercise, or nil if no Dropset technique covers that set.
    private func dropsetTechniqueApplying(
        to setIndex: Int,
        in exercise: PlanExercise
    ) -> TechniquePlanSnapshot? {
        let templates = exercise.templates
        let setCount = effectiveSetCount(for: exercise, resolvedTemplates: templates)
        // Last index whose template kind is .working (fallback: last index)
        let lastWorkingIdx = (0..<setCount).last {
            (templates[safe: $0]?.kind ?? .working) == .working
        } ?? (setCount - 1)

        return exercise.techniquePlansSnapshot.first { snap in
            guard snap.type == .dropset else { return false }
            // New path: explicit indices take precedence.
            let indices = snap.appliesToSetIndices
            if !indices.isEmpty {
                return indices.contains(setIndex)
            }
            // Old path: appliesTo enum fallback.
            switch snap.appliesTo {
            case .lastWorkingSet:
                return setIndex == lastWorkingIdx
            case .allWorkingSets:
                return (templates[safe: setIndex]?.kind ?? .working) == .working
            case .setNumber(let n):
                return setIndex == (n - 1)
            }
        }
    }

    /// Computes and rounds the suggested weight for a new drop.
    /// Base is previous drop's logged weight, or the parent set's logged weight.
    private func suggestedDropWeight(
        exerciseID: UUID,
        parentSetIndex: Int,
        subIndex: Int,
        dropPercent: Double
    ) -> String {
        guard let wi = itemsByExerciseID[exerciseID] else { return "" }
        let base: Double?
        if subIndex > 1 {
            base = wi.setLogs.first(where: {
                $0.indexInExercise == parentSetIndex && $0.subIndex == subIndex - 1
            })?.weight
        } else {
            base = wi.setLogs.first(where: {
                $0.indexInExercise == parentSetIndex && $0.subIndex == nil
            })?.weight
        }
        guard let b = base, b > 0 else { return "" }
        let raw = b * (1.0 - dropPercent / 100.0)
        return formatWeight(roundWeight(raw))
    }

    private func roundWeight(_ raw: Double) -> Double {
        Units.weightIsKg
            ? (raw * 2).rounded() / 2  // nearest 0.5
            : raw.rounded()             // nearest 1.0
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(w)) : String(w)
    }

    /// Appends (or updates) a drop sub-log under `parentSetIndex`.
    private func appendDropLog(
        exerciseID slotID: UUID,
        parentSetIndex: Int,
        subIndex: Int,
        reps: Int,
        weight: Double?
    ) {
        guard let workout else { return }

        if itemsByExerciseID[slotID] == nil {
            guard
                let planEx = plan.blocks.flatMap(\.exercises).first(where: { $0.id == slotID }),
                let ex = fetchExercise(by: planEx.currentExerciseID)
            else { return }
            let newItem = WorkoutItem(exercise: ex, setLogs: [])
            populateSnapshotFields(on: newItem, from: planEx)
            workout.items.append(newItem)
            itemsByExerciseID[slotID] = newItem
        }

        guard let wi = itemsByExerciseID[slotID] else { return }

        if let j = wi.setLogs.firstIndex(where: {
            $0.indexInExercise == parentSetIndex && $0.subIndex == subIndex
        }) {
            wi.setLogs[j].reps = reps
            wi.setLogs[j].weight = weight
            wi.setLogs[j].timestamp = .now
        } else {
            wi.setLogs.append(
                SetLog(
                    indexInExercise: parentSetIndex,
                    kind: .dropset,
                    reps: reps,
                    weight: weight,
                    subIndex: subIndex
                )
            )
        }

        var drops = dropsLoggedByExercise[slotID, default: [:]]
        drops[parentSetIndex, default: []].insert(subIndex)
        dropsLoggedByExercise[slotID] = drops
        try? ctx.save()
    }

    /// Removes a logged drop sub-log. Intentionally preserves any manual weight override
    /// in `dropWeightUserEdited`/`dropWeightInput` so the field shows the previously
    /// entered value rather than reverting to auto-suggestion.
    /// The only action that clears a manual override is the "↩ suggest" button.
    private func undoDropLog(exerciseID slotID: UUID, parentSetIndex: Int, subIndex: Int) {
        guard let wi = itemsByExerciseID[slotID] else { return }
        if let j = wi.setLogs.firstIndex(where: {
            $0.indexInExercise == parentSetIndex && $0.subIndex == subIndex
        }) {
            wi.setLogs.remove(at: j)
            var drops = dropsLoggedByExercise[slotID, default: [:]]
            drops[parentSetIndex]?.remove(subIndex)
            dropsLoggedByExercise[slotID] = drops
            try? ctx.save()
        }
    }

    /// Renders drop sub-rows under a working set row when a Dropset technique applies.
    @ViewBuilder
    private func buildDropSection(
        block: PlanBlock,
        exercise: PlanExercise,
        parentSetIndex: Int
    ) -> some View {
        if let snap = dropsetTechniqueApplying(to: parentSetIndex, in: exercise) {
            let dropCount = max(1, snap.dropCount ?? 1)
            let loggedSubs = dropsLoggedByExercise[exercise.id, default: [:]][parentSetIndex, default: []]
            let parentLogged = loggedByExercise[exercise.id, default: []].contains(parentSetIndex)

            ForEach(1...dropCount, id: \.self) { sub in
                let key = "\(exercise.id)_\(parentSetIndex)_\(sub)"
                let isDropLogged = loggedSubs.contains(sub)
                let canLogDrop = parentLogged && !isDropLogged
                    && (sub == 1 || loggedSubs.contains(sub - 1))
                // Compute weight in the @ViewBuilder body so @Observable setLogs accesses
                // are tracked — this ensures re-render when the parent set weight changes.
                let suggested = suggestedDropWeight(
                    exerciseID: exercise.id,
                    parentSetIndex: parentSetIndex,
                    subIndex: sub,
                    dropPercent: snap.dropPercent ?? 20
                )
                let isOverridden = dropWeightUserEdited.contains(key)
                let currentWeight: String = isOverridden
                    ? (dropWeightInput[key] ?? "")
                    : suggested
                // Show reset only when manually overridden, a suggestion exists, drop not yet logged,
                // AND the visible value actually differs from the suggestion.
                let canReset = isOverridden && !suggested.isEmpty && !isDropLogged
                    && Double(currentWeight) != Double(suggested)

                DropLogRow(
                    dropNumber: sub,
                    isLogged: isDropLogged,
                    canLog: canLogDrop,
                    reps: Binding(
                        get: {
                            if let v = dropRepsInput[key] { return v }
                            let effectiveRaw = snap.dropsetEffortRaw ?? "amrap"
                            if effectiveRaw == "fixedReps", let n = snap.dropsetEffortReps {
                                return String(n)
                            }
                            return ""
                        },
                        set: { dropRepsInput[key] = $0 }
                    ),
                    weight: Binding(
                        get: { currentWeight },
                        set: { newVal in
                            dropWeightInput[key] = newVal
                            dropWeightUserEdited.insert(key)
                            dropWeightDraftStore?.persist(slotKey: key, value: newVal)
                        }
                    ),
                    onLog: { reps, weight in
                        appendDropLog(
                            exerciseID: exercise.id,
                            parentSetIndex: parentSetIndex,
                            subIndex: sub,
                            reps: reps,
                            weight: weight
                        )
                        dropWeightDraftStore?.clear(slotKey: key)
                        let isFinalDrop = (sub == dropCount)
                        if isFinalDrop {
                            if block.isSuperset {
                                // Inside a superset: rest only fires when every exercise
                                // in the round is fully complete (parent + all drops).
                                // Round rest from supersetRoundRestSeconds; on the final
                                // round, block.restAfterSeconds (transition rest) replaces
                                // round rest when configured. Last set of workout: suppressed.
                                if supersetRoundComplete(block: block, setIndex: parentSetIndex),
                                    let r = computeSupersetEndOfRoundRest(block: block, setIndex: parentSetIndex),
                                    r > 0
                                {
                                    startRestWithPersistence(
                                        seconds: r, slotID: exercise.routineSlotID)
                                    showRestOverlay = true
                                } else {
                                    // Round not yet complete (another exercise is pending),
                                    // or the helper returned nil (e.g., last set of workout).
                                    // Clear any stale running rest from earlier in this round.
                                    rest.stop()
                                    clearPersistedRestState()
                                }
                                // Advance focus the same way a normal parent log does once
                                // the dropset set is now fully complete.
                                advanceForSupersetAfterLog(setIndex: parentSetIndex, in: block)
                            } else {
                                // Non-superset: fire between-sets or after-exercise rest.
                                let exSetCount = effectiveSetCount(
                                    for: exercise, resolvedTemplates: exercise.templates)
                                let isLastWorkingSet = parentSetIndex == exSetCount - 1
                                let isLastSetOfWorkout: Bool = {
                                    guard let cb = currentBlock else { return false }
                                    return currentBlockIndex == plan.blocks.count - 1
                                        && currentExerciseIndex == cb.exercises.count - 1
                                        && isLastWorkingSet
                                }()
                                if !isLastSetOfWorkout {
                                    let restDur = isLastWorkingSet
                                        ? (plannedRestAfterExercise(for: exercise)
                                            ?? plannedRestBetweenSets(for: exercise))
                                        : plannedRestBetweenSets(for: exercise)
                                    if let r = restDur, r > 0 {
                                        startRestWithPersistence(
                                            seconds: r, slotID: exercise.routineSlotID)
                                        showRestOverlay = true
                                    }
                                }
                            }
                        } else {
                            // Non-final drop: intra-drop rest (dropset-specific only; no prescription fallback)
                            let restDur = snap.restSeconds.flatMap { $0 > 0 ? $0 : nil }
                            if let r = restDur, r > 0 {
                                startRestWithPersistence(
                                    seconds: r, slotID: exercise.routineSlotID)
                                showRestOverlay = true
                            }
                        }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    },
                    onUndo: {
                        undoDropLog(
                            exerciseID: exercise.id,
                            parentSetIndex: parentSetIndex,
                            subIndex: sub
                        )
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    },
                    onResetWeight: canReset ? {
                        dropWeightUserEdited.remove(key)
                        dropWeightInput.removeValue(forKey: key)
                        dropWeightDraftStore?.clear(slotKey: key)
                    } : nil
                )
            }
        }
    }

    /// Renders one working set index as a cohesive group when a dropset technique applies,
    /// or as separate list rows (set row + technique chips) for non-dropset sets.
    @ViewBuilder
    private func buildWorkingSetGroup(
        block: PlanBlock,
        exercise: PlanExercise,
        idx: Int,
        template: PlanSetTemplate
    ) -> some View {
        if let snap = dropsetTechniqueApplying(to: idx, in: exercise) {
            // Unified card: parent working set + dropset summary + drop sub-rows in one list row.
            VStack(alignment: .leading, spacing: 12) {
                buildSetRow(block: block, exercise: exercise, idx: idx, template: template)
                // Compact dropset config summary — aligned with the indented drop rows below.
                Text(snap.setAttachedLabel)
                    .font(.dsCaption)
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .padding(.leading, 20)
                buildDropSection(block: block, exercise: exercise, parentSetIndex: idx)
            }
        } else {
            // Standard layout: set row and per-set technique chips as separate list rows.
            buildSetRow(block: block, exercise: exercise, idx: idx, template: template)
            buildTechniqueChips(exercise: exercise, setIndex: idx)
        }
    }

    private func isAtLast(block: PlanBlock) -> Bool {
        currentBlockIndex == plan.blocks.count - 1
            && currentExerciseIndex == max(0, block.exercises.count - 1)
    }

    /// Returns seconds of rest to start now, or nil to skip.
    /// Rules (no defaults used):
    /// • Empty rest (nil) or 0 ⇒ skip.
    /// • Working set with a technique-based dropset attached: suppress; rest fires after the final sub-log.
    /// • Before a template-based dropset ⇒ skip.
    /// • After a dropset ⇒ use the nearest prior WORKING set's explicit rest (if any), else skip.
    /// • Non-superset final working set: prefer restSecondsAfterExercise (session plan → snapshot),
    ///   falling back to restSecondsBetweenSets → template rest.
    /// • Supersets compute rest per “round”: wait until all exercises at this index are logged,
    ///   then apply the same rules; when combining, take the max of the explicit rests found.
    /// • Finally, on the *last* set/round of the block:
    ///     – Supersets: block.restAfterSeconds (transition rest) replaces the round rest when configured (>0).
    ///     – Non-superset blocks: legacy additive behavior — block.restAfterSeconds is added to the computed rest.
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
            // Wait for every exercise in the round to be fully complete
            // (parent log AND, if a dropset technique applies, all configured drops).
            for ex in block.exercises {
                let exSetCount = effectiveSetCount(
                    for: ex, resolvedTemplates: ex.templates)
                if idx >= exSetCount { continue }
                if !isWorkingSetComplete(exercise: ex, setIndex: idx) {
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
            } else if dropsetTechniqueApplying(to: idx, in: exercise) != nil {
                // Technique-based dropset on this working set:
                // suppress parent-set rest; rest fires after the final sub-log.
                restSec = nil
            } else {
                // Simple non-superset path — extracted to RestPlanner (Phase 7.4-C.1).
                // Covers: between-set rest, final-set rest, skip-before-template-dropset,
                // and last-set-of-workout suppression. All other branches (supersets,
                // current-set dropset, technique-based dropsets, warmup) remain inline.
                let exSetCount = effectiveSetCount(
                    for: exercise, resolvedTemplates: exercise.templates)
                let isLastBlock = currentBlockIndex == plan.blocks.count - 1
                let isLastExerciseOfBlock =
                    currentExerciseIndex == block.exercises.count - 1
                let isLastSetOfWorkout =
                    isLastBlock && isLastExerciseOfBlock
                    && (idx == exSetCount - 1)
                let nextKind: SetKind? =
                    (idx + 1 < exSetCount)
                        ? (exercise.templates[safe: idx + 1]?.kind ?? .working)
                        : nil
                restSec = RestPlanner.restSecondsAfterLog(
                    RestContext(
                        setIndex: idx,
                        nextTemplateKind: nextKind,
                        effectiveSetCount: exSetCount,
                        plannedRestBetweenSets: plannedRestBetweenSets(for: exercise),
                        plannedRestAfterExercise: plannedRestAfterExercise(for: exercise),
                        templateRestSecondsAfter: t.restSecondsAfter,
                        isLastSetOfWorkout: isLastSetOfWorkout
                    )
                )
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
                if block.isSuperset {
                    // Final round of a superset: transition rest replaces round rest,
                    // but only when the round is actually complete (parent + drops for
                    // every exercise). Otherwise leave restSec untouched (typically nil).
                    if supersetRoundComplete(block: block, setIndex: idx) {
                        restSec = max(0, extra)
                    }
                } else {
                    // Non-superset legacy: additive on top of the final-set rest.
                    if let base = restSec {
                        restSec = max(0, base + extra)
                    } else {
                        restSec = max(0, extra)
                    }
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
        item.exerciseNameSnapshot = planEx.name
        if let payload = planEx.prescriptionSnapshot {
            let snapshot = payload.toModel()
            ctx.insert(snapshot)
            item.plannedPrescriptionSnapshot = snapshot
        }
        // Persist warmup steps so they survive a cold restart when the routine
        // may be unavailable (fallback resume path via planFromWorkoutItems).
        if !planEx.warmupStepsSnapshot.isEmpty {
            item.warmupStepsSnapshotData = try? JSONEncoder().encode(
                planEx.warmupStepsSnapshot
            )
        }
        // Persist technique plans for the same cold-restart reason.
        if !planEx.techniquePlansSnapshot.isEmpty {
            item.techniquePlansSnapshotData = try? JSONEncoder().encode(
                planEx.techniquePlansSnapshot
            )
        }
    }

    /// True iff every exercise in the block has its round at `idx` fully complete
    /// (parent logged AND, when a dropset technique applies, all configured drops logged).
    private func allExercisesLogged(setIndex idx: Int, in block: PlanBlock)
        -> Bool
    {
        for ex in block.exercises {
            let sc = effectiveSetCount(
                for: ex, resolvedTemplates: ex.templates)
            guard idx < sc else { return false }
            if !isWorkingSetComplete(exercise: ex, setIndex: idx) {
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

    /// True iff every exercise in the block has fully completed its round at `setIndex`
    /// (parent set logged AND, when a dropset technique applies, all configured drops logged).
    /// Exercises whose set count does not reach `setIndex` are skipped.
    private func supersetRoundComplete(
        block: PlanBlock,
        setIndex: Int
    ) -> Bool {
        for ex in block.exercises {
            let sc = effectiveSetCount(
                for: ex, resolvedTemplates: ex.templates)
            guard setIndex < sc else { continue }
            if !isWorkingSetComplete(exercise: ex, setIndex: setIndex) {
                return false
            }
        }
        return true
    }

    /// Computes the rest to fire when a superset round completes at `setIndex`.
    /// - Primary: `block.supersetRoundRestSeconds` (>0).
    /// - Fallback: max `plannedRestBetweenSets` across exercises participating in the round.
    /// - Final round: `block.restAfterSeconds` (transition rest) replaces round rest when configured (>0).
    /// - Last set of the workout: returns nil (suppressed).
    private func computeSupersetEndOfRoundRest(
        block: PlanBlock,
        setIndex: Int
    ) -> Int? {
        let isLastRound = setIndex == lastRoundIndex(in: block)
        let isLastBlock = currentBlockIndex == plan.blocks.count - 1
        if isLastRound && isLastBlock { return nil }

        var restSec: Int? = nil
        if let rr = block.supersetRoundRestSeconds, rr > 0 {
            restSec = rr
        } else {
            var maxSeconds = 0
            var found = false
            for ex in block.exercises {
                let sc = effectiveSetCount(
                    for: ex, resolvedTemplates: ex.templates)
                guard setIndex < sc else { continue }
                if let r = plannedRestBetweenSets(for: ex), r > 0 {
                    maxSeconds = max(maxSeconds, r)
                    found = true
                }
            }
            if found, maxSeconds > 0 { restSec = maxSeconds }
        }

        if isLastRound, let extra = block.restAfterSeconds, extra > 0 {
            restSec = extra
        }

        return restSec
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

        // 0) Stay on the current exercise if its round isn't fully complete yet
        //    (e.g., parent logged but a dropset technique still has drops pending).
        if currentExerciseIndex < block.exercises.count {
            let cur = block.exercises[currentExerciseIndex]
            let curSc = effectiveSetCount(
                for: cur, resolvedTemplates: cur.templates)
            if idx < curSc, !isWorkingSetComplete(exercise: cur, setIndex: idx) {
                return
            }
        }

        // 1) Find the next exercise whose round at this index isn't fully complete.
        let total = block.exercises.count
        var next = currentExerciseIndex
        for _ in 0..<total {
            next = (next + 1) % total
            let ex = block.exercises[next]
            let sc = effectiveSetCount(
                for: ex, resolvedTemplates: ex.templates)
            if idx < sc, !isWorkingSetComplete(exercise: ex, setIndex: idx) {
                currentExerciseIndex = next
                return
            }
        }

        // 2) Round is complete. Move to next round (wrap to first), or stay on last.
        guard supersetRoundComplete(block: block, setIndex: idx) else { return }
        let lastIdx = lastRoundIndex(in: block)
        if idx < lastIdx {
            currentExerciseIndex = 0
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

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    var body: some View {
        NavigationStack {
            Form {
                if plan.usesDuration {
                    Section("Duration") {
                        intStepperRow("Min", keyPath: \.durationMinSeconds, range: 0...600, step: 15, unit: "s")
                        intStepperRow("Max", keyPath: \.durationMaxSeconds, range: 0...600, step: 15, unit: "s")
                    }
                } else {
                    Section("Reps") {
                        intStepperRow("Min", keyPath: \.repMin, range: 0...50)
                        intStepperRow("Max", keyPath: \.repMax, range: 0...50)
                    }
                }

                Section("Sets & Rest") {
                    intStepperRow("Sets", keyPath: \.sets, range: 0...20)
                    intStepperRow("Rest between sets", keyPath: \.restSecondsBetweenSets, range: 0...600, step: 15, unit: "s", zeroLabel: "none")
                    intStepperRow("Rest after exercise", keyPath: \.restSecondsAfterExercise, range: 0...600, step: 15, unit: "s", zeroLabel: "none")
                }

                Section("Intensity") {
                    switch autoregMode {
                    case .rir:
                        doubleStepperRow("RIR", active: $plan.rir, paired: $plan.rpe,
                                         range: 0...5, step: 0.5) { 10 - $0 }
                    case .rpe:
                        doubleStepperRow("RPE", active: $plan.rpe, paired: $plan.rir,
                                         range: 5...10, step: 0.5) { 10 - $0 }
                    case .none:
                        EmptyView()
                    }
                    TempoEditorView(tempo: $plan.tempo)
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

    // MARK: - Field Rows

    /// Stepper for a bounded optional-Int field on SessionPlan.
    /// 0 maps to nil (unset); stepping up from 0 begins at `range.lowerBound` + `step`.
    private func intStepperRow(
        _ label: String,
        keyPath: WritableKeyPath<SessionPlan, Int?>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String? = nil,
        zeroLabel: String = "—"
    ) -> some View {
        let current = plan[keyPath: keyPath] ?? 0
        let valStr = current == 0 ? zeroLabel : (unit.map { "\(current)\($0)" } ?? "\(current)")
        return Stepper(
            "\(label): \(valStr)",
            value: Binding(
                get: { plan[keyPath: keyPath] ?? 0 },
                set: { plan[keyPath: keyPath] = $0 == 0 ? nil : $0 }
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

    // MARK: - Binding Helpers

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

// MARK: - Drop sub-row (shown under a working set when a Dropset technique applies)

private struct DropLogRow: View {
    @FocusState private var focused: Field?
    private enum Field { case reps, weight }

    let dropNumber: Int
    let isLogged: Bool
    let canLog: Bool
    @Binding var reps: String
    @Binding var weight: String
    var onLog: (Int, Double?) -> Void
    var onUndo: () -> Void
    /// Non-nil when the weight was manually overridden and a suggestion can be computed.
    /// Tapping resets the field to the auto-suggested value.
    var onResetWeight: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                Text("Drop \(dropNumber)")
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isLogged {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
                    .focused($focused, equals: .reps)

                Text("×").foregroundStyle(.secondary).fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Wt", text: $weight)
                        .font(.dsBody.monospacedDigit())
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .disabled(isLogged)
                        .focused($focused, equals: .weight)
                    if let reset = onResetWeight {
                        Button("↩ suggest") { reset() }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                    }
                }

                Text(Units.weightIsKg ? "kg" : "lb")
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Spacer(minLength: 8)

                if isLogged {
                    Button("Undo") { onUndo() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Log Drop") {
                        let r = Int(reps) ?? 0
                        let w = Double(weight)
                        onLog(r, w)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(DSColor.textInverse)
                    .disabled(!canLog)
                }
            }
            .frame(minWidth: 80)
        }
        .padding(.leading, 20)
    }
}

// MARK: - Phase 3.6: Technique indicators

/// Displays technique badges snapshotted at plan-build time.
/// Read-only — never touches the live SlotPrescription or TechniquePlan models.
private struct TechniqueIndicatorRow: View {
    let labels: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.dsCaption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(Color.orange)
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Phase 3.8: Per-set technique chips + detail sheet

/// Horizontal row of tappable technique chips rendered directly on the applicable set row.
private struct SetTechniqueChipsRow: View {
    let techniques: [TechniquePlanSnapshot]
    let onTap: (TechniquePlanSnapshot) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(techniques.indices, id: \.self) { i in
                    let snap = techniques[i]
                    Button {
                        onTap(snap)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: iconName(for: snap.type))
                                .font(.system(size: 10, weight: .semibold))
                            Text(snap.setAttachedLabel)
                                .font(.dsCaption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(Color.orange)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func iconName(for type: TechniqueType) -> String {
        switch type {
        case .dropset:       return "arrow.down.circle"
        case .partialReps:   return "chart.bar.fill"
        case .restPause:     return "pause.circle"
        case .amrap:         return "infinity"
        case .toFailure:     return "flame"
        case .cluster:       return "square.grid.2x2"
        case .tempoOverride: return "metronome"
        }
    }
}

/// Read-only detail sheet for a TechniquePlanSnapshot. No template mutation.
// MARK: - Exercise Notes Edit Sheet (active workout)

/// Focused editor for the global Exercise.notes field, presented from the read-only
/// "Exercise Notes" section in the active workout. Writes through to the live
/// Exercise (@Bindable). Save is triggered on "Done"; cancel discards in-flight
/// edits by reverting the @Bindable surface to its original value before dismiss.
/// This sheet is the only place in the active workout where Exercise.notes can be
/// edited — the in-list display below Session Notes stays read-only.
private struct ExerciseNotesEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Bindable var exercise: Exercise

    @State private var originalNotes: String?
    @State private var didCapture = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Notes…",
                        text: Binding(
                            get: { exercise.notes ?? "" },
                            set: { newVal in
                                let trimmed = newVal.trimmingCharacters(
                                    in: .whitespacesAndNewlines)
                                exercise.notes = trimmed.isEmpty ? nil : newVal
                            }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                    .textInputAutocapitalization(.sentences)
                } header: {
                    Text("Exercise Notes")
                } footer: {
                    Text("These notes are saved to the exercise and reused across routines and workouts.")
                }
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        exercise.notes = originalNotes
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? ctx.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !didCapture {
                    originalNotes = exercise.notes
                    didCapture = true
                }
            }
        }
    }
}

private struct TechniqueDetailSheet: View {
    let snap: TechniquePlanSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Applies To") {
                    let indices = snap.appliesToSetIndices
                    if !indices.isEmpty {
                        let nums = indices.sorted().map { "Set \($0 + 1)" }.joined(separator: ", ")
                        Text(nums)
                    } else {
                        Text(snap.appliesTo.displayLabel)
                    }
                }
                switch snap.type {
                case .dropset:
                    Section("Drop Set") {
                        if let n = snap.dropCount { LabeledContent("Drops", value: "\(n)") }
                        if let p = snap.dropPercent { LabeledContent("Weight reduction", value: "\(Int(p))%") }
                        if let r = snap.restSeconds, r > 0 { LabeledContent("Rest between drops", value: "\(r)s") }
                        switch snap.dropsetEffort {
                        case .amrap:             LabeledContent("Effort", value: "AMRAP")
                        case .fixedReps(let n):  LabeledContent("Reps per drop", value: "\(n)")
                        }
                    }
                case .restPause:
                    Section("Rest-Pause") {
                        if let n = snap.rounds { LabeledContent("Rounds", value: "\(n)") }
                        if let r = snap.restSeconds, r > 0 { LabeledContent("Rest", value: "\(r)s") }
                    }
                case .cluster:
                    Section("Cluster") {
                        if let n = snap.reps { LabeledContent("Reps per cluster", value: "\(n)") }
                        if let c = snap.rounds { LabeledContent("Clusters", value: "\(c)") }
                        if let r = snap.restSeconds, r > 0 { LabeledContent("Rest between clusters", value: "\(r)s") }
                    }
                case .partialReps:
                    Section("Partial Reps") {
                        if let region = snap.partialRangeNote, !region.isEmpty {
                            LabeledContent("Range", value: region)
                        }
                        if let n = snap.reps, n > 0 { LabeledContent("Partial reps", value: "\(n)") }
                    }
                case .tempoOverride:
                    Section("Tempo") {
                        if let t = snap.note, !t.isEmpty { LabeledContent("Tempo", value: t) }
                    }
                case .amrap:
                    Section("AMRAP") {
                        Text("As many reps as possible on this set.")
                            .foregroundStyle(.secondary)
                    }
                case .toFailure:
                    Section("To Failure") {
                        Text("Push to technical failure on this set.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(snap.type.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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

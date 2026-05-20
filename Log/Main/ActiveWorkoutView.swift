import ActivityKit
import SwiftData
import SwiftUI
import UserNotifications

// Phase 11.1 — top-level support types lifted to dedicated files:
//   `ActiveWorkoutGuard` → `Log/Services/ActiveWorkoutGuard.swift`
//   `SessionPlan`        → `Log/Models/SessionPlan.swift`
//   `Collection.safe`    → `Log/Utilities/Collection+Safe.swift`
//
// Phase 11.4 — supporting private view structs lifted under
// `Log/Main/ActiveWorkout/` (all bumped `private struct` → default-internal):
//   `SetEntryRow`, `TimeSetEntryRow`        → `SetRows.swift`
//   `DropLogRow`                            → `DropLogRow.swift`
//   `TechniqueIndicatorRow`,
//   `SetTechniqueChipsRow`,
//   `TechniqueDetailSheet`                  → `TechniqueChipsViews.swift`
//   `RestOverlayScreen`                     → `RestOverlayScreen.swift`
//   `ExerciseNotesEditSheet`                → `ExerciseNotesEditSheet.swift`
//   `EditSessionPlanSheet` (+ its private
//    `intStepperRow`, `doubleStepperRow`,
//    `optionalString` helpers)              → `EditSessionPlanSheet.swift`
//
// Phase 11.6-A — pure helpers lifted to module-internal free functions
// in `Log/Main/ActiveWorkout/ActiveWorkoutHelpers.swift` (no access bumps
// on `ActiveWorkoutView` state required):
//   `roundWeight(_:)`, `formatWeight(_:)`, `defaultTemplate(for:at:)`,
//   `activeRestNotificationID(workoutID:slotID:)` (replaces the former
//    `restNotificationID(slotID:)` method; callers now pass `workout?.id`
//    explicitly so the "rest.unknown.<slot>" fallback shape is preserved
//    byte-for-byte).

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
    // Phase 5.2 — keyed by routineSlotID (per-slot identity).
    @State private var loggedByExercise: [UUID: Set<Int>] = [:]
    /// Maps exerciseID → parentSetIndex → Set of logged drop subIndices (1-based).
    // Phase 5.2 — keyed by routineSlotID (per-slot identity).
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

    // Phase 5.2 — keyed by routineSlotID (per-slot identity).
    // The "ByExerciseID" suffix is legacy naming; the value is a per-slot
    // WorkoutItem looked up by `WorkoutItem.routineSlotID`.
    @State private var itemsByExerciseID: [UUID: WorkoutItem] = [:]

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    // Phase 5.2 — keyed by routineSlotID (per-slot identity).
    @State private var inputsByExerciseID:
        [UUID: [Int: (reps: String, weight: String, duration: String)]] = [:]

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
                inputsByExerciseID[ex.routineSlotID] = perSet
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
                // Per-slot identity for in-memory state dicts (Phase 5.2).
                let slotID = ex.routineSlotID
                // Legacy Exercise.id — still used for the drop-key string format
                // and ParentDraftStore keys (Slice B will migrate the persistence
                // format; this slice preserves it byte-for-byte).
                let exerciseID = ex.id

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
                        // Phase 5.2-B — drop-key uses routineSlotID. The
                        // on-disk migration in restoreDropWeightDrafts
                        // rewrites any legacy `<Exercise.id>_..._..._...`
                        // entries before the bridge into in-memory dicts,
                        // so by the time this loop reads logged drops the
                        // dropWeight*Input dicts only see new-format keys.
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
                    } else if let draft =
                        // Phase 5.2-B — dual-read: prefer the new
                        // routineSlotID-keyed entry, fall back to the
                        // legacy Exercise.id-keyed entry for in-flight
                        // drafts that predate this slice. Legacy entries
                        // die at `clearAll` on workout finish.
                        parentDraftStore?.load(slotID: slotID, setIndex: i)
                        ?? parentDraftStore?.load(slotID: exerciseID, setIndex: i)
                    {
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
        // Phase 5.2-B — `slotID` is the per-slot key used for both
        // in-memory state and `ParentDraftStore` writes.
        let slotID = exercise.routineSlotID

        func ensureEntry() {
            if inputsByExerciseID[slotID] == nil {
                inputsByExerciseID[slotID] = [:]
            }
            if inputsByExerciseID[slotID]?[setIndex] == nil {
                inputsByExerciseID[slotID]?[setIndex] = (
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
                inputsByExerciseID[slotID]?[setIndex]?.reps
                    ?? String(
                        plannedRepTarget(for: exercise, template: template))
            },
            set: { newVal in
                ensureEntry()
                let filtered = newVal.filter(\.isNumber)
                inputsByExerciseID[slotID]?[setIndex]?.reps = filtered
                syncToGuardCaches()
                parentDraftStore?.persist(
                    slotID: slotID, setIndex: setIndex, field: .reps, value: filtered
                )
            }
        )

        let weightB = Binding<String>(
            get: {
                inputsByExerciseID[slotID]?[setIndex]?.weight
                    ?? (template.targetWeight.map { String($0) } ?? "")
            },
            set: { newVal in
                ensureEntry()
                let filtered = newVal.filter(\.isNumber)
                inputsByExerciseID[slotID]?[setIndex]?.weight = filtered
                syncToGuardCaches()
                parentDraftStore?.persist(
                    slotID: slotID, setIndex: setIndex, field: .weight, value: filtered
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
        // Phase 5.2-B — per-slot key for both in-memory state and
        // ParentDraftStore persistence.
        let slotID = exercise.routineSlotID

        func ensureEntry() {
            if inputsByExerciseID[slotID] == nil {
                inputsByExerciseID[slotID] = [:]
            }
            if inputsByExerciseID[slotID]?[setIndex] == nil {
                inputsByExerciseID[slotID]?[setIndex] = (
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
                inputsByExerciseID[slotID]?[setIndex]?.duration
                    ?? (plannedDurationTarget(
                        for: exercise, template: template)
                        .map { String($0) } ?? "")
            },
            set: { newVal in
                ensureEntry()
                let filtered = newVal.filter(\.isNumber)
                inputsByExerciseID[slotID]?[setIndex]?.duration = filtered
                syncToGuardCaches()
                parentDraftStore?.persist(
                    slotID: slotID, setIndex: setIndex, field: .duration, value: filtered
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
        let logged = loggedByExercise[exercise.routineSlotID, default: []]
        if logged.contains(setIndex) { return false }

        // 1. Within this exercise: earlier sets must be fully complete
        //    (parent + all configured drops for dropset sets).
        for j in 0..<setIndex {
            if !isWorkingSetComplete(exercise: exercise, setIndex: j) { return false }
        }

        // 2. Superset gating. Two complementary checks:
        //    (a) Round-progression — round N+1 stays locked until round N
        //        is complete across every participating exercise. Prevents
        //        the user from manually navigating back to exercise A and
        //        logging A2 before B1 is done.
        //    (b) In-round ordering — within a round, exercises log in
        //        block.exercises order (A1 → B1 → C1).
        //    Both use isWorkingSetComplete so dropsets are respected
        //    (parent logged AND all configured drops logged).
        if block.isSuperset {
            // (a) Previous round must be complete for every participating
            //     exercise (those whose effectiveSetCount reaches setIndex-1).
            if setIndex > 0 {
                let prevRound = setIndex - 1
                for ex in block.exercises {
                    let exSetCount = effectiveSetCount(
                        for: ex, resolvedTemplates: ex.templates)
                    guard prevRound < exSetCount else { continue }
                    if !isWorkingSetComplete(exercise: ex, setIndex: prevRound) {
                        return false
                    }
                }
            }

            // (b) In-round ordering: prior exercises at this set index must
            //     be complete first. Matches by routineSlotID so duplicate
            //     Exercise across slots stay independent.
            guard
                let exIdx = block.exercises.firstIndex(where: {
                    $0.routineSlotID == exercise.routineSlotID
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
        let slotID = exercise.routineSlotID
        guard loggedByExercise[slotID, default: []].contains(setIndex) else {
            return false
        }
        if let snap = dropsetTechniqueApplying(to: setIndex, in: exercise) {
            let required = max(1, snap.dropCount ?? 1)
            let done = dropsLoggedByExercise[slotID, default: [:]][setIndex, default: []].count
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
        // Phase 5.2-B — `slotID` is the per-slot key for both in-memory
        // state and `ParentDraftStore` persistence. `exerciseID` (the
        // legacy Exercise.id) is still passed to `undoSetLog` because
        // its cascade also defensively clears legacy drop-key entries
        // in case a pre-Slice-B-format on-disk entry survived migration.
        let slotID = exercise.routineSlotID
        let exerciseID = exercise.id
        let isLogged = loggedByExercise[slotID, default: []].contains(idx)
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
                            slotID: slotID,
                            setIndex: idx,
                            durationSeconds: durationSeconds,
                            kind: template.kind
                        )
                        var s = loggedByExercise[slotID, default: []]
                        s.insert(idx)
                        loggedByExercise[slotID] = s
                        syncToGuardCaches()
                        // SetLog is now the source of truth — discard the draft.
                        // Phase 5.2-B: new key by slotID, plus a defensive
                        // legacy clear in case a pre-migration entry survived.
                        parentDraftStore?.clear(slotID: slotID, setIndex: idx)
                        parentDraftStore?.clear(slotID: exerciseID, setIndex: idx)

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
                        undoSetLog(slotID: slotID, exerciseID: exerciseID, setIndex: idx)
                        var s = loggedByExercise[slotID, default: []]
                        s.remove(idx)
                        syncToGuardCaches()
                        loggedByExercise[slotID] = s
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
                            slotID: slotID,
                            setIndex: idx,
                            reps: reps,
                            weight: weight,
                            kind: template.kind
                        )
                        var s = loggedByExercise[slotID, default: []]
                        s.insert(idx)
                        loggedByExercise[slotID] = s
                        syncToGuardCaches()
                        // SetLog is now the source of truth — discard the draft.
                        // Phase 5.2-B: new key by slotID, plus a defensive
                        // legacy clear in case a pre-migration entry survived.
                        parentDraftStore?.clear(slotID: slotID, setIndex: idx)
                        parentDraftStore?.clear(slotID: exerciseID, setIndex: idx)

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
                        undoSetLog(slotID: slotID, exerciseID: exerciseID, setIndex: idx)
                        rest.stop()
                        clearPersistedRestState()
                        var s = loggedByExercise[slotID, default: []]
                        s.remove(idx)
                        loggedByExercise[slotID] = s
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
        let slotID = exercise.routineSlotID
        let exerciseID = exercise.id
        let logIndex = -(step.order + 1)
        let isLogged = loggedByExercise[slotID, default: []].contains(logIndex)
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
                    undoSetLog(slotID: slotID, exerciseID: exerciseID, setIndex: logIndex)
                    var s = loggedByExercise[slotID, default: []]
                    s.remove(logIndex)
                    loggedByExercise[slotID] = s
                    syncToGuardCaches()
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    appendSetLog(
                        slotID: slotID,
                        setIndex: logIndex,
                        reps: step.reps ?? 0,
                        weight: step.weight.map { Int($0.rounded()) },
                        kind: .warmup
                    )
                    var s = loggedByExercise[slotID, default: []]
                    s.insert(logIndex)
                    loggedByExercise[slotID] = s
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

        // NB: AppState active* fields are cleared upstream by
        // WorkoutLifecycleService.{finish,discard} at the call sites that
        // lead here. Save & Exit deliberately does NOT call this helper.

        // Clear session locks and dismiss screen
        activeGuard.endSession()
        dismiss()
    }

    /// Marks the persisted AppState singleton `.active` for cold-restart resume.
    /// Sole caller is the session-start path in `onAppear`. The reverse
    /// transition (`.idle` + clearing every `active*` field) is handled by
    /// `WorkoutLifecycleService.clearActiveAppState(_:)` via Finish / Discard.
    private func markAppStateActive() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        appState.workoutState = .active
        appState.activeWorkoutID = workout?.id
        appState.activeWorkoutStartedAt = activeGuard.sessionStart
        try? ctx.save()
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
            rest.stableNotificationID = activeRestNotificationID(workoutID: workout?.id, slotID: slotID)
        }
    }

    /// Starts a rest timer with stable notification ID and persisted state.
    private func startRestWithPersistence(seconds: Int, slotID: UUID) {
        let stableID = activeRestNotificationID(workoutID: workout?.id, slotID: slotID)

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

        let stableID = activeRestNotificationID(workoutID: workout?.id, slotID: slotID)
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
                // Phase 5.2 — cache is keyed by routineSlotID (per-slot identity).
                itemsByExerciseID[slot.routineSlotID] = item
            } else if let ex = item.exercise,
                      let slot = planSlots.first(where: { $0.currentExerciseID == ex.id })
            {
                // Fallback: match by exercise ID (pre-snapshot items without routineSlotID).
                // Note: if the same Exercise occupies two slots, this picks whichever
                // slot the linear scan finds first — pre-snapshot items predate the
                // routineSlotID column, so they can't be disambiguated here. Mixed
                // routines (some snapshot, some not) should hit the routineSlotID
                // branch above first whenever possible.
                itemsByExerciseID[slot.routineSlotID] = item
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

    // MARK: - Planned target wrappers (delegate to SessionPlanResolver)
    //
    // Phase 11.6-B: the per-tier fallback logic for these five helpers
    // was extracted to `Log/Services/SessionPlanResolver.swift`. Each
    // method below is a one-line forwarder that pulls the live
    // `SessionPlan` and the immutable `PrescriptionSnapshotPayload` out
    // of the view's @State surface and hands them to the pure resolver.
    // Behavior is preserved byte-for-byte against the pre-11.6-B bodies.
    // Wrappers are kept so the ~48 existing call sites stay textually
    // unchanged (no large mechanical diff); they may be inlined in a
    // future slice if direct call-site rewrites become preferred.

    private func plannedRepTarget(
        for exercise: PlanExercise,
        template: PlanSetTemplate
    ) -> Int {
        SessionPlanResolver.plannedRepTarget(
            sessionPlan: sessionPlans[exercise.routineSlotID],
            snapshot: exercise.prescriptionSnapshot,
            template: template
        )
    }

    private func plannedDurationTarget(
        for exercise: PlanExercise,
        template: PlanSetTemplate
    ) -> Int? {
        SessionPlanResolver.plannedDurationTarget(
            sessionPlan: sessionPlans[exercise.routineSlotID],
            snapshot: exercise.prescriptionSnapshot,
            template: template
        )
    }

    private func plannedRestBetweenSets(
        for exercise: PlanExercise
    ) -> Int? {
        SessionPlanResolver.plannedRestBetweenSets(
            sessionPlan: sessionPlans[exercise.routineSlotID],
            snapshot: exercise.prescriptionSnapshot
        )
    }

    private func plannedRestAfterExercise(
        for exercise: PlanExercise
    ) -> Int? {
        SessionPlanResolver.plannedRestAfterExercise(
            sessionPlan: sessionPlans[exercise.routineSlotID],
            snapshot: exercise.prescriptionSnapshot
        )
    }

    private func effectiveSetCount(
        for ex: PlanExercise,
        resolvedTemplates: [PlanSetTemplate]
    ) -> Int {
        SessionPlanResolver.effectiveSetCount(
            sessionPlan: sessionPlans[ex.routineSlotID],
            snapshot: ex.prescriptionSnapshot,
            resolvedTemplates: resolvedTemplates
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
        // Phase 5.2 — inputsByExerciseID is keyed by routineSlotID, so the
        // cache key now matches `slotKey`. Variable preserved for clarity.
        let cacheKey = exercise.routineSlotID

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
                                exercise.routineSlotID,
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
                    // Resumable exit: persist any in-flight writes only.
                    // AppState / activeGuard / draft stores are intentionally
                    // left intact so the workout is resumable via both the
                    // in-memory `ActiveGuard` banner and the cold-restart
                    // `RootTabView.checkForActiveSession` flow.
                    WorkoutLifecycleService.saveAndExit(in: ctx)
                    dismiss()
                }
                Button("Discard Workout", role: .destructive) {
                    let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
                    WorkoutLifecycleService.discard(
                        workout: workout, appState: appState, in: ctx
                    )
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
                    finishWorkout(applySwaps: false)
                }

                if hasSwapsPending {
                    Button("Finish + Update routine template") {
                        finishWorkout(applySwaps: true)
                    }
                }

                if hasSessionPlanPending {
                    Button("Finish + Update slot prescription") {
                        finishWorkout(
                            applySwaps: false,
                            applySlotPrescription: true)
                    }
                }

                // Combined option when multiple categories are pending.
                // Exercise.notes is intentionally NOT in this list — it's
                // edited write-through via ExerciseNotesEditSheet, so
                // there's no "pending notes" state to apply at finish.
                let pendingCount = [
                    hasSwapsPending,
                    hasSessionPlanPending,
                ].filter(\.self).count
                if pendingCount >= 2 {
                    Button("Finish + Apply all") {
                        finishWorkout(
                            applySwaps: hasSwapsPending,
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
                markAppStateActive()

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
            if hasSwapsPending || hasSessionPlanPending {
                showFinishConfirm = true
            } else {
                finishWorkout(applySwaps: false)
            }
        }
    }

    // MARK: - Finish helpers

    private var hasSwapsPending: Bool {
        plan.blocks.flatMap(\.exercises).contains {
            $0.originalExerciseID != $0.currentExerciseID
        }
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
        applySlotPrescription: Bool = false
    ) {
        if applySwaps { applyExerciseSwapsToRoutine() }
        if applySlotPrescription { applySessionPlansToSlotPrescriptions() }

        // Mark the workout as completed and clear AppState in one call.
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        WorkoutLifecycleService.finish(
            workout: workout, appState: appState, in: ctx
        )
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
        // Phase 5.2 — slotID is the per-slot key (routineSlotID).
        let slotID = plan.blocks[blockIndex].exercises[exIndex].routineSlotID
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
        // Exercise.notes is sourced live via `fetchExercise(...)` in the
        // active-workout Notes section, so swapping no longer needs to
        // seed any per-slot notes cache. The library Exercise's `notes`
        // field is whatever it was; the new slot's read-only display
        // refreshes when SwiftUI re-renders against the new
        // `currentExerciseID`.
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
        slotID: UUID,
        setIndex: Int,
        reps: Int,
        weight: Int?,
        kind: SetKind
    ) {
        guard let workout else { return }

        // Ensure we have a WorkoutItem for this *slot* — matched by
        // PlanExercise.routineSlotID (per-slot identity).
        if itemsByExerciseID[slotID] == nil {
            guard
                let planEx = plan.blocks.flatMap(\.exercises).first(where: {
                    $0.routineSlotID == slotID
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
        slotID: UUID,
        setIndex: Int,
        durationSeconds: Int,
        kind: SetKind
    ) {
        guard let workout else { return }

        if itemsByExerciseID[slotID] == nil {
            guard
                let planEx = plan.blocks.flatMap(\.exercises).first(where: {
                    $0.routineSlotID == slotID
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

    /// `slotID` is the per-slot identity (routineSlotID) for in-memory
    /// state (`itemsByExerciseID`, `dropsLoggedByExercise`) **and** the
    /// `ParentDraftStore` snapshot-on-undo path (Phase 5.2-B). `exerciseID`
    /// is the legacy `Exercise.id` — retained so the drop-key cascade and
    /// the parent-draft clear can defensively also clear legacy on-disk
    /// entries that survived migration.
    private func undoSetLog(slotID: UUID, exerciseID: UUID, setIndex: Int) {
        guard let wi = itemsByExerciseID[slotID] else { return }
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
            // Phase 5.2-B — write under the new routineSlotID-based key.
            parentDraftStore?.persist(
                slotID: slotID, setIndex: setIndex, field: .reps, value: repsStr
            )
            parentDraftStore?.persist(
                slotID: slotID, setIndex: setIndex, field: .weight, value: weightStr
            )
            if let durationStr = log.durationSeconds.map(String.init) {
                parentDraftStore?.persist(
                    slotID: slotID, setIndex: setIndex, field: .duration, value: durationStr
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
        let loggedSubs = dropsLoggedByExercise[slotID]?[setIndex] ?? []
        wi.setLogs.removeAll { $0.indexInExercise == setIndex && $0.subIndex != nil }
        try? ctx.save()
        // Clear drop UI state for each cascaded sub. Phase 5.2-B: the
        // in-memory dicts use routineSlotID-based keys; defensively also
        // clear the legacy Exercise.id-based on-disk key in case a
        // pre-migration entry survived.
        for sub in loggedSubs {
            let newKey = "\(slotID)_\(setIndex)_\(sub)"
            let legacyKey = "\(exerciseID)_\(setIndex)_\(sub)"
            dropWeightInput.removeValue(forKey: newKey)
            dropWeightUserEdited.remove(newKey)
            dropRepsInput.removeValue(forKey: newKey)
            dropWeightDraftStore?.clear(slotKey: newKey)
            dropWeightDraftStore?.clear(slotKey: legacyKey)
        }
        // Also clear any UNLOGGED drop drafts under this parent set
        // (e.g. user typed Drop 2 weight but never tapped Log for that drop).
        // Without this, the orphan draft would resurface on next render / cold resume.
        // In-memory dicts are routineSlotID-keyed (Slice A); the on-disk
        // legacy prefix is cleared defensively below.
        let newPrefix = "\(slotID)_\(setIndex)_"
        for key in dropWeightInput.keys where key.hasPrefix(newPrefix) {
            dropWeightInput.removeValue(forKey: key)
            dropWeightUserEdited.remove(key)
            dropRepsInput.removeValue(forKey: key)
            dropWeightDraftStore?.clear(slotKey: key)
        }
        // Phase 5.2-B compat — sweep any legacy on-disk drop drafts that
        // share the parent (exerciseID, setIndex) tuple. In-memory dicts
        // no longer use legacy keys, so only the persistent store sweep.
        if let store = dropWeightDraftStore {
            let legacyPrefix = "\(exerciseID)_\(setIndex)_"
            for legacyKey in store.loadAll().keys where legacyKey.hasPrefix(legacyPrefix) {
                store.clear(slotKey: legacyKey)
            }
        }
        dropsLoggedByExercise[slotID]?.removeValue(forKey: setIndex)
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
    /// Only applies to slots NOT already populated by a logged SetLog
    /// (i.e. not in `dropWeightUserEdited`).
    ///
    /// Phase 5.2-B — runs a one-shot legacy-key migration first so any
    /// pre-Slice-B `"<Exercise.id>_<setIdx>_<sub>"` entries on disk are
    /// rewritten to the new `"<routineSlotID>_<setIdx>_<sub>"` format.
    /// For routines where the same `Exercise` occupies two slots, the
    /// legacy entry's value is fanned out to both slot keys. After the
    /// rewrite the on-disk dict and the in-memory dicts are aligned in
    /// new format; subsequent persist/clear/load all use new format.
    private func restoreDropWeightDrafts() {
        guard let store = dropWeightDraftStore else { return }

        // Build the plan's identity map for the migration walker.
        var legacyExerciseToSlots: [UUID: [UUID]] = [:]
        var knownSlots: Set<UUID> = []
        for block in plan.blocks {
            for ex in block.exercises {
                // Use `currentExerciseID` to also catch routines where a
                // swap happened during the pre-update session — the
                // originating Exercise.id may differ from `originalExerciseID`.
                legacyExerciseToSlots[ex.currentExerciseID, default: []].append(ex.routineSlotID)
                if ex.currentExerciseID != ex.originalExerciseID {
                    legacyExerciseToSlots[ex.originalExerciseID, default: []].append(ex.routineSlotID)
                }
                knownSlots.insert(ex.routineSlotID)
            }
        }

        let original = store.loadAll()
        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: original,
            legacyExerciseToSlots: legacyExerciseToSlots,
            knownSlots: knownSlots
        )
        if migrated != original {
            store.setAll(migrated)
        }

        // Bridge the migrated (now new-format) dict into the @State buffers.
        for (slotKey, value) in migrated {
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
    /// `slotID` is the per-slot identity (routineSlotID) — looks up the
    /// per-slot WorkoutItem so duplicate Exercise across slots is independent.
    private func suggestedDropWeight(
        slotID: UUID,
        parentSetIndex: Int,
        subIndex: Int,
        dropPercent: Double
    ) -> String {
        guard let wi = itemsByExerciseID[slotID] else { return "" }
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

    /// Appends (or updates) a drop sub-log under `parentSetIndex`.
    /// `slotID` is the per-slot identity (routineSlotID).
    private func appendDropLog(
        slotID: UUID,
        parentSetIndex: Int,
        subIndex: Int,
        reps: Int,
        weight: Double?
    ) {
        guard let workout else { return }

        if itemsByExerciseID[slotID] == nil {
            guard
                let planEx = plan.blocks.flatMap(\.exercises).first(where: { $0.routineSlotID == slotID }),
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
    /// `slotID` is the per-slot identity (routineSlotID).
    private func undoDropLog(slotID: UUID, parentSetIndex: Int, subIndex: Int) {
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
            // Phase 5.2-B — drop key uses routineSlotID for both the
            // in-memory dicts AND the `DropWeightDraftStore` persistence.
            // `exerciseID` is retained so the "↩ suggest" / on-log
            // cleanup paths can defensively clear any legacy on-disk
            // entry that survived migration.
            let slotID = exercise.routineSlotID
            let exerciseID = exercise.id
            let dropCount = max(1, snap.dropCount ?? 1)
            let loggedSubs = dropsLoggedByExercise[slotID, default: [:]][parentSetIndex, default: []]
            let parentLogged = loggedByExercise[slotID, default: []].contains(parentSetIndex)

            ForEach(1...dropCount, id: \.self) { sub in
                let key = "\(slotID)_\(parentSetIndex)_\(sub)"
                let legacyKey = "\(exerciseID)_\(parentSetIndex)_\(sub)"
                let isDropLogged = loggedSubs.contains(sub)
                let canLogDrop = parentLogged && !isDropLogged
                    && (sub == 1 || loggedSubs.contains(sub - 1))
                // Compute weight in the @ViewBuilder body so @Observable setLogs accesses
                // are tracked — this ensures re-render when the parent set weight changes.
                let suggested = suggestedDropWeight(
                    slotID: slotID,
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
                            slotID: slotID,
                            parentSetIndex: parentSetIndex,
                            subIndex: sub,
                            reps: reps,
                            weight: weight
                        )
                        dropWeightDraftStore?.clear(slotKey: key)
                        // Compat: also clear any pre-migration legacy entry.
                        dropWeightDraftStore?.clear(slotKey: legacyKey)
                        let isFinalDrop = (sub == dropCount)
                        if isFinalDrop {
                            if block.isSuperset {
                                // Phase 7.4-C.3 — dropset-final-drop superset
                                // rest decision extracted to RestPlanner. The
                                // planner handles mid-round suppression,
                                // base round rest, final-round transition
                                // replacement, and last-set-of-workout
                                // suppression. Side effects stay in the view.
                                let participants: [SupersetRoundParticipant] =
                                    block.exercises.map { ex in
                                        let sc = effectiveSetCount(
                                            for: ex, resolvedTemplates: ex.templates)
                                        let participates = parentSetIndex < sc
                                        return SupersetRoundParticipant(
                                            participates: participates,
                                            isComplete: participates
                                                ? isWorkingSetComplete(
                                                    exercise: ex,
                                                    setIndex: parentSetIndex)
                                                : true,
                                            plannedRestBetweenSets:
                                                plannedRestBetweenSets(for: ex),
                                            // Unused by restSecondsAfterFinalDropInSuperset
                                            // — fillers preserve the shared
                                            // SupersetRoundParticipant API.
                                            currentTemplateKind: .working,
                                            currentTemplateRestSecondsAfter: nil,
                                            nextTemplateKind: nil,
                                            priorWorkingRest: nil
                                        )
                                    }
                                let ctx = SupersetRoundContext(
                                    setIndex: parentSetIndex,
                                    participants: participants,
                                    lastRoundIndex: lastRoundIndex(in: block),
                                    supersetRoundRestSeconds:
                                        block.supersetRoundRestSeconds,
                                    blockRestAfterSeconds: block.restAfterSeconds,
                                    isLastBlockOfWorkout:
                                        currentBlockIndex == plan.blocks.count - 1,
                                    // Unused by this planner entry-point.
                                    isLastExerciseOfBlock: false
                                )
                                if let r = RestPlanner
                                    .restSecondsAfterFinalDropInSuperset(ctx),
                                    r > 0
                                {
                                    startRestWithPersistence(
                                        seconds: r, slotID: exercise.routineSlotID)
                                    showRestOverlay = true
                                } else {
                                    // Round incomplete, last set of workout, or
                                    // no planned rest configured. Clear any
                                    // stale running rest from earlier in the round.
                                    rest.stop()
                                    clearPersistedRestState()
                                }
                                // Advance focus the same way a normal parent
                                // log does once the dropset set is now fully
                                // complete.
                                advanceForSupersetAfterLog(
                                    setIndex: parentSetIndex, in: block)
                            } else {
                                // Phase 7.4-C.3 — non-superset dropset-final-drop
                                // rest extracted to RestPlanner. No template-rest
                                // fallback in this chain (the dropset parent
                                // template's rest is intentionally bypassed).
                                let exSetCount = effectiveSetCount(
                                    for: exercise, resolvedTemplates: exercise.templates)
                                let isLastWorkingSet =
                                    parentSetIndex == exSetCount - 1
                                let isLastSetOfWorkout: Bool = {
                                    guard let cb = currentBlock else { return false }
                                    return currentBlockIndex == plan.blocks.count - 1
                                        && currentExerciseIndex
                                            == cb.exercises.count - 1
                                        && isLastWorkingSet
                                }()
                                if let r = RestPlanner
                                    .restSecondsAfterFinalDropInExercise(
                                        setIndex: parentSetIndex,
                                        effectiveSetCount: exSetCount,
                                        plannedRestBetweenSets:
                                            plannedRestBetweenSets(for: exercise),
                                        plannedRestAfterExercise:
                                            plannedRestAfterExercise(for: exercise),
                                        isLastSetOfWorkout: isLastSetOfWorkout
                                    ), r > 0
                                {
                                    startRestWithPersistence(
                                        seconds: r, slotID: exercise.routineSlotID)
                                    showRestOverlay = true
                                }
                            }
                        } else {
                            // Non-final drop: intra-drop rest (dropset-specific
                            // only; no prescription fallback). Kept inline per
                            // Phase 7.4-C.3 scope.
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
                            slotID: slotID,
                            parentSetIndex: parentSetIndex,
                            subIndex: sub
                        )
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    },
                    onResetWeight: canReset ? {
                        dropWeightUserEdited.remove(key)
                        dropWeightInput.removeValue(forKey: key)
                        dropWeightDraftStore?.clear(slotKey: key)
                        // Compat: also clear any pre-migration legacy entry.
                        dropWeightDraftStore?.clear(slotKey: legacyKey)
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
            // Phase 7.4-C.2: superset rest computation extracted to RestPlanner.
            // The planner handles mid-round suppression, base round rest +
            // per-exercise fallback chain (normal-round and after-dropset
            // variants), next-round-dropset skip, final-round transition
            // replacement via `block.restAfterSeconds`, and last-set-of-workout
            // suppression. The view returns the planner's result directly so
            // the trailing non-superset post-processing below doesn't double-
            // apply the additive `restAfterSeconds`.
            let isLastBlock = currentBlockIndex == plan.blocks.count - 1
            let isLastExerciseOfBlock =
                currentExerciseIndex == block.exercises.count - 1
            let participants: [SupersetRoundParticipant] =
                block.exercises.map { ex in
                    let sc = effectiveSetCount(
                        for: ex, resolvedTemplates: ex.templates)
                    let participates = idx < sc
                    let curKind: SetKind =
                        ex.templates[safe: idx]?.kind ?? .working
                    let nextKind: SetKind? =
                        (idx + 1 < sc)
                            ? (ex.templates[safe: idx + 1]?.kind ?? .working)
                            : nil
                    return SupersetRoundParticipant(
                        participates: participates,
                        isComplete: participates
                            ? isWorkingSetComplete(exercise: ex, setIndex: idx)
                            : true,
                        plannedRestBetweenSets: plannedRestBetweenSets(for: ex),
                        currentTemplateKind: curKind,
                        currentTemplateRestSecondsAfter:
                            ex.templates[safe: idx]?.restSecondsAfter,
                        nextTemplateKind: nextKind,
                        priorWorkingRest:
                            priorWorkingRest(in: ex.templates, upTo: idx)
                    )
                }
            return RestPlanner.restSecondsAfterSupersetRound(
                SupersetRoundContext(
                    setIndex: idx,
                    participants: participants,
                    lastRoundIndex: lastRoundIndex(in: block),
                    supersetRoundRestSeconds: block.supersetRoundRestSeconds,
                    blockRestAfterSeconds: block.restAfterSeconds,
                    isLastBlockOfWorkout: isLastBlock,
                    isLastExerciseOfBlock: isLastExerciseOfBlock
                )
            )
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

        // --- Append block rest if this was the final set of the block ---
        // Non-superset only: the superset path returns from RestPlanner
        // above (which already accounts for transition replacement).
        if let current = currentBlock, current.id == block.id {
            let isLastExerciseOfBlock =
                (currentExerciseIndex == block.exercises.count - 1)
            let exSetCount = effectiveSetCount(
                for: exercise, resolvedTemplates: exercise.templates)
            let isFinal =
                (idx == exSetCount - 1) && isLastExerciseOfBlock

            if isFinal, let extra = block.restAfterSeconds, extra != 0 {
                // Non-superset legacy: additive on top of the final-set rest.
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


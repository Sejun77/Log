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
//   `SetupNotesEditSheet`                   → `SetupNotesEditSheet.swift`
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

    /// Identifiable presentation token for the Switch Exercise picker sheet.
    /// Driving the sheet via `.sheet(item:)` (instead of a separate `Bool`
    /// plus an optional index read inside the content closure) guarantees the
    /// picker only renders once a valid slot index exists — fixing a blank
    /// first presentation when the index hadn't committed yet. `index` is the
    /// slot's position in `currentBlock`.
    private struct SwapPickerItem: Identifiable {
        let index: Int
        var id: Int { index }
    }

    /// The plan a pending switch will apply. Mirrors
    /// `ExerciseSwitchPlanAdapter.Choice`, but holds the whole
    /// `SlotAlternative` rather than only its prescription, because the view
    /// also needs the alternative's exercise reference to resolve the switch
    /// target.
    private enum PendingSwapPlan: Equatable {
        case keepCurrentPlan
        case resetPlan
        case useAlternative(SlotAlternative)

        /// True only for the explicit "start over" choice, which is the one
        /// that may auto-open the Edit Plan sheet. A prepared alternative
        /// arrives with a full plan, so it never should.
        var isReset: Bool { self == .resetPlan }

        var adapterChoice: ExerciseSwitchPlanAdapter.Choice {
            switch self {
            case .keepCurrentPlan: return .keepCurrentPlan
            case .resetPlan: return .resetPlan
            case .useAlternative(let alternative):
                return .useAlternative(alternative.prescription)
            }
        }
    }

    @State private var exerciseToSwapIndex: Int? = nil
    @State private var swapPickerItem: SwapPickerItem? = nil
    @State private var pendingSwapNewExercise: Exercise? = nil
    @State private var showSwapPlanChoice = false
    /// Second-stage destructive confirmation, shown only when the pending
    /// switch would delete logged sets. Nil impact = nothing to warn about.
    @State private var showSwapDestructiveConfirm = false
    @State private var pendingSwapImpact: ExerciseSwitchDeletionImpact? = nil
    /// Which plan the pending switch will apply once every confirmation has
    /// passed. Replaced the pre-F1 `Bool` when prepared alternatives became a
    /// third answer to the same question — a `Bool` cannot carry the payload,
    /// and a second parallel flag would let "reset" and "alternative" both be
    /// true.
    @State private var pendingSwapPlan: PendingSwapPlan = .keepCurrentPlan
    /// Non-nil presents the Prepared Alternatives sheet (Phase F1). Only ever
    /// set when the slot actually has an offer, so a slot without alternatives
    /// keeps exactly its pre-F1 flow.
    @State private var preparedAlternativesItem: SwapPickerItem? = nil
    /// Set by the Prepared Alternatives sheet and consumed in its `onDismiss`.
    @State private var pendingPreparedAlternative: SlotAlternative? = nil
    @State private var pendingChooseAnotherExercise = false
    @Query(sort: \Exercise.name) private var allExercises: [Exercise]

    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    @State private var workout: Workout?
    @State private var currentBlockIndex = 0
    @State private var currentExerciseIndex = 0
    @State private var showEndConfirm = false
    @State private var showFinishConfirm = false
    /// The finish variant chosen in the finish-confirmation dialog, recorded
    /// by the dialog button and consumed exactly once on the next main-actor
    /// turn (see the `.onChange` next to the dialog). Running `finishWorkout`
    /// directly inside the dialog button action made its final `dismiss()`
    /// (navigation pop) race the dialog's own dismissal transaction — when a
    /// same-frame re-render landed (e.g. the per-second rest-timer toolbar
    /// tick), the pop was intermittently dropped and the first confirm tap
    /// appeared to do nothing.
    @State private var pendingFinishOption: FinishDialogOption? = nil
    @State private var sessionPlans: [UUID: SessionPlan] = [:]
    @State private var showEditPlanSheet = false
    @State private var showExerciseNotesSheet = false
    @State private var showSetupNotesSheet = false
    /// Local draft for session notes. Typing mutates only this string; it is
    /// committed to `Workout.notes` at discrete points (focus loss, disappear,
    /// scene backgrounding) so per-keystroke edits never invalidate this
    /// ~3400-line body via the model's Observation tracking.
    @State private var sessionNotesDraft = ""
    @FocusState private var sessionNotesFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// Tracks soft-keyboard visibility (driven by keyboardWillShow/Hide). While
    /// the keyboard is up the bottom Back/Next/Finish panel is withdrawn so it
    /// can never overlap the keyboard accessory — deterministic on first focus,
    /// unlike safe-area repositioning which lagged a frame on initial show.
    @State private var keyboardVisible = false
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

    /// Duration-based set countdown. Owns a **separate** persistence namespace
    /// from `rest`; sharing one made a running duration set rehydrate into the
    /// rest timer on foreground and present the "Rest" overlay.
    @StateObject private var setTimer = RestTimer(
        namespace: RestTimer.Namespace.set
    )
    @State private var showSetOverlay = false

    @StateObject private var rest = RestTimer(
        namespace: RestTimer.Namespace.rest
    )

    // Phase 5.2 — keyed by routineSlotID (per-slot identity).
    // The "ByExerciseID" suffix is legacy naming; the value is a per-slot
    // WorkoutItem looked up by `WorkoutItem.routineSlotID`.
    @State private var itemsByExerciseID: [UUID: WorkoutItem] = [:]

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    /// Cardio Slice 8 patch: observable, so a Settings change re-renders this
    /// view. `AppSettings.distanceUnit` is a plain `UserDefaults` read and
    /// SwiftUI cannot see it — reading it in a `body` renders the right unit
    /// once and then never updates. See `AppSettings.distanceUnit`.
    @AppStorage(AppSettings.Keys.distanceIsMetric)
    private var distanceIsMetric: Bool = AppSettings.defaultDistanceIsMetric()

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    // Phase 5.2 — keyed by routineSlotID (per-slot identity).
    @State private var inputsByExerciseID:
        [UUID: [Int: (reps: String, weight: String, duration: String)]] = [:]

    // Slice 2 — last-performance prefill suggestions, keyed by routineSlotID,
    // each holding the previous-session working-set map (setIndex →
    // suggestion) for that slot's current exercise. Computed once in onAppear
    // (`loadLastPerformancePrefill`) from completed workouts excluding this
    // session, then consulted by `tier4Default` at the bottom of the seeding
    // priority chain. Empty when there is no prior completed history.
    @State private var prefillBySlotID:
        [UUID: [Int: LastPerformancePrefillService.LastPerformanceSetSuggestion]] = [:]

    // Slice 3 — dropset sub-row last-performance prefill, keyed by
    // routineSlotID → [parentSetIndex: [subIndex: suggestion]] for that slot's
    // current exercise. Loaded alongside `prefillBySlotID` in
    // `loadLastPerformancePrefill`, then consulted as a read-time fallback in
    // `buildDropSection` (never seeded into dropRepsInput/dropWeightInput, so
    // it cannot mark a weight as user-overridden). Empty when no prior drops.
    // Cardio Slice 7 — previous-performance prefill for the cardio metric
    // fields, keyed by routineSlotID. Loaded from the same completed-workout
    // fetch as `prefillBySlotID` and re-pointed by the same switch hook, so
    // cardio prefill can never disagree with strength prefill about which
    // workouts are eligible. Holds only the prefillable subset — distance,
    // unit, incline, resistance — never the outcome metrics.
    @State private var cardioPrefillBySlotID:
        [UUID: [Int: CardioPrefillSuggestion]] = [:]

    @State private var dropPrefillBySlotID:
        [UUID: [Int: [Int: LastPerformancePrefillService.LastPerformanceDropSuggestion]]] = [:]

    // Cardio Slice 4 — per-set optional metric drafts, keyed by routineSlotID →
    // setIndex, in the same shape as `inputsByExerciseID`. Holds raw entry text
    // (not `CardioMetrics`) so a half-typed "6." survives navigation; it is
    // normalized once, at log time.
    @State private var cardioDraftsBySlotID: [UUID: [Int: CardioEntryDraft]] = [:]

    // Slots whose current exercise is `.cardio`. Cached rather than fetched
    // per row: the row builder runs inside `body` for every visible set, and a
    // SwiftData fetch there would be exactly the kind of work CLAUDE.md rules
    // out. Recomputed at session start and after an exercise switch — the two
    // moments a slot's tracking mode can change.
    //
    // Drives two things: whether the row offers the cardio Details section,
    // and — via `showsEffortUI` — whether the combined RIR/RPE control is
    // shown at all.
    @State private var cardioSlotIDs: Set<UUID> = []

    // Structured Cardio Slice 12D — ticked checklist segments, keyed by
    // routineSlotID → the `ResolvedCardioSegment.id`s the user has checked off.
    //
    // **Session-scoped progress, never a result.** It is persisted only to
    // `CardioSegmentCheckStore` (UserDefaults, per workout) so Save & Exit and
    // a cold resume restore the ticks; nothing here reaches `SetLog`,
    // `WorkoutItem`, or `Workout`. The bout is still logged as one aggregate
    // cardio set from the duration + Details fields.
    //
    // Empty for every slot without a structured plan, which is every strength
    // slot, every timed hold, and every cardio slot programmed without
    // segments.
    @State private var cardioSegmentChecksBySlotID: [UUID: Set<String>] = [:]

    /// Whether this slot shows the combined RIR/RPE effort control. Delegates
    /// to `WorkoutEffortTargetResolver.isEffortApplicable`, which owns the
    /// product rule, so the three display sites (per-set row labels, Plan card
    /// summary, Edit Plan sheet) cannot drift apart.
    private func showsEffortUI(forSlot slotID: UUID) -> Bool {
        WorkoutEffortTargetResolver.isEffortApplicable(
            to: cardioSlotIDs.contains(slotID) ? .cardio : .timedHold)
    }

    /// Rebuilds `cardioSlotIDs` from the live `Exercise` rows behind the plan's
    /// current exercise ids. Reading the model (rather than a denormalized flag
    /// on `PlanExercise`) means a slot swapped to or from a cardio exercise is
    /// picked up for free, without touching the exercise-switch adapter.
    private func refreshCardioSlots() {
        var ids: Set<UUID> = []
        for block in plan.blocks {
            for ex in block.exercises {
                guard let live = fetchExercise(by: ex.currentExerciseID) else {
                    continue
                }
                if live.trackingMode == .cardio {
                    ids.insert(ex.routineSlotID)
                }
            }
        }
        cardioSlotIDs = ids
    }

    /// Structured Cardio Slice 12D — the resolved segment plan for a slot, or
    /// nil when it has none.
    ///
    /// Gated on `cardioSlotIDs` before anything is decoded, so the checklist
    /// can only ever appear on a slot whose **live** exercise is cardio. That
    /// matters after a switch: the routine's stored plan and a frozen snapshot
    /// may both still carry segments for the exercise that was replaced, and
    /// the tracking mode — not the payload — is what decides whether they mean
    /// anything now.
    ///
    /// Resolution below that gate is the standard two-tier walk (session plan →
    /// frozen snapshot), and both tiers decode tolerantly: a corrupt payload
    /// resolves to nil, exactly like a slot that never had a plan.
    private func structuredCardioPlan(
        for exercise: PlanExercise
    ) -> CardioSegmentPlan? {
        let slotID = exercise.routineSlotID
        guard cardioSlotIDs.contains(slotID) else { return nil }
        return SessionPlanResolver.plannedCardioSegments(
            sessionPlan: sessionPlans[slotID],
            snapshot: exercise.prescriptionSnapshot)
    }

    /// Per-workout store for the checklist ticks. Nil until the workout exists,
    /// exactly like `parentDraftStore`.
    private var cardioSegmentCheckStore: CardioSegmentCheckStore? {
        workout.map { CardioSegmentCheckStore(workoutID: $0.id) }
    }

    /// Binding for one slot's ticked segments. Writes through to the store on
    /// every toggle, mirroring how the cardio draft binding persists on every
    /// keystroke — so Save & Exit, a force-quit, and a cold resume all restore
    /// the same ticks without a commit point to miss.
    private func cardioSegmentChecksBinding(
        slotID: UUID
    ) -> Binding<Set<String>> {
        Binding(
            get: { cardioSegmentChecksBySlotID[slotID] ?? [] },
            set: { newValue in
                cardioSegmentChecksBySlotID[slotID] = newValue
                cardioSegmentCheckStore?.save(
                    slotID: slotID, checked: newValue)
            }
        )
    }

    /// Restore ticks on resume, dropping any that no longer name a segment in
    /// the slot's resolved plan.
    ///
    /// Runs after `refreshCardioSlots()` so the cardio gate is current. Orphans
    /// — from a routine whose plan was edited between sessions, or a slot
    /// switched away from cardio in a previous process — are dropped in memory
    /// and rewritten out of the store, so they cannot accumulate.
    private func rehydrateCardioSegmentChecks() {
        guard let store = cardioSegmentCheckStore else { return }
        let persisted = store.loadAll()
        guard !persisted.isEmpty else { return }

        var restored: [UUID: Set<String>] = [:]
        for block in plan.blocks {
            for ex in block.exercises {
                let slotID = ex.routineSlotID
                guard persisted[slotID] != nil else { continue }
                let live = store.checked(
                    slotID: slotID, in: structuredCardioPlan(for: ex))
                if live.isEmpty {
                    store.clear(slotID: slotID)
                } else {
                    restored[slotID] = live
                    // Rewrite so a partially-orphaned entry is pruned on disk
                    // too, not just in memory.
                    store.save(slotID: slotID, checked: live)
                }
            }
        }
        cardioSegmentChecksBySlotID = restored
    }

    /// Reconcile a slot's ticks with its post-switch plan.
    ///
    /// One rule covers all four switch directions, because the plan already
    /// encodes them (`ExerciseSwitchPlanAdapter`): keep the ticks whose segment
    /// is still in the slot's resolved plan, drop the rest.
    ///
    ///  * cardio → cardio, **Keep** — the plan was preserved, so every tick
    ///    still matches and every tick survives.
    ///  * cardio → cardio, **Reset** — the plan is the reset source's (normally
    ///    none), so mismatched ticks go.
    ///  * cardio → strength / timed hold — the adapter cleared the plan and the
    ///    cardio gate is false, so the resolved plan is nil and every tick goes.
    ///  * strength / timed hold → cardio — there were no ticks to keep, and the
    ///    checklist appears only if the new plan has segments.
    private func reconcileCardioSegmentChecks(slotID: UUID) {
        guard let (bi, ei) = findSlotIndex(in: plan, routineSlotID: slotID)
        else { return }
        let resolved = structuredCardioPlan(
            for: plan.blocks[bi].exercises[ei])
        let kept = cardioSegmentCheckStore?
            .checked(slotID: slotID, in: resolved) ?? []
        if kept.isEmpty {
            cardioSegmentChecksBySlotID[slotID] = nil
            cardioSegmentCheckStore?.clear(slotID: slotID)
        } else {
            cardioSegmentChecksBySlotID[slotID] = kept
            cardioSegmentCheckStore?.save(slotID: slotID, checked: kept)
        }
    }

    /// Binding for one set's cardio draft. Writes straight through to
    /// `ParentDraftStore`, mirroring how `durationBinding` persists on every
    /// keystroke so an in-flight entry survives Save & Exit or a force-quit.
    private func cardioDraftBinding(
        slotID: UUID, setIndex: Int
    ) -> Binding<CardioEntryDraft> {
        Binding(
            get: {
                cardioDraftsBySlotID[slotID]?[setIndex]
                    ?? CardioEntryDraft(unit: distanceUnit)
            },
            set: { newValue in
                cardioDraftsBySlotID[slotID, default: [:]][setIndex] = newValue
                parentDraftStore?.persist(
                    slotID: slotID, setIndex: setIndex, cardio: newValue)
            }
        )
    }

    /// The metrics a cardio set would log right now; empty for every
    /// non-cardio slot, which is what keeps strength and timed-hold logging
    /// byte-identical.
    private func cardioMetricsForLog(slotID: UUID, setIndex: Int) -> CardioMetrics {
        guard cardioSlotIDs.contains(slotID),
            let draft = cardioDraftsBySlotID[slotID]?[setIndex]
        else { return CardioMetrics() }
        return draft.metrics
    }

    /// Restores cardio drafts on resume, with the same precedence the
    /// reps/weight/duration rehydrate uses: a persisted `SetLog` wins (the set
    /// is logged and its fields are read-only), else the persisted draft, else
    /// nothing. Runs after `rehydrateFromWorkoutIfPresent` so `itemsByExerciseID`
    /// is populated.
    private func rehydrateCardioDrafts() {
        let displayUnit = distanceUnit
        var drafts = cardioDraftsBySlotID
        var cardioSlots: [UUID] = []

        for block in plan.blocks {
            for ex in block.exercises where cardioSlotIDs.contains(ex.routineSlotID) {
                let slotID = ex.routineSlotID
                cardioSlots.append(slotID)

                // A slot swapped mid-session carries logs and persisted drafts
                // belonging to a *different* exercise, so neither may be
                // restored onto it — exactly as the parent rehydrate skips it.
                // Target seeding still applies afterwards: that reads the
                // slot's **adapted** plan, which already describes the
                // switched-in exercise. Skipping seeding too would make a
                // resume disagree with the live view, which is the class of bug
                // Slice 6 is about.
                if ex.originalExerciseID != ex.currentExerciseID { continue }

                let item = itemsByExerciseID[slotID]
                    ?? workout?.items.first(where: { $0.routineSlotID == slotID })
                var perSet = drafts[slotID] ?? [:]

                let setCount = effectiveSetCount(
                    for: ex, resolvedTemplates: ex.templates)

                for i in 0..<setCount {
                    let loggedSet = item?.setLogs.last(where: {
                        $0.indexInExercise == i && $0.subIndex == nil
                    })
                    if let loggedSet, loggedSet.hasCardioMetrics {
                        perSet[i] = CardioEntryDraft(
                            logged: loggedSet, displayUnit: displayUnit)
                    } else if loggedSet == nil,
                        let snapshot = parentDraftStore?.load(
                            slotID: slotID, setIndex: i),
                        let restored = CardioEntryDraft(
                            snapshot: snapshot, displayUnit: displayUnit)
                    {
                        perSet[i] = restored
                    }
                }
                drafts[slotID] = perSet
            }
        }
        cardioDraftsBySlotID = drafts

        // Tier 3, applied last and only to entries the two tiers above left
        // absent. A logged set wins, then a persisted draft — which exists the
        // moment the user types in *any* cardio field, including when they
        // clear the distance back to empty. So the target only ever fills a
        // field nobody has touched, and Save & Exit → Resume can never
        // overwrite an edit with it.
        for slotID in cardioSlots { seedCardioDraftsFromTarget(slotID: slotID) }
    }

    /// Seed a cardio slot's untouched metric drafts from its resolved routine
    /// target distance.
    ///
    /// This is **prescription initialization, not prefill**: it reads the plan
    /// the session was started with (or the plan a switch just adapted), never
    /// previous performance. History-based cardio prefill remains a later
    /// slice.
    ///
    /// Only fills `perSet[i]` entries that are absent, so it can be called
    /// freely — after a resume, or after a switch — without ever overwriting a
    /// restored or in-progress draft. Deliberately not written through
    /// `parentDraftStore`: leaving the seed unpersisted is what keeps "seeded"
    /// and "user-touched" distinguishable on the next resume.
    private func seedCardioDraftsFromTarget(slotID: UUID) {
        applyCardioDraftSeeding(slotID: slotID, replacingTargetSeeded: false)
    }

    /// Re-seed a cardio slot after the target distance was changed in Edit
    /// Plan, replacing the drafts the user has not typed into.
    ///
    /// The discriminator is the one the seeding contract has always relied on:
    /// **a seeded draft is never persisted, a typed one always is.**
    /// `ParentDraftStore` writes on every keystroke — including writing an
    /// empty string when the user clears the field — so the presence of a
    /// persisted cardio snapshot means "the user touched this", and its absence
    /// means "this is ours to refresh". That is the same rule that makes a
    /// resume prefer a typed draft over the target, which is why the live view
    /// and the resume path land in the same place.
    private func resyncCardioDraftsToTarget(slotID: UUID) {
        applyCardioDraftSeeding(slotID: slotID, replacingTargetSeeded: true)
    }

    /// This slot's cardio draft source for one set, resolved from the four
    /// inputs that decide it. Derived rather than stored, so it survives a
    /// resume for free and cannot drift out of step with the drafts.
    private func cardioDraftSource(
        slotID: UUID, setIndex: Int, hasPrefillDistance: Bool, hasTarget: Bool
    ) -> CardioDraftSource {
        CardioDraftResolver.source(
            isLogged: loggedByExercise[slotID]?.contains(setIndex) ?? false,
            hasUserDraft: parentDraftStore?
                .load(slotID: slotID, setIndex: setIndex)?.hasCardio ?? false,
            hasPrefillDistance: hasPrefillDistance,
            hasTarget: hasTarget)
    }

    /// Seed a cardio slot's entry fields from the one precedence chain:
    /// **logged set → user-typed draft → previous performance → routine
    /// target** (`CardioDraftResolver`).
    ///
    /// - Parameter replacingTargetSeeded: when false, only sets with no draft
    ///   at all are filled (session start, resume, post-switch). When true — the
    ///   Edit Plan path — a draft the **target itself** put there is refreshed
    ///   or cleared to match the new target, while a typed or
    ///   previous-performance draft is left alone. That distinction is the
    ///   whole reason `CardioDraftSource` exists: before Slice 7 "not
    ///   persisted" meant "target seeded", and now it can also mean "prefilled
    ///   from what you actually did last time", which a target edit has no
    ///   business overwriting.
    private func applyCardioDraftSeeding(
        slotID: UUID, replacingTargetSeeded: Bool
    ) {
        guard cardioSlotIDs.contains(slotID),
            let (bi, ei) = findSlotIndex(in: plan, routineSlotID: slotID)
        else { return }

        let ex = plan.blocks[bi].exercises[ei]
        // One preference read for the whole slot: targets and previous-bout
        // prefills alike are expressed in the Settings unit, because both are
        // being rendered into the same editable field.
        let displayUnit = distanceUnit
        let target = SessionPlanResolver.plannedTargetDistance(
            sessionPlan: sessionPlans[slotID],
            snapshot: ex.prescriptionSnapshot,
            displayUnit: displayUnit)
        let prefillMap = cardioPrefillBySlotID[slotID] ?? [:]

        let setCount = effectiveSetCount(
            for: ex, resolvedTemplates: ex.templates)
        var perSet = cardioDraftsBySlotID[slotID] ?? [:]

        for i in 0..<setCount {
            let prefill = CardioPrefillService.suggestion(
                forCurrentSetIndex: i, from: prefillMap)
            let source = cardioDraftSource(
                slotID: slotID, setIndex: i,
                hasPrefillDistance: prefill?.distanceMeters != nil,
                hasTarget: target != nil)

            // A logged set mirrors what was recorded and is read-only until
            // Undo; a typed draft is the user's. Neither is ours to write.
            if source == .logged || source == .userTyped { continue }

            let seeded = CardioDraftResolver.seededDraft(
                prefill: prefill, target: target, displayUnit: displayUnit)

            if perSet[i] == nil {
                guard let seeded else { continue }
                perSet[i] = seeded
                continue
            }

            guard replacingTargetSeeded else { continue }
            // Only the target's own seed may be rewritten by a target edit.
            guard CardioDraftResolver.targetEditMayReplace(source) else {
                continue
            }
            // Preserve anything else on the row (there is nothing today, but
            // that keeps this honest if seeding ever widens) and move only the
            // target-derived fields — clearing them when the target is gone,
            // which is what makes deleting a target visibly empty the row.
            var draft = perSet[i] ?? CardioEntryDraft(unit: displayUnit)
            draft.unit = displayUnit
            draft.distance = seeded?.distance ?? ""
            perSet[i] = draft
        }
        cardioDraftsBySlotID[slotID] = perSet
    }

    /// The unit every cardio row displays and edits in, derived from the
    /// observable preference so `.onChange(of: distanceUnit)` fires.
    private var distanceUnit: DistanceUnit {
        AppSettings.distanceUnit(isMetric: distanceIsMetric)
    }

    /// Re-express every in-flight cardio draft in `newUnit`.
    ///
    /// This is the whole live-refresh fix. Each draft is converted through the
    /// pure `CardioEntryDraft.converted(to:)`, so a parseable distance keeps
    /// its meters and changes only how it reads, an empty row stays empty, and
    /// half-typed text is preserved verbatim. The collapsed preview, the
    /// distance suffix, pace and speed all read `draft.unit`, so they follow
    /// from this one assignment rather than needing to be refreshed separately.
    ///
    /// **Deliberately does not persist.** It writes `cardioDraftsBySlotID`
    /// directly rather than going through `cardioDraftBinding`, whose setter
    /// would push every row into `ParentDraftStore`. Changing a display
    /// preference is not the user editing their workout, and the persisted
    /// draft does not need rewriting to stay correct: it records the text
    /// *with the unit it was typed in*, and
    /// `CardioEntryDraft.init(snapshot:displayUnit:)` converts on resume. So a
    /// resumed session shows exactly what the live one showed, without this
    /// having touched the store.
    ///
    /// Logged sets are included: their rows are read-only mirrors of what was
    /// recorded, and re-expressing one converts its display only — the `SetLog`
    /// is not reachable from here.
    private func resyncCardioDrafts(to newUnit: DistanceUnit) {
        for (slotID, perSet) in cardioDraftsBySlotID {
            for (setIndex, draft) in perSet where draft.unit != newUnit {
                cardioDraftsBySlotID[slotID]?[setIndex] =
                    draft.converted(to: newUnit)
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
                    perSet[i] = tier4Default(for: ex, setIndex: i, template: tpl)
                }
                inputsByExerciseID[ex.routineSlotID] = perSet
            }
        }
        syncToGuardCaches()
    }

    /// Tier-4 seed value for one set: the lowest priority in the draft
    /// seeding chain (below logged sets, persisted drafts, and the guard
    /// cache). Computes the prescription defaults exactly as before, then
    /// lets `resolvedDraftDefault` overlay any last-performance suggestion
    /// per the v1 rules (weighted → reps+weight, bodyweight → reps only,
    /// time-based → duration only). With no prior history the prescription
    /// defaults pass through unchanged.
    private func tier4Default(
        for ex: PlanExercise,
        setIndex i: Int,
        template tpl: PlanSetTemplate
    ) -> (reps: String, weight: String, duration: String) {
        let presReps = String(plannedRepTarget(for: ex, template: tpl))
        let presWeight = tpl.targetWeight.map { String($0) } ?? ""
        let presDuration =
            plannedDurationTarget(for: ex, template: tpl)
            .map { String($0) } ?? ""

        let suggestion = LastPerformancePrefillService.suggestion(
            forCurrentSetIndex: i,
            from: prefillBySlotID[ex.routineSlotID] ?? [:]
        )

        return resolvedDraftDefault(
            suggestion: suggestion,
            prescriptionReps: presReps,
            prescriptionWeight: presWeight,
            prescriptionDuration: presDuration,
            isTimeBased: ex.isTimeBased,
            isBodyweight: isBodyweightEquipment(resolvedActiveEquipment(for: ex))
        )
    }

    /// Equipment string to use for a slot's equipment-dependent behavior
    /// during the active workout — both prefill's bodyweight classification
    /// and the set-row weight-field visibility / bodyweight handling.
    /// Non-swapped slots use the immutable session-start snapshot (unchanged
    /// behavior); a swapped-in exercise uses its own LIVE `equipmentType` so
    /// e.g. swapping a bodyweight movement for a barbell lift shows the weight
    /// field (and vice-versa) instead of trusting the old exercise's snapshot.
    private func resolvedActiveEquipment(for ex: PlanExercise) -> String? {
        let isSwapped = ex.currentExerciseID != ex.originalExerciseID
        return resolvedSwappedValue(
            isSwapped: isSwapped,
            live: isSwapped
                ? fetchExercise(by: ex.currentExerciseID)?.equipmentType : nil,
            snapshot: ex.prescriptionSnapshot?.equipment)
    }

    /// Loads last-performance prefill suggestions once at session start.
    /// Fetches completed workouts (`completedAt != nil`) and, per plan slot,
    /// asks `LastPerformancePrefillService` for the most-recent working-set
    /// map for that slot's CURRENT exercise (so a swapped-in exercise sources
    /// its own history). The active session is excluded by id. Slots with no
    /// prior history are omitted, so `tier4Default` falls back to prescription
    /// defaults for them. Read-only; never mutates any model.
    private func loadLastPerformancePrefill() {
        let currentID = workout?.id
        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.completedAt != nil },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        guard let completed = try? ctx.fetch(descriptor) else { return }

        var map:
            [UUID: [Int: LastPerformancePrefillService.LastPerformanceSetSuggestion]] =
                [:]
        // Slice 3 — dropset sub-row prefill, reusing the same fetch.
        var dropMap:
            [UUID: [Int: [Int: LastPerformancePrefillService.LastPerformanceDropSuggestion]]] =
                [:]
        // Slice 7 — cardio metric prefill, reusing the same fetch.
        var cardioMap: [UUID: [Int: CardioPrefillSuggestion]] = [:]
        for block in plan.blocks {
            for ex in block.exercises {
                let suggestions = LastPerformancePrefillService.suggestions(
                    forExerciseID: ex.currentExerciseID,
                    in: completed,
                    excluding: currentID
                )
                if !suggestions.isEmpty {
                    map[ex.routineSlotID] = suggestions
                }
                let drops = LastPerformancePrefillService.dropSuggestions(
                    forExerciseID: ex.currentExerciseID,
                    in: completed,
                    excluding: currentID
                )
                if !drops.isEmpty {
                    dropMap[ex.routineSlotID] = drops
                }
                let cardio = CardioPrefillService.suggestions(
                    forExerciseID: ex.currentExerciseID,
                    in: completed,
                    excluding: currentID
                )
                if !cardio.isEmpty {
                    cardioMap[ex.routineSlotID] = cardio
                }
            }
        }
        prefillBySlotID = map
        dropPrefillBySlotID = dropMap
        cardioPrefillBySlotID = cardioMap
    }

    /// Re-points a slot's last-performance prefill at the exercise that was
    /// just switched in.
    ///
    /// **Draft-only, by construction.** The only state this writes is
    /// `prefillBySlotID` / `dropPrefillBySlotID` — two `@State` dictionaries of
    /// value-type suggestions. They are read in exactly two places, both of
    /// which produce *editable draft text*:
    ///
    ///  * `tier4Default` → `resolvedDraftDefault`, the lowest tier of the set
    ///    draft seeding chain, whose result lands in `inputsByExerciseID`;
    ///  * `buildDropSection`, as a read-time fallback for dropset sub-rows
    ///    (never seeded, so it can't mark a weight user-overridden).
    ///
    /// Nothing here touches `sessionPlans`, `prescriptionSnapshot`,
    /// `WorkoutItem.plannedPrescriptionSnapshot`, the routine template, the
    /// `Exercise` row, or any of the plan values (set count, rest, RIR/RPE,
    /// tempo, warm-ups, techniques, prescription notes). The plan is decided
    /// solely by `ExerciseSwitchPlanAdapter`, and this runs *after* that
    /// decision has already been applied — so a suggestion can only ever
    /// change what a field is pre-filled with, never what the workout plans.
    /// It is also read-only against SwiftData: it fetches completed workouts
    /// and mutates no model.
    ///
    /// **Order matters.** The clear is not optional: `prefillBySlotID[slotID]`
    /// still holds the suggestions loaded at session start for the exercise
    /// that was just REPLACED. Overwriting unconditionally would be enough
    /// when the new exercise HAS history, but when it has none the stale
    /// entry would survive and overlay Exercise A's last performance onto
    /// Exercise B. Clearing first makes the no-history case fall through to
    /// prescription defaults, as required.
    ///
    /// Mirrors `loadLastPerformancePrefill`'s fetch / service / exclusion
    /// rules — current session excluded by id, `excludedFromPrefill` workouts
    /// skipped inside the service — but scoped to one slot, so other slots and
    /// the normal workout-start prefill are untouched.
    private func refreshLastPerformancePrefill(
        forSlotID slotID: UUID, exerciseID: UUID
    ) {
        // 1) Clear the replaced exercise's stale suggestions for this slot.
        prefillBySlotID[slotID] = nil
        dropPrefillBySlotID[slotID] = nil
        cardioPrefillBySlotID[slotID] = nil

        // 2) Load the switched-in exercise's own history, if any. A nil/empty
        //    result leaves the slot cleared, so seeding falls back to the
        //    prescription defaults resolved from the adapted plan.
        let currentID = workout?.id
        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.completedAt != nil },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        guard let completed = try? ctx.fetch(descriptor) else { return }

        let suggestions = LastPerformancePrefillService.suggestions(
            forExerciseID: exerciseID, in: completed, excluding: currentID)
        prefillBySlotID[slotID] = suggestions.isEmpty ? nil : suggestions

        let drops = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: exerciseID, in: completed, excluding: currentID)
        dropPrefillBySlotID[slotID] = drops.isEmpty ? nil : drops

        let cardio = CardioPrefillService.suggestions(
            forExerciseID: exerciseID, in: completed, excluding: currentID)
        cardioPrefillBySlotID[slotID] = cardio.isEmpty ? nil : cardio
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
                            log.weight.map { Units.formatWeight($0) } ?? ""
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
                        // Backfill any field absent from the draft with the
                        // tier-4 default (last-performance prefill, else
                        // prescription) so partially-filled drafts don't blank
                        // unrelated fields.
                        let d = tier4Default(for: ex, setIndex: i, template: tpl)
                        perSet[i] = (
                            reps: draft.reps ?? d.reps,
                            weight: draft.weight ?? d.weight,
                            duration: draft.duration ?? d.duration
                        )
                    } else if let cached = activeGuard.inputsCache[slotID]?[i] {
                        perSet[i] = cached
                    } else {
                        perSet[i] = tier4Default(
                            for: ex, setIndex: i, template: tpl)
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
                // Weight allows one decimal separator (fractional plates) — the
                // old `filter(\.isNumber)` stripped the "." so decimals could
                // never be typed. reps/duration stay integer-only above/below.
                let filtered = Self.sanitizeDecimalInput(newVal)
                inputsByExerciseID[slotID]?[setIndex]?.weight = filtered
                syncToGuardCaches()
                parentDraftStore?.persist(
                    slotID: slotID, setIndex: setIndex, field: .weight, value: filtered
                )
            }
        )

        return (repsB, weightB)
    }

    /// Keeps digits and a single decimal separator for weight entry. Accepts a
    /// comma as a synonym for "." (some locale keypads emit it) and normalizes
    /// to "." so the stored string round-trips through `Double(_:)`. Any extra
    /// separators or stray characters are dropped. reps/duration intentionally
    /// do NOT use this — they stay integer-only via `filter(\.isNumber)`.
    static func sanitizeDecimalInput(_ raw: String) -> String {
        var out = ""
        var hasSeparator = false
        for ch in raw {
            if ch.isNumber {
                out.append(ch)
            } else if (ch == "." || ch == ",") && !hasSeparator {
                out.append(".")
                hasSeparator = true
            }
        }
        return out
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

        // Superset round gating (round-progression + in-round ordering) plus
        // the within-exercise prior-set check is centralized in the pure,
        // unit-tested `SupersetRoundMath.isSetLoggable`. Rounds are driven by
        // the MAX set count across the block, so uneven supersets work (a
        // shorter exercise drops out of later rounds) while equal-set blocks
        // behave exactly as before. The exercise's block position is matched
        // by `routineSlotID` so duplicate Exercises across slots stay
        // independent; an exercise not found in the block is not loggable.
        let exIdx: Int
        if block.isSuperset {
            guard
                let idx = block.exercises.firstIndex(where: {
                    $0.routineSlotID == exercise.routineSlotID
                })
            else { return false }
            exIdx = idx
        } else {
            exIdx = 0
        }

        let setCounts = block.exercises.map {
            effectiveSetCount(for: $0, resolvedTemplates: $0.templates)
        }

        return SupersetRoundMath.isSetLoggable(
            isSuperset: block.isSuperset,
            exerciseIndex: exIdx,
            setIndex: setIndex,
            setCounts: setCounts,
            alreadyLogged: logged.contains(setIndex),
            isComplete: { i, s in
                isWorkingSetComplete(exercise: block.exercises[i], setIndex: s)
            }
        )
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

    /// Resolve the per-row effort target labels for an exercise's Sets section,
    /// aligned 1:1 with row indices `0..<setCount`. Reads only the immutable
    /// `prescriptionSnapshot` (never the live routine), in the app's autoreg
    /// metric, mapping each working-set ordinal to its target and warmup/dropset
    /// rows to nil. Returns all-nil when there's no snapshot / nothing to show.
    private func effortLabelsPerRow(
        for exercise: PlanExercise, setCount: Int
    ) -> [String?] {
        guard setCount > 0 else { return [] }
        // Cardio Slice 4 patch: RIR is "reps in reserve", which has no meaning
        // for a 30-minute run — there are no reps to hold back. The app's
        // effort UI is a single combined RIR/RPE control, so it is hidden
        // wholesale for cardio rather than split. The snapshot and session
        // values are left untouched: nothing is erased, only not shown, so a
        // slot switched back to a strength exercise still has its targets.
        guard showsEffortUI(forSlot: exercise.routineSlotID) else {
            return Array(repeating: nil, count: setCount)
        }
        let kinds: [SetKind] = (0..<setCount).map {
            exercise.templates[safe: $0]?.kind ?? .working
        }
        // Resolved from the snapshot **plus** the live session override, so an
        // Edit Plan change shows on the rows immediately. Reading the snapshot
        // alone is what made a freshly set intensity invisible until a resume —
        // and, for a slot switched out of cardio, invisible entirely, since its
        // adapted snapshot carries no effort at all.
        let fields = WorkoutEffortTargetResolver.effectiveFields(
            snapshot: exercise.prescriptionSnapshot.map {
                WorkoutEffortTargetResolver.Fields(payload: $0)
            },
            sessionRIR: sessionPlans[exercise.routineSlotID]?.rir,
            sessionRPE: sessionPlans[exercise.routineSlotID]?.rpe)
        return WorkoutEffortTargetResolver.perRowLabels(
            setKinds: kinds, fields: fields, autoregMode: autoregMode)
    }

    private func buildSetRow(
        block: PlanBlock,
        exercise: PlanExercise,
        idx: Int,
        template: PlanSetTemplate,
        effortTarget: String? = nil
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
                    effortTarget: effortTarget,
                    // nil for a timed hold, so Plank's row is untouched.
                    cardioDraft: cardioSlotIDs.contains(slotID)
                        ? cardioDraftBinding(slotID: slotID, setIndex: idx)
                        : nil,
                    duration: durB,
                    onStart: { durationSeconds in
                        setTimer.start(seconds: durationSeconds, mode: .set)
                        showSetOverlay = true
                    },
                    onLog: { durationSeconds in
                        // 9-B2 bug-fix: if the user logs before the
                        // duration timer naturally hits zero, stop it
                        // explicitly so the toolbar "Duration: Ns" label
                        // is replaced by either the rest timer label or
                        // nothing. Without this, the timer keeps ticking
                        // (and the `if setTimer.isRunning` branch keeps
                        // winning over the rest-timer branch) until the
                        // original countdown finishes. `onChange(of:
                        // setTimer.isRunning)` hides `showSetOverlay`
                        // automatically when isRunning flips to false.
                        setTimer.stop()

                        appendTimeSetLog(
                            slotID: slotID,
                            setIndex: idx,
                            durationSeconds: durationSeconds,
                            kind: template.kind,
                            // Empty for a timed hold; every metric nil for a
                            // cardio set the user never expanded Details on.
                            cardio: cardioMetricsForLog(
                                slotID: slotID, setIndex: idx)
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
                    effortTarget: effortTarget,
                    isBodyweight: isBodyweightEquipment(
                        resolvedActiveEquipment(for: exercise)
                    ),
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
                        // Preserve fractional warmup weights (e.g. 2.5 kg) — the
                        // snapshot weight is already Double; the prior
                        // Int($0.rounded()) truncated decimals.
                        weight: step.weight,
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
                parts.append("\(Units.formatWeight(w)) \(unit)")
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
        // Structured Cardio Slice 12D — and the checklist ticks. They are
        // session progress, not a result: finishing must leave no trace of them
        // anywhere, and there is nowhere else they could be, since they were
        // never written to a SetLog or a WorkoutItem.
        cardioSegmentCheckStore?.clearAll()

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

    // Slice C: the session clock no longer lives in `ActiveWorkoutView`'s
    // state. A parent-level `@State now` driven by a 1 Hz `Timer.publish`
    // used to invalidate this entire body every second (it was read by the
    // toolbar's elapsed-time text). The clock now redraws in isolation via
    // `SessionClockView` (a `TimelineView`), so ticks no longer recompute the
    // active workout body / input rows. The pure formatter lives in
    // `ActiveWorkoutHelpers.formatSessionElapsed(start:now:)`.

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

    /// Commits the local `sessionNotesDraft` to the active `Workout.notes`.
    /// Normalizes empty/whitespace-only input to nil (so the history detail row
    /// stays suppressed) and only writes when the value actually changed — this
    /// keeps the model un-dirtied on no-op commits and avoids a needless body
    /// invalidation. Called on focus loss, disappear, and scene backgrounding,
    /// never per keystroke.
    private func commitSessionNotes() {
        let normalized = normalizedOptionalNote(sessionNotesDraft)
        if workout?.notes != normalized {
            workout?.notes = normalized
        }
    }

    // MARK: - Session Plan

    private func initializeSessionPlans() {
        for block in plan.blocks {
            for ex in block.exercises {
                let key = ex.routineSlotID
                guard sessionPlans[key] == nil else { continue }
                if let snap = ex.prescriptionSnapshot {
                    // Alternative Exercises Phase E — the slot's frozen
                    // alternatives move from the plan into the session's own
                    // copy here, which is what `persistSessionPlans` writes and
                    // `restoreSessionPlansFromAppState` reads back. Nothing
                    // reads them yet; the switch sheet is Phase F.
                    sessionPlans[key] = SessionPlan(
                        from: snap, notes: ex.templateNotesSnapshot,
                        alternatives: ex.alternativesSnapshot)
                } else {
                    var p = SessionPlan()
                    p.slotNotes = ex.templateNotesSnapshot
                    p.alternatives = ex.alternativesSnapshot
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

    /// Mode-aware effort summary for the Plan card (`"RIR 2"` / `"RIR 2 → 0"` /
    /// nil). Derived from the immutable `prescriptionSnapshot` (never the live
    /// routine) so it matches the per-set rows and the block summary, with
    /// paired-metric fallback. For a **single** snapshot the editable session
    /// override (`sp.rir/rpe`) is summarized so an in-sheet single edit still
    /// shows; progression/none read the snapshot (the session sheet is
    /// read-only for those).
    private func planEffortSummary(
        for exercise: PlanExercise, sp: SessionPlan
    ) -> String? {
        // Cardio Slice 4 patch: same rule as the per-set labels — the combined
        // RIR/RPE control is not shown for cardio, so the Plan card must not
        // advertise a target the row no longer displays. Values are preserved,
        // just not surfaced.
        guard showsEffortUI(forSlot: exercise.routineSlotID) else { return nil }
        // Same effective fields the per-set rows resolve from, so the card and
        // the rows can no longer disagree. `effectiveFields` keeps a
        // progression snapshot intact and overlays the session's single value
        // otherwise — including when the snapshot had no effort at all, which
        // is the case that previously returned nil forever.
        let fields = WorkoutEffortTargetResolver.effectiveFields(
            snapshot: exercise.prescriptionSnapshot.map {
                WorkoutEffortTargetResolver.Fields(payload: $0)
            },
            sessionRIR: sp.rir,
            sessionRPE: sp.rpe)
        return WorkoutEffortTargetResolver.summary(
            fields: fields, autoregMode: autoregMode,
            // Fits a frozen custom list to the session's set count, so the card
            // states exactly the targets the rows below it show.
            workingSetCount: sp.sets)
    }

    /// Compact plan summary row with "Edit Plan" sheet trigger.
    @ViewBuilder
    private func planSummarySection(for exercise: PlanExercise) -> some View {
        let sp = sessionPlans[exercise.routineSlotID] ?? SessionPlan()
        let line1 = sp.primarySummary(
            distanceUnit: distanceUnit)
        let line2 = sp.secondarySummary(effortSummary: planEffortSummary(for: exercise, sp: sp))
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

    /// Structured Cardio Slice 12D — the read-only segment checklist.
    ///
    /// Renders nothing at all unless the slot's live exercise is cardio **and**
    /// its resolved plan has segments, so a strength slot, a timed hold, and an
    /// unstructured cardio slot each see exactly what they saw before this
    /// slice. Placed below the Plan card and above Sets: it describes the same
    /// prescription the card summarizes, and keeping it out of the Sets section
    /// leaves the duration control and Log button where they were.
    @ViewBuilder
    private func cardioSegmentChecklistSection(
        for exercise: PlanExercise
    ) -> some View {
        if let segmentPlan = structuredCardioPlan(for: exercise) {
            CardioSegmentChecklistSection(
                plan: segmentPlan,
                distanceUnit: distanceUnit,
                checkedIDs: cardioSegmentChecksBinding(
                    slotID: exercise.routineSlotID)
            )
        }
    }

    /// Equipment / Setup section. Equipment stays a read-only row sourced
    /// from the session-start snapshot for non-swapped slots (Phase 10).
    /// Setup notes read the live `Exercise.setupDefaults` (snapshot only as
    /// a deleted-exercise fallback) and are editable via the "Edit Setup
    /// Notes" button below, which opens a focused sheet that writes through
    /// to `Exercise.setupDefaults` — the same explicit-edit pattern as the
    /// Exercise Notes section. The section is omitted only when there is
    /// neither a value to show nor a live exercise to edit.
    /// Trim and treat empty/whitespace-only strings as nil so a blank
    /// snapshot value does not render an empty row.
    private func trimmedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    private func equipmentAndSetupSection(for exercise: PlanExercise) -> some View {
        // Equipment: snapshot for non-swapped slots (Phase 10 immutability),
        // live for swapped slots — unchanged. Setup: live
        // `Exercise.setupDefaults` whenever the library exercise still
        // exists, so edits made via `SetupNotesEditSheet` render immediately
        // (mirroring the live-read Exercise Notes section); the snapshot is
        // only the deleted-exercise fallback. A committed edit is also
        // propagated into the current session's snapshots
        // (`applyActiveSetupNotesEdit`), so this workout's History matches
        // what this row showed; finished workouts stay frozen.
        let isSwapped = exercise.currentExerciseID != exercise.originalExerciseID
        let liveExercise = fetchExercise(by: exercise.currentExerciseID)
        let equipment = trimmedOrNil(
            resolvedSwappedValue(
                isSwapped: isSwapped,
                live: liveExercise?.equipmentType,
                snapshot: exercise.prescriptionSnapshot?.equipment))
        let setup = trimmedOrNil(
            resolvedActiveSetupNotes(
                liveExerciseExists: liveExercise != nil,
                liveSetupNotes: liveExercise?.setupDefaults,
                snapshotSetupNotes: exercise.prescriptionSnapshot?.setupNotes))

        if equipment != nil || setup != nil || liveExercise != nil {
            Section("Equipment & Setup") {
                if let equipment {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Equipment")
                            .font(.dsCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(LocalizedStringKey(equipment))
                            .font(.dsBody)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if setup != nil || liveExercise != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Setup")
                            .font(.dsCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let setup {
                            Text(setup)
                                .font(.dsBody)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("No setup notes yet.")
                                .font(.dsBodySecondary)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if liveExercise != nil {
                    Button {
                        showSetupNotesSheet = true
                    } label: {
                        Label("Edit Setup Notes", systemImage: "square.and.pencil")
                    }
                    // No inline explanation here — the edit sheet's footer
                    // carries the "saved to the exercise, reused everywhere"
                    // explanation, matching the Exercise Notes cleanup.
                }
            }
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
                    // --- Sets section ---
                    // Build 10 C3 — first in the list. Logging sets is the only thing a
                    // user does on this screen every few minutes; everything below is read
                    // once, or not at all. It used to sit ninth, under session notes, the
                    // prefill toggle, exercise notes, Switch Exercise, the Plan card,
                    // Equipment & Setup, warm-ups and the cardio checklist — a scroll away
                    // from the reps field on every exercise, on every phone.
                    Section {
                        let setCount = effectiveSetCount(
                            for: exercise,
                            resolvedTemplates: exercise.templates)
                        // Resolve per-row effort labels ONCE per exercise from
                        // the immutable session snapshot (never the live
                        // routine), keyed to working-set ordinal. Warmup /
                        // dropset rows map to nil. Empty → all nil.
                        let effortRowLabels = effortLabelsPerRow(
                            for: exercise, setCount: setCount)
                        ForEach(0..<setCount, id: \.self) { idx in
                            let t =
                                exercise.templates[safe: idx]
                                ?? defaultTemplate(for: exercise, at: idx)
                            buildWorkingSetGroup(
                                block: block,
                                exercise: exercise,
                                idx: idx,
                                template: t,
                                effortTarget: effortRowLabels[safe: idx] ?? nil
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

                            // Phase 3.8c — the top technique summary row is now a
                            // *fallback only*. Every non-dropset technique normally
                            // surfaces as a tappable set-attached chip
                            // (`buildTechniqueChips`) on each set it targets, and
                            // dropsets render via the unified dropset card — so an
                            // always-on summary just duplicated that and cluttered
                            // the block. One safety net is kept: a technique whose
                            // targeting resolves to NO existing set (e.g.
                            // `.setNumber(n)` or explicit `appliesToSetIndices`
                            // pointing past the current set count after the count
                            // shrank) would otherwise have no chip anywhere. Surface
                            // only those "orphan" techniques here, via the same
                            // `techniquesApplying` source of truth that produces the
                            // chips; hide the row entirely when every technique is
                            // already covered at the set level.
                            let coveredOrders = Set(
                                (0..<setCount).flatMap { i in
                                    techniquesApplying(to: i, in: exercise)
                                        .filter { $0.type != .dropset }
                                        .map(\.order)
                                }
                            )
                            let orphanTechs = compatibleTechniqueSnapshots(
                                for: exercise
                            ).filter {
                                $0.type != .dropset
                                    && !coveredOrders.contains($0.order)
                            }
                            if !orphanTechs.isEmpty {
                                TechniqueIndicatorRow(labels: orphanTechs.map(\.summaryLabel))
                                    .opacity(0.6)
                            }
                        }
                        // No Sets-section footer caption here: a section footer
                        // sits at the section's bottom edge and SwiftUI briefly
                        // animates/reflows it upward with the keyboard on first
                        // focus (a visible jump). Decimal-weight discoverability
                        // instead rides on the stable "0.0" field placeholder in
                        // SetEntryRow / DropLogRow, which never moves with the
                        // keyboard.
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

                    // --- Structured cardio checklist (Slice 12D) ---
                    // Kept directly under the plan-shaped sections and within a screen of
                    // the set rows: it is the plan you read while the bout is running, so
                    // it belongs near the rows you tick it beside rather than down in the
                    // admin half. Cardio slots with a segment plan only; everything else
                    // renders nothing here, so no other section is affected.
                    cardioSegmentChecklistSection(for: exercise)

                    // --- Equipment & Setup ---
                    // Equipment: prescriptionSnapshot.equipment captured at
                    // session start (Phase 10) for non-swapped slots. Setup:
                    // live Exercise.setupDefaults (editable in-workout via
                    // SetupNotesEditSheet, mirroring Exercise Notes); the
                    // snapshot value is only a deleted-exercise fallback.
                    equipmentAndSetupSection(for: exercise)

                    Section("Actions") {
                        Button {
                            exerciseToSwapIndex = currentExerciseIndex
                            // Phase F1 — prepared alternatives come first when
                            // the slot has any; otherwise the picker opens
                            // directly, exactly as it did before.
                            if hasPreparedAlternatives(for: exercise) {
                                preparedAlternativesItem = SwapPickerItem(
                                    index: currentExerciseIndex)
                            } else {
                                swapPickerItem = SwapPickerItem(
                                    index: currentExerciseIndex)
                            }
                        } label: {
                            // Build 10 C4 — the count of what tapping this
                            // would actually offer. Derived from the same
                            // `preparedAlternativeOffers` the sheet is built
                            // from, so the badge can never promise a row the
                            // sheet does not show: disabled alternatives, the
                            // slot's own exercise, and (post-switch) whatever
                            // is now current are already filtered out by
                            // `PreparedAlternatives.offers`. Display only —
                            // the button's action is unchanged, and a slot
                            // with nothing to offer shows no badge and still
                            // opens the picker directly.
                            let offerCount =
                                preparedAlternativeOffers(for: exercise).count
                            HStack {
                                Label(
                                    "Switch Exercise",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                if offerCount > 0 {
                                    Spacer()
                                    Text(
                                        offerCount == 1
                                            ? "\(offerCount) alternative"
                                            : "\(offerCount) alternatives"
                                    )
                                    .font(.dsCaption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
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
                            // The "affects every routine/workout" caption was
                            // removed here — the edit sheet opened by the button
                            // above already carries that explanation in its footer.
                        } header: {
                            Text("Exercise Notes")
                        }
                    }

                    // --- Future-prefill exclusion (workout-level) ---
                    // Positive wording: ON (default) means this workout may seed
                    // last-performance prefill. Turn OFF for recovery/deload days
                    // whose reduced loads shouldn't become the next baseline.
                    // Maps to Workout.excludedFromPrefill (inverted). The workout
                    // still stays in History either way.
                    if let w = workout {
                        Section {
                            Toggle(
                                isOn: Binding(
                                    get: { !w.excludedFromPrefill },
                                    set: { w.excludedFromPrefill = !$0 }
                                )
                            ) {
                                // Explanation moved off the footer into an
                                // on-demand info button next to the toggle label
                                // to reduce clutter.
                                HStack(spacing: DSSpacing.xs) {
                                    Text("Use for future prefill")
                                    InfoButton(
                                        "Use for future prefill",
                                        message: "Turn off for recovery or deload workouts so they don't become the source for your next workout's prefill. The workout still appears in History."
                                    )
                                }
                            }
                        }
                    }

                    // --- Session-level workout notes (written to Workout.notes) ---
                    Section("Session Notes") {
                        // Multiline: Return inserts a newline (no .submitLabel
                        // (.done)), so the keyboard shows a normal return key —
                        // not a second done/check key competing with the shared
                        // keyboard checkmark accessory, which is the sole
                        // dismissal control.
                        TextField(
                            "Notes for this session…",
                            text: $sessionNotesDraft,
                            axis: .vertical
                        )
                        .lineLimit(1...6)
                        .textInputAutocapitalization(.sentences)
                        .focused($sessionNotesFocused)
                        .onChange(of: sessionNotesFocused) { _, focused in
                            if !focused { commitSessionNotes() }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                // Scrolling the active-workout list dismisses the keyboard. The
                // set-input fields (reps/weight/duration, dropset rows) use
                // numeric keyboards with no Return key, and the session note is
                // multiline (Return inserts a newline), so scroll was the only
                // missing dismissal gesture — the `.keyboard` checkmark accessory
                // remains. `.immediately` (vs `.interactively`) gives a clean
                // "scroll = dismiss" for the numeric-pad-dominated list. Session
                // note commits on the resulting focus loss (see commitSessionNotes).
                .scrollDismissesKeyboard(.immediately)
                // Back / Next-Finish navigation, hosted as the List's bottom
                // safe-area inset (reserves space, `.background(.bar)` keeps
                // list rows from showing through while scrolling). It is
                // withdrawn entirely while the keyboard is up: a fixed bottom
                // panel + the `.keyboard` accessory raced on the *first*
                // keyboard presentation (the accessory height wasn't counted in
                // the initial safe-area pass), so the panel overlapped the
                // checkmark until a second layout pass. Removing it on
                // keyboardWillShow is deterministic on first focus — there is no
                // panel to overlap — and it returns on keyboardWillHide. The
                // user can't navigate mid-edit anyway (they dismiss first).
                .safeAreaInset(edge: .bottom) {
                    if !keyboardVisible {
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
                        .padding(.vertical, 8)
                        .background(.bar)
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        // Shared dismiss accessory for every active-workout
                        // field. Required for reps / weight / duration (SetRows)
                        // and drop-set fields (DropLogRow) on .numberPad /
                        // .decimalPad, which have no Return key, and for the
                        // multiline Session Notes whose Return inserts a newline.
                        Spacer()
                        KeyboardDismissButton()
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIResponder.keyboardWillShowNotification)
                ) { _ in keyboardVisible = true }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIResponder.keyboardWillHideNotification)
                ) { _ in keyboardVisible = false }
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
                    // Slice C: isolated clock — only this view redraws each
                    // second, not the whole active workout body.
                    SessionClockView(sessionStart: activeGuard.sessionStart)
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
                finishConfirmTitle,
                isPresented: $showFinishConfirm,
                titleVisibility: .visible
            ) {
                // Options (order + routing) come from the pure
                // `finishDialogOptions` helper, pinned by
                // ActiveWorkoutFinishConfirmTests. Buttons only RECORD the
                // choice — the finish itself runs after the dialog's
                // dismissal transaction commits (see .onChange below), so
                // one confirm tap reliably finishes.
                ForEach(
                    finishDialogOptions(
                        hasSwapsPending: hasSwapsPending,
                        hasSessionPlanPending: hasSessionPlanPending),
                    id: \.self
                ) { option in
                    Button(finishOptionLabel(option)) {
                        pendingFinishOption = option
                    }
                }

                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: pendingFinishOption) { _, option in
                guard option != nil else { return }
                // Next main-actor turn: the dialog teardown has committed by
                // the time this runs, so the navigation pop inside
                // `unlockAndDismiss()` no longer races it. Consuming via
                // `consumePendingFinish` nils the slot first — the finish
                // pipeline can only ever run once per confirmation.
                Task { @MainActor in
                    guard let chosen = consumePendingFinish(&pendingFinishOption)
                    else { return }
                    finishWorkout(
                        applySwaps: chosen.applySwaps,
                        applySlotPrescription: chosen.applySlotPrescription)
                }
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

                // Seed the local session-notes draft from the bound workout so
                // the field shows persisted notes on (re)appear; typing edits
                // only the draft until a commit point.
                sessionNotesDraft = workout?.notes ?? ""

                // Restore the stable notification ID from AppState so that
                // any subsequent rest start (or stop) can cancel the
                // notification from the previous process by its stable ID.
                // resumeIfScheduled() itself does NOT reschedule — it only
                // rehydrates the timer from UserDefaults. The original
                // notification remains pending and fires naturally.
                restoreStableRestID()
                rest.resumeIfScheduled()
                rest.syncNow()

                // Same rehydration for the duration countdown, from its own
                // namespace. Reads UserDefaults only — no notification is
                // scheduled or rescheduled for set mode.
                setTimer.resumeIfScheduled()
                setTimer.syncNow()

                // 0) initialize session plans from snapshots
                initializeSessionPlans()
                // 0a) overlay persisted session plans (cold resume — takes precedence)
                restoreSessionPlansFromAppState()
                // 0b) restore cursor position from AppState (cold resume)
                restorePositionFromAppState()
                // 0c) load last-performance prefill suggestions (Slice 2) so
                //     tier-4 seeding can use them. Must run before seeding.
                loadLastPerformancePrefill()
                // 1) mirror caches (if returning)
                syncFromGuardCachesIfAny()
                // 2) if still empty, seed from plan
                ensureInputsInitializedFromPlan()
                // 3) now rehydrate from existing workout logs (so logged checkmarks & fields match reality)
                rehydrateFromWorkoutIfPresent()
                // 3a) Cardio Slice 4 — identify cardio slots, then restore
                //     their optional metric drafts. Must run after (3) so
                //     `itemsByExerciseID` is populated and a logged set's
                //     stored metrics win over any stale draft.
                refreshCardioSlots()
                rehydrateCardioDrafts()
                // 3b) Structured Cardio Slice 12D — restore the checklist
                //     ticks. After (3a) so the cardio gate and the session
                //     plans are both current; ticks that no longer name a
                //     segment in the slot's resolved plan are dropped here
                //     rather than rendered.
                rehydrateCardioSegmentChecks()

                // Persist active state for cold-restart resume
                markAppStateActive()

                // On cold resume, restore rest from AppState if UserDefaults
                // didn't already rehydrate it (e.g. UserDefaults cleared).
                if !rest.isRunning {
                    resumeRestFromAppState()
                }

                // ensure overlay shows if a rest is already running in background
                showRestOverlay = rest.isRunning
                showSetOverlay = setTimer.isRunning
            }
            .onChange(of: rest.isRunning) { _, running in
                if !running {
                    clearPersistedRestState()
                }
            }
            .onChange(of: currentBlockIndex) { _, _ in persistPosition() }
            .onChange(of: currentExerciseIndex) { _, _ in persistPosition() }
            // Cardio Slice 8 patch. Unlike History — which was simply not
            // observing the preference — the cardio rows render `draft.unit`,
            // which is **state**, seeded when the draft was created. The body
            // already re-renders (this view holds `@AppStorage` for the key),
            // but re-rendering stale state changes nothing, so the drafts
            // themselves have to be re-expressed.
            .onChange(of: distanceUnit) { _, newUnit in
                resyncCardioDrafts(to: newUnit)
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

                // The duration timer's 1 Hz ticker is suspended while
                // backgrounded, so `remaining` is stale by exactly the time
                // spent away. Re-anchor it to wall clock here, the same way
                // rest does — otherwise the toolbar "Duration: Ns" text
                // resumes counting from where it froze. Set mode drives no
                // notification and no Live Activity, so this only affects the
                // in-app countdown and its own overlay.
                setTimer.handleLifecycleDidBecomeActive()
                setTimer.syncNow()
                showSetOverlay = setTimer.isRunning
            }
            .task {
                await AppNotificationService.requestAuthorizationIfNeeded()
            }
            .onDisappear { commitSessionNotes() }
            .onChange(of: scenePhase) { _, phase in
                // Flush the in-flight session-notes draft to the model when the
                // app leaves the foreground so a background/terminate mid-edit
                // doesn't drop it. Idempotent and no-op when unchanged.
                if phase != .active { commitSessionNotes() }
            }
            .sheet(
                item: $swapPickerItem,
                onDismiss: {
                    if pendingSwapNewExercise != nil {
                        showSwapPlanChoice = true
                    }
                }
            ) { target in
                if let block = currentBlock,
                    target.index < block.exercises.count
                {
                    // Phase 9-B2 fix: per-slot identity is `routineSlotID`,
                    // and both logging (`WorkoutItem.routineSlotID`) and
                    // active draft state key on it — so duplicating an
                    // Exercise across different routine slots is safe. The
                    // old "exclude every used exercise across all blocks"
                    // filter was a stale Phase-3-era guard. Now only the
                    // current slot's own exercise is excluded (avoids a
                    // no-op self-swap).
                    let currentSlotExerciseID =
                        block.exercises[target.index].currentExerciseID
                    let filtered = allExercises.filter {
                        $0.id != currentSlotExerciseID
                    }

                    ExercisePickerSingle(exercises: filtered) { picked in
                        pendingSwapNewExercise = picked
                        swapPickerItem = nil
                        if picked == nil {
                            exerciseToSwapIndex = nil
                        }
                    }
                }
            }
            // Phase F1 — the slot's prepared alternatives, offered *before* the
            // picker. Presented only when there is something to offer, so a
            // slot without alternatives never sees this screen.
            //
            // Every action defers its work to `onDismiss` rather than acting
            // inside the sheet: the destructive confirmation and the picker are
            // both presented from this view, and starting one while a sheet is
            // still dismissing is the race the existing swap flow already
            // avoids this way.
            .sheet(
                item: $preparedAlternativesItem,
                onDismiss: {
                    if let alternative = pendingPreparedAlternative {
                        pendingPreparedAlternative = nil
                        applyPreparedAlternative(alternative)
                    } else if pendingChooseAnotherExercise {
                        pendingChooseAnotherExercise = false
                        swapPickerItem = SwapPickerItem(
                            index: exerciseToSwapIndex ?? currentExerciseIndex)
                    } else {
                        // Plain Cancel — nothing has been applied.
                        cancelPendingSwap()
                    }
                }
            ) { target in
                if let block = currentBlock,
                    target.index < block.exercises.count
                {
                    let slot = block.exercises[target.index]
                    PreparedAlternativesSheet(
                        currentExerciseName: slot.name,
                        offers: preparedAlternativeOffers(for: slot),
                        distanceUnit: distanceUnit,
                        effortMetric: effortMetric,
                        onPick: { pendingPreparedAlternative = $0 },
                        onChooseAnother: { pendingChooseAnotherExercise = true }
                    )
                }
            }
            .confirmationDialog(
                "Session plan for this slot",
                isPresented: $showSwapPlanChoice,
                titleVisibility: .visible
            ) {
                Button("Keep current plan") {
                    requestPendingSwap(.keepCurrentPlan)
                }
                Button("Reset plan for this slot") {
                    requestPendingSwap(.resetPlan)
                }
                Button("Cancel", role: .cancel) {
                    cancelPendingSwap()
                }
            }
            // Second stage: only presented when the switch would destroy logged
            // work. Both plan choices route through it, and Cancel returns the
            // slot to exactly its pre-switch state — nothing has been applied
            // at this point, because `performPendingSwap` has not run yet.
            .confirmationDialog(
                ExerciseSwitchConfirmationCopy.title,
                isPresented: $showSwapDestructiveConfirm,
                titleVisibility: .visible
            ) {
                Button(
                    ExerciseSwitchConfirmationCopy.confirmButton,
                    role: .destructive
                ) {
                    let plan = pendingSwapPlan
                    pendingSwapImpact = nil
                    performPendingSwap(plan)
                }
                Button("Cancel", role: .cancel) {
                    cancelPendingSwap()
                }
            } message: {
                if let message = ExerciseSwitchConfirmationCopy.message(
                    for: pendingSwapImpact ?? ExerciseSwitchDeletionImpact()
                ) {
                    Text(message)
                }
            }
            .sheet(
                isPresented: $showEditPlanSheet,
                onDismiss: {
                    applySessionPlanToInputs()
                    // The cardio counterpart of `applySessionPlanToInputs`:
                    // reps and duration already refreshed here from the edited
                    // plan, and the target distance now does too. Without it
                    // the row kept showing the distance it was seeded with at
                    // session start until a resume happened to re-seed it.
                    if let slotID = currentExercise?.routineSlotID {
                        resyncCardioDraftsToTarget(slotID: slotID)
                    }
                    persistSessionPlans()
                }
            ) {
                if let exercise = currentExercise {
                    EditSessionPlanSheet(
                        plan: sessionPlanBinding(
                            for: exercise.routineSlotID),
                        snapshotEffort: exercise.prescriptionSnapshot.map {
                            WorkoutEffortTargetResolver.Fields(payload: $0)
                        },
                        // Read the slot's cardio-ness directly rather than
                        // inferring it from effort applicability: the sheet now
                        // uses this to decide the *target distance* row too,
                        // and those two questions only happen to coincide.
                        isCardio: cardioSlotIDs.contains(
                            exercise.routineSlotID))
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
            .sheet(isPresented: $showSetupNotesSheet) {
                if let ex = currentExercise,
                    let liveEx = fetchExercise(by: ex.currentExerciseID)
                {
                    SetupNotesEditSheet(exercise: liveEx) { normalized in
                        // Propagate the committed edit into the CURRENT
                        // session's snapshots (plan payload + any persisted
                        // WorkoutItem snapshots) so this workout's finished
                        // History records the corrected setup notes. The
                        // sheet saves the context right after this closure.
                        applyActiveSetupNotesEdit(
                            normalized,
                            editedExerciseID: liveEx.id,
                            plan: &plan,
                            itemsBySlotID: itemsByExerciseID
                        )
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
        switch workoutNextAction(
            currentBlockIndex: currentBlockIndex,
            currentExerciseIndex: currentExerciseIndex,
            exerciseCountsPerBlock: plan.blocks.map { $0.exercises.count }
        ) {
        case .advanceExercise(let idx):
            currentExerciseIndex = idx
        case .advanceBlock:
            currentBlockIndex += 1
            currentExerciseIndex = 0
        case .confirmFinish:
            // Always confirm before finishing. Reaching the last step must
            // never finish the workout outright — otherwise spam-tapping Next
            // near the end finishes accidentally. The confirmation dialog
            // (showFinishConfirm) offers Finish + Cancel in every case, and
            // adds the "apply pending changes" options when relevant.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showFinishConfirm = true
        }
    }

    // MARK: - Finish helpers

    /// Title for the finish confirmation dialog. Reads "Apply changes?" only
    /// when there are pending swaps / session-plan edits to apply; otherwise a
    /// plain "Finish workout?" (the dialog then shows just Finish + Cancel).
    private var finishConfirmTitle: LocalizedStringKey {
        (hasSwapsPending || hasSessionPlanPending)
            ? "Apply changes?"
            : "Finish this workout?"
    }

    /// User-facing label for one finish-dialog option. Kept here (not on the
    /// enum) so `ActiveWorkoutHelpers` stays SwiftUI-free; the literals are
    /// the pre-existing localized keys (Korean included).
    private func finishOptionLabel(
        _ option: FinishDialogOption
    ) -> LocalizedStringKey {
        switch option {
        case .finishOnly: "Finish (this workout only)"
        case .applySwaps: "Finish + Update routine template"
        case .applySlotPrescription: "Finish + Update slot prescription"
        case .applyAll: "Finish + Apply all"
        }
    }

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
        // Cardio Slice 6 patch: the target distance became editable in the
        // active Edit Plan sheet, so an edit that touches only it must still
        // count as dirty — otherwise "Update slot prescription" would not be
        // offered and the change would silently stay session-only.
        if sp.targetDistanceMeters != original.targetDistanceMeters {
            return true
        }
        if sp.targetDistanceUnitRaw != original.targetDistanceUnitRaw {
            return true
        }
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
                // Written as a pair so the routine's two columns can never
                // disagree about whether a target exists, matching
                // `SlotPrescription.applyTargetDistance`.
                rx.targetDistanceMeters = sp.targetDistanceMeters
                rx.targetDistanceUnitRaw = sp.targetDistanceUnitRaw
                rx.tempo = sp.tempo?.isEmpty == true ? nil : sp.tempo

                // Copy slotNotes → templateNotes
                re.templateNotes =
                    sp.slotNotes?.isEmpty == true ? nil : sp.slotNotes
            }
        }
    }

    // MARK: - Prepared alternatives (Phase F1)

    /// The alternatives this slot can offer right now.
    ///
    /// Sourced from the slot's **frozen** `SessionPlan`, never from the
    /// routine: the session offers what it froze at start, so editing the
    /// routine mid-workout changes nothing here (§4.2). Filtering — disabled,
    /// already-current, unavailable — is the pure `PreparedAlternatives`.
    private func preparedAlternativeOffers(
        for exercise: PlanExercise
    ) -> [PreparedAlternativeOffer] {
        PreparedAlternatives.offers(
            from: sessionPlans[exercise.routineSlotID]?.alternatives ?? [],
            currentExerciseID: exercise.currentExerciseID,
            availableExerciseIDs: Set(allExercises.map(\.id)))
    }

    /// Whether the switch flow should open the Prepared Alternatives sheet
    /// instead of going straight to the picker. False keeps the pre-F1 flow
    /// exactly as it was.
    private func hasPreparedAlternatives(for exercise: PlanExercise) -> Bool {
        !preparedAlternativeOffers(for: exercise).isEmpty
    }

    /// The app-wide autoreg metric, for the sheet's summary lines. Nil when
    /// autoreg is off, which omits the effort segment as everywhere else.
    private var effortMetric: EffortMetric? {
        switch autoregMode {
        case .rir: return .rir
        case .rpe: return .rpe
        case .none: return nil
        }
    }

    /// Resolve a picked alternative to a live `Exercise` and route it into the
    /// **same** pending-switch pipeline the two plan choices use — so it
    /// inherits the logged-set confirmation, the rest-timer cancellation, the
    /// draft cleanup and the superset cascade without a second copy of any of
    /// them.
    ///
    /// An unresolvable exercise cancels rather than proceeding. The sheet
    /// already renders that alternative as a disabled `Exercise unavailable`
    /// row, so this is only reachable if the library changed underneath the
    /// open sheet.
    private func applyPreparedAlternative(_ alternative: SlotAlternative) {
        guard
            let newEx = allExercises.first(where: {
                $0.id == alternative.exerciseID
            })
        else {
            cancelPendingSwap()
            return
        }
        pendingSwapNewExercise = newEx
        requestPendingSwap(.useAlternative(alternative))
    }

    /// How many logged sets the pending switch would delete.
    ///
    /// Reads the block's **pre-switch** state and defers the arithmetic to
    /// `exerciseSwitchDeletionImpact`, which reuses the same
    /// `supersetLogsToInvalidate` helper the post-swap cascade runs — so the
    /// count in the confirmation and the sets actually removed come from one
    /// rule, not two.
    private func pendingSwapDeletionImpact() -> ExerciseSwitchDeletionImpact {
        guard let idx = exerciseToSwapIndex,
            let block = currentBlock,
            idx < block.exercises.count
        else { return ExerciseSwitchDeletionImpact() }

        var setCounts: [UUID: Int] = [:]
        for ex in block.exercises {
            setCounts[ex.routineSlotID] = effectiveSetCount(
                for: ex, resolvedTemplates: ex.templates
            )
        }

        return exerciseSwitchDeletionImpact(
            slotID: block.exercises[idx].routineSlotID,
            isSuperset: block.isSuperset,
            slotOrder: block.exercises.map(\.routineSlotID),
            setCounts: setCounts,
            loggedBySlot: loggedByExercise
        )
    }

    /// Gate the deferred swap behind a destructive confirmation when it would
    /// delete logged sets; otherwise apply it immediately, exactly as before.
    ///
    /// Applies to **both** plan choices and to every tracking mode — the gate is
    /// a function of logged sets alone, which is what the switch destroys.
    private func requestPendingSwap(_ plan: PendingSwapPlan) {
        let impact = pendingSwapDeletionImpact()
        guard impact.requiresConfirmation else {
            performPendingSwap(plan)
            return
        }
        pendingSwapImpact = impact
        pendingSwapPlan = plan
        showSwapDestructiveConfirm = true
    }

    /// Abandon a pending switch. Nothing has been applied yet at either
    /// confirmation stage, so clearing the pending state is the whole undo:
    /// the exercise, session plan, logged sets, drafts, cardio details,
    /// checklist ticks, and rest timer are all untouched.
    private func cancelPendingSwap() {
        pendingSwapNewExercise = nil
        exerciseToSwapIndex = nil
        pendingSwapImpact = nil
    }

    /// Execute the deferred swap after the user chose keep/reset plan.
    private func performPendingSwap(_ pendingPlan: PendingSwapPlan) {
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
        let slotID = planEx.routineSlotID

        // Resolve the slot's post-switch plan through the ONE adapter that
        // owns keep/reset compatibility (Entry #12 P1). Both choices run the
        // same path, so neither can leave mixed duration + reps/weight state.
        //
        // Critically, this reads the pre-switch `SessionPlan` BEFORE anything
        // is cleared. The previous implementation blanked the plan and the
        // snapshot first and only then derived the set-count hint, so a
        // tracking-type change silently fell back to `AppSettings.defaultSets`
        // (the reported "2 sets became 3 sets" bug).
        //
        // Cardio Slice 6: the adapter is told both **tracking modes**, not two
        // booleans. `isTimeBased` cannot distinguish a treadmill from a plank,
        // and the cardio-only state (target distance, typed metrics) has to be
        // cleared on exactly the switches where the new exercise has no field
        // for it. The old mode comes from `cardioSlotIDs`, the same cached
        // truth that decides whether the row shows the Details section.
        let oldMode: TrackingMode =
            cardioSlotIDs.contains(slotID)
            ? .cardio
            : (planEx.isTimeBased ? .timedHold : .strength)
        let newMode = newEx.trackingMode

        // Structured Cardio Slice 12D note — why **Reset** always drops the
        // segment plan today, and why that is not a bug:
        //
        // A structured plan is a property of the *routine slot*
        // (`SlotPrescription.cardioSegmentsData`), not of an `Exercise` — there
        // is no such column on the exercise, because the same treadmill is
        // programmed differently in different routines. So a switched-in
        // exercise brings no plan with it, and `ResetSource.appDefaults`
        // deliberately supplies none, exactly as it supplies no target
        // distance (Slice 6): "reset" means the values a freshly-authored slot
        // for this exercise would have, and inventing a session structure the
        // user never wrote would be programming on their behalf.
        //
        // The adapter *does* apply a reset source's plan when one is supplied
        // (pinned by the 12D reset tests), so the day a caller has a real
        // replacement plan to offer — a routine-slot-sourced reset — the
        // checklist will show it with no change here.
        let outcome = ExerciseSwitchPlanAdapter.outcome(
            choice: pendingPlan.adapterChoice,
            current: sessionPlans[slotID],
            oldMode: oldMode,
            newMode: newMode,
            resetSource: .appDefaults(for: newMode)
        )
        applySwitchOutcome(outcome, slotID: slotID, newExercise: newEx)

        swapExercise(
            planExercise: planEx, with: newEx,
            keepCardioDrafts: outcome.keepCardioDrafts)

        // The switch has just deleted this slot's logged sets (and possibly a
        // superset partner's, via the round-order cascade). A rest counting
        // down from one of those sets is now counting down from nothing, so
        // stop it before it fires a notification for an exercise the slot no
        // longer holds.
        cancelStaleRestAfterExerciseSwitch()

        // A) After reset+swap, if the new exercise has no templates and the
        //    (now-empty) session plan has no sets, auto-open the Edit Plan
        //    sheet so the user can immediately set sets/reps/rest.
        if pendingPlan.isReset, let swapped = currentExercise {
            let sc = effectiveSetCount(
                for: swapped, resolvedTemplates: swapped.templates)
            if sc <= 1 && swapped.templates.isEmpty {
                showEditPlanSheet = true
            }
        }

        pendingSwapNewExercise = nil
        exerciseToSwapIndex = nil
    }

    /// Stop a rest timer that the just-committed exercise switch orphaned.
    ///
    /// The bug this closes: log a set, then switch that slot's exercise. The
    /// switch deletes the slot's `WorkoutItem` and every `SetLog` under it, but
    /// nothing told the rest timer — so the clock kept running, the Live
    /// Activity kept counting, and the scheduled local notification fired for a
    /// set that no longer existed on an exercise that was no longer there.
    ///
    /// The rest's owning slot comes from `AppState.activeRestSlotID` — the same
    /// value `startRestWithPersistence` writes and `restoreStableRestID` reads
    /// back on a cold resume — so this works identically after a relaunch. The
    /// decision itself is the pure `shouldCancelRestAfterExerciseSwitch`, which
    /// asks only whether the resting slot still has a logged set: a rest
    /// belonging to an untouched slot survives, so logging without switching is
    /// completely unaffected.
    ///
    /// `rest.stop()` cancels the pending **and** delivered notification for the
    /// stable id and returns the Live Activity to its neutral session state —
    /// the existing cancellation path, reused rather than reimplemented. Rest
    /// *rules* (prescription rest, `RestPlanner`) are untouched: this only ends
    /// a rest that already lost its set.
    private func cancelStaleRestAfterExerciseSwitch() {
        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        guard
            shouldCancelRestAfterExerciseSwitch(
                isRestRunning: rest.isRunning,
                restSlotID: appState.activeRestSlotID,
                loggedSetsBySlotID: loggedByExercise)
        else { return }

        rest.stop()
        clearPersistedRestState()
        showRestOverlay = false
    }

    /// Write an `ExerciseSwitchPlanAdapter.Outcome` into the slot's live state.
    ///
    /// This is the single write point that makes the switched slot's plan
    /// authoritative and durable:
    ///
    ///  * `sessionPlans[slotID]` (tier 1) takes the adapted plan;
    ///  * `prescriptionSnapshot` (tier 2) is **rewritten** from the same
    ///    outcome instead of being left stale (keep) or nil'd (reset), so
    ///    every `SessionPlanResolver` read agrees with tier 1 — this is what
    ///    stops a switched-in barbell lift from rendering the replaced
    ///    exercise's duration fields;
    ///  * the prescription/routine-specific note follows the adapter's rule
    ///    rather than carrying the replaced exercise's note over;
    ///  * warm-up and technique snapshots are kept only when the switch stayed
    ///    within one tracking type, and kept techniques are re-filtered against
    ///    the switched-in exercise's compatibility rules;
    ///  * the result is persisted immediately, so leaving and resuming the
    ///    workout restores exactly this plan.
    ///
    /// The routine template is never touched — apply-back stays gated behind
    /// the explicit finish option (`applySessionPlansToSlotPrescriptions`).
    private func applySwitchOutcome(
        _ outcome: ExerciseSwitchPlanAdapter.Outcome,
        slotID: UUID,
        newExercise: Exercise
    ) {
        // Alternative Exercises Phase E — the adapter builds a fresh
        // `SessionPlan` for the switched-in exercise, but a slot's prepared
        // alternatives belong to the **slot**, not to the exercise currently in
        // it: after switching Bench Press → Machine Chest Press, the DB Bench
        // Press the user prepared is still prepared. Carry them across the
        // wholesale replacement so the frozen list survives a switch. No
        // visible effect yet — nothing reads them until Phase F — but without
        // this line the freeze would silently die on the first switch.
        var applied = outcome.sessionPlan
        applied.alternatives = sessionPlans[slotID]?.alternatives ?? []
        sessionPlans[slotID] = applied

        // Phase 6.C1 follow-up — slot identity is `routineSlotID`, not
        // `PlanExercise.id` (which is `Exercise.id` and collides when a
        // superset has duplicate Exercise slots; see findSlotIndex).
        if let (bi, ei) = findSlotIndex(in: plan, routineSlotID: slotID) {
            plan.blocks[bi].exercises[ei].prescriptionSnapshot =
                ExerciseSwitchPlanAdapter.adaptedSnapshot(
                    from: outcome,
                    base: plan.blocks[bi].exercises[ei].prescriptionSnapshot,
                    equipment: newExercise.equipmentType,
                    setupNotes: newExercise.setupDefaults
                )
            plan.blocks[bi].exercises[ei].templateNotesSnapshot =
                outcome.sessionPlan.slotNotes

            // Warm-ups survive a same-tracking-type switch as authored; a
            // tracking-type change or a reset clears them. A prepared
            // alternative answers a third question — **replace** them with the
            // ones it carries (Phase F1) — including with an empty list, which
            // is what an alternative authored without a warm-up means.
            if let replacement = outcome.replacementWarmupSteps {
                plan.blocks[bi].exercises[ei].warmupStepsSnapshot = replacement
            } else if !outcome.keepWarmupSteps {
                plan.blocks[bi].exercises[ei].warmupStepsSnapshot = []
            }

            // Same three-way rule for techniques, and the retention filter runs
            // on all of them: a prepared alternative cannot introduce a
            // combination the routine editor would have rejected on the
            // switched-in exercise (a Drop Set onto a bodyweight movement, a
            // rep-count technique onto a duration target).
            let techniqueSource =
                outcome.replacementTechniques
                ?? (outcome.keepTechniques
                    ? plan.blocks[bi].exercises[ei].techniquePlansSnapshot
                    : [])
            plan.blocks[bi].exercises[ei].techniquePlansSnapshot =
                ExerciseSwitchPlanAdapter.retainedTechniques(
                    from: techniqueSource,
                    isBodyweight: isBodyweightEquipment(
                        newExercise.equipmentType),
                    usesDuration: newExercise.isTimeBased
                )
        }

        persistSessionPlans()
    }

    /// - Parameter keepCardioDrafts: `ExerciseSwitchPlanAdapter.Outcome`'s
    ///   verdict on the slot's typed cardio metrics — true only for
    ///   cardio → cardio "Keep current plan".
    private func swapExercise(
        planExercise: PlanExercise, with newEx: Exercise,
        keepCardioDrafts: Bool
    ) {
        // 1) Locate slot by `routineSlotID` — the slot-unique identifier.
        // Phase 6.C1 follow-up — must NOT key on `planExercise.id`, which is
        // `Exercise.id` and collides when a superset has duplicate Exercise
        // slots; see `findSlotIndex` doc for the original manual-test bug.
        guard let (blockIndex, exIndex) = findSlotIndex(
            in: plan, routineSlotID: planExercise.routineSlotID
        ) else { return }

        let oldExerciseID = plan.blocks[blockIndex].exercises[exIndex]
            .currentExerciseID
        let oldIsTimeBased = plan.blocks[blockIndex].exercises[exIndex]
            .isTimeBased
        let modeChanged = oldIsTimeBased != newEx.isTimeBased

        // 1a) Mode-change draft cleanup: rep ↔ duration swaps strand
        // mode-incompatible DRAFT state on the slot — drop draft inputs carry
        // reps + weight strings that mean nothing for a timed exercise.
        //
        // The plan-level half of this cleanup (session plan, prescription
        // snapshot, warm-up + technique snapshots, slot note) is NOT done here
        // any more: `applySwitchOutcome` already resolved all of it through
        // `ExerciseSwitchPlanAdapter` before this call. Re-blanking it here was
        // the second half of the set-count bug — it discarded the adapter's
        // preserved set count and forced `makeSwapDefaultTemplates` below onto
        // `AppSettings.defaultSets`.
        let slotID = plan.blocks[blockIndex].exercises[exIndex].routineSlotID
        if modeChanged {
            dropsLoggedByExercise[slotID] = nil
            let dropPrefix = "\(slotID)_"
            // Capture affected keys before pruning the in-memory dicts so
            // the persistent store gets cleared for the right set of keys.
            let affectedKeys = Set(
                dropRepsInput.keys.filter { $0.hasPrefix(dropPrefix) }
            ).union(
                dropWeightInput.keys.filter { $0.hasPrefix(dropPrefix) }
            )
            for key in affectedKeys {
                dropRepsInput.removeValue(forKey: key)
                dropWeightInput.removeValue(forKey: key)
                dropWeightUserEdited.remove(key)
                dropWeightDraftStore?.clear(slotKey: key)
            }
        }

        // 2) Build new templates from the slot's ADAPTED session plan +
        // snapshot rather than from `newEx.defaultTemplates` (Phase 9-B2 —
        // see `makeSwapDefaultTemplates` doc for the field-by-field
        // contract and the 9-A.5 audit's documented `targetWeight` loss).
        // Both tiers were just written by `applySwitchOutcome` and already
        // agree on the new exercise's tracking type, so the hints below carry
        // the set count / rest the user is entitled to keep (Keep) or the
        // reset source's values (Reset) — never the replaced exercise's
        // mode-specific leftovers.
        let sp = sessionPlans[slotID]
        let snap = plan.blocks[blockIndex].exercises[exIndex]
            .prescriptionSnapshot
        let newTemplates = makeSwapDefaultTemplates(
            forExerciseID: newEx.id,
            isTimeBased: newEx.isTimeBased,
            setsHint: sp?.sets ?? snap?.sets,
            restBetweenSetsHint:
                sp?.restSecondsBetweenSets ?? snap?.restSecondsBetweenSets,
            durationMinHint:
                sp?.durationMinSeconds ?? snap?.durationMinSeconds,
            durationMaxHint:
                sp?.durationMaxSeconds ?? snap?.durationMaxSeconds
        )

        // 3) Replace PlanExercise fields
        plan.blocks[blockIndex].exercises[exIndex].currentExerciseID = newEx.id
        plan.blocks[blockIndex].exercises[exIndex].name = newEx.name
        plan.blocks[blockIndex].exercises[exIndex].templates = newTemplates
        plan.blocks[blockIndex].exercises[exIndex].isTimeBased =
            newEx.isTimeBased

        // 3a) Cardio Slice 4/6 — the slot's tracking mode may have changed in
        // either direction. Re-derive which slots are cardio, then reconcile
        // this slot's metric drafts with the adapter's verdict.
        //
        // Slice 4 cleared them unconditionally. Slice 6 narrows that to
        // everything *except* cardio → cardio "Keep current plan", where the
        // numbers still describe the same kind of bout and the user explicitly
        // asked to keep what they had. On every other switch they are dropped
        // from memory **and from the persisted store** — the Slice 4 version
        // only cleared memory, so the typed values sat in `UserDefaults` and
        // could be restored onto the slot if it later became cardio again.
        if !keepCardioDrafts {
            cardioDraftsBySlotID[slotID] = nil
            parentDraftStore?.clearCardio(slotID: slotID)
            // Structured Cardio Slice 12D — the checklist ticks go with them,
            // on the same verdict. An explicit Reset means start over, and a
            // switch off cardio leaves the ticks describing a bout the slot is
            // no longer doing. The routine's stored segment plan is untouched
            // either way ("hidden but intact"), so switching back and re-ticking
            // is always possible.
            cardioSegmentChecksBySlotID[slotID] = nil
            cardioSegmentCheckStore?.clear(slotID: slotID)
        }
        refreshCardioSlots()
        // Then reconcile against whatever plan the slot now resolves to. For
        // cardio → cardio "Keep" this is what preserves the ticks (the plan was
        // preserved, so every id still matches); for every other direction the
        // clear above already emptied them and this is a no-op.
        reconcileCardioSegmentChecks(slotID: slotID)
        // Seeding deliberately does NOT happen here. It needs this slot's
        // cardio prefill to have been re-pointed at the switched-in exercise
        // first — otherwise it would seed from the *replaced* exercise's
        // history, which is the exact stale-state bug Slice 6 exists to
        // prevent. It runs at step 4a below, straight after
        // `refreshLastPerformancePrefill`.

        // 4) Build fresh per-set inputs for this slot from newTemplates
        // Phase 5.2 — slotID is the per-slot key (routineSlotID); already
        // bound above in step (2) for the template-build priority chain.
        let swappedPlanEx = plan.blocks[blockIndex].exercises[exIndex]

        // Re-point last-performance prefill at the switched-in exercise before
        // seeding the drafts below, so `tier4Default` can overlay Exercise B's
        // own last performance (never Exercise A's, which was loaded at session
        // start) onto the prescription defaults.
        //
        // This is DRAFT-ONLY and deliberately runs here, at step 4: steps 1a–3
        // already applied the `ExerciseSwitchPlanAdapter` outcome and rewrote
        // `isTimeBased` / `templates`, so the plan is fully valid for the new
        // exercise type before any history is consulted. `resolvedDraftDefault`
        // then keys off that adapted type — duration drafts for a timed
        // exercise, reps/weight for a normal one — and prefill can only change
        // what the input fields start at, never the plan itself.
        //
        // The slot is being rebuilt fresh (every set empty and unlogged at swap
        // time; logs/inputs for the replaced exercise are cleared below and in
        // steps 6–7), so this seeds and never overwrites user data. If B has no
        // history the maps stay cleared and seeding falls back to prescription.
        refreshLastPerformancePrefill(
            forSlotID: slotID, exerciseID: newEx.id)

        // 4a) Cardio Slice 7 — now that the slot's prefill points at the
        // switched-in exercise, seed its cardio fields from the same
        // precedence chain a fresh session uses: previous performance first,
        // then the adapted routine target. Only fills entries that are absent,
        // so a draft kept by a cardio → cardio "Keep current plan" wins.
        seedCardioDraftsFromTarget(slotID: slotID)

        let swappedCount = effectiveSetCount(
            for: swappedPlanEx, resolvedTemplates: newTemplates)
        var perSet: [Int: (reps: String, weight: String, duration: String)] =
            [:]
        for i in 0..<swappedCount {
            let tpl =
                newTemplates[safe: i]
                ?? defaultTemplate(for: swappedPlanEx, at: i)
            perSet[i] = tier4Default(
                for: swappedPlanEx, setIndex: i, template: tpl)
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

        // 7a) Phase 6.C3 — superset round-order consistency. When the
        // replaced slot belongs to a superset block, clearing only the
        // swapped slot's logs can strand later members' logs ahead of
        // the now-empty earlier required member (e.g. A1 + B1 logged →
        // swap A → B1 is orphaned ahead of the unlogged A1). Cascade
        // a clear of any extraneous logs in the block so the surviving
        // logs form a valid prefix of the round sequence. Non-superset
        // blocks are unaffected — the helper is only invoked when
        // `isSuperset == true`.
        if plan.blocks[blockIndex].isSuperset {
            cascadeClearSupersetRoundOrderViolations(
                in: plan.blocks[blockIndex]
            )
        }

        try? ctx.save()

        // 8) Keep global plan in guard for resume
        activeGuard.activePlan = plan
    }

    /// Phase 6.C3 — clear any logs in the given superset block that
    /// violate the round-prefix invariant after a member's logs have
    /// already been cleared (e.g. by the swap path). Delegates to the
    /// pure `supersetLogsToInvalidate(...)` helper to decide which
    /// `(slotID, setIndex)` pairs are extraneous, then mirrors that
    /// clear across every in-memory + persisted store the swap path
    /// also touches for the replaced slot itself.
    @MainActor
    private func cascadeClearSupersetRoundOrderViolations(in block: PlanBlock)
    {
        let slotOrder = block.exercises.map(\.routineSlotID)
        var setCounts: [UUID: Int] = [:]
        for ex in block.exercises {
            setCounts[ex.routineSlotID] = effectiveSetCount(
                for: ex, resolvedTemplates: ex.templates
            )
        }
        var loggedBySlot: [UUID: Set<Int>] = [:]
        for slot in slotOrder {
            loggedBySlot[slot] = loggedByExercise[slot] ?? []
        }
        let extraneous = supersetLogsToInvalidate(
            slotOrder: slotOrder,
            setCounts: setCounts,
            loggedBySlot: loggedBySlot
        )
        guard !extraneous.isEmpty else { return }

        for (cSlotID, indices) in extraneous {
            // Look up the *current* exercise ID for the slot so legacy
            // drop-draft keys (which key on Exercise.id, not slotID)
            // can be defensively swept.
            guard let cPlanEx = block.exercises.first(where: {
                $0.routineSlotID == cSlotID
            }) else { continue }
            let exerciseID = cPlanEx.currentExerciseID
            for setIndex in indices.sorted() {
                clearLoggedSetForSupersetCascade(
                    slotID: cSlotID,
                    exerciseID: exerciseID,
                    setIndex: setIndex
                )
            }
        }

        syncToGuardCaches()
    }

    /// Phase 6.C3 — cascade-clear a single logged set for a slot in
    /// the same superset block as the just-swapped slot. Mirrors the
    /// state cleared by the swap path for its own slot:
    ///   - persisted `SetLog` rows (parent + drop sub-logs) on the
    ///     `WorkoutItem`
    ///   - `loggedByExercise[slotID]` membership
    ///   - `dropsLoggedByExercise[slotID][setIndex]`
    ///   - `ParentDraftStore` (reps/weight/duration drafts)
    ///   - `DropWeightDraftStore` and the in-memory drop input dicts
    ///     under the new `<slotID>_<set>_` key prefix; defensively
    ///     also sweeps any legacy `<exerciseID>_<set>_` prefix on disk
    ///     (matches the sweep in `undoSetLog(...)`)
    /// Caller is responsible for the trailing `ctx.save()` /
    /// `syncToGuardCaches()` (we batch one save at the end of the
    /// swap path).
    @MainActor
    private func clearLoggedSetForSupersetCascade(
        slotID: UUID,
        exerciseID: UUID,
        setIndex: Int
    ) {
        if let wi = itemsByExerciseID[slotID] {
            wi.setLogs.removeAll { $0.indexInExercise == setIndex }
        }
        if loggedByExercise[slotID] != nil {
            loggedByExercise[slotID]?.remove(setIndex)
        }
        dropsLoggedByExercise[slotID]?.removeValue(forKey: setIndex)

        parentDraftStore?.clear(slotID: slotID, setIndex: setIndex)

        let newPrefix = "\(slotID)_\(setIndex)_"
        let affectedKeys = Set(
            dropWeightInput.keys.filter { $0.hasPrefix(newPrefix) }
        ).union(
            dropRepsInput.keys.filter { $0.hasPrefix(newPrefix) }
        )
        for key in affectedKeys {
            dropWeightInput.removeValue(forKey: key)
            dropWeightUserEdited.remove(key)
            dropRepsInput.removeValue(forKey: key)
            dropWeightDraftStore?.clear(slotKey: key)
        }
        if let store = dropWeightDraftStore {
            let legacyPrefix = "\(exerciseID)_\(setIndex)_"
            for legacyKey in store.loadAll().keys
            where legacyKey.hasPrefix(legacyPrefix) {
                store.clear(slotKey: legacyKey)
            }
        }
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
        weight: Double?,
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
            wi.setLogs[j].weight = weight
            wi.setLogs[j].kindRaw = kind.rawValue
            wi.setLogs[j].timestamp = .now
        } else {
            wi.setLogs.append(
                SetLog(
                    indexInExercise: setIndex,
                    kind: kind,
                    reps: reps,
                    weight: weight
                )
            )
        }
        try? ctx.save()
    }

    /// - Parameter cardio: optional metrics for a cardio set. Defaults to an
    ///   empty `CardioMetrics`, which **clears** every cardio column — so
    ///   re-logging a set after Undo never leaves a previous attempt's distance
    ///   or heart rate attached, and a timed hold can never acquire one.
    private func appendTimeSetLog(
        slotID: UUID,
        setIndex: Int,
        durationSeconds: Int,
        kind: SetKind,
        cardio: CardioMetrics = CardioMetrics()
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
            wi.setLogs[j].applyCardioMetrics(cardio)
        } else {
            let log = SetLog(
                indexInExercise: setIndex,
                kind: kind,
                reps: 0,
                weight: nil,
                restSeconds: nil,
                timestamp: .now,
                durationSeconds: durationSeconds
            )
            log.applyCardioMetrics(cardio)
            wi.setLogs.append(log)
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
            let weightStr = log.weight.map { Units.formatWeight($0) } ?? ""
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

    // Rest-timer semantics for techniques (Phase 3.8 — clarified; no behavior change):
    //
    //   • Rest-AFFECTING: Dropset ONLY. A dropset suppresses the parent set's
    //     normal rest and instead drives inter-drop pacing (its own `restSeconds`
    //     between drops), with the real next-set / after-exercise rest fired only
    //     after the FINAL drop. This is the single technique consulted by the rest
    //     decision (`restSecondsAfterCurrentLog` → `dropsetTechniqueApplying`) and
    //     by `RestPlanner`'s dropset branches.
    //
    //   • DISPLAY-ONLY / instructional (never touch the rest timer): Partial Reps,
    //     To Failure, AMRAP, Tempo Override, Rest-Pause, Cluster. Rest-Pause and
    //     Cluster carry a `restSeconds` config value, but it is surfaced only as
    //     guidance in `TechniqueDetailSheet` — deliberately NOT wired into the
    //     app's rest timer. After logging such a set, rest still comes from the
    //     prescription (`restSecondsBetweenSets` / `restSecondsAfterExercise`).
    //
    // Auto-running a Rest-Pause / Cluster intra-set rest would be a NEW feature the
    // current model does not support — do not add it without an explicit
    // rest-semantics design pass.

    /// The slot's technique snapshots that are still legal for the exercise the
    /// slot is CURRENTLY running.
    ///
    /// A snapshot can outlive its own validity — the slot was flipped to
    /// duration, the exercise was switched, or the routine was imported — and
    /// the active workout's snapshots are immutable, so the only correct
    /// response is to suppress at read time. Same "resolve, don't mutate"
    /// precedent as `dropsetSupportedActive`. Notably this is what keeps a
    /// Tempo Override off a duration-based exercise.
    private func compatibleTechniqueSnapshots(
        for exercise: PlanExercise
    ) -> [TechniquePlanSnapshot] {
        compatibleTechniques(
            exercise.techniquePlansSnapshot,
            isBodyweight: isBodyweightEquipment(
                resolvedActiveEquipment(for: exercise)),
            usesDuration: exercise.isTimeBased
        )
    }

    /// Returns all TechniquePlanSnapshots that apply to `setIndex` in the exercise.
    /// Checks explicit appliesToSetIndices first, then falls back to the old appliesTo enum.
    /// Incompatible techniques are filtered out first, so neither the set chips
    /// nor the orphan-summary fallback can surface one.
    private func techniquesApplying(
        to setIndex: Int,
        in exercise: PlanExercise
    ) -> [TechniquePlanSnapshot] {
        let templates = exercise.templates
        let setCount = effectiveSetCount(for: exercise, resolvedTemplates: templates)
        let lastWorkingIdx = (0..<setCount).last {
            (templates[safe: $0]?.kind ?? .working) == .working
        } ?? (setCount - 1)

        return compatibleTechniqueSnapshots(for: exercise).filter { snap in
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

    /// Renders compact, tappable technique chips for a working set, embedded
    /// inside that set's card. Tapping a chip opens the read-only detail sheet.
    ///
    /// Dropset techniques are intentionally excluded: a dropset is shown by the
    /// unified dropset card (inline summary label + drop sub-rows in
    /// `buildWorkingSetGroup` / `buildDropSection`), so rendering it as a chip too
    /// would duplicate it. In the non-dropset (`else`) branch of
    /// `buildWorkingSetGroup` the filter is a no-op (if a dropset applied we'd be
    /// in the dropset branch); in the dropset branch the filter lets the set's
    /// OTHER techniques (e.g. To Failure, Tempo) still show inside the card.
    @ViewBuilder
    private func buildTechniqueChips(
        exercise: PlanExercise,
        setIndex: Int
    ) -> some View {
        let snaps = techniquesApplying(to: setIndex, in: exercise)
            .filter { $0.type != .dropset }
        if !snaps.isEmpty {
            SetTechniqueChipsRow(techniques: snaps) { snap in
                techniqueDetailSnap = snap
            }
        }
    }

    // MARK: - Dropset Sub-logging

    /// Whether Drop Set is active for this slot during the workout.
    ///
    /// Bodyweight exercises do not support Drop Set in the current app model
    /// (no assisted / negative / mechanical-variation load), so a stale Drop
    /// Set technique on a Bodyweight-resolved slot must be treated as INACTIVE
    /// for Active Workout rendering, completion, rest, and logging — without
    /// mutating the underlying template/technique. Uses the resolved ACTIVE
    /// equipment so the parent weight field and dropset rendering share one
    /// rule: non-swapped slots follow the session-start snapshot; swapped slots
    /// follow the switched-in exercise's live equipment.
    private func dropsetSupportedActive(for exercise: PlanExercise) -> Bool {
        !isBodyweightEquipment(resolvedActiveEquipment(for: exercise))
    }

    /// Returns the first Dropset TechniquePlanSnapshot that applies to `setIndex`
    /// in the given exercise, or nil if no Dropset technique covers that set.
    ///
    /// Single source of truth for "does a dropset apply here?" — consulted by
    /// dropset rendering (`buildWorkingSetGroup` / `buildDropSection`),
    /// working-set completion, and rest pacing. Returns nil for a
    /// Bodyweight-resolved slot (see `dropsetSupportedActive`) so every one of
    /// those paths suppresses the stale dropset consistently.
    private func dropsetTechniqueApplying(
        to setIndex: Int,
        in exercise: PlanExercise
    ) -> TechniquePlanSnapshot? {
        guard dropsetSupportedActive(for: exercise) else { return nil }
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
                // Slice 3 — last-performance drop prefill, applied as a
                // read-time fallback. It is never seeded into dropRepsInput /
                // dropWeightInput / dropWeightUserEdited, so it cannot mark the
                // weight as a user override or trigger "↩ suggest".
                let techniqueFixedReps: Int? = {
                    let effectiveRaw = snap.dropsetEffortRaw ?? "amrap"
                    return effectiveRaw == "fixedReps" ? snap.dropsetEffortReps : nil
                }()
                let dropSuggestion = LastPerformancePrefillService.dropSuggestion(
                    forParentSetIndex: parentSetIndex,
                    subIndex: sub,
                    from: dropPrefillBySlotID[slotID] ?? [:]
                )
                let resolvedDrop = resolvedDropDraft(
                    suggestion: dropSuggestion,
                    typedReps: dropRepsInput[key],
                    isWeightOverridden: isOverridden,
                    overriddenWeight: dropWeightInput[key],
                    percentageSuggestion: suggested,
                    techniqueFixedReps: techniqueFixedReps
                )
                let currentWeight: String = resolvedDrop.weight
                // Show reset only when manually overridden, a suggestion exists, drop not yet logged,
                // AND the visible value actually differs from the suggestion.
                let canReset = isOverridden && !suggested.isEmpty && !isDropLogged
                    && Double(currentWeight) != Double(suggested)

                DropLogRow(
                    dropNumber: sub,
                    isLogged: isDropLogged,
                    canLog: canLogDrop,
                    reps: Binding(
                        get: { resolvedDrop.reps },
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
        template: PlanSetTemplate,
        effortTarget: String? = nil
    ) -> some View {
        if let snap = dropsetTechniqueApplying(to: idx, in: exercise) {
            // Unified card: parent working set + this set's other (non-dropset)
            // technique chips + dropset summary + drop sub-rows — all in ONE list
            // row so the dropset reads as a single cohesive block.
            VStack(alignment: .leading, spacing: 12) {
                buildSetRow(block: block, exercise: exercise, idx: idx, template: template, effortTarget: effortTarget)
                // Non-dropset techniques that also target this set (e.g. To Failure)
                // stay visible inside the dropset card. `buildTechniqueChips` filters
                // out the dropset itself, so the summary below is not duplicated.
                buildTechniqueChips(exercise: exercise, setIndex: idx)
                // Compact dropset config summary — aligned with the indented drop rows below.
                Text(snap.setAttachedLabel)
                    .font(.dsCaption)
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .padding(.leading, 20)
                buildDropSection(block: block, exercise: exercise, parentSetIndex: idx)
            }
        } else {
            // Set row + this set's technique chips wrapped in ONE list row (card)
            // so the chips are visually attached to the set rather than rendered as
            // a separate card floating in the gap between set rows.
            VStack(alignment: .leading, spacing: 8) {
                buildSetRow(block: block, exercise: exercise, idx: idx, template: template, effortTarget: effortTarget)
                buildTechniqueChips(exercise: exercise, setIndex: idx)
            }
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
    /// • Finally, on the *last* round of a superset block:
    ///     – Supersets: block.restAfterSeconds (transition rest) replaces the round rest when configured (>0).
    /// • Non-superset blocks: block.restAfterSeconds is intentionally ignored.
    ///   The non-superset "Rest after block" UI was removed during the rest
    ///   cleanup, so any non-superset restAfterSeconds is stale legacy data
    ///   and must not affect timing — final-set rest is controlled solely by
    ///   planned rest-after-exercise → between-sets → template fallback.
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
            // suppression. The view returns the planner's result directly.
            // (Non-superset blocks no longer apply any `restAfterSeconds`
            // post-processing — that legacy additive was removed.)
            let isLastBlock = currentBlockIndex == plan.blocks.count - 1
            // The planner uses `isLastExerciseOfBlock` to fire the final-round
            // transition rest and last-set-of-workout suppression exactly once,
            // on the log that COMPLETES the final round. For uneven supersets
            // the round-completing log is on the last *participating* exercise
            // of this round (the highest block-order slot whose set count
            // reaches `idx`) — which is NOT necessarily the last exercise in
            // block order (e.g. A=3, B=2: round 2 completes on A, not B). For
            // equal-set supersets every exercise participates in every round, so
            // the last participant is the last exercise — behavior unchanged.
            let blockSetCounts = block.exercises.map {
                effectiveSetCount(for: $0, resolvedTemplates: $0.templates)
            }
            let lastParticipantIdx =
                SupersetRoundMath.lastParticipantIndex(
                    setCounts: blockSetCounts, roundIndex: idx)
                ?? (block.exercises.count - 1)
            let loggedExerciseIdx =
                block.exercises.firstIndex {
                    $0.routineSlotID == exercise.routineSlotID
                } ?? currentExerciseIndex
            let isLastExerciseOfBlock = loggedExerciseIdx == lastParticipantIdx
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

        // Non-superset block rest is intentionally NOT applied. The
        // non-superset "Rest after block" UI was removed during the rest
        // cleanup; any `block.restAfterSeconds` on a non-superset block is
        // stale legacy data and must not lengthen final-set rest. The
        // superset path returns from RestPlanner above (which already
        // accounts for transition replacement via `block.restAfterSeconds`).

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
            // Switch Exercise consistency: the `prescriptionSnapshot` payload
            // captured at session start still describes the ORIGINAL exercise's
            // equipment/setup (the keep-plan swap path preserves it verbatim),
            // while `item.exercise` / `exerciseNameSnapshot` already point at
            // the swapped-in exercise. History reads Equipment & Setup solely
            // from this frozen snapshot, so without this it would show the
            // switched exercise's NAME alongside the original's equipment/setup.
            // Freeze the swapped-in exercise's LIVE equipment/setup here —
            // mirroring the `resolvedSwappedValue` contract the live Active
            // Workout display uses — so finished History is internally
            // consistent. Frozen at snapshot time: later library edits never
            // mutate it (snapshot-immutability invariant preserved for the
            // non-swapped case, which keeps the snapshot values).
            let isSwapped =
                planEx.currentExerciseID != planEx.originalExerciseID
            let liveExercise =
                isSwapped ? fetchExercise(by: planEx.currentExerciseID) : nil
            let resolved = resolvedSnapshotEquipmentSetup(
                isSwapped: isSwapped && liveExercise != nil,
                liveEquipment: liveExercise?.equipmentType,
                liveSetup: liveExercise?.setupDefaults,
                snapshotEquipment: snapshot.equipment,
                snapshotSetup: snapshot.setupNotes
            )
            snapshot.equipment = resolved.equipment
            snapshot.setupNotes = resolved.setupNotes
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
        // Phase 6.C1 — copy source-block snapshot for future History
        // superset grouping. Nil values (e.g. swap-target PlanExercise
        // built without block context in some edge case) propagate
        // through unchanged and the future display treats them as flat.
        item.sourceBlockSlotID = planEx.sourceBlockSlotID
        item.sourceBlockIsSuperset = planEx.sourceBlockIsSuperset
        item.sourceBlockOrder = planEx.sourceBlockOrder
        item.sourceExerciseOrderInBlock = planEx.sourceExerciseOrderInBlock
    }

    /// 0-based index of the final round in a superset block.
    ///
    /// Rounds are driven by the **maximum** effective set count across all
    /// exercises in the block, not the first exercise's count. This supports
    /// uneven supersets (e.g. A=3, B=2): the block runs `max` rounds and the
    /// shorter exercise simply drops out of the later rounds — no
    /// equalization, no phantom sets. For equal-set supersets the max equals
    /// every exercise's count, so behavior is unchanged.
    private func lastRoundIndex(in block: PlanBlock) -> Int {
        let setCounts = block.exercises.map {
            effectiveSetCount(for: $0, resolvedTemplates: $0.templates)
        }
        return SupersetRoundMath.lastRoundIndex(setCounts: setCounts)
    }

    /// Advance focus after logging within a superset. Focus moves to the
    /// exercise that owns the **next loggable set** in the uneven-aware round
    /// schedule (`SupersetRoundMath.nextLoggableSlot`):
    ///   - within a round, to the next not-yet-complete participating exercise;
    ///   - when a round completes, to the first participating exercise of the
    ///     next round — **skipping any exercise that has dropped out** (a
    ///     shorter exercise with no set in that round). It never lands on an
    ///     exercise that has no remaining loggable set just because it is next
    ///     in block order.
    ///   - when the whole block is complete, focus **stays** on the current
    ///     exercise.
    ///
    /// For equal-set supersets the schedule is the plain round-robin, so this
    /// is behavior-identical to the previous wrap-to-first logic. The `idx`
    /// parameter is retained for call-site symmetry; the decision is derived
    /// from the full per-exercise completion state.
    private func advanceForSupersetAfterLog(
        setIndex idx: Int,
        in block: PlanBlock
    ) {
        guard block.isSuperset else { return }

        let setCounts = block.exercises.map {
            effectiveSetCount(for: $0, resolvedTemplates: $0.templates)
        }
        if let next = SupersetRoundMath.nextLoggableSlot(
            setCounts: setCounts,
            isComplete: { i, s in
                isWorkingSetComplete(exercise: block.exercises[i], setIndex: s)
            }
        ) {
            currentExerciseIndex = next.exercise
        }
        // nil → every set in the block is complete; keep focus where it is.
    }
}


# REFACTOR_PLAN.md

Gym Log — Architecture v2 Refactor (SwiftUI + SwiftData)

Branches:

- `refactor/architecture-v2` — plan & rules
- `refactor/architecture-v2-exec` — execution (active)

Last updated: 2026-05-18 (KST) — Phase 6.B Slice B complete: idempotent launch-time backfill links pre-existing workouts to a routine's preferred variant via routineID, with a lowercased routineName fallback; history UI still unchanged (Slice C pending)

---

## 0) Why This Refactor Exists

The app works, but had production blockers that are being systematically resolved:

- **~~Templates and exercise defaults were silently mutated by session behavior~~** — **RESOLVED.** Silent calls to `persistDefaultsOnlyForCurrentExercises()`, `persistExerciseNotesOnlyForCurrentExercises()`, and `applyExerciseSwapsToRoutine()` have been removed. A finish-time confirmation dialog now gates any propagation.
- **~~Routine slots had no stable UUIDs~~** — **RESOLVED.** `RoutineBlock.slotID` and `RoutineExercise.slotID` added (named `slotID` to avoid shadowing SwiftData's `PersistentIdentifier`-based `.id`).
- **~~Exercise deletion cascaded into workout history~~** — **RESOLVED.** `Exercise.workoutItems` delete rule changed from `.cascade` to `.nullify`.
- **~~No persisted workout lifecycle state~~** — **RESOLVED.** `AppState` model persists `activeWorkoutID`, `activeWorkoutStartedAt`, rest timer state. Cold resume rebuilds `WorkoutPlan` via `WorkoutResumeService`.
- **History is still linked by strings**: `Workout.routineName: String?` — to be replaced by RoutineVariant relationship.

---

## 1) Reality Rules / Invariants

These are the enforced invariants as of Phase 5. All new work must preserve them.

### Session isolation

- Templates are never silently mutated by workout actions.
- Sessions snapshot prescription at start (`PlannedPrescriptionSnapshot`) — immutable thereafter.
- Session-level edits (SessionPlan) default to "this workout only." Applying back to slot prescription requires explicit user action via `applySessionPlansToSlotPrescriptions()`.

### Slot identity

- `RoutineBlock.slotID` and `RoutineExercise.slotID` are stable UUIDs distinct from SwiftData's `PersistentIdentifier`.
- `WorkoutItem.routineSlotID` copies `RoutineExercise.slotID` at session start for later reconciliation.

### History protection

- `Exercise.workoutItems` delete rule is `.nullify` — deleting an exercise preserves workout history.
- `Workout.routineID: UUID?` links workouts to their source routine (additive, optional).
- `WorkoutItem.exerciseNameSnapshot` (Phase 4b) preserves exercise name for display when exercise is deleted.

### Workout lifecycle

- `AppState` (SwiftData singleton, keyed `"appState"`) persists: `workoutState` (idle/active/finished), `activeWorkoutID`, `activeWorkoutStartedAt`, `activeRestEndsAt`, `activeRestSlotID`.
- On cold launch, `BootstrapRoot.validateActiveSession()` resets to `.idle` if the referenced workout is missing.
- `RootTabView.checkForActiveSession()` rebuilds a `WorkoutPlan` via `WorkoutResumeService` and presents `ActiveWorkoutView` in a `.fullScreenCover`. Resume binds to the existing `Workout` — never creates a new one.
- `ActiveWorkoutGuard` is the in-memory session singleton; `AppState` is the persistence layer.

### Rest timer durability

- Rest timer persists via both UserDefaults (warm resume) and AppState (cold resume).
- Stable notification IDs (`"rest.<workoutID>.<slotID>"`) prevent duplicate local notifications.
- Cancel-before-reschedule on every `startRestWithPersistence` call.
- `.onChange(of: rest.isRunning)` clears persisted rest state on natural expiration.

### Active workout input persistence

Set inputs (reps / weight / duration) for parent working sets and dropset drops survive force-quit/cold-resume via layered sources. Drafts are persisted per-workout in UserDefaults (keyed by `workoutID`) and are **never** written as `SetLog` rows.

**Parent working-set input source priority** (resolved in `rehydrateFromWorkoutIfPresent`):

1. Logged parent `SetLog` (`subIndex == nil`) — source of truth while the set is logged; field is read-only.
2. Persisted parent draft (UserDefaults `parentDrafts_<workoutID>`, keyed by `<slotID>_<setIndex>_<field>`) — un-logged user input that must survive cold resume.
3. In-memory `inputsCache` on `ActiveWorkoutGuard` — warm-navigation draft for the same process.
4. Plan prescription default from `SlotPrescription` / `SetTemplate`.

**Parent draft lifecycle:**

- Written per keystroke from the `reps` / `weight` / `duration` bindings.
- Cleared when the parent set is logged (SetLog becomes the truth).
- On parent **undo**, the just-removed SetLog's reps / weight / duration are snapshotted back into the parent draft before deletion, so the now-editable field retains those values across cold resume; the draft is **not** cleared by undo.
- Cleared when the workout finishes or dismisses (`unlockAndDismiss` → `clearAllParentDrafts`).

**Dropset drop-weight draft lifecycle:**

- Written per keystroke when the user manually edits a drop weight (UserDefaults `dropWeightDrafts_<workoutID>`, keyed by `<slotID>_<parentSetIndex>_<subIndex>`).
- Logged drops resume from `SetLog` (`subIndex != nil`); drafts are skipped for keys already populated by a logged drop.
- Cleared when: the drop is logged, the user taps "↩ suggest" to revert to the auto-computed value, the parent set is undone (cascade clears logged + un-logged drop drafts under that parent), or the workout finishes/dismisses.

### Template resolution (3-tier, current)

1. `RoutineExercise.setTemplates` — explicit per-set overrides (compatibility/power-user)
2. `SlotPrescription.generateTemplates()` — primary source of programming intent
3. `Exercise.defaultTemplates` — exercise-level fallback (targeted for removal in Phase 9)

### Session plan (in-workout editing)

- `SessionPlan` is a per-exercise in-memory copy of prescription fields, created at workout start.
- Users can edit sets, rep range, rest, RIR, RPE, tempo during the workout via a sheet.
- `effectiveSetCount` resolves the displayed set target from session plan → prescription snapshot → setTemplate count.
- Rest timer uses session plan rest values with precedence over prescription snapshot. On the final working set of a non-superset exercise, `restSecondsAfterExercise` (session plan → snapshot) is preferred; all other sets use `restSecondsBetweenSets` → template rest.
- `hasSessionPlanPending` detects if any session plan diverges from the original snapshot.
- On finish, if pending changes exist, an explicit apply-back dialog offers to write them to `SlotPrescription`.

### Exercise swap (in-workout)

- Swapping an exercise during a workout shows a keep/reset dialog for logged sets.
- The exercise picker filters out exercises already present in the current block.
- Swap changes are tracked and surfaced at finish time for optional routine update.

---

## 2) Current System Snapshot

### Models

- **Exercise**
  - `id: UUID`, `name`, `bodyPart?`, `notes?`, `isCustom`, `isTimeBased`, `order: Int = 0`
  - `order` — user-controlled display order on the Exercises tab; additive (default 0); legacy data normalized once via `ExercisesView.backfillExerciseOrderIfNeeded` on first appear
  - `defaultTemplates: [SetTemplate]` (.cascade) — **legacy; targeted for removal** (see Phase 9)
  - `routineUsages: [RoutineExercise]` (.cascade)
  - `workoutItems: [WorkoutItem]` (**.nullify** — history preserved on exercise deletion)

- **Routine**
  - `id: UUID`, `name`, `notes?`, `order: Int = 0`
  - `order` — user-controlled display order on the Routines tab; additive (default 0); legacy data normalized once via `RoutinesView.backfillRoutineOrderIfNeeded` on first appear
  - `blocks: [RoutineBlock]` (.cascade)
  - `variants: [RoutineVariant]` (.cascade)

- **RoutineVariant**
  - `id: UUID`, `name`, `order`
  - `blocks: [RoutineBlock]` (.cascade)
  - Currently one "Default" variant per routine (backfilled on launch).

- **RoutineBlock**
  - `slotID: UUID` (stable slot identity; NOT `id` — avoids SwiftData shadow)
  - `isSuperset`, `order`, `restAfterSeconds?`, `supersetRoundRestSeconds?`
  - `exercises: [RoutineExercise]` (.cascade)

- **RoutineExercise**
  - `slotID: UUID` (stable slot identity)
  - `exercise: Exercise?` (inverse of `Exercise.routineUsages`)
  - `order`, `setTemplates: [SetTemplate]` (.cascade) — compatibility/override layer
  - `templateNotes: String?` — slot-level notes (distinct from `Exercise.notes`)
  - `prescription: SlotPrescription?` (.cascade) — structured programming intent

- **SlotPrescription**
  - Core: `sets?`, `repMin?`, `repMax?`, `restSecondsBetweenSets?`, `restSecondsAfterExercise?`
  - Autoregulation: `rir?`, `rpe?`, `tempo?`
  - Duration: `durationMinSeconds?`, `durationMaxSeconds?`, `usesDuration`
  - Context: `equipment?`, `setupNotes?` — **deprecated in slot; migrating to Exercise-level** (see Phase 10)
  - `warmupScheme: WarmupScheme?` (.nullify — reusable across slots)
  - `techniquePlans: [TechniquePlan]` (.cascade — owned by this prescription)

- **PlannedPrescriptionSnapshot** — immutable copy of SlotPrescription fields stored on WorkoutItem at session start
- **PrescriptionSnapshotPayload** — lightweight value-type carried in WorkoutPlan for snapshot creation

- **WarmupScheme** — `name`, `steps: [WarmupStep]` (.cascade)
- **WarmupStep** — `order`, `kind` (percentage/fixedReps/noteOnly), `reps?`, `percentOfWorking?`, `restSecondsAfter?`, `note?`

- **TechniquePlan**
  - Template-side, parameterized technique configuration owned by `SlotPrescription`
  - Supports per-technique parameters (e.g. dropset effort mode, drop %, count) and explicit target selection via working-set indices
  - Uses persisted targeting fields (`appliesToSetIndicesRaw`) rather than only preset buckets
- **TechniquePlanSnapshot**
  - Immutable value-type copy carried in the workout plan and persisted for resume
  - Used by workout UI for display and per-set attachment without mutating templates

- **SetLog**
  - `indexInExercise`, `subIndex?`, `kind`, `reps`, `weight?`, `restSeconds?`, `durationSeconds?`, `timestamp`
  - `subIndex` is used for sub-set logging (e.g. dropsets) while preserving the parent working set index
- **SetTemplate** — `order`, `kind` (warmup/working/dropset), `targetReps`, `targetWeight?`, `restSecondsAfter?`, `durationSeconds?`
- **WorkoutItem**
  - `exercise: Exercise?` (inverse), `setLogs: [SetLog]` (.cascade)
  - `routineSlotID: UUID?` — copy of `RoutineExercise.slotID` at session start
  - `templateNotesSnapshot: String?` — copy of `RoutineExercise.templateNotes`
  - `plannedPrescriptionSnapshot: PlannedPrescriptionSnapshot?` (.cascade) — immutable prescription snapshot
  - `exerciseNameSnapshot: String?` (**Phase 4b**) — copy of `exercise.name` at creation time (survives exercise deletion)
- **Workout** — `id: UUID`, `date`, `routineName: String?`, `routineID: UUID?`, `routineVariantID: UUID?` (**Phase 6.B Slice A** — additive, default nil; stored by UUID rather than relationship to mirror `routineID` and tolerate variant deletion), `completedAt: Date?` (**Phase 4b**), `items: [WorkoutItem]` (.cascade), `notes?`

- **AppState** — persisted singleton (`@Attribute(.unique) key: "appState"`)
  - `workoutState: WorkoutLifecycleState` (idle/active/finished)
  - `activeWorkoutID: UUID?`, `activeWorkoutStartedAt: Date?`
  - `activeRestEndsAt: Date?`, `activeRestSlotID: UUID?`
  - `sessionPlansJSON: String?` (**Phase 4c**) — Codable `[String: SessionPlan]` keyed by routineSlotID
  - `activeBlockIndex: Int?`, `activeExerciseIndex: Int?` (**Phase 4c**)

- **AppSettings** — `@AppStorage`-backed UserDefaults singleton (not a SwiftData model)
  - `weightIsKg: Bool`, `autoregMode: AutoregMode` (rir/rpe/none)
  - New-slot defaults: `defaultSets`, `defaultRepMin`, `defaultRepMax`, `defaultRestBetweenSets`, `defaultRestAfterExercise`, `defaultRIR` / `defaultRPE`
  - Changing settings affects newly created prescriptions only; never silently mutates existing routines or active sessions

---

## 3) Completed Phases

### Phase 0 — Baseline & guardrails ✅

- [x] Create `CLAUDE.md` (rules/invariants)
- [x] Create `REFACTOR_PLAN.md`
- [x] Commit as first commit on `refactor/architecture-v2`
- [x] Confirm app builds and runs

### Phase 1.1 — Identity & variant skeleton ✅

- [x] Add `RoutineVariant` model (`id: UUID`, `name`, `order`, `blocks`)
- [x] Add `slotID: UUID` to `RoutineBlock` and `RoutineExercise`
- [x] Backfill: deduplicate `slotID`s, create "Default" variant for existing routines
- [x] Register `RoutineVariant` in model container
- [x] UI unchanged; existing routines display correctly

### Phase 1.2 — Data integrity hardening ✅

- [x] Change `Exercise.workoutItems` delete rule from `.cascade` to `.nullify`
- [x] Verified: deleting an exercise no longer destroys workout history

### Phase 2.1 — Remove silent mutations ✅

- [x] Removed `persistDefaultsOnlyForCurrentExercises()` from finish path
- [x] Removed `persistExerciseNotesOnlyForCurrentExercises()` from finish path
- [x] Removed `applyExerciseSwapsToRoutine()` from finish path
- [x] Verified: completing a workout does not silently mutate Exercise or Routine

### Phase 2.2 — Explicit apply flow ✅

- [x] Added `hasSwapsPending` / `hasNotesPending` detection on workout finish
- [x] Added `.confirmationDialog` with 4 options: this workout only / update routine swaps / update global notes / apply both
- [x] `finishWorkout(applySwaps:applyNotes:)` centralized finish helper

### Phase 3.1 — Prescription models ✅

- [x] Added `SlotPrescription` model (core + autoregulation + duration + context fields)
- [x] Added `WarmupScheme` + `WarmupStep` models (reusable, `.nullify` delete rule)
- [x] Added `TechniquePlan` model (parameterized, `.cascade` owned by prescription)
- [x] Added `WarmupStepKind` and `TechniqueType` enums
- [x] Added `templateNotes: String?` and `prescription: SlotPrescription?` (.cascade) to `RoutineExercise`
- [x] Backfill: `BootstrapRoot.backfillPhase3_1()` ensures every `RoutineExercise` has a `SlotPrescription`

### Phase 3.2a — Prescription-driven template generation ✅

- [x] `SlotPrescription.hasContent` computed property
- [x] `SlotPrescription.generateTemplates() -> [SetTemplate]` (deterministic; does not insert into context)
- [x] `RoutineExercise.resolvedTemplates() -> [SetTemplate]` (shared 3-tier resolver)

### Phase 3.2b — Workout plan uses prescription resolver ✅

- [x] `StartWorkoutFromRoutineView.makePlan()` calls `re.resolvedTemplates()`
- [x] Removed local `resolvedTemplates(for:)` and `normalizeTemplateOrder()`

### Phase 3.2c — Routine editor writes prescription + slot notes ✅

- [x] `SlotPrescriptionSection` + `PrescriptionFields` views
- [x] Slot notes field bound to `re.templateNotes`
- [x] Shows precedence hint when custom `setTemplates` exist

### Phase 3.3a — Session snapshot fields ✅

- [x] `PlannedPrescriptionSnapshot` @Model (mirrors SlotPrescription display fields)
- [x] `routineSlotID`, `templateNotesSnapshot`, `plannedPrescriptionSnapshot` on `WorkoutItem`

### Phase 3.3b — Populate snapshots at workout start ✅

- [x] `PrescriptionSnapshotPayload` value struct in plan
- [x] `PlanExercise` extended with `routineSlotID`, `templateNotesSnapshot`, `prescriptionSnapshot`
- [x] `makePlan()` populates snapshot fields; all `WorkoutItem` creation sites populate snapshots

### Phase 3.3c — Workout UI displays planned prescription ✅

- [x] Compact "Planned" section in `ActiveWorkoutView` between Actions and Sets
- [x] Reads from `PlanExercise.prescriptionSnapshot` (immutable snapshot data)
- [x] Section hidden when no snapshot data exists (graceful fallback for old workouts)

### Phase 3.5 — Warmup scheme + technique plan editor UI ✅

Template-level editing for advanced prescription elements.

**Completed:**

- [x] Warmup scheme picker/editor in routine slot detail (select existing or create new)
- [x] WarmupStep list editor (order, kind, reps, percent, rest, note)
- [x] TechniquePlan list editor in routine slot detail (add/remove/reorder techniques)
- [x] Technique type picker with parameterized fields per type
- [x] Prescription section reflects warmup/technique counts as summary badges

### Phase 3.6 — Technique execution + snapshot UX ✅

How techniques are parameterized, snapshotted, targeted, and rendered during a workout.

**Completed:**

- [x] Technique plans support parameterized fields per type (e.g. dropset %, count, effort mode)
- [x] Technique plans are snapshotted at workout start into `TechniquePlanSnapshot` value types (no live SwiftData references in session UI)
- [x] Technique snapshots are persisted/resumable for cold restart
- [x] Technique targeting uses explicit working-set indices rather than only preset buckets
- [x] Workout UI renders technique summaries from snapshot data (including applies-to detail when relevant)
- [x] Dropsets support sub-set logging under the parent working set via `SetLog.subIndex`
- [x] Drop weight suggestion auto-computes from parent / prior drop unless manually overridden
- [x] Conflict rules enforced:
  - one intensity finisher per target set
  - dropset and AMRAP mutually exclusive on overlapping targets
  - duplicate technique type on overlapping targets blocked
- [x] Technique plan defaults (effort mode, drop %, count, targeting indices) are initialized when a new `TechniquePlan` is created
- [x] Verified: technique plans remain template-side; sessions do not mutate them unless a future explicit apply-back flow is added

### Phase 3.7 — Warmup execution UX + cold-resume persistence ✅

Warmup schemes are editable at the template level and execute in workouts as dedicated, loggable warmup rows.

**Completed:**

- [x] Warmup steps are snapshotted into the workout plan as value types (not converted into working `SetTemplate` rows)
- [x] Active workout renders a dedicated **Warmup** section above working sets
- [x] Warmup rows display reps / percent of working / note / rest correctly
- [x] Warmup rows are loggable and create `SetLog(kind: .warmup)` entries
- [x] Warmup logging starts rest timers using step rest (fallback to prescription rest-between)
- [x] Warmup logs do not count toward working-set progress
- [x] Warmup snapshot persists across cold resume, so the Warmup section remains visible after app restart

### Phase 4a — Persisted AppState + resume after restart ✅

- [x] `AppState` model: `WorkoutLifecycleState` enum (idle/active/finished), singleton with `@Attribute(.unique) key`
- [x] Fields: `activeWorkoutID`, `activeWorkoutStartedAt`, `activeRestEndsAt`, `activeRestSlotID`
- [x] `Workout.routineID: UUID?` added (single source of truth for routine association)
- [x] `WorkoutResumeService.rebuildPlan(for:in:)` — primary path (routine exists) + fallback path (routine deleted, flat blocks from workout items)
- [x] `BootstrapRoot.fetchOrCreateAppState(in:)` — idempotent singleton fetch/create
- [x] `BootstrapRoot.validateActiveSession()` — resets to `.idle` if referenced workout missing
- [x] `RootTabView.checkForActiveSession()` — `.task` with run-once guard, presents `.fullScreenCover`
- [x] Resume binds to existing `Workout` via `rebuildItemsByExerciseID()` — never creates duplicates
- [x] `ActiveWorkoutView.updateAppState(to:)` — sets on `.onAppear`, clears on `unlockAndDismiss()`
- [x] `RoutinesView.endActiveSessionIfAny()` clears AppState
- [x] `PrescriptionSnapshotPayload.init(from: PlannedPrescriptionSnapshot)` for fallback rebuild

**Manual verification:**

- Start workout → kill app → relaunch → fullScreenCover resumes with correct plan, bound to same Workout
- Start workout → finish → relaunch → no resume prompt
- Start workout → delete routine → kill → relaunch → degraded flat-block resume works
- Start workout → end (discard) → relaunch → no resume

### Phase 4a.1 — Rest timer durability ✅

- [x] `RestTimer.stableNotificationID` — deterministic IDs (`"rest.<workoutID>.<slotID>"`)
- [x] `scheduleRestDoneNotification` uses stable ID, cancels pending+delivered before scheduling
- [x] `startRestWithPersistence(seconds:slotID:)` — cancels old slot notification before overwriting ID
- [x] `persistRestState(endsAt:slotID:)` / `clearPersistedRestState()` write to AppState
- [x] `restoreStableRestID()` + `resumeRestFromAppState()` for cold resume fallback
- [x] `.onChange(of: rest.isRunning)` auto-clears persisted rest on natural expiration

**Manual verification:**

- Rest timer survives app kill and cold restart
- No duplicate notifications on resume or cross-slot transitions

### Phase 4b — Lifecycle hardening: non-destructive end + workout metadata ✅

Core concern: prevent accidental data loss from destructive dismissal paths. Add workout metadata so history has duration and exercise names survive deletion.

**Completed:**

- [x] `completedAt: Date?` on `Workout` — set in all finish and "Save & Exit" paths
- [x] "End Workout" replaced with two-option `.confirmationDialog` (Save & Exit / Discard)
- [x] `RoutinesView.endActiveSessionIfAny()` finalizes old workout (`completedAt = Date()`) instead of deleting
- [x] `exerciseNameSnapshot: String?` on `WorkoutItem` — populated at init and all creation sites
- [x] `WorkoutItem.init(exercise:setLogs:)` sets `exerciseNameSnapshot = exercise.name`
- [x] `populateSnapshotFields(on:from:)` sets `exerciseNameSnapshot = planEx.name` (covers appendSetLog, appendTimeSetLog, swapExercise)
- [x] HistoryView: "In Progress" badge on active workout row; deletion blocked with alert
- [x] HistoryView: `workoutDuration()` displays formatted duration from `completedAt - date`
- [x] WorkoutDetailView: exercise name fallback via `exerciseNameSnapshot` when exercise is deleted

**Manual verification:**

1. Start workout → log 3 sets → End → "Save & Exit" → workout appears in history with 3 sets and duration
2. Start workout → log sets → End → "Discard Workout" → workout is gone from history
3. Start routine A → log sets → go back → start routine B with override → old workout A appears in history with sets preserved
4. Start workout → switch to History tab → in-progress workout is visually distinct or not shown
5. Finish workout normally → `completedAt` is populated → duration shown in history row
6. Delete an exercise → check history still shows the exercise name from snapshot

### Phase 4c — Cold restart session fidelity ✅

Core concern: in-workout edits (session plans, exercise swaps, current position) survive cold restart. Without this, a cold restart loses all session plan edits and resets position to the first exercise.

**Completed:**

- [x] `SessionPlan` conforms to `Codable`
- [x] `sessionPlansJSON: String?` added to `AppState` — stores `[String: SessionPlan]` as JSON (keyed by `routineSlotID` UUID string)
- [x] `activeBlockIndex: Int?` and `activeExerciseIndex: Int?` added to `AppState`
- [x] Session plans persisted to AppState on edit-sheet dismiss
- [x] Position persisted to AppState on block/exercise navigation changes
- [x] On resume: persisted session plans overlaid from AppState after `initializeSessionPlans()` via `restoreSessionPlansFromAppState()`
- [x] On resume: `currentBlockIndex` / `currentExerciseIndex` restored from AppState (clamped to valid range) via `restorePositionFromAppState()`
- [x] `WorkoutResumeService.rebuildPlan()`: reconciles exercise swaps — for each plan slot, checks if workout items have a different exercise for the same `routineSlotID`; updates plan's `currentExerciseID` and `name` if so
- [x] `updateAppState(to: .idle)` clears `sessionPlansJSON`, `activeBlockIndex`, `activeExerciseIndex`

**Manual verification:**

1. Start workout → edit session plan (sets 3→5, rest 60→90) → kill app → resume → session plan shows edited values
2. Start workout → navigate to 3rd exercise → kill app → resume → position at 3rd exercise (or nearest valid)
3. Start workout → swap bench press for incline bench → log 2 sets → kill app → resume → plan shows incline bench in that slot with 2 logged sets
4. Finish workout normally → verify `sessionPlansJSON`, `activeBlockIndex`, `activeExerciseIndex` are nil in AppState

### Phase 5 — Session plan editing + explicit apply-back ✅

- [x] `SessionPlan` struct: in-memory per-exercise copy of prescription fields (sets, repMin/Max, rest, RIR, RPE, tempo)
- [x] `sessionPlans: [UUID: SessionPlan]` dictionary in `ActiveWorkoutView`, keyed by `PlanExercise.id`
- [x] Session plan edit sheet: modify sets, rep range, rest, autoregulation during workout
- [x] `effectiveSetCount` resolves displayed set target: session plan → prescription snapshot → setTemplate count
- [x] Rest timer uses session plan rest values with precedence over prescription snapshot
- [x] Set target defaults (reps, weight input) use session plan values
- [x] Compact "Planned" display updates live from session plan edits
- [x] `hasSessionPlanPending` detects divergence from original prescription snapshot
- [x] Finish dialog: explicit apply-back via `applySessionPlansToSlotPrescriptions()` — writes changed fields to `SlotPrescription` using `routineSlotID` matching
- [x] Exercise swap: keep/reset dialog for logged sets
- [x] Exercise picker filters out exercises already present in the current block

**Manual verification:**

- Editing session plan during workout does not touch SlotPrescription until explicit apply
- Apply-back only writes to matching slots via `routineSlotID`

### Phase 5.1 — User settings: autoregulation mode, weight units, and default prescription values ✅

Persisted user preferences that affect workout UX, input defaults, and slot creation flow.

**Completed:**

- [x] `AppSettings` (`@AppStorage`-backed UserDefaults) with `autoregMode`, `weightIsKg`, and new-slot defaults (`defaultSets`, `defaultRepMin`, `defaultRepMax`, `defaultRestBetweenSets`, `defaultRestAfterExercise`, `defaultRIR`, `defaultRPE`)
- [x] Settings screen (Settings tab) for editing all preferences
- [x] New routine slot prescriptions prefill from `AppSettings` defaults instead of hardcoded values
- [x] In-workout plan edit sheet shows only the active autoregulation field (RIR or RPE); `none` hides the intensity row
- [x] Switching autoregulation mode does not destroy stored data; RIR and RPE fields are kept in sync via `10 − x` conversion (editing one writes the other); plan preview and editors show only the active mode field; see Phase 3.9 for implementation details
- [x] Changing settings affects newly created prescriptions only; existing routines and active sessions not silently mutated

**Manual verification:**

- Create new slot prescription → fields prefill from AppSettings defaults
- Change autoregMode to RIR → workout plan edit shows only RIR field
- Change autoregMode to none → intensity row hidden in workout plan edit
- Change defaultSets to 5 → next new slot prescription has 5 sets

---

## 4) Remaining Phases

### Phase 3.8 — Technique attachment UX / interaction redesign

Current technique infrastructure is functional but still clunky in production use. Techniques should feel attached to the sets they modify, not primarily grouped in a top summary row.

**Completed:**

- [x] Render techniques inline on the affected working-set rows (set-attached chips / badges)
- [x] Per-set technique chip labels use payload-only text (no redundant applies-to suffix)
- [x] Reduce reliance on the top-level technique summary as the primary interaction surface
- [x] Improve technique editor flow so targeting multiple sets is fast and obvious
- [x] Dropset UI cohesion: parent working set + drop sub-rows rendered as one unified `VStack` card in a single list row; redundant dropset chip/badge in the top summary suppressed when drop rows are already shown inline
- [x] Dropset rest timing: parent working set no longer starts normal rest when a dropset technique applies; non-final drops use only dropset-specific `restSeconds` (no prescription fallback); final drop fires the appropriate next rest (see Phase 5.2 for full details)
- [x] Dropset grouped card: dropset technique summary (effort mode, drop %, count) displayed inside the unified card between the parent set row and drop rows; no detached or duplicate chip display
- [x] Dropset completion gating: a working set with a dropset technique is not complete until the parent set AND all configured drops are logged; Drop 1 unlocks after parent, Drop N after Drop N-1; the next working set unlocks only after the final drop is logged; gating state preserved across cold resume via `dropsLoggedByExercise`
- [x] Dropset Log button visual consistency: "Log Drop" buttons now use `.borderedProminent` style matching normal set Log buttons; enabled/unlogged drops show the active primary visual state; disabled and logged states match normal set row behavior
- [x] Duration-based technique compatibility: rep/weight-dependent techniques (Drop Set, Partial Reps, Rest-Pause, Cluster, AMRAP) are disabled in the Add Technique picker for duration-based prescriptions with the reason "Not available for duration-based exercises."; Tempo Override and To Failure remain available; existing incompatible saved techniques are displayed and editable without crashing or silent mutation
- [x] Drop weight reset/suggest UX: drop weight rows show a "↩ suggest" reset action only when the current visible value differs from the computed suggestion; tapping clears the manual override and returns the field to auto-suggestion behavior
- [x] Dropset manual/draft weight persistence: manually edited unlogged drop weights survive cold resume via per-workout UserDefaults draft store (key `dropWeightDrafts_<workoutID>`, slot key `<slotID>_<parentSetIndex>_<subIndex>`); logged drops continue to resume from `SetLog` (`subIndex != nil`); drafts never stored as `SetLog`; drafts cleared on log, "↩ suggest" reset, parent undo cascade, or workout finish/dismiss
- [x] Parent working-set input persistence: logged parent reps/weight restore from `SetLog` (`subIndex == nil`); unlogged parent draft reps/weight survive cold resume via per-workout UserDefaults draft store (key `parentDrafts_<workoutID>`, slot key `<slotID>_<setIndex>_<field>` where field ∈ {reps, weight, duration}); see "Active workout input persistence" in §1 for the full source-priority model
- [x] Parent undo / dropset cascade consistency: undoing the parent working set removes child drop `SetLog`s for that parent, clears child drop completion state, clears both logged and un-logged child drop drafts under that parent, and relocks the next working set; parent reps/weight are preserved as editable draft values by snapshotting the just-removed `SetLog` into the parent draft before removal, so log → undo → force-quit → resume retains the value

**Pending:**

- [ ] Non-dropset technique chip cohesion: integrate set-attached technique info directly into the affected set row rather than appending a separate chip row below it
- [ ] Extend sub-set logging pattern to rest-pause / cluster if retained as supported techniques
- [ ] Hide or collapse the top technique summary row when all techniques are already represented as set-attached chips (redundancy now that chips are primary)

### Phase 3.9 — Warmup editor redesign + numeric input polish

Warmup step definitions need clearer per-type field presentation. Numeric inputs across the app need consistent bounded controls.

**Completed:**

- [x] Warmup step editor: per-kind field visibility — Fixed Weight shows weight (typed decimal) + reps; % of Working shows percent + reps; Note Only shows only note; step kind selector drives visible fields
- [x] Fixed-weight warmup: `WarmupStep.weight: Double?` added (additive, nil default); editor exposes weight input; `WarmupStepSnapshot.weight` propagated to active workout
- [x] Percent warmup: reps field now available alongside percent field in the editor
- [x] Warmup editor uses `Stepper` controls for bounded numeric fields: reps (1–30), percent of working weight (10–100%, step 5), rest after (0–300s, step 15); weight remains typed decimal for precision
- [x] `WarmupStepRow` (editor list) updated to display combined summary per kind: fixed-weight shows `weight × reps`, percent shows `N% × M reps`, note-only shows note
- [x] Active workout warmup rows: `warmupStepDescription` updated to show `weight × reps` for fixed-weight steps; `buildWarmupRow` logs weight when present for fixed-weight steps (`SetLog(kind: .warmup)` unchanged)
- [x] Warmup rest timer behavior, cold-resume path, and `SetLog.kind = .warmup` logging semantics unchanged
- [x] Numeric input consistency (prescription editors): bounded integer fields (sets, rep min/max, rest between/after sets, duration min/max) use `Stepper` in both routine editor (`PrescriptionFields`) and in-session plan edit sheet (`EditSessionPlanSheet`); weight inputs remain free-form for precision
- [x] RIR and RPE use 0.5-step `Stepper` controls (RIR 0–5, RPE 5–10); active autoregulation mode controls which field is shown in prescription editors and plan preview
- [x] RIR↔RPE conversion sync: editing either field writes the counterpart via `RPE = 10 − RIR` / `RIR = 10 − RPE`; `doubleStepperRow(active:paired:range:step:convert:)` helper handles display derivation and sync-on-write in both editors
- [x] Plan preview (`SessionPlan.secondarySummary(autoregMode:)`) shows only the active autoregulation mode field — never both RIR and RPE simultaneously; `autoregMode` surfaced in `ActiveWorkoutView` via `@AppStorage` for this purpose
- [x] Settings default RIR/RPE sync: editing `defaultRIR` updates `defaultRPE` and vice versa via `.onChange`; default RIR range corrected to 0–5 (was incorrectly 0–10)
- [x] Tempo field replaced with structured 4-part `Stepper` editor: eccentric – stretch pause – concentric – squeeze pause (each 0–10 s); serializes to `"e-s-c-sq"` string (e.g. `"3-1-1-0"`); nil when all zero; 3-part legacy values parse safely (squeeze pause defaults to 0); `TempoEditorView` is a module-internal `View` shared by both prescription editors

### Phase 5.2 — Rest semantics cleanup + superset flow streamline

Reduce confusion by making rest fields consistent across routine editor and in-workout editing.

**Completed:**

- [x] `SlotPrescription.restSecondsAfterExercise` exposed in routine prescription editor as "Rest after exercise"
- [x] `AppSettings.defaultRestAfterExercise` applied when creating new slot prescriptions
- [x] Session plan edit sheet label renamed to "Rest after exercise (s)"
- [x] `restSecondsAfterExercise` wired into timer: on the final working set of a non-superset exercise, session plan → snapshot value is used; falls back to `restSecondsBetweenSets` → template rest if nil
- [x] "Rest after block" user-facing UI removed from the block row list
- [x] `RoutineBlock.restAfterSeconds` model field retained for compatibility (additive in runtime if non-zero on old data)
- [x] `applySessionPlansToSlotPrescriptions()` correctly writes `restSecondsAfterExercise` to `SlotPrescription`
- [x] `makeDefaultPrescription(isTimeBased:in:)` extracted as shared factory; `ensurePrescription()` delegates to it
- [x] `appendBlock()` eagerly calls `makeDefaultPrescription` for every new `RoutineExercise` — prescriptions are no longer lazy
- [x] `SupersetPicker.setCount(for:)` falls back to `AppSettings.defaultSets` for prescription-only exercises (no `defaultTemplates`)
- [x] `appendBlock()` superset validation uses resolved set count; no longer rejects prescription-only exercises
- [x] Superset "Rest after round" editing moved from `BlockRow` into `SupersetDetailNoRest` Details sheet (editable `Stepper`)
- [x] `BlockRow` simplified: removed editable round-rest text field, `@FocusState`, keyboard toolbar, `roundRestBinding(for:)`
- [x] Block list warning updated to guide users to Details sheet when round rest is unset
- [x] Normal blocks and supersets both start workouts with valid working-set rows
- [x] Existing routines not silently mutated by superset-related changes
- [x] Logging the parent working set no longer starts the normal rest timer when a dropset technique applies
- [x] Non-final drops use only dropset-specific `restSeconds` if > 0; no fallback to `restSecondsBetweenSets`
- [x] Final drop fires the real next rest: `restBetweenSets` if not the last working set, `restAfterExercise` (→ `restBetweenSets` fallback) if last working set, none if last set of entire workout
- [x] Warmup rest and superset round rest behavior unchanged
- [x] Mid-superset `restSecondsAfterExercise` suppression verified by code audit: `restSecondsAfterCurrentLog`'s `block.isSuperset` branch never consults `plannedRestAfterExercise`; per-exercise after-exercise rest cannot fire between exercises inside a round. Mid-round logs return `nil` until every exercise has logged the current set index, so no rest timer starts between exercises in a round
- [x] End-to-end (live workout) verification: `supersetRoundRestSeconds` correctly drives the round-rest timer after each non-final completed round in an active superset workout
- [x] Superset transition rest exposed as an editable "Rest before next block" `Stepper` in `SupersetDetailNoRest` (Superset Details sheet), bound to `RoutineBlock.restAfterSeconds`, range 0…600s step 15, 0 stored as nil. Block list (`BlockRow`) remains simplified — transition rest is not editable there
- [x] Final-round behavior wired: on the final round of a superset, `block.restAfterSeconds` (transition rest) **replaces** `supersetRoundRestSeconds` when configured (>0); if transition rest is unset, the previously computed round-rest fallback chain still applies; last set of the last block of the workout is still suppressed; non-superset blocks retain the legacy additive `restAfterSeconds` behavior (UI hidden)
- [x] Dropset-inside-superset rest timing fixed: the dropset final-drop path is now block-aware — inside a superset it never fires `restSecondsAfterExercise`; it only fires rest after every exercise's round at the parent set index is `isWorkingSetComplete` (parent + all configured drops). Non-final completed round → `supersetRoundRestSeconds` (fallback: max `plannedRestBetweenSets` across the round). Final completed round → `block.restAfterSeconds` (transition rest) replaces round rest when configured; otherwise round-rest fallback. Last set of the last block of the workout → suppressed. A defensive `supersetRoundComplete` guard was also added to the end-of-block transition-rest append branch so it cannot fire while drops are pending. Non-superset dropset rest semantics unchanged
- [x] Dropset-aware superset focus/advance: `advanceForSupersetAfterLog` is now completeness-aware (`isWorkingSetComplete`) — parent-logging a dropset-attached exercise no longer advances focus while drops are pending; focus stays until the final drop. The final-drop `onLog` now invokes `advanceForSupersetAfterLog`, so completing the drops triggers the same "set completed" advance behavior a normal parent log triggers. `allExercisesLogged` was updated to the same completeness semantics for internal consistency
- [x] Shared "Sets per exercise" control in `SupersetDetailNoRest`: a single `Stepper` in the Timing section drives all child `SlotPrescription.sets` for the block (range 0…20, step 1, 0 → nil). Per-exercise sets editing is suppressed in superset context via a new `hideSetsField: Bool` flag plumbed through `SlotPrescriptionSection` → `PrescriptionFields` (default `false` keeps non-superset blocks unchanged). Mismatched legacy data shows the **max** value across child prescriptions on first display — not silently truncated — and normalizes only when the user explicitly touches the shared Stepper
- [x] Shared "Sets per exercise" Stepper display refresh fix: backed by `@State private var displayedSets: Int?` so SwiftUI re-renders the Stepper label when the user edits. Root cause was that `@Bindable var block: RoutineBlock` does not propagate observation through nested `@Model` mutations (`block.exercises[i].prescription?.sets`), so a purely-computed display value did not refresh. Setter writes both the local `@State` (immediate label update) and every child prescription (persisted)
- [x] Superset exercise reordering: new "Exercises (drag to reorder)" section in `SupersetDetailNoRest` exposes `.onMove(perform: moveExercises)`, persisted by rewriting `RoutineExercise.order` based on the new sorted order; `EditButton()` added to the navigation toolbar to engage edit mode. No model changes. Active workout follows the new order via existing `block.exercises.sorted { $0.order < $1.order }` ordering. Non-superset block ordering UI is untouched

**Rest ownership reference (current):**

| Field | Owner | Editable in | Timer behavior |
|---|---|---|---|
| `restSecondsBetweenSets` | `SlotPrescription` | Routine editor + session plan | Non-final sets; final-set fallback |
| `restSecondsAfterExercise` | `SlotPrescription` | Routine editor + session plan | Final working set of non-superset exercise only |
| `restAfterSeconds` | `RoutineBlock` | Superset Details sheet ("Rest before next block") for supersets; no UI on non-superset blocks | Supersets: replaces round rest on the final round when >0. Non-supersets: legacy additive on the final set when non-zero |
| `supersetRoundRestSeconds` | `RoutineBlock` | Superset Details sheet | After each non-final completed superset round |

**Design refinement — superset timing decomposes into two distinct concepts:**

Superset rest must be editable as two independent fields:

1. **Rest after round** — `RoutineBlock.supersetRoundRestSeconds`. Fires after each **non-final** completed round of the superset. Already wired and edited in the Superset Details sheet.
2. **Rest after superset / before next block** — block-level transition rest. Fires after the **final** round of the superset before advancing to the next block. The model field is `RoutineBlock.restAfterSeconds` (UI was removed from the block list during the rest cleanup; needs to be re-exposed in the Superset Details / plan sheet, not the block list).

In a superset, the per-exercise `SlotPrescription.restSecondsAfterExercise` remains hidden / de-emphasized in editing UI and must never fire between exercises inside a round (already enforced; see verified completed item above).

The block list stays simplified — block transition rest is edited inside the Superset Details sheet alongside round rest, not as an inline field on the block row.

**Edit-mode / reorder consistency — canonical app-wide rule:**

- Any list that supports reorder, delete, or both exposes a standard SwiftUI `EditButton()` in its `NavigationStack` toolbar at `.topBarTrailing`.
- When `EditButton` coexists with a primary action (e.g., `+` add, `Start`), both live inside a single `ToolbarItemGroup(placement: .topBarTrailing)` with `EditButton` first, primary action second.
- `EditButton` engages SwiftUI edit mode, which surfaces drag handles for `.onMove` and inline minus-delete buttons for `.onDelete`. Swipe-to-delete continues to work outside edit mode where it was previously declared.
- Active workout / routine / block / exercise locks are honored in edit mode the same way as in swipe mode: locked rows surface the existing "In use" alert instead of being silently deleted; `.moveDisabled(...)` still blocks reorder on locked rows.
- All edit-mode delete paths route through the **existing** confirmation alert for that surface — no silent deletes, no bypass of impact-summary messages.

**Completed (5.2 — reorder / edit-mode consistency):**

- [x] Top-level **Saved Routines** list (`RoutinesView`): `EditButton` in `.topBarTrailing`; `@Query(sort: [\Routine.order, \Routine.name])`; `.onMove(perform: moveRoutines)` persists `Routine.order`; `.onDelete(perform: deleteRoutinesFromEdit)` routes to the existing `pendingDeleteRoutine` + `routineImpactMessage` alert; swipe-to-delete retained; locked routines surface the existing "In use" alert in both edit and swipe paths; new routines created via `addRoutine` get `order = max(existing) + 1`; one-shot `backfillRoutineOrderIfNeeded` on `.onAppear` normalizes legacy data only when every row has `order == 0` or values collide (idempotent)
- [x] Top-level **All Exercises** list (`ExercisesView`): `EditButton` in `.topBarTrailing`; `@Query(sort: [\Exercise.order, \Exercise.name])`; `.onMove(perform: moveExercises)` persists `Exercise.order`; `.onDelete(perform: deleteExercisesFromEdit)` routes to the existing `pendingDeleteExercise` + `buildImpactMessage` alert (impact summary preserved); swipe-to-delete retained; locked exercises surface the existing "In use" alert in both edit and swipe paths; reorder is disabled while search is non-empty via `.moveDisabled(!search.isEmpty)` (placed after `.onMove` / `.onDelete` so the modifier chain compiles on `DynamicViewContent`); new exercises created via `addExercise` get `order = max(existing) + 1`; one-shot `backfillExerciseOrderIfNeeded` on `.onAppear`
- [x] **Routine Editor → Blocks** list (`RoutineEditor` blocks section): `EditButton` in `.topBarTrailing` alongside Start; `.onMove(perform: moveBlocks)` (existing) with `.moveDisabled(activeGuard.isRoutineLocked(routine.id))` preserved; `.onDelete(perform: deleteBlocksFromEdit)` routes to the existing `DeletePrompt` alert; locked blocks surface the existing "In use" alert
- [x] **Warmup steps** (`WarmupSchemeEditor`) and **Technique plans** (`TechniquePlanEditor`): `EditButton` in `.topBarTrailing` alongside the existing `+` button via `ToolbarItemGroup`; `.onMove` and `.onDelete` (existing) now reachable via standard edit mode
- [x] **Superset Details — Exercises** (`SupersetDetailNoRest`): reorder via `EditButton` + `.onMove(perform: moveExercises)` persisting `RoutineExercise.order` (already shipped in the earlier superset slice; reaffirmed as part of the canonical pattern)

**Additive schema changes from this slice:** `Routine.order: Int = 0`, `Exercise.order: Int = 0`. Both are optional-with-default fields, so SwiftData performs a lightweight migration. Legacy rows are normalized once per surface via the backfill helpers above. See updated model snapshot in §2.

**Pending:**

- [ ] **Superset Details — exercise delete / remove path.** No existing safe "remove exercise from superset" path exists. Adding edit-mode delete here requires a design decision for the degenerate case where a superset drops to a single exercise: auto-collapse to a normal block, leave a single-exercise "superset" with a warning, or block the delete. Until that decision is made, edit mode in Superset Details surfaces drag handles only (no minus buttons)
- [ ] **`ExerciseEditView` default-templates list** (`ExercisesView.swift`): still has `.onMove` + `.onDelete` but no `EditButton`. Deferred because `Exercise.defaultTemplates` is targeted for removal in **Phase 9**; revisit alongside that decision rather than adding a short-lived `EditButton`

**Manual verification:**

- Logging parent working set with dropset technique: no rest timer starts
- Non-final drop with `restSeconds = 30`: timer fires for 30s only (no prescription fallback)
- Final drop on last working set: `restAfterExercise` fires (if set), else `restBetweenSets`
- Final drop on last set of entire workout: no rest timer

### Phase 6 — History refactor + workout detail

Upgrade history from string-based grouping to relationship-based, and add workout detail view.

**Completed (6.A — workout detail view + notes semantics):**

- [x] `WorkoutDetailView`: read-only, pushed via `NavigationLink` from every history row
- [x] In-progress workouts show `"Status: In Progress"` in the Overview section instead of Duration
- [x] Exercise name resolved as: `exercise.name` → `exerciseNameSnapshot` → `"Deleted exercise"`; renaming an exercise does not alter history display
- [x] Time-based sets display duration (`durationSeconds`); rep-based sets display reps + weight
- [x] Set logs sorted by `(indexInExercise, subIndex ?? -1)` so dropset sub-logs follow their parent working set in order
- [x] **Session Notes** (`Workout.notes`) — user-typed workout-level notes specific to the current session; editable in `ActiveWorkoutView`; persisted on the `Workout`; shown in `WorkoutDetailView` Overview when non-empty (nil/whitespace-only produces no visible Notes row). Distinct from both `Exercise.notes` and `RoutineExercise.templateNotes`
- [x] **Slot Guidance / Plan Notes** (`RoutineExercise.templateNotes` snapshot via `templateNotesSnapshot`) — per-slot coaching cues authored in the routine editor; shown read-only in the active workout Plan section without requiring the plan sheet. Distinct from both `Exercise.notes` and `Workout.notes`
- [x] **Exercise Notes** (`Exercise.notes`) — dedicated "Exercise Notes" `Section` in `ActiveWorkoutView`, positioned directly below Session Notes and above Actions. Source: live `Exercise.notes` fetched by `exercise.currentExerciseID` (via `fetchExercise(by:)`). The section renders whenever there is a focused exercise: it shows the notes text when present, and a "No notes yet." placeholder when nil/whitespace-only. The in-list display uses plain `Text` — **no inline `TextField` and no inline `Binding`** — preserving the no-silent-mutation invariant (Phase 2). Order in the active workout: Session Notes (editable) → Exercise Notes (read-only with edit affordance, see next item) → Actions → Plan section (containing Slot Guidance / Plan Notes, read-only)
- [x] **Exercise Notes edit path** — explicit `Edit Exercise Notes` button (`square.and.pencil`) inside the Exercise Notes section opens a focused `ExerciseNotesEditSheet`. The sheet binds via `@Bindable` to the live `Exercise` resolved at present-time, exposes a multi-line `TextField` over `Exercise.notes` (writes `nil` when the trimmed value is empty), and shows a footer caption: "These notes are saved to the exercise and reused across routines and workouts." Toolbar: **Done** persists via `try? ctx.save()` then dismisses; **Cancel** reverts to the original `Exercise.notes` value captured `onAppear` then dismisses, discarding in-flight edits. This sheet is the **only** place in the active workout where `Exercise.notes` can be edited — the in-list display remains read-only. In-list caption updated to: "Saved to this exercise. Editing here affects every routine and workout that uses this exercise."

**Notes semantics — three distinct note types (canonical):**

| Type | Field | Scope | Authored where | Shown where |
|---|---|---|---|---|
| Session Notes | `Workout.notes` | Per-workout | Active workout (inline editable) | Active workout + `WorkoutDetailView` |
| Exercise Notes | `Exercise.notes` | Global per-exercise (reusable) | Exercise page (editable); active workout via focused `ExerciseNotesEditSheet` (editable); no inline editing in the active workout list | Active workout list (read-only display, with edit-via-sheet affordance); Exercise page |
| Slot Guidance / Plan Notes | `RoutineExercise.templateNotes` (snapshotted to `WorkoutItem.templateNotesSnapshot`) | Per routine slot | Routine editor (editable on slot); session plan edit sheet for the in-progress workout's local copy | Active workout Plan section (read-only); history detail when present |

`Exercise.notes` is **retained** as the global notes field for an exercise. It is **not** being deprecated. The active workout exposes it as a read-only display surfacing reusable cues, plus an explicit, isolated edit sheet — there is no inline bound `TextField` on the active workout list (the historical silent-mutation source). All in-workout edits to `Exercise.notes` route exclusively through `ExerciseNotesEditSheet`.

**Pending (6.A — notes semantics correction):**

_None — Phase 6.A notes semantics are complete._

Phase 6.B is split into three sequential slices: **A** add + populate (additive schema), **B** backfill existing rows, **C** display switch (live-routed labels; sectioned grouping optional follow-up).

**Completed (6.B Slice A — additive `routineVariantID` + populate on new workouts):**

- [x] `Workout.routineVariantID: UUID?` added — additive, optional, default nil. Lightweight SwiftData migration (existing rows take nil). Stored by UUID (not relationship) to mirror `routineID` and to tolerate variant deletion (orphan UUIDs survive harmlessly; future display path falls back to live routine name, then to `routineName` snapshot). `Workout.init` accepts `routineVariantID: UUID? = nil`; pre-existing call sites compile because the parameter has a default
- [x] `WorkoutPlan.routineVariantID: UUID?` added — carries the value from the start path through to insertion and from the existing `Workout` through resume
- [x] `StartWorkoutFromRoutineView.preferredVariantID(for:)` — deterministic, read-only variant selection: (1) variant whose name case-insensitively equals "Default"; (2) otherwise lowest `(order, name)`; (3) otherwise nil. `makePlan(from:)` calls it and passes the result via `WorkoutPlan(routineVariantID:)`. No mutation: the launch-time variant backfill remains the single creator of variant rows
- [x] `ActiveWorkoutView` new-Workout insertion site (≈L1644, gated by `else if workout == nil`) writes `Workout(…, routineVariantID: plan.routineVariantID, …)`. Resume binds to the existing `Workout` and does not re-insert, so the persisted value is never overwritten
- [x] `WorkoutResumeService` preserves `routineVariantID` on **both** rebuild paths — primary `planFromRoutine(_:workout:workoutName:)` and fallback `planFromWorkoutItems(_:)` — by reading directly from the persisted `Workout` row
- [x] History UI / `HistoryView` / `WorkoutDetailView` intentionally untouched in this slice — Slice C covers display
- [x] No backfill of existing workouts in this slice — they remain `routineVariantID == nil` until Slice B
- [x] Build passes; no debug print / `TEMP DEBUG` code remains. Project has no `XCTest` target so the schema-change test policy could not be exercised automatically — recommend adding a test target as a follow-up so future model changes can be covered

**Completed (6.B Slice B — backfill existing workouts):**

- [x] `BootstrapRoot.backfillPhase6B()` added — idempotent, `@MainActor`, scoped to `Workout`s with `routineVariantID == nil`. Invoked from `BootstrapRoot.body.task` **after** `backfillPhase1()` (which guarantees every routine has at least one variant) and `backfillPhase3_1()`, and **before** `validateActiveSession()` so resumed sessions see the freshly linked rows
- [x] Candidate selection filters in Swift (`allWorkouts.filter { $0.routineVariantID == nil }`) rather than via a SwiftData `#Predicate { $0.routineVariantID == nil }` — optional-UUID predicates have been historically finicky and the candidate set is small, so an in-memory filter is the safer equivalent path (documented inline)
- [x] Resolution precedence per candidate: (1) match by `routineID` → preferred variant of that routine; (2) else lowercased `routineName` → preferred variant of that routine; (3) else leave nil so the row stays eligible for a future pass if the routine reappears. **Never overwrites** a non-nil `routineVariantID`
- [x] Preferred-variant selection extracted as `Routine.preferredVariantID` (in `Entities.swift`) — shared rule reused by both the start path (`StartWorkoutFromRoutineView.makePlan`) and this backfill so a backfilled workout resolves to the same variant a newly-started workout would: (1) variant whose name case-insensitively equals "Default"; (2) otherwise lowest `(order, name)`; (3) otherwise nil. Read-only; never mutates the model
- [x] Lookup tables (`byID`, `byLowercaseName`, `preferredByRoutineID`) built once per pass. Duplicate lowercased routine names are deterministically resolved by keeping the routine with the lowest `(order, name)` so reruns are stable and not dependent on fetch order
- [x] History UI / `HistoryView` / `WorkoutDetailView` intentionally still untouched — Slice C covers display. Existing `routineName` snapshot fallback remains the source of truth for rendering until then
- [x] Idempotency verified by simulator runs with temporary debug instrumentation (since removed): cold run on already-linked data short-circuited at the empty-candidates guard with zero writes; after artificially nilling two rows in the persistent store (one with `routineID`, one with only `routineName`), the next run resolved 1 via the id path + 1 via the name fallback and wrote 2 rows; the immediately following relaunch reported 0 candidates and 0 writes. No temporary debug print / `TEMP DEBUG` code remains. Build passes

**Pending (6.B Slice C — relationship-driven display, with optional grouping):**

- [ ] Replace direct `routineName` reads in `HistoryView` and `WorkoutDetailView` with a single `displayedRoutineLabel(_:)` helper that resolves: live `RoutineVariant.name` (when `routineVariantID` is non-nil and the variant still exists) → live `Routine.name` (when `routineID` resolves) → frozen `Workout.routineName` snapshot. Renaming a routine or variant must update history labels without rewriting any persisted field
- [ ] Performance: per CLAUDE.md "no heavy regrouping inside SwiftUI `body`" — compute any per-workout label resolution against a memoized `[UUID: String]` cache keyed by `routineVariantID` / `routineID`, recomputed on `workouts` change rather than per row
- [ ] **Design decision before implementing:** keep `HistoryView` as a flat reverse-chronological list with live labels (**C.1**, smallest), or switch to per-variant `Section` grouping with an "Other / Unlinked" bucket for nil-variant rows (**C.2**, larger UX change). Recommendation in the prior audit: **start with C.1**; only pursue C.2 after explicit confirmation
- [ ] Verify: renaming a routine or its variant does not break history grouping/labels; deleting a routine still keeps prior workouts visible via the `routineName` snapshot fallback; resume of pre-Slice-A workouts (nil `routineVariantID`) continues to render correctly

### Phase 7 — Tests + performance pass

**Pending:**

- [ ] Test: session creation snapshots prescription from template slot + stores routineSlotID
- [ ] Test: session edits do not mutate template unless explicit apply action is invoked
- [ ] Test: finishing a workout produces immutable history and clears active state
- [ ] Test: "Save & Exit" preserves workout with `completedAt` set; "Discard" deletes it
- [ ] Test (optional): resume active session after app restart with correct position and session plans
- [ ] Test (optional): history grouping by RoutineVariant survives name changes
- [ ] Performance: ensure history grouping is not done expensively in SwiftUI `body`
- [ ] Performance: add lightweight summary fields or caching if needed
- [ ] Performance: audit `resolvedTemplates(in:)` — avoid redundant fetches in list views

### Phase 8 — Deprecation cleanup

**Pending:**

- [ ] Deprecate `Workout.routineName` as primary grouping link (keep as display fallback)
- [ ] Evaluate deprecating `RoutineExercise.setTemplates` once prescription adoption is stable
- [ ] Remove commented-out silent mutation calls from `ActiveWorkoutView`
- [ ] Remove or use `WorkoutLifecycleState.finished` (currently unused — either remove it or use it in Phase 4b's "Save & Exit" path)
- [ ] Consider migration tool for existing device data cleanup
- [ ] Keep fallback read-only until migration is proven stable across updates

### Phase 9 — Remove Exercise.defaultTemplates

Slot prescription becomes the single source of programming intent.

**Pending:**

- [ ] Stop exposing `defaultTemplates` editing UI in exercise detail screens
- [ ] Update `resolvedTemplates()` to remove tier 3 (exercise defaults fallback)
- [ ] Replace tier 3 with "unprogrammed slot" logic: return empty array or sentinel
- [ ] Add "Unprogrammed" UX in routine editor (clear visual state + quick-fill buttons like "3x8", "5x5")
- [ ] Ensure all existing routines have prescriptions populated (migration pass or user prompt)
- [ ] Remove `Exercise.defaultTemplates` relationship and `SetTemplate` dependence on Exercise
- [ ] Handle migration: lightweight migration drops the field; backfill ensures no data loss
- [ ] Update `SupersetPicker` set-count validation to use prescription

### Phase 10 — Equipment & setup migration + Exercise UI polish

Move equipment/setup to Exercise-level and fill UI gaps.

**Pending:**

- [ ] Add `equipmentType: String?` and `setupDefaults: String?` to Exercise model
- [ ] Migrate existing `SlotPrescription.equipment` / `setupNotes` values to Exercise fields (one-time backfill)
- [ ] Deprecate and remove `equipment` / `setupNotes` from `SlotPrescription` (or keep as optional slot-level override)
- [ ] Add equipment and setup display/editing in Exercise detail UI
- [ ] Display `bodyPart` / muscle group in Exercise detail screens
- [ ] Optional: slot-level equipment override field

**Acceptance criteria:**

- [ ] Exercise detail screen shows `bodyPart` / muscle group (read + edit)
- [ ] Equipment and setup are edited on Exercise (not SlotPrescription) after migration
- [ ] `SlotPrescription.equipment` / `setupNotes` either removed or demoted to "override only"
- [ ] Migration backfill is idempotent and non-destructive
- [ ] Snapshots remain immutable: `PlannedPrescriptionSnapshot` equipment/setup reflect session-start state
- [ ] No silent mutations: editing Exercise-level equipment does not propagate to history

### Phase 11 — View decomposition / file architecture

`ActiveWorkoutView.swift` and `RoutinesView.swift` have grown large and contain multiple concerns. This phase splits them into focused subview and helper files in a strictly behavior-preserving refactor.

**Pending:**

- [ ] Split `ActiveWorkoutView.swift` into focused files: warmup section, set rows (reps/weight + time-based), dropset section + drop rows, technique chips + detail sheet
- [ ] Split `RoutinesView.swift` into focused files: prescription fields + `SlotPrescriptionSection`, technique plan editor, warmup step editor
- [ ] No logic changes during decomposition — behavior must be fully preserved
- [ ] Build must pass after each file split; run relevant test paths to confirm no regressions

---

## 5) Prescription Elements

### Exercise-level concerns (definition — shared across routines)

- `name`, `bodyPart`, `isTimeBased`, `isCustom`
- `notes` — global form cues / coaching notes
- `equipmentType` + `setupDefaults` — **future** (Phase 10; currently on SlotPrescription, migrating out)

### Slot-level concerns (stored on `SlotPrescription`)

- **Core**: sets, rep range (min/max), rest between sets, rest after exercise
- **Autoregulation**: RIR, RPE, tempo
- **Duration**: duration min/max seconds, `usesDuration` flag (only when `Exercise.isTimeBased`)
- **Warmup**: `WarmupScheme` (reusable, `.nullify`) with ordered `WarmupStep`s
- **Techniques**: `TechniquePlan` (owned, `.cascade`) — dropset, partial reps, rest-pause, AMRAP, to-failure, cluster, tempo override
- **Slot notes**: `RoutineExercise.templateNotes` — per-slot coaching notes distinct from `Exercise.notes`

> **Equipment/setup** currently lives on `SlotPrescription` but is being migrated to Exercise-level defaults (Phase 10). Slot-level equipment override is optional and only if a clear use case emerges.

### Additional production-grade prescription candidates (later)

These are NOT part of the current refactor scope but represent future prescription enrichment:

- **Set targeting mode**: straight sets vs top set + backoffs vs ramping
- **Intensity guidance**: %1RM target, suggested load rules (not fixed weight — weight is always session truth)
- **Pause reps / tempo variants / ROM constraints**: structured tempo patterns beyond the single tempo string
- **Grip / stance / cues**: structured fields or notes for setup specifics (may live on Exercise or slot)
- **Rest semantics (superset unification)**: slot-level rest fields (`restSecondsBetweenSets`, `restSecondsAfterExercise`) and `supersetRoundRestSeconds` are now wired. Future work: fold `RoutineBlock.restAfterSeconds` into slot-level fields and remove the legacy block-level field
- **Autoregulation rules**: stop conditions (e.g., "stop if bar speed drops"), adjust-load rules, performance-based set count
- **Progression hints**: last-time summary display, suggested load increases (read-only; never auto-writing defaults)

> **Weight is session truth.** Templates may include optional weight guidance later (e.g., %1RM, RPE-based suggestion), but weight should never be auto-written back to templates or exercise defaults.

---

## 6) Explicit "Not Part of This Refactor" (Backlog)

These are product tweaks and must not block completion:

- routine name editable
- **multi-select exercise add**
  - [ ] Selection UI: checkmark-based multi-select in exercise picker
  - [ ] Confirm-add action: selected exercises added in selection order
  - [ ] Search & filter: name search and optional bodyPart/muscle group filter
  - [ ] Edge case: duplicate exercise in same block shows warning or is silently allowed
- **remove extra "Done" buttons**
  - [ ] Audit: identify all views with standalone "Done" buttons
  - [ ] Replace with toolbar `.confirmationAction` placement or automatic dismiss
  - [ ] Keyboard UX: consistent "Done" toolbar on `.keyboard` placement
  - [ ] Sheet dismiss: prefer drag-to-dismiss over explicit close buttons
- preset note options
- pause/resume workout (may integrate with WorkoutState later)
- machine-specific weight/rep handling
- separate exercise progression history UI + charts
- full existing-history cleanup UI
- CSV import/export

---

## 7) Acceptance Criteria (Ship Bar)

### Core invariants

- Templates are never silently modified by workout actions
- Sessions are snapshotted and become immutable history when finished
- Slot IDs (`slotID`) are stable and unique per slot
- Deletion does not wipe history by default (`Exercise.workoutItems` is `.nullify`)

### Prescription architecture

- `SlotPrescription` is the single source of programming intent for routine slots
- `setTemplates` are compatibility/override only (Phase 8 evaluates deprecation)
- `Exercise.defaultTemplates` is targeted for removal (Phase 9); unprogrammed slots use "Unprogrammed" UX with quick-fill instead
- Resolution precedence target: slot setTemplates (optional) → slot prescription (primary) → unprogrammed fallback (UI prompt)
- Equipment/setup belongs on Exercise, not SlotPrescription (Phase 10 migration)

### Session snapshots + session plans

- Workout UI displays rep range (min-max), tempo, RIR, RPE, and slot notes from session-level snapshots
- Snapshots are copied at session start and are immutable thereafter
- Old workouts with nil snapshots degrade gracefully (section hidden)
- Session plans allow in-workout editing; apply-back to slot prescription is explicit and opt-in

### Workout lifecycle

- `AppState` persists active workout state across app restarts
- Cold resume presents `ActiveWorkoutView` via `WorkoutResumeService.rebuildPlan()`, binding to the existing `Workout`
- Rest timer survives restart with stable notification IDs (no duplicates)
- Finishing or discarding a workout clears all `AppState` fields
- "End Workout" offers "Save & Exit" (keeps data) vs "Discard" (deletes) — never silently destroys logged sets (Phase 4b)
- Session plan edits and exercise position survive cold restart (Phase 4c)

### History & grouping (once Phase 6 is complete)

- History grouping uses RoutineVariant relationship/ID (not `routineName` string)

### Quality

- 3-5 tests pass reliably
- No heavy regrouping inside SwiftUI `body` for history lists

---

## 8) Production Requirements (Non-negotiable)

### Migrations: non-destructive, additive first

- Add new entities/fields as optional with safe defaults.
- Backfill lazily or via migration helpers.
- Keep compatibility for existing data until stable.

### Deletion rules: protect history

Exercise → WorkoutItem is now `.nullify` (done).
Remaining goals:

- Deleting a routine/variant should NOT delete past workouts.
- Workouts should keep exercise name snapshots or survive nullified links gracefully.

### Performance

Avoid heavy grouping/filtering/sorting in SwiftUI `body`.
Prefer:

- Query-based fetch with sort descriptors
- Precomputed summaries (last performed, session count, duration, etc.)
- Cached groupings keyed by IDs

# REFACTOR_PLAN.md

Gym Log — Architecture v2 Refactor (SwiftUI + SwiftData)

Branches:

- `refactor/architecture-v2` — plan & rules
- `refactor/architecture-v2-exec` — execution (active)

Last updated: 2026-02-24 (KST)

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

### Template resolution (3-tier, current)

1. `RoutineExercise.setTemplates` — explicit per-set overrides (compatibility/power-user)
2. `SlotPrescription.generateTemplates()` — primary source of programming intent
3. `Exercise.defaultTemplates` — exercise-level fallback (targeted for removal in Phase 8)

### Session plan (in-workout editing)

- `SessionPlan` is a per-exercise in-memory copy of prescription fields, created at workout start.
- Users can edit sets, rep range, rest, RIR, RPE, tempo during the workout via a sheet.
- `effectiveSetCount` resolves the displayed set target from session plan → prescription snapshot → setTemplate count.
- Rest timer uses session plan rest values with precedence over prescription snapshot.
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
  - `id: UUID`, `name`, `bodyPart?`, `notes?`, `isCustom`, `isTimeBased`
  - `defaultTemplates: [SetTemplate]` (.cascade) — **legacy; targeted for removal** (see Phase 8)
  - `routineUsages: [RoutineExercise]` (.cascade)
  - `workoutItems: [WorkoutItem]` (**.nullify** — history preserved on exercise deletion)

- **Routine**
  - `id: UUID`, `name`, `notes?`
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
  - Context: `equipment?`, `setupNotes?` — **deprecated in slot; migrating to Exercise-level** (see Phase 9)
  - `warmupScheme: WarmupScheme?` (.nullify — reusable across slots)
  - `techniquePlans: [TechniquePlan]` (.cascade — owned by this prescription)

- **PlannedPrescriptionSnapshot** — immutable copy of SlotPrescription fields stored on WorkoutItem at session start
- **PrescriptionSnapshotPayload** — lightweight value-type carried in WorkoutPlan for snapshot creation

- **WarmupScheme** — `name`, `steps: [WarmupStep]` (.cascade)
- **WarmupStep** — `order`, `kind` (percentage/fixedReps/noteOnly), `reps?`, `percentOfWorking?`, `restSecondsAfter?`, `note?`
- **TechniquePlan** — `order`, `type` (dropset/partialReps/restPause/amrap/toFailure/cluster/tempoOverride), plus parameterized fields

- **SetTemplate** — `order`, `kind` (warmup/working/dropset), `targetReps`, `targetWeight?`, `restSecondsAfter?`, `durationSeconds?`
- **SetLog** — `indexInExercise`, `kind`, `reps`, `weight?`, `restSeconds?`, `durationSeconds?`, `timestamp`
- **WorkoutItem**
  - `exercise: Exercise?` (inverse), `setLogs: [SetLog]` (.cascade)
  - `routineSlotID: UUID?` — copy of `RoutineExercise.slotID` at session start
  - `templateNotesSnapshot: String?` — copy of `RoutineExercise.templateNotes`
  - `plannedPrescriptionSnapshot: PlannedPrescriptionSnapshot?` (.cascade) — immutable prescription snapshot
  - `exerciseNameSnapshot: String?` (**Phase 4b**) — copy of `exercise.name` at creation time (survives exercise deletion)
- **Workout** — `id: UUID`, `date`, `routineName: String?`, `routineID: UUID?`, `completedAt: Date?` (**Phase 4b**), `items: [WorkoutItem]` (.cascade), `notes?`

- **AppState** — persisted singleton (`@Attribute(.unique) key: "appState"`)
  - `workoutState: WorkoutLifecycleState` (idle/active/finished)
  - `activeWorkoutID: UUID?`, `activeWorkoutStartedAt: Date?`
  - `activeRestEndsAt: Date?`, `activeRestSlotID: UUID?`
  - `sessionPlansJSON: String?` (**Phase 4c**) — Codable `[String: SessionPlan]` keyed by routineSlotID
  - `activeBlockIndex: Int?`, `activeExerciseIndex: Int?` (**Phase 4c**)

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

**Verification:**

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

**Verification:**

- Rest timer survives app kill and cold restart
- No duplicate notifications on resume or cross-slot transitions

### Phase 4b — Lifecycle hardening: non-destructive end + workout metadata ✅

- [x] `completedAt: Date?` on `Workout` — set in all finish and "Save & Exit" paths
- [x] "End Workout" replaced with two-option `.confirmationDialog` (Save & Exit / Discard)
- [x] `RoutinesView.endActiveSessionIfAny()` finalizes old workout (`completedAt = Date()`) instead of deleting
- [x] `exerciseNameSnapshot: String?` on `WorkoutItem` — populated at init and all creation sites
- [x] `WorkoutItem.init(exercise:setLogs:)` sets `exerciseNameSnapshot = exercise.name`
- [x] `populateSnapshotFields(on:from:)` sets `exerciseNameSnapshot = planEx.name` (covers appendSetLog, appendTimeSetLog, swapExercise)
- [x] HistoryView: "In Progress" badge on active workout row; deletion blocked with alert
- [x] HistoryView: `workoutDuration()` displays formatted duration from `completedAt - date`
- [x] WorkoutDetailView: exercise name fallback via `exerciseNameSnapshot` when exercise is deleted

**Verification:**

- "End Workout" → "Save & Exit" keeps all logged sets with `completedAt`
- "End Workout" → "Discard Workout" deletes workout (explicit destructive choice)
- Starting routine B while routine A is active preserves workout A with `completedAt`
- In-progress workout shows "In Progress" badge in history (cannot be deleted)
- Completed workouts show duration (e.g. "1h 23m") in history row and detail
- Deleting an exercise still shows its name in history via `exerciseNameSnapshot`

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

**Verification:**

- Editing session plan during workout does not touch SlotPrescription until explicit apply
- Apply-back only writes to matching slots via `routineSlotID`

---

## 4) Remaining Phases

### Phase 4b — Lifecycle hardening: non-destructive end + workout metadata ✅

Core concern: prevent accidental data loss from destructive dismissal paths. Add workout metadata so history has duration and exercise names survive deletion.

**Current problems this solves:**

- ~~"End Workout" deletes the entire `Workout` — all logged sets silently destroyed.~~ **RESOLVED.**
- ~~"Start New" override in `RoutinesView.endActiveSessionIfAny()` deletes the old workout — logged sets lost.~~ **RESOLVED.**
- ~~`Workout` has no `completedAt` — can't display duration, can't distinguish finished from abandoned.~~ **RESOLVED.**
- ~~`WorkoutItem` has no exercise name snapshot — deleting an exercise makes history rows unreadable.~~ **RESOLVED.**
- ~~Active in-progress workout appears in HistoryView without visual distinction.~~ **RESOLVED.**

**Checklist:**

- [x] Add `completedAt: Date?` to `Workout` model (additive, lightweight migration)
- [x] Set `workout.completedAt = Date()` in all `finishWorkout()` paths (before `unlockAndDismiss`)
- [x] Replace "End Workout" destructive alert with a two-option `.confirmationDialog`:
  - "Save & Exit" — sets `completedAt`, clears AppState, dismisses (keeps all logged sets)
  - "Discard Workout" — deletes workout, clears AppState, dismisses (current behavior, clearly labeled)
- [x] `RoutinesView.endActiveSessionIfAny()`: finalize old workout (set `completedAt = Date()`) instead of deleting it
- [x] Add `exerciseNameSnapshot: String?` to `WorkoutItem` — copy of `exercise.name` at creation time
- [x] Populate `exerciseNameSnapshot` at all `WorkoutItem` creation sites (appendSetLog, appendTimeSetLog, swapExercise)
- [x] HistoryView: skip rows where `activeGuard.activeWorkoutID == w.id`, or show with a distinct "In Progress" badge
- [x] HistoryView: display workout duration on completed rows (computed: `completedAt - date`, formatted as `1h 23m`)

**Acceptance criteria:**

- [x] "End Workout" never silently destroys logged data — user must explicitly choose "Discard"
- [x] Overriding an active session with a new routine preserves the old workout with all logged sets
- [x] History shows workout duration for completed workouts
- [x] Deleting an exercise doesn't make history workout rows unreadable (`exerciseNameSnapshot` displayed as fallback)
- [x] In-progress workout is visually distinct or hidden in history

**Manual test checklist:**

1. Start workout → log 3 sets → End → "Save & Exit" → workout appears in history with 3 sets and duration
2. Start workout → log sets → End → "Discard Workout" → workout is gone from history
3. Start routine A → log sets → go back → start routine B with override → old workout A appears in history with sets preserved
4. Start workout → switch to History tab → in-progress workout is visually distinct or not shown
5. Finish workout normally → `completedAt` is populated → duration shown in history row
6. Delete an exercise → check history still shows the exercise name from snapshot

**Guardrails (must never regress):**

- AppState transitions: `.active` ↔ `.idle` clearing always nils all fields (including rest)
- Rest timer stable IDs and cancel-before-reschedule remain intact
- Session snapshot immutability: `PlannedPrescriptionSnapshot` is never mutated after creation
- Resume binds to existing Workout — never creates duplicates

---

### Phase 4c — Cold restart session fidelity ✅

Core concern: in-workout edits (session plans, exercise swaps, current position) survive cold restart. Without this, a cold restart loses all session plan edits and resets position to the first exercise.

**Current problems this solves:**

- `sessionPlans` dictionary is `@State` — edits (sets 3→5, rest 60→90) lost on cold restart.
- `currentBlockIndex` / `currentExerciseIndex` are `@State` — position resets to first exercise.
- Exercise swaps are in the in-memory `plan` only — after restart, routine-based rebuild shows the original exercise, not the swapped one.

**Checklist:**

- [x] Make `SessionPlan` conform to `Codable`
- [x] Add `sessionPlansJSON: String?` to `AppState` — stores `[String: SessionPlan]` as JSON (keyed by `routineSlotID` UUID string)
- [x] Add `activeBlockIndex: Int?` and `activeExerciseIndex: Int?` to `AppState`
- [x] Persist session plans to AppState on session plan edit (on edit-sheet dismiss)
- [x] Persist position to AppState on block/exercise navigation changes
- [x] On resume: after `initializeSessionPlans()`, overlay persisted session plans from AppState (they take precedence) via `restoreSessionPlansFromAppState()`
- [x] On resume: restore `currentBlockIndex` / `currentExerciseIndex` from AppState (clamped to valid range) via `restorePositionFromAppState()`
- [x] `WorkoutResumeService.rebuildPlan()`: reconcile exercise swaps — for each plan slot, check if workout items have a different exercise for the same `routineSlotID`; if so, update plan's `currentExerciseID` and `name`
- [x] Clear `sessionPlansJSON`, `activeBlockIndex`, `activeExerciseIndex` in `updateAppState(to: .idle)`

**Acceptance criteria:**

- [x] Session plan edits survive cold restart (verified with round-trip: edit → kill → resume → check values)
- [x] Exercise position survives cold restart (at least within valid bounds)
- [x] Swapped exercises display correctly after cold restart (plan shows swapped exercise, not original)
- [x] Finishing or discarding a workout clears all persisted session state from AppState

**Manual test checklist:**

1. Start workout → edit session plan (sets 3→5, rest 60→90) → kill app → resume → session plan shows edited values
2. Start workout → navigate to 3rd exercise → kill app → resume → position at 3rd exercise (or nearest valid)
3. Start workout → swap bench press for incline bench → log 2 sets → kill app → resume → plan shows incline bench in that slot with 2 logged sets
4. Finish workout normally → verify `sessionPlansJSON`, `activeBlockIndex`, `activeExerciseIndex` are nil in AppState

**Guardrails (must never regress):**

- Session plans keyed by `routineSlotID` (stable UUID, survives rebuild)
- `rebuildItemsByExerciseID()` matching logic unchanged (routineSlotID-first, then exercise ID fallback)
- Plan rebuild primary path (routine exists) and fallback path (routine deleted) both work correctly
- Persisted session plan values are always validated against live plan on restore (ignore stale keys)

---

### Phase 3.5 — Warmup scheme + technique plan editor UI ✅

Template-level editing for advanced prescription elements.

- [x] Warmup scheme picker/editor in routine slot detail (select existing or create new)
- [x] WarmupStep list editor (order, kind, reps, percent, rest, note)
- [x] TechniquePlan list editor in routine slot detail (add/remove/reorder techniques)
- [x] Technique type picker with parameterized fields per type
- [x] Prescription section reflects warmup/technique counts as summary badges

### Phase 3.6 — Technique execution UX ✅

How techniques affect set rendering and logging during a workout.

- [x] Define how each `TechniqueType` modifies set display — labels: Dropset, Partial Reps, Rest-Pause, AMRAP, To Failure, Cluster, Tempo Override (with parameterized detail where available)
- [x] Technique labels snapshotted at plan-build time into `PlanExercise.techniqueSummaries: [String]` — value type, no live SwiftData reference during session
- [x] Workout UI renders `TechniqueIndicatorRow` (horizontal scrollable capsule badges) in the Sets section header when `techniqueSummaries` is non-empty
- [x] SetLog captures technique metadata via existing `kind` field (dropset already handled); further metadata inferred from plan
- [x] Verified: `techniqueSummaries` is a read-only snapshot — technique plans are never mutated by session actions

### Phase 3.7 — Warmup execution UX

Warmup schemes exist in slot prescriptions (Phase 3.5 editor UI), but must render and log correctly during workouts.

- [ ] Convert `WarmupScheme.steps` into executable set rows at plan-build time
- Prefer: generate `SetTemplate(kind: .warmup, ...)` prepended before working sets
- Ensure templates are deterministic and snapshot-safe (value types in plan; no live SwiftData links)
- [ ] ActiveWorkoutView renders warmup sets distinctly (badge/label) but logs them like normal sets
- [ ] Verify: warmup steps appear in workout UI exactly as configured in prescription (order + rest fields)
- [ ] Verify: warmup does not affect session plan “working set count” math (warmups are extra, not counted as working sets)

### Phase 5.1 — User settings: autoregulation mode + weight units

Persisted user preferences that affect workout UX and inputs.

- [ ] Add persisted settings model (singleton): `autoregulationMode` (RIR vs RPE), `weightUnit` (kg vs lb)
- [ ] Settings screen: user can change both
- [ ] In-workout plan edit sheet shows only the active autoregulation field by default (RIR or RPE)
- [ ] Verify: switching mode does not destroy stored data (both fields may exist; UI chooses which to emphasize)

### Phase 5.2 — Rest semantics cleanup + superset flow streamline

Reduce confusion by making rest fields consistent across routine editor and in-workout editing.

- [ ] Move slot-level "Rest after exercise" UX fully into `SlotPrescription.restSecondsAfterExercise`
- [ ] Ensure routine editor and in-workout plan edit present rest fields consistently:
- Rest between sets (slot)
- Rest after exercise (slot)
- Superset round rest (block, if superset)
- Block rest-after (block, if used)
- [ ] Verify: apply-back writes slot rest-after into SlotPrescription (not an unrelated field)
- [ ] Verify: superset rest fields have clear labels and do not conflict with slot rest fields

### Phase 6 — History refactor + workout detail

Upgrade history from string-based grouping to relationship-based, and add workout detail view.

- [ ] Add `routineVariantID: UUID?` (or relationship) on `Workout`
- [ ] New sessions always populate `routineVariantID`
- [ ] Backfill existing workouts: if `routineName` matches an existing Routine → link to its Default variant
- [ ] Keep `routineName` for display fallback (read-only compatibility)
- [ ] Update `HistoryView` grouping to use relationship/ID, falling back to `routineName` for unlinked records
- [ ] Verify: renaming a routine or variant does not break history grouping
- [ ] Add workout detail view: `NavigationLink` from history row → detail screen showing exercises, sets, weights, duration
- [ ] Workout detail: display exercise names from `exerciseNameSnapshot` when `exercise` relationship is nil (exercise deleted)
- [ ] Workout detail: show workout notes if present

### Phase 7 — Tests + performance pass

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

- [ ] Deprecate `Workout.routineName` as primary grouping link (keep as display fallback)
- [ ] Evaluate deprecating `RoutineExercise.setTemplates` once prescription adoption is stable
- [ ] Remove commented-out silent mutation calls from `ActiveWorkoutView`
- [ ] Remove or use `WorkoutLifecycleState.finished` (currently unused — either remove it or use it in Phase 4b's "Save & Exit" path)
- [ ] Consider migration tool for existing device data cleanup
- [ ] Keep fallback read-only until migration is proven stable across updates

### Phase 9 — Remove Exercise.defaultTemplates

Slot prescription becomes the single source of programming intent.

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

- [ ] Add `equipmentType: String?` and `setupDefaults: String?` to Exercise model
- [ ] Migrate existing `SlotPrescription.equipment` / `setupNotes` values to Exercise fields (one-time backfill)
- [ ] Deprecate and remove `equipment` / `setupNotes` from `SlotPrescription` (or keep as optional slot-level override)
- [ ] Add equipment and setup display/editing in Exercise detail UI
- [ ] Display `bodyPart` / muscle group in Exercise detail screens
- [ ] Optional: slot-level equipment override field

**Acceptance criteria (Phase 10):**

- [ ] Exercise detail screen shows `bodyPart` / muscle group (read + edit)
- [ ] Equipment and setup are edited on Exercise (not SlotPrescription) after migration
- [ ] `SlotPrescription.equipment` / `setupNotes` either removed or demoted to "override only"
- [ ] Migration backfill is idempotent and non-destructive
- [ ] Snapshots remain immutable: `PlannedPrescriptionSnapshot` equipment/setup reflect session-start state
- [ ] No silent mutations: editing Exercise-level equipment does not propagate to history

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
- **Rest semantics**: unified model for set rest vs exercise rest vs superset round rest (currently separate fields)
- **Autoregulation rules**: stop conditions (e.g., "stop if bar speed drops"), adjust-load rules, performance-based set count
- **Progression hints**: last-time summary display, suggested load increases (read-only; never auto-writing defaults)

> **Weight is session truth.** Templates may include optional weight guidance later (e.g., %1RM, RPE-based suggestion), but weight should never be auto-written back to templates or exercise defaults.

---

## 6) Explicit "Not Part of This Refactor" (Backlog)

These are product tweaks and must not block completion:

- routine name editable
- reorder routines by drag
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
- +/- steppers for reps
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

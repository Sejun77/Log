# REFACTOR_PLAN.md

Gym Log — Architecture v2 Refactor (SwiftUI + SwiftData)

Branches:

- `refactor/architecture-v2` — plan & rules
- `refactor/architecture-v2-exec` — execution (active)

Last updated: 2026-05-18 (KST) — Phase 7 Slices 7.0 + 7.1 + 7.2 + 7.3 + 7.4 (RestTimer + ParentDraftStore + DropWeightDraftStore + RestPlanner simple-branch + RestPlanner superset sub-slices) + 7.5 complete: `LogTests` XCTest target wired with an in-memory `ModelContainer` harness and full suite at 90/90; the 7.4-B DropWeightDraftStore sub-slice lifted drop-weight draft persistence out of `ActiveWorkoutView.swift` into `Log/Services/DropWeightDraftStore.swift` (storage layout byte-identical; `restoreDropWeightDrafts` @State bridge kept in the view) and added 10 pure-XCTest cases including a literal-string format pin. The 7.4-A ParentDraftStore sub-slice had already added 13 cases and the 7.4 RestTimer sub-slice 7. The 7.4-C.1 RestPlanner sub-slice lifted the simple non-superset rest decisions (between-set rest, final-set after-exercise rest, template-based dropset skip, last-set-of-workout suppression) out of `ActiveWorkoutView.restSecondsAfterCurrentLog` into `Log/Services/RestPlanner.swift` (pure `RestContext` value type + pure `RestPlanner.restSecondsAfterLog(_:)` function; supersets, current-set-is-dropset final-drop, technique-based dropset suppression, warmup rest, and `block.restAfterSeconds` additive post-processing all stay inline) and added 12 pure-XCTest cases. The 7.4-C.2 RestPlanner sub-slice extended the planner with `SupersetRoundParticipant` + `SupersetRoundContext` + `RestPlanner.restSecondsAfterSupersetRound(_:)` and lifted the entire `block.isSuperset` rest branch — mid-round suppression, base round rest from `supersetRoundRestSeconds`, max-combined per-exercise planned/template fallback (both normal-round and after-dropset variants), next-round template-dropset skip, final-round transition rest replacement, and the superset-side last-set-of-workout suppression — out of the view, with 17 new pure-XCTest cases (29 total in `RestPlannerTests`). Rest-decision extraction sub-slices 7.4-C.3 (dropset final-drop) and 7.4-C.4 (intra-drop helper, if pursued) remain the open 7.4-C items. Active-workout identity Slice A (in-memory rekey from `Exercise.id` to `routineSlotID` across `loggedByExercise` / `dropsLoggedByExercise` / `inputsByExerciseID` / `itemsByExerciseID` and the three `ActiveWorkoutGuard` caches — `inputsCache` / `loggedCache` / `notesCache`) and Slice B (`ParentDraftStore` / `DropWeightDraftStore` persisted-key migration to `routineSlotID` with a parent-draft dual-read fallback and a drop-draft one-shot migration walker — `setAll(_:)` + `migrateLegacyKeys(in:legacyExerciseToSlots:knownSlots:)` — plus 11 new pure-XCTest cases bringing the suite to 101/101) both shipped: duplicate-Exercise-across-slots draft state is now slot-scoped end-to-end, including across force-quit + cold-resume, with in-flight legacy-format drafts migrated transparently. The superset manual-switch round-gating bug also shipped: `canLogSet` now enforces "previous round complete across every participating exercise" for supersets with `setIndex > 0`, using the dropset-aware `isWorkingSetComplete` so a dropset-attached round blocks the next round until the parent + all required drops are logged. The notes apply-back vestige (`ActiveWorkoutGuard.notesCache`, `notesBinding(for:)`, `persistExerciseNotesOnlyForCurrentExercises`, `hasNotesPending`, the swap-time cache seeding, the `"Finish + Update exercise notes"` button, and the `applyNotes` parameter on `finishWorkout`) was also deleted — `Exercise.notes` is now write-through-only via `ExerciseNotesEditSheet` (active workout) and the standalone Exercise page; duplicate-`Exercise` notes ambiguity is resolved by product semantics (global notes shared across slots, per-slot cues live in Slot Guidance / `RoutineExercise.templateNotes`); a latent revert-on-finish bug was fixed as a side effect. Superset Details exercise management also shipped: `+ Add Exercise` and `.onDelete` are wired in `SupersetDetailNoRest` (with a min-2-exercises alert, shared-sets coercion on Add, duplicate Exercise allowed by design), the parent-relationship cascade bug that caused the whole block to disappear on child delete is fixed by `block.exercises = survivors` before `ctx.delete`, and routine-lock gating is now scoped to individual mutation controls (per-Stepper / per-Button / per-Section / `.moveDisabled` / `.deleteDisabled` plus a Section-level `.disabled(isLocked)` inside `SlotPrescriptionSection`) so locked routines remain scrollable and readable. Duplicate-`Exercise`-inside-superset **integration verification** is the only open Pending block under Phase 5.2 — the prior UI blocker is gone, and only a manual smoke test on a hand-built two-slot superset remains. Phase 5.2 is NOT marked complete. Slice 7.3 extracted Phase 6.B backfill into `BackfillService`; Slice 7.2 extracted `RoutineLabelResolver`; Slice 7.5 aligned the test target's deployment to 18.5 and documented the concrete-simulator + app-hosted policy in CLAUDE.md. Host-less conversion attempted and reverted (iOS app targets can't link `@testable` symbols without `TEST_HOST` / `BUNDLE_LOADER`). Phase 6.B Slice C.1 / Slice B remain shipped; Slice C.2 grouping and rename verification still pending

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

**Completed (5.2 — superset manual-switch round gating):**

- [x] `ActiveWorkoutView.canLogSet(block:exercise:setIndex:)` tightened: in supersets, `setIndex > 0` now requires every exercise that participates in round `setIndex - 1` to be `isWorkingSetComplete` before any exercise in the block can log `setIndex`. Existing in-round ordering (within round `setIndex`, prior exercises in `block.exercises` order must complete first) is preserved as the second of two superset-only checks. Root cause: pre-fix, `canLogSet` only enforced (a) within-exercise progression of THIS exercise and (b) in-round prior-exercise order — neither required the **previous round** to be complete across the whole block, so after a manual Back to exercise A the user could log A2 with B1 still empty
- [x] Dropset-aware completion preserved: the new gate calls `isWorkingSetComplete(exercise:setIndex:)`, which already enforces "parent logged AND, for sets where a dropset technique applies, all configured drops logged." A dropset-attached round N of any superset exercise blocks round N+1 of every exercise in the block until both the parent log and every configured drop sub-log are present. No special-casing needed inside `canLogSet`
- [x] Non-superset blocks unaffected — the `if block.isSuperset` guard skips both superset checks entirely; the within-exercise progression check (rule 1) still runs for normal blocks, matching pre-fix behavior. Normal superset flow `A1 → B1 → A2 → B2 → …` is preserved: at the moment the user logs B1, round 0 becomes complete and `canLogSet(A, setIndex: 1)` passes both gates so A2 enables
- [x] `RestPlanner.restSecondsAfterSupersetRound(_:)` untouched. Its `SupersetRoundParticipant.isComplete` already used the same `isWorkingSetComplete` semantics through Slice A (Phase 5.2), so the rest-decision side has been correct since 7.4-C.2; the bug existed only on the logging-gate side. `advanceForSupersetAfterLog`, `allExercisesLogged`, `supersetRoundComplete`, and `isWorkingSetComplete` are unchanged
- [x] Build green; full XCTest suite **90/90 pass in ~1.10s**. Manual test verified: in a 2-exercise superset, A's set-2 log button stays disabled after a manual Back until B1 is logged; with a dropset technique attached to A's set 1, B's set-1 log button stays disabled until every configured drop of A1 lands. No regression in normal non-superset progression. No model / history / routines / exercises / notes / warmup / RIR / RPE / tempo changes

**Completed (5.2 — active-workout identity Slice A: in-memory rekey to `routineSlotID`):**

- [x] `ActiveWorkoutView` and `ActiveWorkoutGuard` in-memory state dictionaries rekeyed from `Exercise.id` to `routineSlotID`: `loggedByExercise`, `dropsLoggedByExercise`, `inputsByExerciseID`, `itemsByExerciseID`, `ActiveWorkoutGuard.inputsCache`, `ActiveWorkoutGuard.loggedCache`, `ActiveWorkoutGuard.notesCache`. Every read/write callsite migrated: `rehydrateFromWorkoutIfPresent`, `ensureInputsInitializedFromPlan`, `syncFromGuardCachesIfAny` / `syncToGuardCaches`, `inputBindings`, `durationBinding`, `canLogSet`, `isWorkingSetComplete`, `buildSetRow` (time-based + reps/weight branches, including their onLog/onUndo callbacks), `buildWarmupRow` (log + undo), `buildDropSection` (logged-subs read, parent-logged read, three internal helper calls), `notesBinding` (get + set), `applySessionPlanToInputs`, `swapExercise`, header logged-count read, `hasNotesPending`, `persistExerciseNotesOnlyForCurrentExercises`, `rebuildItemsByExerciseID`
- [x] Function signatures aligned: `appendSetLog(exerciseID:)` → `appendSetLog(slotID:)`, `appendTimeSetLog(exerciseID:)` → `appendTimeSetLog(slotID:)`, `appendDropLog(exerciseID:)` → `appendDropLog(slotID:)`, `undoDropLog(exerciseID:)` → `undoDropLog(slotID:)`, `suggestedDropWeight(exerciseID:)` → `suggestedDropWeight(slotID:)`. Each function's internal `$0.id == slotID` plan-walk is now `$0.routineSlotID == slotID`. `undoSetLog` gained a second parameter so it can carry both identities: `undoSetLog(slotID:exerciseID:setIndex:)` — `slotID` for in-memory state (items, drops, logged), `exerciseID` for the `ParentDraftStore.persist` snapshot-on-undo path and the drop-key string construction
- [x] **Persistence formats intentionally preserved in Slice A** (since shipped in Slice B): at the time of Slice A, `ParentDraftStore.persist/clear/load(slotID:)` still received `Exercise.id` from every callsite and drop-key strings remained `"<exerciseID>_<setIndex>_<sub>"`. Slice B (see Completed block below) flipped both layers to `routineSlotID` with a dual-read fallback (parent drafts) and a one-shot migration walker (drop drafts), so in-flight drafts from older builds migrate transparently on first cold-resume after the update
- [x] **Exercise.id usage intentionally preserved** where it's the correct identity: `ActiveWorkoutGuard.lockedExerciseIDs` / `lockExercises` / `unlockExercises` (library "exercise is in use" semantics), `fetchExercise(by:)` reads, `currentExerciseID` snapshot field on `WorkoutItem`, `populateSnapshotFields(from:)`, the swap path's `lockExercises([newEx.id])` / `unlockExercises([oldExerciseID])`, and `PlanExercise.id` itself (still equal to `Exercise.id` per slice scope — the slot identity is read explicitly via `exercise.routineSlotID` at every callsite that needs it)
- [x] `rebuildItemsByExerciseID` primary path matches by `WorkoutItem.routineSlotID` (already correct pre-slice); only the cache **write** key changed from `slot.id` to `slot.routineSlotID`. The legacy fallback path (pre-snapshot items missing `routineSlotID`) still finds the slot via `$0.currentExerciseID == ex.id` — for duplicate-Exercise routines with that legacy data shape the linear scan returns whichever slot it finds first, an ambiguity inherent to pre-snapshot data that the primary path resolves whenever `routineSlotID` is populated. Documented inline
- [x] **`RestPlanner.restSecondsAfterSupersetRound(_:)` correctness inherits this fix for free**: its `SupersetRoundParticipant.isComplete` is caller-fed from `isWorkingSetComplete(exercise:setIndex:)`, which now reads from the slot-keyed `loggedByExercise` / `dropsLoggedByExercise`. Duplicate-Exercise-in-a-superset routines that previously fake-completed the round when one slot was logged will now correctly stay mid-round-suppressed until every slot completes — pending the verification block below
- [x] Build green; full XCTest suite **90/90 pass in ~1.21s**. Manual verification for two slots referencing the same Exercise across **separate non-superset blocks**: typing in slot A's reps/weight/duration no longer leaks into slot B; logging set 0 in slot A no longer flips slot B's checkmark; undo cascades only the targeted slot. Superset variant deferred (see Pending below)

**Completed (5.2 — active-workout identity Slice B: persisted draft-store keys → `routineSlotID`):**

- [x] **`ParentDraftStore` callers migrated**: every `parentDraftStore?.persist/clear` callsite in `ActiveWorkoutView` now passes `exercise.routineSlotID` — `inputBindings` (reps + weight), `durationBinding`, `buildSetRow` time-based onLog clear, reps/weight onLog clear, and the three persist calls inside `undoSetLog`'s snapshot-on-undo path. The single `parentDraftStore?.load` callsite in `rehydrateFromWorkoutIfPresent` performs a **dual-read**: `load(slotID: slotID) ?? load(slotID: exerciseID)`, so in-flight drafts written under pre-Slice-B `Exercise.id` keys remain readable until they're either re-typed (new write uses `routineSlotID`) or wiped at `clearAll` on workout finish/dismiss. On-log clear paths additionally issue a defensive `clear(slotID: exerciseID)` so any pre-migration on-disk leftover for that slot disappears as soon as the user logs the set. **`ParentDraftStore` store API is unchanged** — it stays identity-agnostic; the fix is purely on the caller side
- [x] **`DropWeightDraftStore` key migration**: drop-key string construction in `rehydrateFromWorkoutIfPresent`, `undoSetLog`, and `buildDropSection` now produces `"<routineSlotID>_<parentSetIndex>_<subIndex>"`. The in-memory string-keyed dicts `dropWeightInput` / `dropRepsInput` / `dropWeightUserEdited` therefore see only new-format keys post-Slice-B. Defensive legacy clears added at three sites (`undoSetLog` cascade per cascaded sub, `buildDropSection.onLog`, `buildDropSection.onResetWeight`) plus an orphan sweep inside `undoSetLog` that walks `store.loadAll()` once with a `"<exerciseID>_<setIndex>_"` prefix and clears any matching legacy on-disk entries
- [x] **`DropWeightDraftStore` gained two pure additions**: `func setAll(_ dict: [String: String])` for atomic dict replacement (single `UserDefaults` write, calls `removeObject` on empty input), and `static func migrateLegacyKeys(in:legacyExerciseToSlots:knownSlots:)` — a pure key-rewrite helper covered by 9 focused unit tests. Migration rules: (1) already-migrated keys (leading UUID ∈ `knownSlots`) pass through untouched (idempotent); (2) legacy keys (leading UUID ∈ `legacyExerciseToSlots`) are rewritten, **fanned out** to every matching slot for duplicate-Exercise routines; (3) **new-key-wins** if a new-format key for the same slot already exists; (4) stale legacy (UUID not in the plan, e.g. retired by a swap) preserved unchanged; (5) malformed keys preserved unchanged
- [x] **`restoreDropWeightDrafts` runs migration before bridging into `@State`**: builds `legacyExerciseToSlots` (using BOTH `currentExerciseID` and `originalExerciseID` so mid-session-swap sessions migrate cleanly) and `knownSlots: Set<UUID>` from `plan.blocks`, calls `migrateLegacyKeys`, atomically writes the rewritten dict back via `setAll(_:)` (only when it actually differs to avoid spurious churn), then iterates the new-format-only dict into `dropWeightInput` with the unchanged "skip if `dropWeightUserEdited.contains(key)`" guard so logged-SetLog values keep their priority over drafts. The "Must run AFTER logged drops are restored" ordering is preserved — `rehydrateFromWorkoutIfPresent` calls `restoreDropWeightDrafts` after seeding logged drops into `dropWeightUserEdited`
- [x] **Storage format pins still hold** — `parentDrafts_<workoutUUID>` / `<UUID>_<setIndex>_<field>` for `ParentDraftStore` and `dropWeightDrafts_<workoutUUID>` / caller-formed string for `DropWeightDraftStore` are unchanged. The leading UUID's *meaning* flipped from `Exercise.id` to `routineSlotID`, but the templates themselves are identity-agnostic. Existing `testStorageKeyFormatIsStable` tests in both store test files pass unchanged
- [x] `LogTests/DropWeightDraftStoreTests.swift` — **11 new cases, all green** (file now at 21 tests total): `testMigrateLegacyKeysRewritesLegacyExerciseIDToRoutineSlotID`, `testMigrateLegacyKeysFansOutToBothSlotsForDuplicateExercise`, `testMigrateLegacyKeysPrefersExistingNewKeyOverLegacyValue`, `testMigrateLegacyKeysLeavesAlreadyMigratedKeysUnchanged`, `testMigrateLegacyKeysPreservesStaleLegacyKey`, `testMigrateLegacyKeysPreservesMalformedKey`, `testMigrateLegacyKeysEmptyInputReturnsEmpty`, `testMigrateLegacyKeysDoesNotMutateInputDictionary`, `testMigrateLegacyKeysPreservesUnrelatedSuffixShapes`, `testSetAllReplacesEntireDict`, `testSetAllWithEmptyDictRemovesTopLevelKey`. `ParentDraftStoreTests` not updated — the store remained identity-agnostic, no API surface change, existing 13 tests still cover behavior
- [x] **Self-converging without a version stamp**: post-Slice-B writes always use the new format; the migration walker is idempotent on already-migrated dicts; the orphan sweep + workout-end `clearAll` retire any stragglers naturally. No `migrationV1: true` sentinel or feature flag needed
- [x] Build green; full XCTest suite **101/101 pass in ~0.58s** (12 BackfillServiceTests + 21 DropWeightDraftStoreTests + 1 ModelTests + 13 ParentDraftStoreTests + 5 PreferredVariantIDTests + 29 RestPlannerTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). Logged-`SetLog` priority over drafts preserved; auto-suggested drop weights still not persisted as drafts; dropset rest timing, dropset completion gating, superset rest timing/gating, `RestPlanner` behavior, models, history, routines/exercises, notes, warmups, RIR/RPE/tempo — all untouched. **Duplicate-Exercise-across-slots draft collision is now resolved across cold resume** — the in-memory fix from Slice A and the persistence fix from Slice B compose into end-to-end per-slot draft isolation

**Completed (5.2 — Superset Details exercise management + locked-routine scroll fix):**

- [x] **Add Exercise to an existing superset**: new `Button("Add Exercise") { showAddExerciseSheet = true }` row at the top of the "Exercises (drag to reorder)" Section in `SupersetDetailNoRest`. Tapping presents `ExercisePickerSingle(exercises: allExercises)` — the same picker the routine-level Add Exercise button uses. On pick, `addExercise(_:)` creates `RoutineExercise(exercise: ex, order: nextOrder, setTemplates: [])` (slot-unique `slotID` defaults to a fresh `UUID()` per the model), inserts into the context, attaches a fresh `SlotPrescription` via `makeDefaultPrescription`, and coerces `p.sets = currentSetsValue > 0 ? currentSetsValue : AppSettings.defaultSets` so the new slot inherits the block's shared "Sets per exercise" value immediately. Appends to `block.exercises`, saves. Section gains a footer documenting both invariants (min 2, duplicates allowed)
- [x] **Remove Exercise from a superset**: `.onDelete(perform: removeExercise)` on the reorderable ForEach → minimum-2-exercises guard (`if remaining < 2 { showMinExerciseAlert = true; return }`), then explicit `block.exercises = survivors` **before** `ctx.delete(re)` for each removed slot, then `re.order = i` renormalization on survivors, then save. Edit-mode `-` button and swipe-to-delete both route through the same handler
- [x] **Cascade-deletion regression fixed**: the `block.exercises = survivors` write is **load-bearing**. Without it, `ctx.delete(re)` alone leaves a tombstone reference in the parent `@Relationship(deleteRule: .cascade) var exercises: [RoutineExercise]` array. `normalizeRoutineModel`'s `b.exercises.contains(where: { re.safeExercise(in: ctx) == nil })` then matches the tombstone on the next routine-view `.onAppear` and cascades `ctx.delete(b)`, deleting the entire superset block. Detaching the parent reference first keeps `block.exercises` consistent with the persistent store, so the normalizer never sees a stale entry
- [x] **Duplicate `Exercise` inside a superset allowed by design**: `ExercisePickerSingle` doesn't deduplicate against the current block's contents, so the same `Exercise` can occupy two slots in one superset. Each slot has a unique `RoutineExercise.slotID`. The runtime per-slot identity (Slice A in-memory state, Slice B persisted drafts, the superset manual-switch round-gating fix) handles duplicates correctly end-to-end at the data layer; user-facing verification is tracked separately below
- [x] **Shared "Sets per exercise" stays consistent after Add**: new slot's `SlotPrescription.sets` is coerced to `currentSetsValue` at Add time. The existing `applySetsToAllExercises(_:)` (`L1100`) iterates `block.exercises` on every Stepper change, automatically picking up the new slot for subsequent edits. No additional plumbing needed
- [x] **Reorder unchanged**: existing `.onMove(perform: moveExercises)` on the same ForEach continues to rewrite `order` 0…N-1 after a drag — interacts cleanly with Add (new slot inserted at bottom, then user can drag) and with Remove (survivors are renormalized in `removeExercise` so the move handler sees contiguous orders)
- [x] **Routine-lock gating** (`isRoutineLocked: Bool` plumbed from `RoutinesView.blockRowView(for:)` as `activeGuard.isRoutineLocked(routine.id)` into both `SupersetDetailNoRest` and `RoutineBlockDetailView`): every mutation surface is individually `.disabled(isRoutineLocked)` — the 3 timing Steppers (Sets per exercise / Rest after round / Rest before next block), the `Add Exercise` Button, the `EditButton` in the toolbar (toolbar items aren't inside the List, gated separately), the ForEach `.moveDisabled(isRoutineLocked)` / `.deleteDisabled(isRoutineLocked)`, and the per-exercise `SlotPrescriptionSection` (new `isLocked: Bool = false` parameter; the Section-level `.disabled(isLocked)` cascades to `PrescriptionFields`, the Warmup / Techniques `NavigationLink`s, and the slot-notes `TextField`). `RoutineBlockDetailView` gained the same `isRoutineLocked: Bool = false` param and plumbs `isLocked: isRoutineLocked` into its single `SlotPrescriptionSection`
- [x] **Locked routines remain scrollable** (scroll regression fixed): the body-level `.disabled(isRoutineLocked)` initially applied to the `List { … }` of both detail views was removed — wrapping the List itself in `.disabled` suppressed the List/ScrollView scroll-pan gesture on iOS, leaving locked routines unreadable. Locking is now scoped exclusively to individual mutation controls (per-Stepper / per-Button / per-Section), so taps on mutation widgets are blocked but the parent List's scroll behavior is untouched. The "In use" chip on the block row continues to communicate the lock state. Defensive `guard !isRoutineLocked else { return }` retained inside `removeExercise(at:)` even though the UI gate already covers it. Active-workout session-plan editing in the in-workout "Edit Plan" sheet is unaffected — it operates on local `SessionPlan` state, not the routine-editor surface, and was never coupled to the routine lock
- [x] Build green; full XCTest suite **101/101 pass in ~0.60s** (unchanged composition: 12 BackfillServiceTests + 21 DropWeightDraftStoreTests + 1 ModelTests + 13 ParentDraftStoreTests + 5 PreferredVariantIDTests + 29 RestPlannerTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). No model changes, no test edits required for this routine-editor UI slice (per-slot runtime correctness was already covered by Phase 5.2's prior test surface). Manual verification: add to an existing superset; remove one of three exercises (the block survives); two-exercise removal is blocked with the min-2 alert; reorder after Add works; locked routines scroll freely while every mutation control is non-interactive

**Pending (5.2 — duplicate-`Exercise` inside superset integration verification):**

- [ ] **UI blocker resolved** (the prior "no way to add an exercise to an existing superset" gate is gone, shipped in the Completed block above), but the integration test itself hasn't been confirmed end-to-end on a routine that actually has the same `Exercise` in two slots of one superset. Runtime correctness is already pinned at every layer: Slice A's in-memory dicts are routineSlotID-keyed; Slice B's persisted drafts are routineSlotID-keyed with a one-shot legacy migration; the superset manual-switch gate uses `isWorkingSetComplete` per-slot; `RestPlanner.restSecondsAfterSupersetRound`'s `SupersetRoundParticipant.isComplete` is fed from the same per-slot state. The remaining work is purely a manual smoke test — **construct the routine via the now-shipped Add Exercise flow** (pick the same `Exercise` twice into one superset), start a workout, and verify: (a) logging slot A's set 1 leaves slot B's set 1 unlogged and B's input fields untouched; (b) round rest does NOT fire until both slots' set 1 are logged; (c) typing drafts in slot A's drop weight (if a dropset technique is attached) doesn't echo into slot B, and force-quit + cold-resume restores per-slot; (d) A's set 2 stays gated until B's set 1 is logged. **Close this Pending item by running the test and recording the result** — no further code changes are anticipated unless the manual sweep surfaces something new

**Completed (5.2 / 6.A — notes apply-back vestige removed; duplicate-`Exercise` ambiguity resolved by product semantics):**

- [x] Deleted the entire stale `Exercise.notes` apply-back pipeline from `ActiveWorkoutView` / `ActiveWorkoutGuard`: `ActiveWorkoutGuard.notesCache` (declaration + `endSession` wipe), the unused `notesBinding(for: PlanExercise) -> Binding<String>`, `persistExerciseNotesOnlyForCurrentExercises()`, `hasNotesPending` computed, and the `notesCache` seeding in `swapExercise`. Audit confirmed `notesBinding` had **no callers** anywhere in the project — it was a leftover from the pre-Phase-6.A inline-`TextField` design that the canonical 6.A redesign had already replaced with the read-only display + focused `ExerciseNotesEditSheet`
- [x] Deleted the `"Finish + Update exercise notes"` button from the finish confirmation dialog. `finishWorkout(applySwaps:applyNotes:applySlotPrescription:)` lost its `applyNotes: Bool` parameter (and the `if applyNotes { persistExerciseNotesOnlyForCurrentExercises() }` branch). The four `finishWorkout` callsites (no-apply path, swaps-only, slot-prescription-only, apply-all) were updated in lockstep. `pendingCount` and `"Finish + Apply all"` now only consider `hasSwapsPending` and `hasSessionPlanPending`; an inline comment documents why `Exercise.notes` is intentionally absent from the apply-all list. The dialog-trigger guard at finish-tap (`if hasSwapsPending || hasNotesPending || hasSessionPlanPending`) became `if hasSwapsPending || hasSessionPlanPending` — sessions where the user only edited `Exercise.notes` (via the sheet) now skip the dialog entirely and dismiss directly, because the notes change is already persisted
- [x] **Final note semantics aligned with the Phase 6.A canonical reference**: (a) Session Notes = `Workout.notes` — inline-editable in the active workout via `workoutNotesBinding`, shown in `WorkoutDetailView`; (b) Exercise Notes = global `Exercise.notes` — read-only display in the active-workout list (sourced live via `fetchExercise(by: currentExerciseID)?.notes`), edited write-through only via `ExerciseNotesEditSheet` (Done saves immediately, Cancel reverts to the `onAppear`-captured value) and the standalone Exercise page; (c) Slot Guidance / Plan Notes = `RoutineExercise.templateNotes` / `SessionPlan.slotNotes` — edited in the routine editor and the active-workout "Edit Plan" sheet, applied to the routine via the `"Update slot prescription"` finish button + `applySessionPlansToSlotPrescriptions()`, snapshotted into `WorkoutItem.templateNotesSnapshot` for history
- [x] **Duplicate-`Exercise` notes ambiguity resolved by product semantics, not by code disambiguation**: since `Exercise.notes` is global by definition, two slots that reference the same Exercise share the same notes — editing in either slot's `ExerciseNotesEditSheet` writes through to the single `Exercise.notes` and both slots' read-only displays refresh in lockstep. Per-slot coaching cues belong in Slot Guidance (`RoutineExercise.templateNotes`), which is already per-slot and unaffected. The pre-cleanup last-slot-wins collision (cached value overwriting a fresh sheet edit on `"Finish + Update exercise notes"`) is no longer reachable because the path no longer exists
- [x] **Latent bug fixed as a side effect**: pre-cleanup, swapping slot A to a new exercise, then editing its notes via `ExerciseNotesEditSheet`, then tapping `"Finish + Update exercise notes"` would **revert** the sheet edit by writing the swap-time cached value back over the fresh edit. With the entire apply-back path deleted, this revert is structurally impossible — the sheet's write-through is now the only `Exercise.notes` mutator in the active-workout flow
- [x] Build green; full XCTest suite **101/101 pass in ~0.62s** (no regressions; `notesCache` was never directly under test, so no test edits were required). Manual test passed: read-only display still renders; sheet edits persist on Done and revert on Cancel; finish dialog surfaces only when swaps / slot-prescription edits are pending; swap path no longer touches any notes cache. No model changes; no `Workout.notes` / Session Notes / Slot Guidance / dropset / superset / rest / draft / history / RIR / RPE / tempo behavior changed

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

**Completed (6.B Slice C.1 — relationship-driven display labels, flat layout):**

- [x] **Design decision (C.1 over C.2):** kept `HistoryView` as a flat reverse-chronological list and routed labels through live relationship data. Per-variant `Section` grouping with an "Other / Unlinked" bucket (**C.2**) is intentionally deferred to a separate slice — see the pending C.2 block below
- [x] `RoutineLabelResolver` added in `HistoryView.swift` (file-private) — single shared helper consumed by both the History row (`recentWorkoutsSection`) and `WorkoutDetailView`'s overview. Resolution priority: (1) `workout.routineVariantID` → live `RoutineVariant` + its owning `Routine` (formatted as `routine.name` when the variant is case-insensitively named "Default", else `"\(routine.name) — \(variant.name)"`); (2) `workout.routineID` → live `Routine.name`; (3) frozen `workout.routineName` snapshot (non-empty); (4) `nil` → caller omits the routine line, preserving the pre-Slice-C visual outcome for unattributable workouts. Pure read — no mutation, no writes to `routineName` / `routineID` / `routineVariantID`
- [x] Performance: resolver built **once per view-body evaluation** via a `let` at the top of `recentWorkoutsSection` (and `WorkoutDetailView.body`) and captured by the row closures, so per-row lookups are O(1) dict reads — no `ctx.fetch` in the rendering path, no per-row recomputation. Internal caches: `routineByID`, `variantByID`, `routineByVariantID` (built by walking each `Routine.variants` once → O(R + V_total)). Reading routine/variant properties inside `init` ties the surrounding `body` to those models, so a rename will re-render automatically with the new label
- [x] `@Query private var routines: [Routine]` added to both `HistoryView` and `WorkoutDetailView`. `WorkoutDetailView` is in the same file so the resolver type is in scope without a public API
- [x] History layout intentionally still flat. No `Section` grouping by routine/variant. No "Other / Unlinked" bucket. No changes to the calendar or progression sections, the Workout overview's other rows (Date / Status / Duration / Notes), the per-exercise sections, the chart, the picker, or any active-workout / routine-editor / exercise / notes / warmup / dropset / superset / RIR / RPE / tempo code path
- [x] Fallback paths exercised manually on simulator: variant-resolves path renders `"Routine — Variant"` for non-Default variants and `routine.name` alone for Default; nil-variantID workouts (pre-Slice-B legacy and post-Slice-B name-fallback-only rows) flow through the routineID path; rows with no resolvable relationship still render the frozen `routineName` snapshot; rows with no snapshot at all omit the routine line as before. Build passes

**Pending (6.B Slice C — verification gated on rename UI):**

- [ ] Verify renaming a routine or variant updates History/WorkoutDetail labels live without rewriting any persisted field. **Blocked:** the Routines tab does not currently expose a rename action; once routine/variant rename UI lands (or via a manual SwiftData edit harness), exercise: (a) rename a routine while its workouts are visible in History → labels update without a relaunch; (b) rename a non-Default variant → "Routine — Variant" labels update; (c) rename a variant to "Default" → label collapses to routine name; (d) rename away from "Default" → label expands back to "Routine — Variant"

**Pending (6.B Slice C.2 — optional sectioned grouping):**

- [ ] **Design decision before implementing:** decide whether to switch `HistoryView` from a flat list to per-variant `Section` grouping with an "Other / Unlinked" bucket for nil-variantID rows. C.1 (flat with live labels) is shipped; C.2 is a larger UX change and should not be started without explicit confirmation. If pursued, the existing `RoutineLabelResolver` cache strategy is reusable; only the section partitioning logic needs to be added — keep grouping work out of SwiftUI `body` per CLAUDE.md by precomputing partitions on `workouts` / `routines` change

### Phase 7 — Tests + performance pass

**Completed (7.0 — `LogTests` target scaffold):**

- [x] `LogTests` target added in Xcode (modern `PBXFileSystemSynchronizedRootGroup`, so any `.swift` file dropped into `LogTests/` is auto-included — no `project.pbxproj` edits needed for future test files)
- [x] `LogTests/SwiftDataTestHarness.swift` — `@MainActor` `XCTestCase` base class that builds a fresh in-memory `ModelContainer` per test via `ModelConfiguration(isStoredInMemoryOnly: true)`. Schema list **must be kept in sync with `LogApp.swift`** — drift will surface as fetch failures in any test that touches the missing entity
- [x] Auto-generated Swift-Testing template (`LogTests/LogTests.swift`) removed so the target uses **XCTest consistently**. New tests use `import XCTest` + `@testable import Log`
- [x] `LogTests.xctest` wired into the shared `Log.xcscheme` Test action so `cmd-U` and `xcodebuild ... test` discover it
- [x] **Operational note:** `xcodebuild ... -destination 'generic/platform=iOS Simulator' test` is rejected with *"Tests must be run on a concrete device"* — the generic destination is fine for `build` (still used per slice) but `test` requires a concrete destination such as `-destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'`. This is now documented in CLAUDE.md's Build & Test Policy (Slice 7.5)

**Completed (7.1 — first behavior tests, no production extraction required):**

- [x] `LogTests/PreferredVariantIDTests.swift` — 5 tests on `Routine.preferredVariantID` (the shared variant selection rule used by both the start path and `backfillPhase6B`): (1) empty variants → nil; (2) `Default`-named variant wins over a lower-`order` sibling; (3) match is case-insensitive (`default` / `DEFAULT` / `Default` all qualify); (4) lowest `order` wins when no Default; (5) `(order, name)` tiebreak is deterministic (lexicographic name)
- [x] `LogTests/WorkoutModelTests.swift` — 4 smoke tests on the Phase 6.B Slice A additive field `Workout.routineVariantID`: (1) defaults to nil when constructed with no args beyond `items: []`; (2) initializer accepts an explicit UUID; (3) value round-trips through an in-memory `ModelContainer` save/fetch; (4) a nil value persists safely (mirrors a pre-Slice-A legacy row). Doubles as a schema-registration canary
- [x] Pre-existing scaffold test `LogTests/ModelTests.swift` updated for the current schema: `RoutineExercise.exercise` is now `Exercise?`, so the assertion is now `.exercise?.name`. One-character fix; no production behavior change
- [x] Suite green: **10/10 tests pass in ~0.16s** on iOS 26.5 iPhone 17 simulator (full suite includes the pre-existing `ModelTests.testRoutineRoundTrip`). Tests are `@MainActor` and reuse the shared `SwiftDataTestHarness`

**Completed (7.2 — extract & test `RoutineLabelResolver`):**

- [x] Moved `RoutineLabelResolver` from `HistoryView.swift` (was file-private) to `Log/Services/RoutineLabelResolver.swift`. Default `internal` access (not `public`). API preserved verbatim: `init(routines: [Routine])` + `func label(for workout: Workout) -> String?`. Internal lookup tables (`routineByID`, `variantByID`, `routineByVariantID`) and resolution body are byte-for-byte unchanged
- [x] Both consumers — `HistoryView.recentWorkoutsSection` and the nested `WorkoutDetailView` — continue to construct the resolver once per body and reuse it across rows. No call-site signature change. History layout still flat — no grouping introduced
- [x] `LogTests/RoutineLabelResolverTests.swift` — **9 cases, all green**, extending `SwiftDataTestHarness`: (a) Default variant → routine name alone; (b) non-Default variant → `"Routine — Variant"`; (c) case-insensitive Default match (`"dEfAuLt"` collapses); (d) nil `routineVariantID` → routineID path returns `routine.name`; (e) orphaned `routineVariantID` (id not present in any routine's variants) falls through to routineID; (f) both id paths miss → frozen `routineName` snapshot; (g) nil snapshot → resolver returns nil; (h) empty-string snapshot also returns nil (caller omits row); (i) renaming `routine.name` updates the next `label(for:)` result without rebuilding — locks down the Slice C.1 live-label invariant currently blocked at the UI level by the missing rename action
- [x] Build green; full suite **19/19 pass in ~0.23s** (1 ModelTests + 5 PreferredVariantIDTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). No production behavior change beyond the file move

**Completed (7.3 — extract & test launch-time backfill):**

- [x] Extracted Phase 6.B Slice B backfill from `BootstrapRoot.swift` into `Log/Services/BackfillService.swift` as `@MainActor enum BackfillService { static func backfillRoutineVariantIDs(in ctx: ModelContext) }`. Function body is byte-identical to the prior inline implementation (same Swift-side filter rather than `#Predicate`, same `byID` / `byLowercaseName` / `preferredByRoutineID` lookup tables, same deterministic `(order, name)` tie-break for duplicate lowercased routine names, same single-save-when-dirty guard). Kept **non-throwing** to preserve the original `try?`-swallow behavior at launch — making it `throws` would have changed `BootstrapRoot`'s call contract
- [x] `BootstrapRoot.body.task` updated: the call site is now `BackfillService.backfillRoutineVariantIDs(in: ctx)` on a single line, in the same launch-order position (after `backfillPhase1()` + `backfillPhase3_1()`, before `validateActiveSession()`). The surrounding "Phase 6.B Slice B" comment block was preserved. The `// MARK: - Phase 6.B Slice B Backfill` section and its `private func backfillPhase6B()` body (~75 lines) were deleted from `BootstrapRoot.swift`. `backfillPhase1` and `backfillPhase3_1` were intentionally left in `BootstrapRoot` for this slice (no tests required yet)
- [x] `LogTests/BackfillServiceTests.swift` — **12 cases, all green**, extending `SwiftDataTestHarness`: (a) no-op when every workout is already linked; (a′) no-op when the store has zero workouts; (b) `routineID` match fills `routineVariantID`; (c) name fallback fills when `routineID` is nil; (c′) lowercased name fallback (`"LEGS"` matches `"Legs"`); (c″) stale `routineID` that no longer resolves falls through to the name fallback; (d) **never overwrites** a non-nil `routineVariantID` even when the routine resolves to a different variant; (e) unresolved workout stays nil so it remains eligible for a future pass; (e′) no-routines-at-all leaves the candidate nil; (f) idempotency — state after a second `backfillRoutineVariantIDs` call equals state after the first across resolved / unresolved / pre-linked rows; (g) preferred-variant delegation: Default wins over a lower-`order` sibling; (g′) lowest `(order, name)` wins when no Default exists. Replaces / formalizes the manual simulator verification used during Slice B
- [x] Build green; full suite **31/31 pass in ~0.41s** (12 BackfillServiceTests + 1 ModelTests + 5 PreferredVariantIDTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). No production behavior change beyond the file move + call-site swap. No model schema changes; no `Workout.routineVariantID` write changes for new workouts; no `RoutineLabelResolver` / History display / active-workout / routines / exercises / notes / warmups / dropsets / supersets / RIR / RPE / tempo changes

**Completed (7.4 — RestTimer.stableNotificationID tests):**

- [x] `LogTests/RestTimerTests.swift` — **7 pure XCTest cases, all green**, no SwiftData rig: (1) same `workoutID` + `slotID` produces identical IDs (determinism); (2) different `workoutID` produces a different ID; (3) different `slotID` produces a different ID; (4) output is non-empty; (5) format starts with `"rest."` (pins the consumer-visible prefix); (6) output contains both UUID strings (pins the format that `BootstrapRoot.validateActiveSession`'s cleanup path reconstructs); (7) swapping `workoutID` ↔ `slotID` produces a different ID (defensive — guards against a future refactor that drops positional structure)
- [x] No visibility change required: `static func stableNotificationID` lives in `extension RestTimer` with default `internal` access and is reachable via `@testable import Log`. The test class is marked `@MainActor` because `RestTimer` is `@MainActor`-isolated and the static method inherits that isolation — pure additive test-side change, no production edit
- [x] **API gap noted (NOT addressed in this slice):** the original 7.4 plan listed two nil-`slotID` cases. The production signature takes a **non-optional `slotID: UUID`**, so those cases aren't applicable to today's API. Adding `Optional` support would be an API change; out of scope for this pure-test slice. The omission is called out inline in `RestTimerTests.swift`'s file header
- [x] Build green; full suite **38/38 pass in ~0.41s** (12 BackfillServiceTests + 1 ModelTests + 5 PreferredVariantIDTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). No runtime timer behavior changed; no notification-scheduling behavior changed; no active-workout / model / history / routine / exercise / warmup / dropset / superset / RIR / RPE / tempo behavior changed

**Completed (7.4-A — `ParentDraftStore` extraction + tests):**

- [x] Extracted `persistParentDraft` / `loadParentDraft` / `clearParentDraft` / `clearAllParentDrafts` / `parentDraftsUDKey` / `parentDraftSlotKey` / the `ParentDraftField` enum (~7 private members) from `ActiveWorkoutView` into `Log/Services/ParentDraftStore.swift`. New API: `struct ParentDraftStore { enum Field: String; struct Snapshot: Equatable; init(workoutID:defaults:); persist(slotID:setIndex:field:value:); clear(slotID:setIndex:); clearAll(); load(slotID:setIndex:) -> Snapshot? }`. `defaults` defaults to `.standard`; tests inject `UserDefaults(suiteName: UUID().uuidString)`. `Snapshot` is `Equatable` and exposes `isEmpty` for the eventual drop-draft consumer
- [x] **Storage format preserved byte-for-byte** so existing installs with in-flight drafts read unchanged after the update: top-level key `"parentDrafts_<workoutUUID>"`, per-field key `"<slotID>_<setIndex>_<field>"`, dict type `[String: String]` with the same defensive `as?` cast + `?? [:]` default for corrupted state. A dedicated `testStorageKeyFormatIsStable` test pins both literal formats so any drift fails CI with a "add a migration before merging" comment
- [x] `ActiveWorkoutView` rewired to use a single computed property `private var parentDraftStore: ParentDraftStore? { workout.map { ParentDraftStore(workoutID: $0.id) } }` and optional-chained call sites (`parentDraftStore?.persist(...)` / `.clear(...)` / `.clearAll()` / `.load(...)`). 9 call sites updated: 1 rebuild-fallback read (L347), 3 binding-set writes (L435/L451/L495), 2 clear-on-log sites (L601/L662), 1 clearAll on `unlockAndDismiss` (L805), 3 undo-of-logged-parent-set re-persistence writes (L2335/L2338/L2342). Optional-chaining preserves the prior `guard let udKey else { return }` no-op semantics for any call before the workout binds. Leading-dot inference (`.reps` / `.weight` / `.duration`) continues to work because the `field:` parameter is typed `Field`. Net diff inside `ActiveWorkoutView`: `+18 / -64`
- [x] All 5 invariants preserved by call-site equivalence: parent drafts survive cold resume; logged `SetLog` takes priority over draft during rebuild (the existing `if let log = parentLog { ... } else if let draft = parentDraftStore?.load(...)` ordering is untouched); undo of a logged parent set still snapshots `SetLog` values back into the draft; `clearAll` runs on `unlockAndDismiss`; no `dropWeight*` helpers touched (7.4-B scope)
- [x] `LogTests/ParentDraftStoreTests.swift` — **13 cases, all green**, hermetic per-suite via `UserDefaults(suiteName: UUID().uuidString)` in `setUp` + `removePersistentDomain` in `tearDown`: (1) persist → load round trip with all three fields; (2) load returns nil when empty; (3) partial snapshot when only one field exists; (4) clear one slot leaves other slots intact; (5) clear removes all three fields for one slot; (6) clear on empty slot is no-op; (7) clear one set-index leaves other set-index intact for same slot (prefix-bleed defense); (8) clearAll removes all drafts; (9) two workoutIDs isolated in same `UserDefaults`; (10) empty string persists as empty string (NOT collapsed to nil — protects the body-weight undo path that writes `log.weight.map { ... } ?? ""`); (11) overwrite same field keeps latest value; (12) corrupted UserDefaults entry reads as no-draft and does not crash, subsequent writes succeed; (13) storage-key format pin
- [x] Build green; full suite **51/51 pass in ~0.64s** (12 BackfillServiceTests + 1 ModelTests + 13 ParentDraftStoreTests + 5 PreferredVariantIDTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). No drop-weight-draft / workout execution / rest timing / models / history / routines / exercises / notes / warmups / dropsets / supersets / RIR / RPE / tempo changes. Storage-format equivalence is unit-tested but the integration with `rebuild()` and the undo path cannot be proven from XCTest — recommend a manual regression sweep against the simulator before merging (see the 7.4 planning report's §8 checklist)

**Completed (7.4-B — `DropWeightDraftStore` extraction + tests):**

- [x] Extracted 4 storage-only private members (`dropWeightDraftsUDKey`, `persistDropWeightDraft`, `clearDropWeightDraft`, `clearAllDropWeightDrafts`) from `ActiveWorkoutView` into `Log/Services/DropWeightDraftStore.swift`. New API: `struct DropWeightDraftStore { init(workoutID:defaults:); persist(slotKey:value:); clear(slotKey:); clearAll(); loadAll() -> [String: String] }`. `defaults` defaults to `.standard`; tests inject `UserDefaults(suiteName: UUID().uuidString)`. `slotKey` is opaque to the store — the `"<slotID>_<parentSetIndex>_<subIndex>"` format stays owned by the view (same string used by sibling `@State` dictionaries `dropWeightInput` / `dropWeightUserEdited` / `dropRepsInput`)
- [x] **Storage format preserved byte-for-byte**: top-level UserDefaults key `"dropWeightDrafts_<workoutUUID>"`, dict type `[String: String]` with the same defensive `as?` cast + `?? [:]` default, `clear` retains the write-skip optimization for missing keys, `clearAll` is `removeObject(forKey:)`. A `testStorageKeyFormatIsStable` test pins the literal top-level key so any drift fails CI with a "add a migration before merging" comment
- [x] `ActiveWorkoutView` rewired to use a single computed property `private var dropWeightDraftStore: DropWeightDraftStore? { workout.map { DropWeightDraftStore(workoutID: $0.id) } }` and optional-chained call sites. **`restoreDropWeightDrafts` kept in the view per the planning constraint** — its body was rewritten from `guard let dict = UserDefaults.standard.dictionary(...) ...` to `guard let store = dropWeightDraftStore else { return }; for (slotKey, value) in store.loadAll() { ... }`, with the inner loop (the `dropWeightUserEdited.contains` skip + `dropWeightInput[slotKey] = value` + `dropWeightUserEdited.insert(slotKey)`) byte-identical. The "Must run AFTER logged drops are restored" comment at the call site (L383) is untouched, so logged-SetLog priority is preserved
- [x] 6 call sites updated by purpose: dropset weight binding `set` (L2661 persist); dropset `onLog` (L2672 clear); dropset `onResetWeight` / "↩ suggest" (L2743 clear); parent-undo cascade for logged drops (L2363 clear); parent-undo cascade for unlogged orphan drafts (L2373 clear); `unlockAndDismiss` (L803 clearAll). Optional-chaining preserves the prior `guard let udKey else { return }` no-op semantics before the workout binds. Net diff inside `ActiveWorkoutView`: `+15 / -35`
- [x] All 7 invariants preserved by call-site equivalence: manually edited unlogged drop weights persist across cold resume; logged SetLog values take priority (the `dropWeightUserEdited` guard in `restoreDropWeightDrafts` is unchanged); drafts clear on log / on "↩ suggest" / on parent unlog / on workout dismiss; auto-suggested values are not persisted (only the user-typed binding writes; suggested values flow through `currentWeight` without touching the store); draft values are not stored as `SetLog` (the `appendDropLog` write path is untouched). No changes to `ParentDraftStore`, dropset rest timing, dropset completion gating
- [x] `LogTests/DropWeightDraftStoreTests.swift` — **10 cases, all green**, hermetic per-suite via `UserDefaults(suiteName: UUID().uuidString)` in `setUp` + `removePersistentDomain` in `tearDown`: (1) persist → loadAll round trip; (2) loadAll returns empty when nothing persisted; (3) clear one slot leaves others intact; (4) clear on missing slot is no-op (defensive — cascade paths fire indiscriminately); (5) clearAll removes all drafts; (6) two workoutIDs isolated in same `UserDefaults`; (7) overwrite keeps latest; (8) empty string persists distinctly from "absent" (protects the dropset binding's `.filter(\.isNumber)` empty-string path); (9) corrupted UserDefaults entry reads as empty and does not crash, subsequent writes succeed; (10) storage-key format pin
- [x] Build green; full suite **61/61 pass in ~0.48s** (12 BackfillServiceTests + 10 DropWeightDraftStoreTests + 1 ModelTests + 13 ParentDraftStoreTests + 5 PreferredVariantIDTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). No changes to `ParentDraftStore` behavior, dropset rest timing, dropset completion gating, workout execution, models, history, routines/exercises, notes, warmups, supersets, RIR/RPE, or tempo. Storage-format equivalence is unit-tested but the `restoreDropWeightDrafts` @State-bridge interaction with the dropset UI can't be proven from XCTest — recommend a manual regression sweep on the simulator before merging (drafts persist across force-quit; log clears draft; "↩ suggest" clears draft; parent undo cascades through to child drafts; discard workout leaves no leakage)

**Completed (7.4-C.1 — `RestPlanner` simple-branch extraction + tests):**

- [x] New `Log/Services/RestPlanner.swift` introduces `struct RestContext { setIndex; nextTemplateKind: SetKind?; effectiveSetCount; plannedRestBetweenSets: Int?; plannedRestAfterExercise: Int?; templateRestSecondsAfter: Int?; isLastSetOfWorkout: Bool }` and `enum RestPlanner { static func restSecondsAfterLog(_ ctx: RestContext) -> Int? }`. Pure value type + pure function — no SwiftData, no UserDefaults, no timer, no haptics, no UI state. Handles exactly four branches with byte-identical behavior to the inline code it replaces: (a) non-superset between-set rest = `plannedRestBetweenSets ?? template.restSecondsAfter`; (b) non-superset final-set rest = `plannedRestAfterExercise ?? plannedRestBetweenSets ?? template.restSecondsAfter`; (c) skip rest when the next set's template is `.dropset` (only when not on the final set); (d) `isLastSetOfWorkout` ⇒ nil. The trailing `r > 0` filter is preserved at the chain output so `0` / negative / `nil` template rest all collapse to `nil`. Callers (`ActiveWorkoutView.plannedRestBetweenSets(for:)` / `plannedRestAfterExercise(for:)`) already pre-normalize non-positive values to nil, so the planner mirrors the original `?? ?? > 0` chain rather than re-filtering those fields
- [x] `ActiveWorkoutView.restSecondsAfterCurrentLog` rewired: the innermost else-branch (the non-superset path that was neither current-set `.dropset` nor inside a technique-based dropset) now constructs a `RestContext` from `effectiveSetCount(for:resolvedTemplates:)`, `currentBlockIndex == plan.blocks.count - 1`, `currentExerciseIndex == block.exercises.count - 1`, the next template's `kind ?? .working`, the resolved `plannedRestBetweenSets(for:)` / `plannedRestAfterExercise(for:)`, and `t.restSecondsAfter`, then assigns `restSec = RestPlanner.restSecondsAfterLog(...)`. **All other branches remain inline byte-for-byte**: the ~70-line `block.isSuperset` branch (round-completion wait via `isWorkingSetComplete` per exercise, `supersetRoundRestSeconds` base, dropset-in-round after-rest using `priorWorkingRest` + max-combine, normal-round max-combine, next-round-has-dropset skip via `lastRoundIndex`), the current-set `.dropset` final-drop branch (`priorWorkingRest` fallback), the `dropsetTechniqueApplying != nil` technique-suppression branch, the `block.restAfterSeconds` post-processing (non-superset additive `max(0, base + extra)` and superset transition replacement gated on `supersetRoundComplete`), and the shared trailing `isLastBlock && isLastExercise && isLastSet ⇒ nil` guard (which still runs for every path and idempotently re-applies the suppression). **All side effects stay in the view**: `startRestWithPersistence(seconds:slotID:)`, `rest.stop()`, `clearPersistedRestState()`, `showRestOverlay`, focus advance, haptics
- [x] `LogTests/RestPlannerTests.swift` — **12 pure XCTest cases, all green**, no SwiftDataTestHarness, no UserDefaults injection, no MainActor isolation: (1) non-final set uses `plannedRestBetweenSets`; (2) non-final set falls back to `template.restSecondsAfter`; (3) non-final set ignores `plannedRestAfterExercise` (defensive — leak guard); (4) final set prefers `plannedRestAfterExercise`; (5) final set falls back to `plannedRestBetweenSets`; (6) final set falls back to `template.restSecondsAfter`; (7) `nextTemplateKind == .dropset` ⇒ nil; (8) the next-is-dropset check is ignored on the final set (defensive — only fires when there IS a next set); (9) `isLastSetOfWorkout` overrides every planned value; (10) zero template rest normalizes to nil; (11) negative template rest normalizes to nil; (12) all-nil inputs return nil. A private `makeCtx(...)` helper with defaults keeps each test focused on a single input dimension
- [x] Build green; `RestPlannerTests` 12/12 pass in ~0.06s (run via `-only-testing:LogTests/RestPlannerTests`; the full suite was not re-run this slice). No superset / dropset final-drop / technique-dropset / warmup / `block.restAfterSeconds` / persistence / model / history / routine / exercise / notes / RIR / RPE / tempo behavior changes

**Completed (7.4-C.2 — `RestPlanner` superset round-rest extraction + tests):**

- [x] `Log/Services/RestPlanner.swift` extended with two new pure value types and one new pure function: `struct SupersetRoundParticipant { participates: Bool; isComplete: Bool; plannedRestBetweenSets: Int?; currentTemplateKind: SetKind; currentTemplateRestSecondsAfter: Int?; nextTemplateKind: SetKind?; priorWorkingRest: Int? }`, `struct SupersetRoundContext { setIndex; participants: [SupersetRoundParticipant]; lastRoundIndex; supersetRoundRestSeconds: Int?; blockRestAfterSeconds: Int?; isLastBlockOfWorkout: Bool; isLastExerciseOfBlock: Bool }`, and `static func RestPlanner.restSecondsAfterSupersetRound(_:) -> Int?`. No SwiftData / SwiftUI / RestTimer / ModelContext dependencies; only `SetKind` from `Entities.swift`. Each participant carries the exact fields the inline branch read off `PlanExercise` / `PlanSetTemplate` (current/next template kind, current template rest, planned rest, nearest prior-working-set rest via the same back-scan the view's `priorWorkingRest` performs), so the planner does not repeat the resolution chain and stays independent of view-side types
- [x] Byte-identical behavior to the inline `block.isSuperset` branch + its post-processing: (1) mid-round suppression returns `nil` until every participating exercise's `isComplete` is true; (2) base round rest from `supersetRoundRestSeconds > 0`; (3) after-dropset fallback uses max(`plannedRestBetweenSets ?? priorWorkingRest`) across participants when ANY participant has `currentTemplateKind == .dropset`; (4) normal-round fallback uses max(`plannedRestBetweenSets ?? currentTemplateRestSecondsAfter`) across participants; (5) next-round-template-dropset skip returns `nil` when `setIndex < lastRoundIndex` AND no round-level rest is configured AND any participant's `nextTemplateKind == .dropset`; (6) final-round transition replacement fires when `setIndex == lastRoundIndex && isLastExerciseOfBlock && blockRestAfterSeconds != 0` and **replaces** (not adds to) round rest via `max(0, extra)` — preserving the inline gate that lets `0` fall through and the inline clamp that turns negative `extra` into `0` rest; (7) last-set-of-workout suppression fires when `isLastRound && isLastBlockOfWorkout && isLastExerciseOfBlock`. Dropset-aware completion is delegated to the caller via `isComplete` so the planner stays pure
- [x] `ActiveWorkoutView.restSecondsAfterCurrentLog` rewired: the inline `if block.isSuperset { ... }` branch (~67 lines) becomes a `block.exercises.map { ex in SupersetRoundParticipant(...) }` build followed by `return RestPlanner.restSecondsAfterSupersetRound(...)`. The participant build reads `effectiveSetCount(for:resolvedTemplates:)`, `isWorkingSetComplete(exercise:setIndex:)` (for `isComplete`), `plannedRestBetweenSets(for:)`, `ex.templates[safe: idx]?.kind ?? .working` (current), `ex.templates[safe: idx]?.restSecondsAfter` (raw, may be 0/negative/nil), the next-template kind via the same `?? .working` rule clamped to `idx + 1 < sc`, and `priorWorkingRest(in: ex.templates, upTo: idx)`. The local `priorWorkingRest(...)` helper, `lastRoundIndex(in:)`, `isWorkingSetComplete(...)`, `effectiveSetCount(...)`, `supersetRoundComplete(...)`, focus advance (`advanceForSupersetAfterLog`), and all side effects (`startRestWithPersistence(seconds:slotID:)`, `rest.stop()`, `clearPersistedRestState()`, `showRestOverlay`, haptics) stay in the view. The post-processing block was simplified: the now-dead `block.isSuperset ? ... : ...` branches were removed since the superset path early-returns above; the non-superset additive `max(0, base + extra)` / `max(0, extra)` behavior is untouched
- [x] `LogTests/RestPlannerTests.swift` — **17 new pure XCTest cases**, all green, on top of the 12 from 7.4-C.1 (total 29 in the file): mid-round suppression (3 — incomplete round, dropset drops pending via `isComplete`, non-participating exercises skipped); base round rest + fallback chain (4 — round-rest wins, max planned, max template, all-nil); after-dropset round (2 — `plannedRestBetweenSets ?? priorWorkingRest`, `currentTemplateRestSecondsAfter` ignored on the after-dropset branch); next-round template-dropset skip (3 — fires on non-final normal round, ignored on final round, ignored when round-rest configured); final-round transition replacement (4 — fires when configured, falls back to round rest when nil, not on non-final round, not when not last exercise of block); last-set-of-workout suppression (1). A `makeParticipant(...)` / `makeSupersetCtx(...)` helper pair keeps each test focused on a single input dimension
- [x] Build green; full suite **90/90 pass in ~0.48s** (12 BackfillServiceTests + 10 DropWeightDraftStoreTests + 1 ModelTests + 13 ParentDraftStoreTests + 5 PreferredVariantIDTests + 29 RestPlannerTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). No dropset final-drop / technique-dropset / warmup / persistence / model / history / routines/exercises / notes / RIR / RPE / tempo behavior changes. Two unrelated active-workout integrity bugs surfaced during testing and are now tracked separately (see Phase 5.2 Pending blocks below): superset round gating when manually switching exercises, and duplicate-`Exercise`-across-slots active-workout state sharing

**Pending (7.4-C.3 — dropset final-drop rest branch extraction + tests):**

- [ ] Extract the current-set-is-`.dropset` branch (non-superset path) from `ActiveWorkoutView.restSecondsAfterCurrentLog` into `RestPlanner`. Coverage: `plannedRestBetweenSets(for:) ?? priorWorkingRest(in: exercise.templates, upTo: idx)` precedence, the `> 0` filter, and the return-nil case when no positive rest is found. `priorWorkingRest` itself is small (a back-scan loop over `templates` starting from `min(i - 1, templates.count - 1)`) and is a natural co-extraction

**Pending (7.4-C.4 — non-final intra-drop helper, if still desired):**

- [ ] Decide whether the `dropsetTechniqueApplying != nil` technique-suppression branch (returns nil to defer rest to the final sub-log) and the intra-drop rest path that fires after the last drop sub-log belong in `RestPlanner` or stay in the view. If pursued, extract + test. Otherwise close out 7.4-C.4 with a "kept inline, not worth extracting — single call site, no testable behavior beyond the boolean check" note. Lowest-priority sub-slice; gated on 7.4-C.2 / 7.4-C.3 outcome

**Pending (7.4 — `RestTimer.stableNotificationID` nil-slotID coverage, gated on API change):**

- [ ] Extend the production signature to accept `slotID: UUID?` (and decide what an absent slot means for the cancellation key), then add nil-aware tests: (a) two calls with nil `slotID` and the same `workoutID` produce identical IDs; (b) nil `slotID` differs from any non-nil `slotID` for the same `workoutID`. **Gated**: only worth doing if a real consumer actually needs a nil-slot rest notification — today no caller passes nil, so the API change should not be made speculatively

**Completed (7.5 — test target hygiene):**

- [x] `LogTests` `IPHONEOS_DEPLOYMENT_TARGET` lowered from 26.5 → 18.5 in both Debug and Release `XCBuildConfiguration` blocks. Now matches the `Log` app target, so the suite runs on any iOS 18.5+ simulator instead of being constrained to iOS 26.5+ devices
- [x] CLAUDE.md "Build & Test Policy" rewritten with: the concrete-simulator requirement (`test` rejects `'generic/platform=iOS Simulator'` with *"Tests must be run on a concrete device"*); the verified default command `-destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'`; instructions to use `xcrun simctl list devices` to pick a different sim per machine; the app-hosted explanation (with expected `CoreData: error: Failed to stat path .../default.store` noise called out as non-failures, because tests use the in-memory `ModelContainer` via `SwiftDataTestHarness`); and the **schema-mirror invariant** — any new `@Model` registered in `LogApp.swift`'s `.modelContainer(for:)` must also be appended to the `Schema(...)` list in `LogTests/SwiftDataTestHarness.swift`, or every test touching that entity will fail to fetch
- [x] Build and test both re-verified post-change: `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` → `** BUILD SUCCEEDED **`; `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test` → 10/10 pass in ~0.17s

**Pending (7.5 — host-less conversion, NOT currently recommended):**

- [ ] Switch `LogTests` to host-less (clear `TEST_HOST` + `BUNDLE_LOADER`). **Attempted and reverted** during the 7.5 work: removing both keys caused the linker to fail with ~30 *Undefined symbol* errors for every `@testable`-imported Log type (e.g. `Log.Routine.blocks.getter`, `type metadata accessor for Log.Workout`, `protocol conformance descriptor for Log.AppState : SwiftData.PersistentModel in Log`). Root cause is structural: iOS app targets aren't framework targets, so a host-less test bundle has no way to resolve the app's internal Swift symbols at link/load time — `BUNDLE_LOADER = $(TEST_HOST)` is what defers resolution to the app binary at runtime. **Path forward (if pursued):** would require restructuring `Log` so the testable code lives in a separate framework / SwiftPM module that the test target can link directly. Out of scope for now; the only loss from staying app-hosted is the cosmetic CoreData log noise, which CLAUDE.md flags as expected

**Pending (broader Phase 7 — original coverage gaps, unchanged):**

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

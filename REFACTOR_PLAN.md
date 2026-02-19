# REFACTOR_PLAN.md
Gym Log — Architecture v2 Refactor (SwiftUI + SwiftData)

Branches:
- `refactor/architecture-v2` — plan & rules
- `refactor/architecture-v2-exec` — execution (active)

Last updated: 2026-02-18 (KST)

---

## 0) Why This Refactor Exists

The app works, but had production blockers that are being systematically resolved:

- **~~Templates and exercise defaults were silently mutated by session behavior~~** — **RESOLVED.** Silent calls to `persistDefaultsOnlyForCurrentExercises()`, `persistExerciseNotesOnlyForCurrentExercises()`, and `applyExerciseSwapsToRoutine()` have been removed. A finish-time confirmation dialog now gates any propagation.
- **~~Routine slots had no stable UUIDs~~** — **RESOLVED.** `RoutineBlock.slotID` and `RoutineExercise.slotID` added (named `slotID` to avoid shadowing SwiftData's `PersistentIdentifier`-based `.id`).
- **~~Exercise deletion cascaded into workout history~~** — **RESOLVED.** `Exercise.workoutItems` delete rule changed from `.cascade` to `.nullify`.
- **History is still linked by strings**: `Workout.routineName: String?` — to be replaced by RoutineVariant relationship.
- **Persisted workout lifecycle state** (resume after restart) — not yet implemented.

Enforced invariants (in progress):
- Templates = stable blueprint (prescription is now source of intent)
- Sessions = snapshotted, append-only record (Phase 3.3 done — snapshots populated at session start, displayed in workout UI)
- Explicit "apply changes" flow for any propagation back to templates/defaults (implemented)
- History grouped by IDs/relationships, not names (not yet implemented)

---

## 1) Current System Snapshot (as of Phase 3.3)

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
- **TechniquePlan** — `order`, `type` (dropset/partialReps/restPause/amrap/toFailure/cluster/tempoOverride), plus parameterized fields (`repMin?`, `repMax?`, `reps?`, `durationSeconds?`, `restSeconds?`, `rounds?`, `dropPercent?`, `dropCount?`, `partialRangeNote?`, `note?`)

- **SetTemplate** — `order`, `kind` (warmup/working/dropset), `targetReps`, `targetWeight?`, `restSecondsAfter?`, `durationSeconds?`
- **SetLog** — `indexInExercise`, `kind`, `reps`, `weight?`, `restSeconds?`, `durationSeconds?`, `timestamp`
- **WorkoutItem**
  - `exercise: Exercise?` (inverse), `setLogs: [SetLog]` (.cascade)
  - `routineSlotID: UUID?` — copy of `RoutineExercise.slotID` at session start
  - `templateNotesSnapshot: String?` — copy of `RoutineExercise.templateNotes`
  - `plannedPrescriptionSnapshot: PlannedPrescriptionSnapshot?` (.cascade) — immutable prescription snapshot
- **Workout** — `id: UUID`, `date`, `routineName: String?`, `items: [WorkoutItem]` (.cascade), `notes?`

### Exercise-level vs Slot-level responsibility

**Exercise-level** (definition — shared across all routines):
- `name`, `bodyPart`, `isTimeBased`, `isCustom`
- `notes` — global cues / form notes
- `equipmentType` + `setupDefaults` — **future** (not yet added; see Phase 9)

**Slot-level** (per-routine programming intent — varies per routine/variant):
- `sets`, `repMin`/`repMax`, `restSecondsBetweenSets`, `restSecondsAfterExercise`
- `rir`, `rpe`, `tempo`
- `durationMinSeconds`/`durationMaxSeconds` (when `isTimeBased`)
- `warmupScheme`, `techniquePlans`
- `templateNotes` (slot-specific coaching notes)

### Template resolution (current 3-tier, with target 2-tier)

**Current (compatibility):**
1. **`RoutineExercise.setTemplates`** — explicit per-set overrides (compatibility/power-user layer)
2. **`SlotPrescription.generateTemplates()`** — deterministic generation from structured prescription
3. **`Exercise.defaultTemplates`** — exercise-level fallback (**targeted for removal**)

**Target architecture (after Phase 8):**
1. **`RoutineExercise.setTemplates`** — explicit per-set overrides (optional/advanced)
2. **`SlotPrescription.generateTemplates()`** — primary source of programming intent
3. **Unprogrammed slot** — UI shows "Unprogrammed" state with optional quick-fill buttons (e.g., 3x8), NOT exercise default templates

Implemented in:
- `RoutineExercise.resolvedTemplates()` (shared, in Entities.swift)
- `RoutineExercise.resolvedTemplates(in:)` (context-aware, in RoutinesView.swift — adds order normalization)
- `StartWorkoutFromRoutineView.makePlan()` — calls `re.resolvedTemplates()`

### Duration-based design

- **`Exercise.isTimeBased`**: describes the exercise mode/capability (e.g., plank, wall sit).
- **`SlotPrescription.durationMinSeconds` / `durationMaxSeconds`**: slot-level duration targets that vary per routine/variant. These belong on the prescription, not the exercise.
- **`SlotPrescription.usesDuration`**: synced with `Exercise.isTimeBased` by the prescription editor on appear. Controls whether `generateTemplates()` produces duration-based or rep-based templates.

### Compatibility bridge

- `setTemplates` on `RoutineExercise` remain for existing data and power-user overrides.
- When `setTemplates` is non-empty, it wins (tier 1). The routine editor shows an orange hint: "Custom set templates override prescription."
- Prescription-generated templates (tier 2) produce `[SetTemplate]` with a single `targetReps` value (`repMax ?? repMin ?? 8`). Min/max range display uses session snapshots in the workout UI.
- `Exercise.defaultTemplates` (tier 3) remains as a compatibility fallback until Phase 8 removes it.

---

## 2) Target Architecture (Remaining)

### 2.1 Workout lifecycle (single source of truth)
`WorkoutState`:
- idle
- configuringTemplate
- active(sessionID)
- finished(sessionID)

Persist `activeSessionID` so sessions can resume after app restart.

### 2.2 History grouping by IDs (not strings)
Replace:
- `Workout.routineName: String?` as primary link
with:
- `Workout.routineVariantID` (or relationship to RoutineVariant)

### 2.3 Exercise-level equipment & setup (future)
Move equipment/setup from `SlotPrescription` to Exercise-level defaults:
- Add `equipmentType: String?` and `setupDefaults: String?` to Exercise
- Deprecate `SlotPrescription.equipment` and `SlotPrescription.setupNotes`
- Optional: slot-level overrides only if explicitly required (rare case where same exercise uses different equipment in different routines)

### 2.4 Remove Exercise.defaultTemplates
`Exercise.defaultTemplates` is a legacy field. Target state:
- Slot prescription is the single source of programming intent
- Unprogrammed slots show a clear "Unprogrammed" UX with quick-fill options
- No global default templates on Exercise

---

## 3) Production Requirements (Non-negotiable)

### 3.1 Migrations: non-destructive, additive first
- Add new entities/fields as optional with safe defaults.
- Backfill lazily or via migration helpers.
- Keep compatibility for existing data until stable.

### 3.2 Deletion rules: protect history
Exercise → WorkoutItem is now `.nullify` (done).
Remaining goals:
- Deleting a routine/variant should NOT delete past workouts.
- Workouts should keep exercise name snapshots or survive nullified links gracefully.

### 3.3 Tests (3-5)
1) Session creation snapshots prescription from template slot
2) Session edits do not mutate template without explicit apply
3) Finish produces immutable history record
Optional:
4) Resume active session after restart
5) History grouping survives name changes

### 3.4 Performance
Avoid heavy grouping/filtering/sorting in SwiftUI `body`.
Prefer:
- Query-based fetch with sort descriptors
- Precomputed summaries (last performed, session count, duration, etc.)
- Cached groupings keyed by IDs

---

## 4) Tight Execution Checklist

### Completed Phases

#### Phase 0 — Baseline & guardrails
- [x] Create `CLAUDE.md` (rules/invariants)
- [x] Create `REFACTOR_PLAN.md`
- [x] Commit as first commit on `refactor/architecture-v2`
- [x] Confirm app builds and runs

#### Phase 1.1 — Identity & variant skeleton (additive)
- [x] Add `RoutineVariant` model (`id: UUID`, `name`, `order`, `blocks`)
- [x] Add `slotID: UUID` to `RoutineBlock` and `RoutineExercise` (named `slotID`, NOT `id`, to avoid shadowing SwiftData identity)
- [x] Backfill: deduplicate `slotID`s, create "Default" variant for existing routines (`BootstrapRoot.backfillPhase1()`)
- [x] Register `RoutineVariant` in model container (`LogApp.swift`)
- [x] UI unchanged; existing routines display correctly

#### Phase 1.2 — Data integrity hardening
- [x] Change `Exercise.workoutItems` delete rule from `.cascade` to `.nullify`
- [x] Verified: deleting an exercise no longer destroys workout history

#### Phase 2.1 — Remove silent mutations
- [x] Commented out `persistDefaultsOnlyForCurrentExercises()` in `ActiveWorkoutView.next()` finish path
- [x] Commented out `persistExerciseNotesOnlyForCurrentExercises()` in finish path
- [x] Commented out `applyExerciseSwapsToRoutine()` in finish path
- [x] Verified: completing a workout does not silently mutate Exercise or Routine

#### Phase 2.2 — Explicit apply flow
- [x] Added `hasSwapsPending` / `hasNotesPending` detection on workout finish
- [x] Added `.confirmationDialog` with 4 options: this workout only / update routine swaps / update global notes / apply both
- [x] `finishWorkout(applySwaps:applyNotes:)` centralized finish helper

#### Phase 3.1 — Prescription models (additive)
- [x] Added `SlotPrescription` model (core + autoregulation + duration + context fields)
- [x] Added `WarmupScheme` + `WarmupStep` models (reusable, `.nullify` delete rule)
- [x] Added `TechniquePlan` model (parameterized, `.cascade` owned by prescription)
- [x] Added `WarmupStepKind` and `TechniqueType` enums
- [x] Added `templateNotes: String?` and `prescription: SlotPrescription?` (.cascade) to `RoutineExercise`
- [x] Backfill: `BootstrapRoot.backfillPhase3_1()` ensures every `RoutineExercise` has a `SlotPrescription`
- [x] Registered all new models in model container

#### Phase 3.2a — Prescription-driven template generation (model only)
- [x] Added `SlotPrescription.hasContent` computed property
- [x] Added `SlotPrescription.generateTemplates() -> [SetTemplate]` (deterministic; does not insert into context)
- [x] Added `RoutineExercise.resolvedTemplates() -> [SetTemplate]` (shared 3-tier resolver in Entities.swift)

#### Phase 3.2b — Workout plan uses prescription resolver
- [x] `StartWorkoutFromRoutineView.makePlan()` now calls `re.resolvedTemplates()` (shared helper)
- [x] Removed local `resolvedTemplates(for:)` and `normalizeTemplateOrder()` from `StartWorkoutFromRoutineView`

#### Phase 3.2c — Routine editor writes prescription + slot notes
- [x] Added `SlotPrescriptionSection` view (ensures prescription exists on appear, syncs `usesDuration`)
- [x] Added `PrescriptionFields` view (sets, rep range or duration range, rest, RIR, tempo)
- [x] Added slot notes field bound to `re.templateNotes`
- [x] Wired into both `RoutineBlockDetailView` and `SupersetDetailNoRest`
- [x] Shows precedence hint when custom `setTemplates` exist
- [x] Updated `resolvedTemplates(in:)` to 3-tier (matching shared helper)

#### Phase 3.3a — Session snapshot fields (additive)
- [x] Added `PlannedPrescriptionSnapshot` @Model (mirrors SlotPrescription display fields)
- [x] Added `PlannedPrescriptionSnapshot.init(from: SlotPrescription)` convenience init
- [x] Added `routineSlotID: UUID?`, `templateNotesSnapshot: String?`, `plannedPrescriptionSnapshot: PlannedPrescriptionSnapshot?` (.cascade) to `WorkoutItem`
- [x] Registered `PlannedPrescriptionSnapshot` in model container
- [x] Added to UI test reset; no backfill needed (old items get nil, UI falls back)

#### Phase 3.3b — Populate snapshots at workout start
- [x] Added `PrescriptionSnapshotPayload` value struct to carry snapshot data in plan
- [x] Extended `PlanExercise` with `routineSlotID`, `templateNotesSnapshot`, `prescriptionSnapshot`
- [x] `makePlan()` populates snapshot fields from `re.slotID`, `re.templateNotes`, `re.prescription`
- [x] Added `populateSnapshotFields(on:from:)` helper in `ActiveWorkoutView`
- [x] All 3 `WorkoutItem` creation sites (appendSetLog, appendTimeSetLog, swapExercise) populate snapshots

#### Phase 3.3c — Workout UI displays planned prescription
- [x] Added compact "Planned" section in `ActiveWorkoutView` between Actions and Sets
- [x] Displays rep range, duration range, sets, rest, tempo, RIR, RPE, slot notes from snapshot
- [x] Reads from `PlanExercise.prescriptionSnapshot` (snapshot data, not live template)
- [x] Section hidden when no snapshot data exists (graceful fallback for old workouts)

---

### Remaining Phases

#### Phase 3.5 — Warmup scheme + technique plan editor UI
Template-level editing for advanced prescription elements.
- [ ] Warmup scheme picker/editor in routine slot detail (select existing or create new)
- [ ] WarmupStep list editor (order, kind, reps, percent, rest, note)
- [ ] TechniquePlan list editor in routine slot detail (add/remove/reorder techniques)
- [ ] Technique type picker with parameterized fields per type
- [ ] Modifier scope field (if needed for technique application rules)
- [ ] Prescription section reflects warmup/technique counts as summary badges

#### Phase 3.6 — Technique execution UX
How techniques affect set rendering and logging during a workout.
- [ ] Define how each `TechniqueType` modifies set display (e.g., dropset adds sub-sets, rest-pause shows rest intervals)
- [ ] Optional: generate technique-derived set structures from `TechniquePlan` into the set list
- [ ] Workout UI renders technique indicators on affected sets
- [ ] SetLog captures technique metadata if needed (or inferred from plan)
- [ ] Verify: technique plans do not silently mutate the underlying prescription

#### Phase 4 — WorkoutState + persisted resume
- [ ] Implement `WorkoutState` enum (idle / configuringTemplate / active(sessionID) / finished(sessionID))
- [ ] Persist `activeSessionID` (UserDefaults or lightweight model)
- [ ] On app launch: if activeSessionID exists and session exists → resume; else → reset to idle
- [ ] Prevent duplicate sessions on relaunch
- [ ] Handle edge case: session data deleted externally while activeSessionID persists

#### Phase 5 — History refactor from strings to relationships
- [ ] Add `routineVariantID: UUID?` (or relationship) on `Workout`
- [ ] New sessions always populate `routineVariantID`
- [ ] Backfill existing workouts: if `routineName` matches an existing Routine → link to its Default variant
- [ ] Keep `routineName` for display fallback (read-only compatibility)
- [ ] Update `HistoryView` grouping to use relationship/ID, falling back to `routineName` for unlinked records
- [ ] Verify: renaming a routine or variant does not break history grouping

#### Phase 6 — Tests + performance pass
- [ ] Test: session creation snapshots prescription from template slot + stores routineSlotID
- [ ] Test: session edits do not mutate template unless explicit apply action is invoked
- [ ] Test: finishing a workout produces immutable history and clears active state
- [ ] Test (optional): resume active session after app restart
- [ ] Test (optional): history grouping by RoutineVariant survives name changes
- [ ] Performance: ensure history grouping is not done expensively in SwiftUI `body`
- [ ] Performance: add lightweight summary fields or caching if needed
- [ ] Performance: audit `resolvedTemplates(in:)` — avoid redundant fetches in list views

#### Phase 7 — Deprecation cleanup
- [ ] Deprecate `Workout.routineName` as primary grouping link (keep as display fallback)
- [ ] Evaluate deprecating `RoutineExercise.setTemplates` once prescription adoption is stable
- [ ] Remove commented-out silent mutation calls from `ActiveWorkoutView`
- [ ] Consider migration tool for existing device data cleanup
- [ ] Keep fallback read-only until migration is proven stable across updates

#### Phase 8 — Remove Exercise.defaultTemplates
Slot prescription becomes the single source of programming intent. `Exercise.defaultTemplates` is removed.
- [ ] Stop exposing `defaultTemplates` editing UI in exercise detail screens
- [ ] Update `resolvedTemplates()` / `resolvedTemplates(in:)` to remove tier 3 (exercise defaults fallback)
- [ ] Replace tier 3 with "unprogrammed slot" logic: return empty array or a sentinel indicating no programming
- [ ] Add "Unprogrammed" UX in routine editor for slots without prescription content (clear visual state)
- [ ] Add quick-fill buttons for unprogrammed slots (e.g., "3×8", "3×10", "5×5") that write directly to `SlotPrescription`
- [ ] Ensure all existing routines/variants have prescriptions populated (migration pass or user-facing prompt)
- [ ] Remove `Exercise.defaultTemplates` relationship and `SetTemplate` dependence on Exercise
- [ ] Handle migration: lightweight migration drops the field; backfill ensures no data loss
- [ ] Update `SupersetPicker` set-count validation to use prescription instead of `defaultTemplates`

#### Phase 9 — Equipment & setup migration + Exercise UI polish
Move equipment/setup to Exercise-level and fill UI gaps.
- [ ] Add `equipmentType: String?` and `setupDefaults: String?` to Exercise model
- [ ] Migrate existing `SlotPrescription.equipment` / `setupNotes` values to Exercise fields (one-time backfill)
- [ ] Deprecate and remove `equipment` / `setupNotes` from `SlotPrescription` (or keep as optional slot-level override behind explicit "Override equipment" toggle)
- [ ] Add equipment and setup display/editing in Exercise detail UI
- [ ] Display `bodyPart` / muscle group in Exercise detail screens (currently exists on model but not shown in detail UI)
- [ ] Optional: slot-level equipment override field (only if a clear use case emerges, e.g., same exercise on cable vs dumbbell)

**Acceptance criteria (Phase 9):**
- [ ] Exercise detail screen shows `bodyPart` / muscle group (read + edit)
- [ ] Equipment and setup are edited on Exercise (not SlotPrescription) after migration completes
- [ ] `SlotPrescription.equipment` / `setupNotes` are either removed entirely or demoted to "override only" behind a clear UI affordance (e.g., "Override equipment for this slot" toggle — collapsed by default)
- [ ] Migration backfill is idempotent and non-destructive (existing slot values copied to Exercise; slot fields cleared only after Exercise fields are confirmed populated)
- [ ] Snapshots remain immutable: `PlannedPrescriptionSnapshot` equipment/setup fields reflect whatever was active at session start and are never back-mutated
- [ ] No silent mutations: editing Exercise-level equipment does not propagate to existing workout history or active sessions

---

## 5) Prescription Elements

### Exercise-level concerns (definition — shared across routines)
- `name`, `bodyPart`, `isTimeBased`, `isCustom`
- `notes` — global form cues / coaching notes
- `equipmentType` + `setupDefaults` — **future** (Phase 9; currently on SlotPrescription, migrating out)

### Slot-level concerns (stored on `SlotPrescription`)
- **Core**: sets, rep range (min/max), rest between sets, rest after exercise
- **Autoregulation**: RIR, RPE, tempo
- **Duration**: duration min/max seconds, `usesDuration` flag (only when `Exercise.isTimeBased`)
- **Warmup**: `WarmupScheme` (reusable, `.nullify`) with ordered `WarmupStep`s
- **Techniques**: `TechniquePlan` (owned, `.cascade`) — dropset, partial reps, rest-pause, AMRAP, to-failure, cluster, tempo override
- **Slot notes**: `RoutineExercise.templateNotes` — per-slot coaching notes distinct from `Exercise.notes`

> **Equipment/setup** currently lives on `SlotPrescription` but is being migrated to Exercise-level defaults (Phase 9). Slot-level equipment override is optional and only if a clear use case emerges.

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
  - [ ] Selection UI: checkmark-based multi-select in exercise picker (replace current single-pick sheet)
  - [ ] Confirm-add action: selected exercises added to the target block in selection order
  - [ ] Preserve ordering: insertion follows user selection sequence, appended after existing slot exercises
  - [ ] Search & filter: exercise picker supports name search and optional bodyPart/muscle group filter
  - [ ] Edge case: duplicate exercise in same block shows warning or is silently allowed (decide)
- **remove extra "Done" buttons**
  - [ ] Audit: identify all views with standalone "Done" buttons (routine editor sheets, prescription editor, exercise detail, etc.)
  - [ ] Replace with toolbar `.confirmationAction` placement or automatic dismiss on save
  - [ ] Keyboard UX: ensure "Done" toolbar item on `.keyboard` placement is consistent across all text-input views (no double "Done")
  - [ ] Sheet dismiss: prefer SwiftUI `.presentationDetents` + drag-to-dismiss over explicit close buttons where appropriate
  - [ ] Verify: no views lose their only dismissal path after cleanup
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
- `setTemplates` are compatibility/override only (Phase 7 evaluates deprecation)
- `Exercise.defaultTemplates` is targeted for removal (Phase 8); unprogrammed slots use "Unprogrammed" UX with quick-fill instead
- Resolution precedence target: slot setTemplates (optional) → slot prescription (primary) → unprogrammed fallback (UI prompt)
- Equipment/setup belongs on Exercise, not SlotPrescription (Phase 9 migration)

### Session snapshots
- Workout UI displays rep range (min-max), tempo, RIR, RPE, and slot notes from session-level snapshots
- Snapshots are copied at session start and are immutable thereafter
- Old workouts with nil snapshots degrade gracefully (section hidden)

### History & lifecycle (once Phase 4-5 are complete)
- History grouping uses RoutineVariant relationship/ID (not `routineName` string)
- Active session resumes after restart (persisted `activeSessionID`)

### Quality
- 3-5 tests pass reliably
- No heavy regrouping inside SwiftUI `body` for history lists

# REFACTOR_PLAN.md
Gym Log — Architecture v2 Refactor (SwiftUI + SwiftData)

Branches:
- `refactor/architecture-v2` — plan & rules
- `refactor/architecture-v2-exec` — execution (active)

Last updated: 2025-02-18 (KST)

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
- Sessions = snapshotted, append-only record (snapshot fields not yet added)
- Explicit "apply changes" flow for any propagation back to templates/defaults (implemented)
- History grouped by IDs/relationships, not names (not yet implemented)

---

## 1) Current System Snapshot (as of Phase 3.2)

### Models

- **Exercise**
  - `id: UUID`, `name`, `bodyPart?`, `notes?`, `isCustom`, `isTimeBased`
  - `defaultTemplates: [SetTemplate]` (.cascade)
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
  - Context: `equipment?`, `setupNotes?`
  - `warmupScheme: WarmupScheme?` (.nullify — reusable across slots)
  - `techniquePlans: [TechniquePlan]` (.cascade — owned by this prescription)

- **WarmupScheme** — `name`, `steps: [WarmupStep]` (.cascade)
- **WarmupStep** — `order`, `kind` (percentage/fixedReps/noteOnly), `reps?`, `percentOfWorking?`, `restSecondsAfter?`, `note?`
- **TechniquePlan** — `order`, `type` (dropset/partialReps/restPause/amrap/toFailure/cluster/tempoOverride), plus parameterized fields (`repMin?`, `repMax?`, `reps?`, `durationSeconds?`, `restSeconds?`, `rounds?`, `dropPercent?`, `dropCount?`, `partialRangeNote?`, `note?`)

- **SetTemplate** — `order`, `kind` (warmup/working/dropset), `targetReps`, `targetWeight?`, `restSecondsAfter?`, `durationSeconds?`
- **SetLog** — `indexInExercise`, `kind`, `reps`, `weight?`, `restSeconds?`, `durationSeconds?`, `timestamp`
- **WorkoutItem** — `exercise: Exercise?` (inverse), `setLogs: [SetLog]` (.cascade)
- **Workout** — `id: UUID`, `date`, `routineName: String?`, `items: [WorkoutItem]` (.cascade), `notes?`

### Template resolution (3-tier precedence, enforced everywhere)

1. **`RoutineExercise.setTemplates`** — explicit per-set overrides (compatibility/power-user layer)
2. **`SlotPrescription.generateTemplates()`** — deterministic generation from structured prescription
3. **`Exercise.defaultTemplates`** — exercise-level fallback

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
- Prescription-generated templates (tier 2) produce `[SetTemplate]` with a single `targetReps` value (`repMax ?? repMin ?? 8`). Min/max range display requires session snapshots + workout UI work (Phase 3.4).
- Slot notes, tempo, and RIR are stored on the prescription but not shown in the workout UI until session snapshot fields are added (Phase 3.3) and the workout UI is updated (Phase 3.4).

---

## 2) Target Architecture (Remaining)

### 2.1 Session snapshot fields on WorkoutItem
On the performed item (WorkoutItem):
- `plannedPrescriptionSnapshot: Data?` (Codable snapshot of SlotPrescription at session start)
- `templateNotesSnapshot: String?` (copy of `RoutineExercise.templateNotes`)
- `routineSlotID: UUID?` (copy of `RoutineExercise.slotID`)

These enable the workout UI to display rep ranges, tempo, RIR, slot notes without live model references.

### 2.2 Workout lifecycle (single source of truth)
`WorkoutState`:
- idle
- configuringTemplate
- active(sessionID)
- finished(sessionID)

Persist `activeSessionID` so sessions can resume after app restart.

### 2.3 History grouping by IDs (not strings)
Replace:
- `Workout.routineName: String?` as primary link
with:
- `Workout.routineVariantID` (or relationship to RoutineVariant)

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

---

### Remaining Phases

#### Phase 3.3 — Session snapshot fields
Add fields to `WorkoutItem` so the workout UI can display prescription data without live model references.
- [ ] Add `routineSlotID: UUID?` to `WorkoutItem` (copy of `RoutineExercise.slotID`)
- [ ] Add `plannedPrescriptionSnapshot: Data?` to `WorkoutItem` (Codable JSON of `SlotPrescription` at session start)
- [ ] Add `templateNotesSnapshot: String?` to `WorkoutItem`
- [ ] Create `CodablePrescriptionSnapshot` struct mirroring `SlotPrescription` fields (rep range, rest, RIR, tempo, duration, equipment)
- [ ] Update `makePlan()` / session creation to populate snapshot fields from `re.prescription` + `re.templateNotes`
- [ ] Backfill strategy: existing `WorkoutItem`s get nil snapshots (graceful fallback in UI)
- [ ] Verify: snapshot is immutable after session start (no live reference back to prescription)

#### Phase 3.4 — ActiveWorkoutView becomes prescription-aware
Display prescription data from session snapshots in the workout UI.
- [ ] Show rep range (min–max) instead of single target reps when snapshot has both `repMin` and `repMax`
- [ ] Show tempo badge/label when snapshot includes tempo
- [ ] Show RIR target when snapshot includes RIR
- [ ] Show slot notes (from `templateNotesSnapshot`) in exercise header or expandable section
- [ ] Show duration targets for time-based exercises from snapshot
- [ ] Show equipment/setup notes if present
- [ ] Graceful fallback: if snapshot is nil, use existing single-value display

#### Phase 3.5 — Warmup scheme + technique plan editor UI
Template-level editing for advanced prescription elements.
- [ ] Warmup scheme picker/editor in routine slot detail (select existing or create new)
- [ ] WarmupStep list editor (order, kind, reps, percent, rest, note)
- [ ] TechniquePlan list editor in routine slot detail (add/remove/reorder techniques)
- [ ] Technique type picker with parameterized fields per type
- [ ] Equipment / setup notes fields in prescription section
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

#### Phase 7 — Deprecation cleanup (optional, later)
- [ ] Deprecate `Workout.routineName` as primary grouping link (keep as display fallback)
- [ ] Evaluate deprecating `RoutineExercise.setTemplates` once prescription adoption is stable
- [ ] Remove commented-out silent mutation calls from `ActiveWorkoutView`
- [ ] Consider migration tool for existing device data cleanup
- [ ] Keep fallback read-only until migration is proven stable across updates

---

## 5) Prescription Elements

### Currently implemented (stored on `SlotPrescription`)
- **Core**: sets, rep range (min/max), rest between sets, rest after exercise
- **Autoregulation**: RIR, RPE, tempo
- **Duration**: duration min/max seconds, `usesDuration` flag
- **Context**: equipment, setup notes
- **Warmup**: `WarmupScheme` (reusable, `.nullify`) with ordered `WarmupStep`s
- **Techniques**: `TechniquePlan` (owned, `.cascade`) — dropset, partial reps, rest-pause, AMRAP, to-failure, cluster, tempo override

### Additional production-grade prescription candidates (later)
These are NOT part of the current refactor scope but represent future prescription enrichment:
- **Set targeting mode**: straight sets vs top set + backoffs vs ramping
- **Intensity guidance**: %1RM target, suggested load rules (not fixed weight — weight is always session truth)
- **Pause reps / tempo variants / ROM constraints**: structured tempo patterns beyond the single tempo string
- **Grip / stance / cues**: structured fields or notes for setup specifics
- **Rest semantics**: unified model for set rest vs exercise rest vs superset round rest (currently separate fields)
- **Autoregulation rules**: stop conditions (e.g., "stop if bar speed drops"), adjust-load rules, performance-based set count
- **Progression hints**: last-time summary display, suggested load increases (read-only; never auto-writing defaults)

> **Weight is session truth.** Templates may include optional weight guidance later (e.g., %1RM, RPE-based suggestion), but weight should never be auto-written back to templates or exercise defaults.

---

## 6) Explicit "Not Part of This Refactor" (Backlog)
These are product tweaks and must not block completion:
- routine name editable
- reorder routines by drag
- multi-select exercise add
- remove extra "Done" buttons
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
- `SlotPrescription` is the source of programming intent; `setTemplates` are compatibility/override only
- 3-tier resolution (setTemplates → prescription → exercise defaults) is enforced in all code paths
- `setTemplates` will be deprecated once prescription adoption is stable (not before Phase 7)

### Session snapshots (once Phase 3.3-3.4 are complete)
- Workout UI displays rep range (min-max), tempo, RIR, and slot notes from session-level snapshots
- Snapshots are copied at session start and are immutable thereafter

### History & lifecycle (once Phase 4-5 are complete)
- History grouping uses RoutineVariant relationship/ID (not `routineName` string)
- Active session resumes after restart (persisted `activeSessionID`)

### Quality
- 3-5 tests pass reliably
- No heavy regrouping inside SwiftUI `body` for history lists

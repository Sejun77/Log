# REFACTOR_PLAN.md
Gym Log — Architecture v2 Refactor (SwiftUI + SwiftData)

Branch: refactor/architecture-v2  
Last updated: 2026-02-16

---

## 0) Why This Refactor Exists
Your current app already works, but it has production blockers:

- **Templates and exercise defaults are being mutated by session behavior** (confirmed in `ActiveWorkoutView.swift`):
  - completion writes to `Exercise.notes`
  - completion updates `Exercise.defaultTemplates` via `persistDefaultsOnlyForCurrentExercises()`
  - completion applies swaps back into the routine via `applyExerciseSwapsToRoutine()`
- **History is linked by strings**: `Workout.routineName: String?`
- **Routine slots have no stable UUIDs** (`RoutineExercise` and `RoutineBlock` lack `id`)
- **Deletion rules are dangerous**: many relationships are `.cascade`, which risks wiping history when deleting templates/exercises.
- The workflow needs a **single persisted workout lifecycle state** to support resume safely after app restart.

This refactor enforces clean invariants:
- Templates = stable blueprint
- Sessions = snapshotted, append-only record
- Explicit “apply changes” flow for any propagation back to templates/defaults
- History grouped by IDs/relationships, not names

---

## 1) Current System Snapshot (Confirmed from Entities.swift + Views)

### Models (current)
- Exercise
  - `id`, `name`, `notes`, `defaultTemplates: [SetTemplate]` (cascade)
  - `routineUsages: [RoutineExercise]` (cascade)
  - `workoutItems: [WorkoutItem]` (cascade)  ⚠️ dangerous
- Routine
  - `id`, `name`, `blocks: [RoutineBlock]` (cascade)
- RoutineBlock
  - `isSuperset`, `restAfterSeconds`, `supersetRoundRestSeconds`, `exercises: [RoutineExercise]` (cascade)
- RoutineExercise
  - `exercise: Exercise?` (inverse), `order`, `setTemplates: [SetTemplate]` (cascade)
- Workout
  - `id`, `date`, `routineName: String?`, `items: [WorkoutItem]` (cascade), `notes`
- WorkoutItem
  - `exercise: Exercise?` (inverse), `setLogs: [SetLog]` (cascade)
- SetTemplate / SetLog

### Confirmed refactor conflicts (must remove)
- Per-session writes to Exercise (`notes`, default templates)
- Template slot identity tied indirectly to Exercise
- History grouping by `routineName` string
- Excessive `.cascade` delete rules risking history deletion

---

## 2) Target Architecture (What We’re Building)

### 2.1 Data model additions
**RoutineVariant**
- `name`, `order`
- relationship: blocks/items (variant owns template structure)
- A routine can have multiple variants (A/B, Strength/Hypertrophy)

**Stable slot IDs**
- Add `id: UUID` to:
  - RoutineBlock
  - RoutineExercise
These IDs must persist for the slot lifetime (not regenerated on reorder).

**Structured Prescription on template slot**
Move prescription structure from “defaultTemplates on Exercise” toward **slot-owned prescription** on `RoutineExercise`.
Prescription contains:
- Core: sets, min/max reps, rest (set/exercise), RIR/RPE, warm-up scheme
- Modifiers: tempo, AMRAP, failure, duration-based
- Techniques: drop set, partial reps, rest-pause
- Context: equipment (+ setup)
- Metadata: modifier scope

### 2.2 Session snapshot fields on session item
On the performed item (WorkoutItem or renamed):
- `plannedPrescriptionSnapshot` (copied from template slot at start)
- `templateNotesSnapshot` (optional)
- `routineSlotID` (UUID of RoutineExercise slot)

### 2.3 Workout lifecycle (single source of truth)
`WorkoutState`:
- idle
- configuringTemplate
- active(sessionID)
- finished(sessionID)

Persist `activeSessionID` so sessions can resume after app restart.

### 2.4 Editing during workout (explicit apply flow)
Any edit while active must prompt:
- This workout only (default)
- Update this routine template
- Update exercise defaults (optional + tightly scoped)

### 2.5 History grouping by IDs (not strings)
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
Current `.cascade` usage is unsafe (especially Exercise ↔ WorkoutItem).
Goal:
- Deleting a routine/variant should NOT delete past workouts.
- Deleting an exercise should NOT delete past workouts.
Prefer:
- `.nullify` for relationships from history → definitions/templates
- or soft-delete / “orphaned reference” strategy
(Exact choice depends on SwiftData constraints; default is “keep history readable.”)

### 3.3 Tests (3–5)
1) session creation snapshots prescription from template slot
2) session edits do not mutate template without explicit apply
3) finish produces immutable history record
Optional:
4) resume active session after restart
5) history grouping survives name changes

### 3.4 Performance
Avoid heavy grouping/filtering/sorting in SwiftUI `body`.
Prefer:
- Query-based fetch with sort descriptors
- precomputed summaries (last performed, session count, duration, etc.)
- cached groupings keyed by IDs

---

## 4) Tight Execution Checklist (Full Process)

### Phase 0 — Baseline & guardrails (commit now)
- [ ] Create `CLAUDE.md` (rules/invariants)
- [ ] Create `REFACTOR_PLAN.md` (this plan)
- [ ] Commit these as the FIRST commit on `refactor/architecture-v2`
- [ ] Confirm app builds and runs on simulator/device

### Phase 1 — Add identity & variant skeleton (additive, no behavior change)
- [ ] Add `RoutineVariant` model
- [ ] Add `id: UUID` to RoutineBlock + RoutineExercise (stable slot IDs)
- [ ] Migration/backfill:
  - [ ] existing blocks/exercises get UUIDs if missing
  - [ ] existing routines get a default variant (e.g., “Default”)
- [ ] Ensure existing UI still displays routines correctly

### Phase 2 — Introduce Prescription model on slot (additive)
- [ ] Add `Prescription` fields to RoutineExercise
- [ ] Decide representation:
  - embedded struct + Codable OR explicit fields
- [ ] Map existing `setTemplates` usage:
  - [ ] preserve old setTemplates temporarily for compatibility
  - [ ] begin reading from Prescription where appropriate
- [ ] Template editor updates slot prescription fields (not Exercise defaults)

### Phase 3 — Session snapshot fields (additive)
- [ ] Add on WorkoutItem:
  - [ ] plannedPrescriptionSnapshot
  - [ ] templateNotesSnapshot
  - [ ] routineSlotID
- [ ] Update “Start Workout” flow:
  - [ ] create session items from routine variant slots
  - [ ] snapshot planned prescription + notes
  - [ ] store routineSlotID

### Phase 4 — WorkoutState + persisted resume
- [ ] Implement `WorkoutState` store (single source of truth)
- [ ] Persist `activeSessionID`
- [ ] On app launch:
  - [ ] if activeSessionID exists and session exists → resume
  - [ ] else → reset to idle
- [ ] Prevent duplicate sessions on relaunch

### Phase 5 — Remove silent mutations (critical behavior change)
This phase eliminates current violations in `ActiveWorkoutView.swift`:
- [ ] Remove/disable:
  - [ ] `persistDefaultsOnlyForCurrentExercises()`
  - [ ] `persistExerciseNotesOnlyForCurrentExercises()`
  - [ ] `applyExerciseSwapsToRoutine()`
- [ ] Introduce explicit “Apply changes to…” flow:
  - [ ] default: “This workout only”
  - [ ] optional: template update (by routineSlotID)
  - [ ] optional: exercise defaults update (narrow scope, never history)
- [ ] Verify: completing a workout does not mutate Exercise or Routine silently

### Phase 6 — History refactor from strings to relationships
- [ ] Add `routineVariantID` / relationship on Workout
- [ ] New sessions always write it
- [ ] Backfill existing workouts:
  - [ ] if routineName matches an existing Routine → link to its Default variant
  - [ ] else keep routineName for display fallback (read-only compatibility)
- [ ] Update HistoryView grouping to use relationship/ID

### Phase 7 — Deletion rule hardening
- [ ] Change relationships so history does not cascade-delete
- [ ] Define “delete routine” behavior:
  - [ ] does not delete workouts
  - [ ] optionally soft-delete routine/variant
- [ ] Define “delete exercise” behavior:
  - [ ] does not delete workouts
  - [ ] workouts keep exercise name snapshot or nullify link safely

### Phase 8 — Tests + performance pass
- [ ] Add 3–5 tests listed above
- [ ] Ensure history grouping is not done expensively in `body`
- [ ] Add lightweight summary fields or caching if needed

### Phase 9 — Deprecation cleanup (optional, later)
- [ ] Deprecate `Workout.routineName` as primary link
- [ ] Keep fallback read-only until you’re confident migration is stable
- [ ] Consider a future cleanup tool for existing device data

---

## 5) Explicit “Not Part of This Refactor” (Backlog)
These are product tweaks and must not block completion:
- routine name editable
- reorder routines by drag
- multi-select exercise add
- remove extra “Done” buttons
- +/- steppers for reps
- preset note options
- pause/resume workout (may integrate with WorkoutState later)
- machine-specific weight/rep handling
- separate exercise progression history UI + charts
- full existing-history cleanup UI
- CSV import/export

---

## 6) Acceptance Criteria (Ship Bar)
- Templates are never silently modified by workout actions
- Sessions are snapshotted and become immutable history when finished
- History grouping uses RoutineVariant relationship/ID
- Slot IDs are stable and unique per slot
- Active session resumes after restart (persisted activeSessionID)
- Deletion does not wipe history by default
- 3–5 tests pass reliably
- No heavy regrouping inside SwiftUI body for history lists
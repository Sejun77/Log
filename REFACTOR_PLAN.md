# REFACTOR_PLAN.md

Gym Log — Architecture v2 Refactor (SwiftUI + SwiftData)

Branches:

- `refactor/architecture-v2` — plan & rules
- `refactor/architecture-v2-exec` — execution (active)

Last updated: 2026-05-20 (KST, late session — Phase 11 CLOSED; 11.6-C/D deferred to Phase 12) — Phase 7 Slices 7.0 + 7.1 + 7.2 + 7.3 + 7.4 (RestTimer + ParentDraftStore + DropWeightDraftStore + RestPlanner simple-branch + RestPlanner superset sub-slices) + 7.5 complete: `LogTests` XCTest target wired with an in-memory `ModelContainer` harness and full suite at 90/90; the 7.4-B DropWeightDraftStore sub-slice lifted drop-weight draft persistence out of `ActiveWorkoutView.swift` into `Log/Services/DropWeightDraftStore.swift` (storage layout byte-identical; `restoreDropWeightDrafts` @State bridge kept in the view) and added 10 pure-XCTest cases including a literal-string format pin. The 7.4-A ParentDraftStore sub-slice had already added 13 cases and the 7.4 RestTimer sub-slice 7. The 7.4-C.1 RestPlanner sub-slice lifted the simple non-superset rest decisions (between-set rest, final-set after-exercise rest, template-based dropset skip, last-set-of-workout suppression) out of `ActiveWorkoutView.restSecondsAfterCurrentLog` into `Log/Services/RestPlanner.swift` (pure `RestContext` value type + pure `RestPlanner.restSecondsAfterLog(_:)` function; supersets, current-set-is-dropset final-drop, technique-based dropset suppression, warmup rest, and `block.restAfterSeconds` additive post-processing all stay inline) and added 12 pure-XCTest cases. The 7.4-C.2 RestPlanner sub-slice extended the planner with `SupersetRoundParticipant` + `SupersetRoundContext` + `RestPlanner.restSecondsAfterSupersetRound(_:)` and lifted the entire `block.isSuperset` rest branch — mid-round suppression, base round rest from `supersetRoundRestSeconds`, max-combined per-exercise planned/template fallback (both normal-round and after-dropset variants), next-round template-dropset skip, final-round transition rest replacement, and the superset-side last-set-of-workout suppression — out of the view, with 17 new pure-XCTest cases (29 total in `RestPlannerTests`). The 7.4-C.3 RestPlanner sub-slice extracted the dropset-final-drop rest decisions from `ActiveWorkoutView.buildDropSection.onLog` into two new pure functions — `RestPlanner.restSecondsAfterFinalDropInExercise(setIndex:effectiveSetCount:plannedRestBetweenSets:plannedRestAfterExercise:isLastSetOfWorkout:)` and `RestPlanner.restSecondsAfterFinalDropInSuperset(_:)` (reuses `SupersetRoundContext`) — preserving the deliberate divergences from the parent-log paths (no template-rest fallback; superset last-set-of-workout suppression is symmetric across exercises; superset transition rest uses a stricter `> 0` clamp). The now-unused `computeSupersetEndOfRoundRest` helper was deleted from the view (the planner is now a strict superset of its semantics). Added 14 new pure-XCTest cases bringing the suite to **43 RestPlannerTests / 115 total** (still all green). Sub-slice 7.4-C.4 (non-final intra-drop helper + a couple of one-line dropset variants in `restSecondsAfterCurrentLog`) was audited and **closed by decision** — those remaining branches are single optional-`Int` positivity filters, one-line `nil` guards, or a rarely-exercised legacy template-kind path; extracting any of them would add public-function names whose bodies are shorter than the names and tests that verify `Optional<Int>` arithmetic. `RestPlanner` extraction (7.4-C.1 → 7.4-C.2 → 7.4-C.3) is **functionally complete for the high-traffic rest-decision paths** (simple non-superset, superset round, dropset final-drop), pinned by 43 pure-XCTest cases. Phase 7.4-C as a whole is complete; the remaining one-line filters are documented as inline-by-decision. **Phase 11 (view decomposition) has begun**: Slice 11.1 lifted `ActiveWorkoutGuard` to `Log/Services/`, `SessionPlan` to `Log/Models/`, and `Collection.safe` to `Log/Utilities/` (a new folder); `ActiveWorkoutView.swift` went from 3,849 → 3,695 LOC with no behavior change, 115/115 tests still green. The Phase 11 section now carries a five-slice roadmap (11.2 Routines pickers/warmup/prescription, 11.3 Routines techniques/block-detail/model-helpers, 11.4 ActiveWorkout supporting private structs, 11.5 RoutineEditor extraction, 11.6 ActiveWorkoutView per-concern extension files) plus an explicit Phase-12 deferral list for the `@State`-capturing `@ViewBuilder` methods. Active-workout identity Slice A (in-memory rekey from `Exercise.id` to `routineSlotID` across `loggedByExercise` / `dropsLoggedByExercise` / `inputsByExerciseID` / `itemsByExerciseID` and the three `ActiveWorkoutGuard` caches — `inputsCache` / `loggedCache` / `notesCache`) and Slice B (`ParentDraftStore` / `DropWeightDraftStore` persisted-key migration to `routineSlotID` with a parent-draft dual-read fallback and a drop-draft one-shot migration walker — `setAll(_:)` + `migrateLegacyKeys(in:legacyExerciseToSlots:knownSlots:)` — plus 11 new pure-XCTest cases bringing the suite to 101/101) both shipped: duplicate-Exercise-across-slots draft state is now slot-scoped end-to-end, including across force-quit + cold-resume, with in-flight legacy-format drafts migrated transparently. The superset manual-switch round-gating bug also shipped: `canLogSet` now enforces "previous round complete across every participating exercise" for supersets with `setIndex > 0`, using the dropset-aware `isWorkingSetComplete` so a dropset-attached round blocks the next round until the parent + all required drops are logged. The notes apply-back vestige (`ActiveWorkoutGuard.notesCache`, `notesBinding(for:)`, `persistExerciseNotesOnlyForCurrentExercises`, `hasNotesPending`, the swap-time cache seeding, the `"Finish + Update exercise notes"` button, and the `applyNotes` parameter on `finishWorkout`) was also deleted — `Exercise.notes` is now write-through-only via `ExerciseNotesEditSheet` (active workout) and the standalone Exercise page; duplicate-`Exercise` notes ambiguity is resolved by product semantics (global notes shared across slots, per-slot cues live in Slot Guidance / `RoutineExercise.templateNotes`); a latent revert-on-finish bug was fixed as a side effect. Superset Details exercise management also shipped: `+ Add Exercise` and `.onDelete` are wired in `SupersetDetailNoRest` (with a min-2-exercises alert, shared-sets coercion on Add, duplicate Exercise allowed by design), the parent-relationship cascade bug that caused the whole block to disappear on child delete is fixed by `block.exercises = survivors` before `ctx.delete`, and routine-lock gating is now scoped to individual mutation controls (per-Stepper / per-Button / per-Section / `.moveDisabled` / `.deleteDisabled` plus a Section-level `.disabled(isLocked)` inside `SlotPrescriptionSection`) so locked routines remain scrollable and readable. Duplicate-`Exercise`-inside-superset **integration verification** is the only open Pending block under Phase 5.2 — the prior UI blocker is gone, and only a manual smoke test on a hand-built two-slot superset remains. Phase 5.2 is NOT marked complete. Slice 7.3 extracted Phase 6.B backfill into `BackfillService`; Slice 7.2 extracted `RoutineLabelResolver`; Slice 7.5 aligned the test target's deployment to 18.5 and documented the concrete-simulator + app-hosted policy in CLAUDE.md. Host-less conversion attempted and reverted (iOS app targets can't link `@testable` symbols without `TEST_HOST` / `BUNDLE_LOADER`). Phase 6.B Slice C.1 / Slice B remain shipped; Slice C.2 grouping and rename verification still pending. **Phase 11 Slice 11.2 (Routines pass 1) has shipped**: `ExercisePickerSingle` + `SupersetPicker` lifted to `Log/Main/Routines/ExercisePickers.swift`; `WarmupSchemeEditor` + `WarmupStepRow` + `WarmupStepEditSheet` lifted to `Log/Main/Routines/WarmupSchemeEditor.swift`; `SlotPrescriptionSection` + `PrescriptionFields` + `TempoEditorView` + the `makeDefaultPrescription` factory lifted to `Log/Main/Routines/PrescriptionFields.swift`. Four access bumps were required for cross-file use: `makeDefaultPrescription` (`fileprivate` → internal, planned), `SupersetPicker` (`private` → internal, called from `RoutineEditor`), `WarmupSchemeEditor` (`private` → internal, navigated to from `SlotPrescriptionSection`), and one unplanned bump — `TechniquePlanEditor` (`private` → internal) — because `SlotPrescriptionSection` now navigates to it across files until 11.3 moves it. `RoutinesView.swift` went **2,543 → 1,896 LOC (−647, −25%)**; the three new files together carry 659 LOC; full XCTest suite **115/115 still green** in ~0.68s. **Phase 11 is now CLOSED** (owner decision 2026-05-20): 11.6-C (per-concern extension-file split) and 11.6-D (`restSecondsAfterCurrentLog` extraction) were explicitly deferred to Phase 12, since both are no longer simple low-risk file-moves — 11.6-C would force widening many `private` `@State` and helper members of `ActiveWorkoutView` to default-internal, and that access-surface decision is better made together with the Phase-12 viewmodel hoist (some members may move *onto* the viewmodel rather than be bumped on the view). 11.6-D depends on 11.6-C and follows. The full Phase-11 ledger is: 11.1 (top-level support types) + 11.2 (Routines pickers/warmup/prescription) + 11.3 (Routines techniques/block-detail/model-helpers) + 11.4 (ActiveWorkout supporting structs) + 11.5 (RoutineEditor) + 11.6-A (ActiveWorkout pure utilities) + 11.6-B (SessionPlanResolver service with 23 tests) all shipped; 11.6-C / 11.6-D explicitly deferred to Phase 12. Cumulative LOC deltas: `RoutinesView.swift` **2,543 → 380 (−2,163, −85%)**, `ActiveWorkoutView.swift` **3,849 → 3,030 (−819, −21%)**, with the remaining `ActiveWorkoutView.swift` LOC dominated by the `body` + six `@State`-capturing `@ViewBuilder` methods (Phase-12 viewmodel-hoist territory). Full XCTest suite **138/138 still green**. **Phase 11 Slice 11.6-B (`SessionPlanResolver` service) had shipped earlier this session** before the deferral decision: five pure resolution helpers — `effectiveSetCount`, `plannedRepTarget`, `plannedDurationTarget`, `plannedRestBetweenSets`, `plannedRestAfterExercise` — extracted from `ActiveWorkoutView` into a pure `enum SessionPlanResolver` namespace at `Log/Services/SessionPlanResolver.swift` (139 LOC). Each function takes `sessionPlan: SessionPlan?`, `snapshot: PrescriptionSnapshotPayload?`, and (where relevant) a `PlanSetTemplate` / `[PlanSetTemplate]` by value — **zero access bumps required** because the resolver never touches an `ActiveWorkoutView` member. The 5 methods on `ActiveWorkoutView` were kept as thin one-line wrappers that forward `sessionPlans[exercise.routineSlotID]` + `exercise.prescriptionSnapshot` to the resolver (same pattern as `RestPlanner`), which minimized call-site churn but meant `ActiveWorkoutView.swift` actually grew by **+3 LOC** (`3,027 → 3,030`) rather than the audit's `~−80` estimate — that estimate assumed direct call-site rewrites that were deliberately deferred since the resolver is now in place, tested, and trivially inline-able later. Fallback behavior preserved byte-for-byte (verified against `HEAD~1` of the moved methods): three-tier precedence (sessionPlan → snapshot → template / count clamp / nil), `> 0` filter at both stored-sets tiers + the load-bearing `max(1, …)` clamp for `effectiveSetCount`, `(repMax ?? repMin)` and `(durationMaxSeconds ?? durationMinSeconds)` `??` chains that accept stored `0`, `> 0` filter on both rest fields. Added `LogTests/SessionPlanResolverTests.swift` (368 LOC, **23 pure XCTest cases**, no SwiftData harness) — the suite uses a small test-only memberwise `init` extension on `PrescriptionSnapshotPayload` that delegates to `init(from: PlannedPrescriptionSnapshot)` (the @Model's compiler-generated init is invokable without a `ModelContext`, so the suite stays SwiftData-free). First test build hit Swift's "extension init can't directly assign to `self.field`" rule; switching to delegation fixed it. Total suite: **115 → 138 tests** in ~0.85s. **Phase 11 Slice 11.6-A (ActiveWorkout pure utility lift) had shipped earlier this session**: four pure helpers — `roundWeight(_:)`, `formatWeight(_:)`, `defaultTemplate(for:at:)`, and `activeRestNotificationID(workoutID:slotID:)` (renamed from `restNotificationID(slotID:)` with `workoutID` now an explicit `UUID?` parameter threaded through as `workout?.id`) — lifted from `ActiveWorkoutView` into `Log/Main/ActiveWorkout/ActiveWorkoutHelpers.swift` (67 LOC) as module-internal free functions. One required isolation annotation: `@MainActor` on `activeRestNotificationID` because `RestTimer.stableNotificationID` is `static` on a `@MainActor` final class — caught by the first build attempt, fixed before green. Rest notification fallback shape `"rest.unknown.<slotID>"` preserved byte-for-byte (load-bearing — `RestTimer` keys pending `UNUserNotificationCenter` requests off this string). Three `restNotificationID` callsites rewritten to pass `workout?.id`; six `defaultTemplate` callsites + one `formatWeight(roundWeight(…))` callsite unchanged textually. **Zero access bumps on `ActiveWorkoutView`'s `@State` surface** — that's the whole point of starting with 11.6-A before the larger 11.6-C bumps. `ActiveWorkoutView.swift` went **3,061 → 3,027 LOC (−34, −1.1%)**. Full XCTest suite **115/115 still green** in ~0.60s. **Phase 11 Slice 11.5 (RoutineEditor extraction) had shipped earlier this session**: `struct RoutineEditor: View` (538 LOC pre-move) lifted from `RoutinesView.swift` to `Log/Main/Routines/RoutineEditor.swift` — its nested `private DeletePrompt`, the full @State surface, `@Bindable var routine`, `@Query allExercises`, and all 16 private helpers (`addSection`, `blocksContent`, `emptyBlocksSection`, `blocksSection`, `deleteBlocksFromEdit`, `blockRowView`, `blockSwipeActions`, `moveBlocks`, `normalizeRoutineModel`, `routineIsStartable`, `blockIsInvalidSuperset`, `blockTitle`, `blockContainsLockedExercise`, `endActiveSessionIfAny`, `deleteBlockSafely`, `appendBlock`) relocated as struct members without promotion. One required access bump — `BlockRow`: `private` → default-internal (so `RoutineEditor.blockRowView(for:)` can reach it across files); `LockBadge` stays file-private under the Phase-11.3 collision rationale (`BlockRow.body`'s `LockBadge()` lookup resolves at definition site, which is still `RoutinesView.swift`). `RoutinesView.swift` went **913 → 380 LOC (−533, −58%; cumulative from pre-Phase-11 2,543 is −85%)**, ~12% better than the ~430 estimate. Locked-routine cascade preserved (routine stays scrollable; Add Exercise / Add Superset / EditButton / move / swipe-delete / swipe-`In use` remain individually disabled-or-guarded); superset add/remove/reorder behavior preserved at the `SupersetDetailNoRest` callsite via `routineLocked:` plumbing; `normalizeRoutineModel`'s exact-copy override detection + per-superset RE order renumber + three sequential `try? ctx.save()` checkpoints all preserved byte-for-byte. Full XCTest suite **115/115 still green** in ~1.29s. **Phase 11 Slice 11.4 (ActiveWorkout supporting private structs) had shipped earlier this session**: nine supporting private subview structs — `SetEntryRow` + `TimeSetEntryRow` → `SetRows.swift`, `DropLogRow` → `DropLogRow.swift`, `TechniqueIndicatorRow` + `SetTechniqueChipsRow` + `TechniqueDetailSheet` → `TechniqueChipsViews.swift`, `RestOverlayScreen` → `RestOverlayScreen.swift`, `ExerciseNotesEditSheet` → `ExerciseNotesEditSheet.swift`, `EditSessionPlanSheet` (+ its private `intStepperRow` / `doubleStepperRow` / `optionalString` helpers) → `EditSessionPlanSheet.swift` — all lifted out of `ActiveWorkoutView.swift` into a new `Log/Main/ActiveWorkout/` directory. Nine identical access bumps (`private struct` → default-internal) — every caller is still inside `ActiveWorkoutView.swift` so no public surface widened. `@ViewBuilder` section methods + ~60 private helpers (persistence / swap / snapshot / superset / technique) stay in place — Phase 11.6 / Phase 12 scope. `ActiveWorkoutView.swift` went **3,695 → 3,061 LOC (−634 LOC, −17%; cumulative from pre-Phase-11 3,849 is −20%)**; the six new files together carry 660 LOC; full XCTest suite **115/115 still green** in ~0.67s. Technique-chip tap → detail-sheet wiring was **preserved exactly** (Phase 3.8 pre-existing semantics) — 11.4 added no interactivity. **Phase 11 Slice 11.3 (Routines pass 2) had shipped earlier this session**: `TechniquePlanEditor` + `TechniquePlanRow` + `TechniqueTypePickerSheet` + `TechniqueParamEditView` lifted to `Log/Main/Routines/TechniquePlanEditor.swift` (598 LOC — biggest single move of Phase 11); `RoutineBlockDetailView` + `SupersetDetailNoRest` lifted to `Log/Main/Routines/BlockDetailViews.swift` (346 LOC, both bumped `private` → internal for cross-file call from `RoutineEditor.blockRowView(for:)`); `extension RoutineExercise { safeExercise(in:), normalizeOrderIfNeeded (private), resolvedTemplates(in:) }` lifted to `Log/Models/RoutineExercise+Helpers.swift` (71 LOC, also imports `Foundation` so the `#Predicate` macro resolves). The planned `BlockRow` + `LockBadge` extraction to `Log/Main/Routines/BlockRow.swift` was attempted and **rolled back**: Swift's top-level namespace is module-wide regardless of access level, so promoting `LockBadge` to default-internal collides with the file-private `LockBadge` in `ExercisesView.swift` (which intentionally uses a different `.dsCaption` font). Both badges stay in their original files; a documentation comment + "Deferred badge cleanup" subsection of the Phase-11 section now tracks the unblock options (rename, unify, or split-with-rename — all are out of scope for behavior-preserving pure decomposition). `RoutinesView.swift` went **1,896 → 913 LOC (−983, −52% this slice; cumulative from pre-Phase-11 2,543 LOC is −64%)**; the three new files together carry 1,015 LOC; full XCTest suite **115/115 still green** in ~0.91s

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

**Completed (7.4-C.3 — dropset final-drop rest extraction + tests):**

- [x] `Log/Services/RestPlanner.swift` gained two new pure static functions covering the final-drop rest decision that previously lived inline in `ActiveWorkoutView.buildDropSection.onLog`: `static func restSecondsAfterFinalDropInExercise(setIndex:effectiveSetCount:plannedRestBetweenSets:plannedRestAfterExercise:isLastSetOfWorkout:) -> Int?` for the non-superset path and `static func restSecondsAfterFinalDropInSuperset(_ ctx: SupersetRoundContext) -> Int?` for the superset path. The non-superset function takes plain parameters (deliberately not a `RestContext`) because its chain intentionally omits `templateRestSecondsAfter` and the next-template-dropset skip — passing don't-care fillers via the shared context would risk drift. The superset function reuses `SupersetRoundContext` / `SupersetRoundParticipant` for API symmetry; the unused fields (`currentTemplateKind`, `currentTemplateRestSecondsAfter`, `nextTemplateKind`, `priorWorkingRest`, `isLastExerciseOfBlock`) are documented as don't-care for this entry-point
- [x] **Non-superset final-drop** preserved byte-for-byte: `isLastSetOfWorkout` ⇒ nil; last working set ⇒ `plannedRestAfterExercise ?? plannedRestBetweenSets`; earlier working sets ⇒ `plannedRestBetweenSets`; all values filtered by `> 0`. **Template `restSecondsAfter` is intentionally NOT in this chain** — the dropset's parent-template rest is bypassed because dropset-final-drop rest follows the planned-rest contract (the parent template typically carries 0 or a short rest meant for inter-drop pacing, not for the post-dropset transition)
- [x] **Superset final-drop** preserved byte-for-byte: mid-round suppression returns `nil` until every participating exercise's `isComplete` is true; last set of last block (`isLastRound && isLastBlockOfWorkout`) ⇒ nil — **symmetric across exercises in the round** (does NOT require `isLastExerciseOfBlock`, distinguishing this from the parent-log superset path's last-set-of-workout check); base round rest from `supersetRoundRestSeconds > 0`, else max of per-exercise `plannedRestBetweenSets > 0` (**no template-rest fallback**, distinguishing from `restSecondsAfterSupersetRound`); final-round transition replacement with **stricter `> 0` clamp** (not the `!= 0` gate used by the parent-log path's transition rest)
- [x] `ActiveWorkoutView.buildDropSection.onLog` rewired: the inline `if isFinalDrop { if block.isSuperset { … } else { … } }` block now constructs the appropriate `SupersetRoundContext` (with don't-care fillers for the unused participant fields) or passes plain args, calls the planner, and applies the existing side-effect contract. Superset path's `nil` result still triggers `rest.stop()` + `clearPersistedRestState()` to clear any stale running rest from earlier in the round, then `advanceForSupersetAfterLog(...)`; non-superset path's `nil` still simply doesn't fire (preserving the inline divergence in nil-handling between the two paths). All other side effects unchanged: `startRestWithPersistence`, `showRestOverlay = true`, `UINotificationFeedbackGenerator`
- [x] **Dead-code removal**: `private func computeSupersetEndOfRoundRest(block:setIndex:)` (~37 LOC) deleted from `ActiveWorkoutView` — the function was a strict subset of what `restSecondsAfterFinalDropInSuperset` now implements; the only caller (`buildDropSection.onLog`'s superset branch) was migrated to the planner. `supersetRoundComplete(block:setIndex:)` is unchanged and still in the view — it's still used by `advanceForSupersetAfterLog` for focus advancement
- [x] `LogTests/RestPlannerTests.swift` — **14 new pure XCTest cases**, all green, on top of the 29 from 7.4-C.1 + 7.4-C.2 (total **43 in the file**): non-superset (5 — non-final-set planned-between-sets, final-set prefers planned-after-exercise, final-set fallback to planned-between-sets, last-set-of-workout suppression, all-nil returns nil); superset (9 — mid-round suppression, base round rest from `supersetRoundRestSeconds`, max-combined `plannedRestBetweenSets` fallback, **explicit pin that current-template rest is ignored** (distinguishes from `restSecondsAfterSupersetRound`), final-round transition fires, **negative `blockRestAfterSeconds` ignored** (pins the `> 0` clamp), last-set-of-workout suppression with `isLastExerciseOfBlock: false` explicitly to pin the symmetric behavior, non-final-round defensive guard, all-nil returns nil)
- [x] Build green; full suite **115/115 pass in ~0.59s** (composition unchanged except 29 → 43 RestPlannerTests: 12 BackfillServiceTests + 21 DropWeightDraftStoreTests + 1 ModelTests + 13 ParentDraftStoreTests + 5 PreferredVariantIDTests + 43 RestPlannerTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 4 WorkoutModelTests). Manual regression on the simulator covered non-superset dropsets, superset dropsets, final-round transition rest, and the still-inline non-final intra-drop branch. No model / history / routines / exercises / notes / warmup / RIR / RPE / tempo changes

**Closed (7.4-C.4 — non-final intra-drop helper + inline-dropset variants: kept inline by decision):**

- [x] **Non-final intra-drop rest** (the `else` branch of `isFinalDrop` in `ActiveWorkoutView.buildDropSection.onLog`): the decision math is a single optional-`Int` positivity filter — `snap.restSeconds.flatMap { $0 > 0 ? $0 : nil }`. No fallback chain, no contextual dependencies (only reads `snap`, already in scope), no testable behavior beyond what every other `RestPlanner.*` function already pins via its trailing `r > 0` guard. Extracting would add a public function whose body is shorter than its name, plus a handful of trivial test cases verifying `Optional<Int>` arithmetic. **Decision: kept inline.** Documented with a one-line "Non-final drop: intra-drop rest" comment at the call site
- [x] **`dropsetTechniqueApplying != nil` technique-suppression branch** in `restSecondsAfterCurrentLog` (returns `nil` to defer parent-set rest until the final drop fires): a one-line `restSec = nil` guard. Same close-or-defer rationale as the intra-drop case — exposing a `restSecondsAfterTechniqueDropsetParent(_:) -> Int?` that returns `nil` for a boolean input adds API surface for a constant function. **Kept inline**
- [x] **Template-kind `.dropset` branch** in `restSecondsAfterCurrentLog` (the legacy template-based dropset path, separate from the technique-based final-drop path that 7.4-C.3 covered): uses `plannedRestBetweenSets(for:) ?? priorWorkingRest(in: exercise.templates, upTo: idx)` with the `> 0` filter. The branch is small (~10 lines including the `priorWorkingRest` local), and today's users use technique-based dropsets so this code path fires rarely in production. Co-extracting would require hoisting `priorWorkingRest` out of `restSecondsAfterCurrentLog` into a pure planner helper — manageable but adds API surface for a legacy path. **Kept inline.** If a future refactor needs `priorWorkingRest` from another callsite, the hoist+extract becomes natural; until then, the legacy branch stays where it is
- [x] **`RestPlanner` extraction sequence (7.4-C.1 → 7.4-C.2 → 7.4-C.3) is functionally complete for the high-traffic paths**: simple non-superset between-set / final-set rest, superset round rest with mid-round suppression / max-combined fallback / final-round transition replacement, and dropset final-drop rest (both non-superset and superset variants). The **43 pure-XCTest cases** in `RestPlannerTests.swift` pin the contract. Phase 7.4-C closes with this documented decision on one-line filters and the legacy template-kind branch — Phase 7.4-C as a whole is **complete**

**Pending (7.4 — `RestTimer.stableNotificationID` nil-slotID coverage, gated on API change):**

- [ ] Extend the production signature to accept `slotID: UUID?` (and decide what an absent slot means for the cancellation key), then add nil-aware tests: (a) two calls with nil `slotID` and the same `workoutID` produce identical IDs; (b) nil `slotID` differs from any non-nil `slotID` for the same `workoutID`. **Gated**: only worth doing if a real consumer actually needs a nil-slot rest notification — today no caller passes nil, so the API change should not be made speculatively

**Completed (7.5 — test target hygiene):**

- [x] `LogTests` `IPHONEOS_DEPLOYMENT_TARGET` lowered from 26.5 → 18.5 in both Debug and Release `XCBuildConfiguration` blocks. Now matches the `Log` app target, so the suite runs on any iOS 18.5+ simulator instead of being constrained to iOS 26.5+ devices
- [x] CLAUDE.md "Build & Test Policy" rewritten with: the concrete-simulator requirement (`test` rejects `'generic/platform=iOS Simulator'` with *"Tests must be run on a concrete device"*); the verified default command `-destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'`; instructions to use `xcrun simctl list devices` to pick a different sim per machine; the app-hosted explanation (with expected `CoreData: error: Failed to stat path .../default.store` noise called out as non-failures, because tests use the in-memory `ModelContainer` via `SwiftDataTestHarness`); and the **schema-mirror invariant** — any new `@Model` registered in `LogApp.swift`'s `.modelContainer(for:)` must also be appended to the `Schema(...)` list in `LogTests/SwiftDataTestHarness.swift`, or every test touching that entity will fail to fetch
- [x] Build and test both re-verified post-change: `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` → `** BUILD SUCCEEDED **`; `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test` → 10/10 pass in ~0.17s

**Pending (7.5 — host-less conversion, NOT currently recommended):**

- [ ] Switch `LogTests` to host-less (clear `TEST_HOST` + `BUNDLE_LOADER`). **Attempted and reverted** during the 7.5 work: removing both keys caused the linker to fail with ~30 *Undefined symbol* errors for every `@testable`-imported Log type (e.g. `Log.Routine.blocks.getter`, `type metadata accessor for Log.Workout`, `protocol conformance descriptor for Log.AppState : SwiftData.PersistentModel in Log`). Root cause is structural: iOS app targets aren't framework targets, so a host-less test bundle has no way to resolve the app's internal Swift symbols at link/load time — `BUNDLE_LOADER = $(TEST_HOST)` is what defers resolution to the app binary at runtime. **Path forward (if pursued):** would require restructuring `Log` so the testable code lives in a separate framework / SwiftPM module that the test target can link directly. Out of scope for now; the only loss from staying app-hosted is the cosmetic CoreData log noise, which CLAUDE.md flags as expected

**Completed (7.6 — lifecycle/resume unit coverage, 2026-05-20):**

- [x] Added `LogTests/WorkoutResumeServiceTests.swift` — **7 cases, all green**, on `SwiftDataTestHarness`: (1) `rebuildPlan` returns nil when the workout has no `routineID` and no items; (2) primary path uses the routine when `routineID` is set and the `Routine` exists (verifies `routineID`, `routineName`, block/exercise counts, template `kind` / `targetReps` / `targetWeight`); (3) fallback path triggers when `routineID` references a missing `Routine`; (4) swap reconciliation overrides `currentExerciseID` / `name` from the matching `WorkoutItem.exercise` while preserving `originalExerciseID`; (5) `exerciseNameSnapshot` falls through when the swapped-in `Exercise` is nullified (post-delete cascade); (6) fallback reconstructs templates from `SetLog`s sorted by `indexInExercise` with per-log `reps` / `weight` / `restSeconds` fidelity; (7) fallback seeds templates from `PlannedPrescriptionSnapshot` (sets / repMax / restSecondsBetweenSets) when there are no logs yet
- [x] Added `LogTests/AppStateLifecycleTests.swift` — **5 cases, all green**, on `SwiftDataTestHarness`: (1) `AppState()` defaults to `.idle` with all `active*` fields nil and key `"appState"`; (2) `workoutState` get/set round-trips through `workoutStateRaw` and survives `ctx.save()` + refetch; (3) unknown raw strings (`"finished"`, `"bogus-future-case"`, `""`) decode to `.idle` via the `?? .idle` fallback — **this test pins the Phase 8-A `WorkoutLifecycleState.finished` removal's backward-compat guarantee** so future enum prunes have a regression net; (4) `BootstrapRoot.fetchOrCreateAppState(in:)` is singleton-safe across repeat calls (same identity, no duplicate insert); (5) all `active*` fields (workoutID, startedAt, restSlotID, blockIndex, exerciseIndex, sessionPlansJSON) survive save + re-fetch via the helper
- [x] **Pins the service/model contract Save & Exit relies on.** The Save & Exit lifecycle fix (commit `9fbcfc9`) depends on three invariants now under automated coverage: (a) `WorkoutResumeService.rebuildPlan` correctly rebuilds a `WorkoutPlan` from a resumable workout via either the routine-primary or items-fallback path — exercised by `WorkoutResumeServiceTests` 1–7; (b) `AppState.workoutState == .active` + `activeWorkoutID` non-nil persist correctly across save / refetch — exercised by `AppStateLifecycleTests` 2 + 5; (c) the singleton-fetch helper used by `BootstrapRoot.validateActiveSession` + `RootTabView.checkForActiveSession` returns the same instance with all fields intact — exercised by `AppStateLifecycleTests` 4 + 5. The `RoutinesView` "Resume workout" banner and the cold-restart resume path are end-to-end UI flows; they consume these primitives but are themselves not unit-testable without view extraction
- [x] **Production code unchanged.** Both new test files use only existing module-internal symbols (`WorkoutResumeService.rebuildPlan`, `BootstrapRoot.fetchOrCreateAppState`, `AppState`, `WorkoutLifecycleState`, standard model initializers). No access bumps required
- [x] Build green; full suite **150/150 pass in ~0.76s** (composition: 12 BackfillServiceTests + 21 DropWeightDraftStoreTests + 1 ModelTests + 13 ParentDraftStoreTests + 5 PreferredVariantIDTests + 43 RestPlannerTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 23 SessionPlanResolverTests + 4 WorkoutModelTests + **5 AppStateLifecycleTests** + **7 WorkoutResumeServiceTests**). Suite delta from pre-slice: 138 → 150 (+12). No regressions in any existing suite; no behavior changes to active workout, finish/save/discard, history, routine editing, or any of the warmup/dropset/superset/rest/RIR/RPE/tempo flows

**Completed (7.7 / 8-B — `WorkoutLifecycleService` extraction + tests, 2026-05-20):**

- [x] Added `Log/Services/WorkoutLifecycleService.swift` (~93 LOC) — `@MainActor enum` namespace with four `static` functions: `saveAndExit(in: ModelContext)` (single `try? ctx.save()` — the resumable-exit primitive); `finish(workout:appState:in:) -> Date?` (writes `completedAt = Date()`, clears every `active*` field on AppState, `try? ctx.save()`, returns the timestamp written or nil if `workout` was nil); `discard(workout:appState:in:)` (deletes the workout if non-nil, clears AppState, `try? ctx.save()`); `clearActiveAppState(_ appState: AppState?)` (the shared 8-field clear — `workoutState = .idle` + 7 nilable fields — used by both `finish` and `discard`, defensive no-op when `appState` is nil, no `ctx.save()` so callers batch). Field names mapped to the actual `AppState` model (`activeRestEndsAt`, `activeBlockIndex`, `activeExerciseIndex`, `sessionPlansJSON`). Service deliberately does NOT call `dismiss()`, touch `RestTimer`, end Live Activities, clear `ActiveWorkoutGuard` locks, or touch `DropWeightDraftStore` / `ParentDraftStore` UserDefaults — those view-instance-owned side effects remain in `ActiveWorkoutView`
- [x] `ActiveWorkoutView` rewired at 5 sites: (1) Save & Exit button (`L1444-1452`) — body becomes `WorkoutLifecycleService.saveAndExit(in: ctx); dismiss()`; (2) Discard button (`L1453-1459`) — fetches AppState, calls `WorkoutLifecycleService.discard(workout:appState:in:)`, then `unlockAndDismiss()`; (3) `finishWorkout(applySwaps:applySlotPrescription:)` — preserves the apply-swaps + apply-prescription branches verbatim then calls `WorkoutLifecycleService.finish(workout:appState:in:)` instead of the inline `workout?.completedAt = Date(); try? ctx.save()`; (4) `unlockAndDismiss()` — removed the `updateAppState(to: .idle)` call (now handled upstream by Finish/Discard via the service); still handles draft-store clears + `rest.stop()` + `setTimer.stop()` + `rest.endLiveActivityForWorkout()` + `activeGuard.endSession()` + `dismiss()`; (5) `updateAppState(to: WorkoutLifecycleState)` collapsed to `markAppStateActive()` (no parameter) — body trimmed to the four-line `.active` write since the `.idle` arm migrated to the service. Sole caller at session-start `onAppear` updated. Net view diff: ~+5 / −22 LOC
- [x] Added `LogTests/WorkoutLifecycleServiceTests.swift` (197 LOC) — **9 cases, all green**, on `SwiftDataTestHarness`: (1) `saveAndExitDoesNotCompleteWorkout`; (2) `saveAndExitPreservesActiveAppStateFields` (verifies all 8 fields survive); (3) `finishSetsCompletedAt` (pins write + return-value semantics + timestamp window via before/after `Date()`); (4) `finishClearsActiveAppStateFields` (shared `assertActiveAppStateCleared` helper pins all 8 fields nil + `workoutState == .idle`); (5) `discardDeletesWorkout` (fetchCount 1 → 0); (6) `discardClearsActiveAppStateFields`; (7) `clearActiveAppStateIsIdempotent` (single call clears, two more leave the same state, nil input is defensive no-op); (8) `finishWithNilWorkoutStillClearsAppState` (defensive — nil workout still clears AppState + returns nil so dangling resume gate cannot survive); (9) `discardWithNilWorkoutStillClearsAppState` (same defensive contract)
- [x] **Closes the direct unit-test gap for Save & Exit / Finish / Discard lifecycle mutations.** Phase 7.6 pinned the service/model contract that the *resume side* relies on (`WorkoutResumeService.rebuildPlan` + `AppState` round-trips); 7.7 pins the *terminal-write* contract for the three buttons themselves. Together they form a regression net for the Phase 8-A Save & Exit lifecycle bug: any future code change that wires Save & Exit to a path that sets `completedAt` or clears `activeWorkoutID` will fail one of the 7.7 tests; any change that breaks resume rebuild will fail one of the 7.6 tests
- [x] **Button UI wiring itself remains SwiftUI / manual-test territory.** XCTest cannot drive the `.confirmationDialog` button closures or the `dismiss()` / `rest.stop()` / `activeGuard.endSession()` view-side calls; those continue to be exercised by the manual lifecycle regression checklist (start workout → Save & Exit → confirm Resume banner; → Discard → confirm no History entry + no Resume banner; → Finish → confirm History entry with `completedAt` + duration). The 7.7 service tests pin every *mutation* those buttons perform, so a regression that flips one button to the wrong service call would still be caught by the per-test-name semantics (e.g. `testSaveAndExitDoesNotCompleteWorkout` would fail if Save & Exit accidentally routed through `finish`)
- [x] Build green; full suite **159/159 pass in ~0.90s** (composition: 12 BackfillServiceTests + 21 DropWeightDraftStoreTests + 1 ModelTests + 13 ParentDraftStoreTests + 5 PreferredVariantIDTests + 43 RestPlannerTests + 7 RestTimerTests + 9 RoutineLabelResolverTests + 23 SessionPlanResolverTests + 4 WorkoutModelTests + 5 AppStateLifecycleTests + 7 WorkoutResumeServiceTests + **9 WorkoutLifecycleServiceTests**). Suite delta from pre-slice: 150 → 159 (+9). No model changes, no UI tests, no schema migrations. Pre-existing `idx` / `block` "never used" warnings at `ActiveWorkoutView.swift:1593-1594` survive (verified against a stashed-baseline rebuild — same warnings appear on the pristine tree, line-number shift only). No active-workout / Finish / Discard / Save & Exit / Resume / draft-store / RestTimer / Live Activity / ActiveWorkoutGuard / history / routine-editing / warmup / dropset / superset / RIR / RPE / tempo behavior changes

**Pending (broader Phase 7 — original coverage gaps; closed at the service layer by 7.6 + 7.7):**

- [ ] Test: session creation snapshots prescription from template slot + stores routineSlotID
- [ ] Test: session edits do not mutate template unless explicit apply action is invoked
- [x] ~~Test: finishing a workout produces immutable history and clears active state~~ — **covered by 7.7 `WorkoutLifecycleServiceTests.testFinishSetsCompletedAt` + `testFinishClearsActiveAppStateFields`** at the service/model layer (the SwiftUI button wiring that invokes the service remains manual-test territory)
- [x] ~~Test: **Save & Exit** preserves the workout as resumable + **Discard** deletes the workout and clears active state~~ — **covered by 7.7 `testSaveAndExitDoesNotCompleteWorkout` + `testSaveAndExitPreservesActiveAppStateFields` + `testDiscardDeletesWorkout` + `testDiscardClearsActiveAppStateFields`** at the service/model layer. The inline `.confirmationDialog` button closures themselves are still SwiftUI surface; the *mutations they perform* are now exhaustively pinned
- [ ] Test (optional): resume active session after app restart with correct position and session plans — *partially covered*: `WorkoutResumeServiceTests` covers the plan-rebuild side; `AppStateLifecycleTests` 5 covers the `activeBlockIndex` / `activeExerciseIndex` / `sessionPlansJSON` round-trip through `AppState`. The end-to-end cold-restart flow (`RootTabView.checkForActiveSession` reading those fields and wiring `ActiveWorkoutGuard.beginSession`) remains view-coupled
- [ ] Test (optional): history grouping by RoutineVariant survives name changes
- [ ] Performance: ensure history grouping is not done expensively in SwiftUI `body`
- [ ] Performance: add lightweight summary fields or caching if needed
- [ ] Performance: audit `resolvedTemplates(in:)` — avoid redundant fetches in list views

Phase 7 is **not closed** — two original coverage items (session-creation snapshot, session-edits-don't-mutate-template), the optional resume / history-grouping tests, and all three performance items remain. 7.6 + 7.7 together close the lifecycle/resume service-and-model contract coverage; what's left is unrelated to lifecycle.

### Phase 8 — Deprecation cleanup

**Completed (Phase 8-A — safe dead-state cleanup + Save & Exit lifecycle fix, 2026-05-20):**

- [x] **Audited `ActiveWorkoutView` for commented-out silent-mutation debris** — none present. `grep` over `ActiveWorkoutView.swift`, `RoutinesView.swift`, `Entities.swift`, and every extracted file under `Log/Main/ActiveWorkout/` + `Log/Main/Routines/` for commented assignments, block comments, and the keywords *apply-back / silent-mut / pre-Phase-2 / formerly / previously* turned up no commented-out code blocks. The two surviving "silent-mutation" mentions (`ActiveWorkoutView.swift:1247` Exercise Notes section header, `Log/Models/SessionPlan.swift:11` type doc) are **live design comments** explaining the *current* no-silent-mutation invariant and were intentionally retained — deletion would obscure why the inline Exercise Notes TextField is read-only and why `SessionPlan` is an in-memory value type rather than a write-back
- [x] **Removed `WorkoutLifecycleState.finished`** — the case was never assigned anywhere in production or tests. Verified by `grep` across `Log/` + `LogTests/` and by `git log -S` pickaxe over `AppState.swift` + `ActiveWorkoutView.swift` (no commit ever introduced an assignment). Workout completion is represented by `Workout.completedAt != nil`, not by a lifecycle-state case. The remaining two-case enum (`.idle`, `.active`) covers every assignment. Backward-compat safe: `WorkoutLifecycleState(rawValue: workoutStateRaw) ?? .idle` already falls back to `.idle` for any unknown raw string, so a device that somehow held a persisted `"finished"` string (none does — pickaxe confirms) degrades gracefully. No migration needed. The `case .idle, .finished:` switch arm in `updateAppState(to:)` (`ActiveWorkoutView.swift:748`) was collapsed to `case .idle:` — semantically identical since Save & Exit / Discard / Finish always passed `.idle`
- [x] **Fixed Save & Exit lifecycle bug** found during Phase 8-A manual testing (pre-existing, introduced by commit `ea32164` on 2026-02-24; **not** caused by the enum cleanup). The Save & Exit button at `ActiveWorkoutView.swift:1448` was incorrectly wired to write `workout?.completedAt = Date()` and call `unlockAndDismiss()`, which made the workout (a) appear as a completed History entry and (b) unresumable (because `unlockAndDismiss()` → `updateAppState(to: .idle)` cleared `AppState.activeWorkoutID` + the `activeGuard` in-memory state). Replaced with a resumable-exit body: `try? ctx.save()` (persists any in-flight workout notes edits) + `dismiss()`. **Nothing else is cleared** — `appState.workoutState` stays `.active`, `appState.activeWorkoutID` stays set, `activeGuard.activePlan` stays bound, rest-timer + Live Activity + scheduled notification keep running, and the `DropWeightDraftStore` / `ParentDraftStore` UserDefaults entries are preserved so unsaved typed input survives. Resume works through both the in-memory path (`RoutinesView` "Active Session — Resume workout" banner gated on `activeGuard.activePlan != nil`, `RoutinesView.swift:105`) and the cold-restart path (`RootTabView.checkForActiveSession` → `WorkoutResumeService.rebuildPlan`, `RootTabView.swift:99-145`)

**Lifecycle semantics (final, post Phase-8-A):**

| Action | Sets `completedAt` | Clears active session | Shows in History | Resumable |
|---|:---:|:---:|:---:|:---:|
| **Save & Exit** (End → Save & Exit) | ✗ | ✗ | ✗ (in-progress only) | ✓ |
| **Discard** (End → Discard) | — (workout deleted) | ✓ | ✗ | ✗ |
| **Finish** (Next past last set → Finish) | ✓ | ✓ | ✓ (completed) | ✗ |

Save & Exit is the "I'll be back" exit; Finish is the "this workout is done" terminus; Discard is the "throw it away" path. All three are exercised by manual lifecycle regression and produce the expected History / Resume-banner / cold-restart behavior.

**Automated regression coverage (added 2026-05-20, see Phase 7.7 / 8-B-lifecycle):** the Save & Exit lifecycle fix is now pinned by `LogTests/WorkoutLifecycleServiceTests.swift` (9 cases covering `saveAndExit` / `finish` / `discard` / `clearActiveAppState` / nil-workout defensive paths). The three SwiftData/AppState mutation primitives were extracted from `ActiveWorkoutView`'s inline button closures into the `@MainActor enum WorkoutLifecycleService` namespace, so any future code change that re-introduces the 8-A bug (Save & Exit writing `completedAt` or clearing `activeWorkoutID`) fails one of the new tests. See the 7.7 entry under Phase 7 for the full slice report.

**Completed (Phase 8-C — dead `Exercise.defaultTemplates` write-back helper removal, 2026-05-20):**

> **Numbering note:** the prior cross-reference under the Phase 8-A lifecycle table labelled the `WorkoutLifecycleService` extraction "Phase 7.7 / 8-B"; this slice is the *second* small Phase 8 cleanup and is filed as **Phase 8-C** to keep the two distinguishable. Both share the Phase-8 "safe dead-state cleanup" spirit; neither is in scope for the broader Phase-8 deprecation items listed below.

- [x] **Removed `ActiveWorkoutView.persistDefaultsOnlyForCurrentExercises()`** (former `L1823-1864`, 42 LOC including its 4-line doc comment). Zero-caller verification: `grep -rn "persistDefaultsOnlyForCurrentExercises" Log/ LogTests/ LogUITests/` returned only the definition line — no production, test, or UI-test reference. The function was a relic of the **pre-Phase-2 silent-mutation era**: it would have read every logged `SetLog`'s `reps` / `weight` / `durationSeconds` and written them back into `ex.defaultTemplates[idx]` for any Exercise still present in the final plan. Reachable from nowhere since the Phase-2 no-silent-mutation rule landed; survived Phase 8-A's debris audit because that pass swept commented-out code, not unreferenced functions. Found and recommended for removal by the **Phase 9 planning audit** (see the "Final recommendation" section of that audit), which also surfaced that defaultTemplates removal cannot proceed without a backfill plan
- [x] **Does NOT remove `Exercise.defaultTemplates`.** The model field stays as-is in `Entities.swift:20-21`. The field remains **load-bearing**: the Exercises-tab editor UI, both `resolvedTemplates` Tier-3 fallbacks (`Entities.swift:560` + `RoutineExercise+Helpers.swift:63-64`), `WorkoutResumeService` cold-restart fallback (`WorkoutResumeService.swift:220`), the mid-workout `swapExercise` path (`ActiveWorkoutView.swift:1952`, post-removal line number), and the superset working-set-count gates (`Routines/RoutineEditor.swift:509-511`, `Routines/ExercisePickers.swift:62`) all continue to read it unchanged. Removal of the model field is **Phase 9 work** and remains blocked on a backfill plan + a TestFlight diagnostic measuring legacy-slot density (see the Phase 9 prelude below)
- [x] **Side benefit — two pre-existing warnings eliminated.** The compiler "value 'idx' was never used" / "value 'block' was never used" warnings reported as pre-existing across Phase 7.7 / 8-B (verified at the time via a stash-rebuild on the un-modified tree) were emitted from inside the dead function's body. They went with it. Production build now emits zero warnings (filtered for non-system / non-deprecation noise)
- [x] **No model changes**, no schema changes, no migrations, no test additions or modifications. View-side behavior preserved exactly: start workout, mid-workout swap, finish/save/discard, resume, history, routine editing, warmup/dropset/superset/rest/RIR/RPE/tempo — all untouched (no live code path crossed the removed function)
- [x] Build green; full suite **159/159 pass in ~1.47s** (composition unchanged from Phase 7.7). Manual smoke test passed

**Pending (broader Phase 8 — defer to a later slice; Phase 8-A, 8-B-lifecycle, and 8-C are intentionally small safety slices):**

- [ ] Deprecate `Workout.routineName` as primary grouping link (keep as display fallback)
- [ ] Evaluate deprecating `RoutineExercise.setTemplates` once prescription adoption is stable
- [ ] Consider migration tool for existing device data cleanup
- [ ] Keep fallback read-only until migration is proven stable across updates

Phase 8 is **not closed** — the four items above remain. The shipped 8-A (lifecycle-bug fix + safe state cleanup), 8-B-lifecycle (`WorkoutLifecycleService` extraction, filed under Phase 7.7), and 8-C (dead `defaultTemplates` write-back helper) sub-slices together close the small-safety subset; the deprecation items above are independent larger work.

### Phase 9 — Remove Exercise.defaultTemplates

Slot prescription becomes the single source of programming intent.

**Status (2026-05-21): planning audits complete; 9-pre regression-pinning tests shipped; 9-A (both 9-A1 service and 9-A2 bootstrap wiring) complete; 9-A.5 pre-9-C loss audit complete (decisions recorded — implementation items still pending); 9-B1 routine-editor `defaultTemplates` read removal complete (commit `bcf7fc9`); 9-B2 ActiveWorkout swap path + 9-C / 9-D / 9-E still pending.** Two audits on 2026-05-20 mapped every read/write of `Exercise.defaultTemplates` and designed the legacy-slot backfill. On 2026-05-21 the 9-pre regression-pinning tests landed (`SlotPrescriptionResolutionTests`, 25 cases, +0 production LOC) — they freeze the current three-tier fallback so the upcoming backfill and 9-C Tier-3 removal cannot silently change resolution behavior. A **second 9-A audit pass on 2026-05-21** refined the exact `SetTemplate → SlotPrescription` field mapping. Later the same day **9-A1** shipped (`BackfillService.hydrateEmptySlotPrescriptions(in:)` + `HydrateEmptySlotPrescriptionsTests`, 16 cases, commit `053ccfe`), followed by **9-A2** (one-line `BootstrapRoot.body.task` wiring + composition test `testBootstrapOrder_HydrateThenVariantIDsLeavesBothStatesConsistent`, commit `5bfee05`; full suite 201/201; manual smoke test passed). The **9-A.5 pre-9-C loss audit on 2026-05-21** then traced `targetWeight` / warmup / dropset / hardcoded-duration-fallback risks across every read site and reached three concrete decisions (see 9-A.5 block below): (1) accept `targetWeight` loss for routine-flow Class-B slots — already silenced by 9-A2 — and gate **9-E** (not 9-C) on a diagnostic measuring at-risk weights; (2) accept warmup/dropset kind loss in the routine flow on the same gate; (3) keep the hardcoded 60s duration fallback and move any `AppSettings.defaultDuration` work to Phase 10. **9-B1 shipped 2026-05-21** (commit `bcf7fc9`): three routine-editor `defaultTemplates` read sites eliminated (`RoutineEditor.appendBlock` superset count gate + its alert state, `RoutineEditor.normalizeRoutineModel` exact-copy comparison now against `prescription.generateTemplates()`, `SupersetPicker` row badge + footer + per-pick validation machinery); full suite 201/201 unchanged; manual smoke passed for superset create/edit and starting workout. **9-B2 is unblocked. 9-C is softly blocked on diagnostic confidence + a deliberate cold-resume fallback rewrite. 9-E is softly blocked on the diagnostic.** Existing legacy slots are hydrated at every launch — idempotent, never mutates Tier 1 or Tier 3 sources. `Exercise.defaultTemplates` and both `resolvedTemplates` Tier-3 arms remain **load-bearing and untouched** at this point — Phase 9-C is the read-removal event, Phase 9-E is the data-deletion event. Headline findings:

- `Exercise.defaultTemplates` is **still load-bearing**, not merely a fallback. Live primary readers include the Exercises-tab editor UI (~17 sites), `RoutineEditor.appendBlock` + `SupersetPicker.setCount` (superset working-set-count gate), `ActiveWorkoutView.swapExercise` (mid-workout swap template seed), `RoutineEditor.normalizeRoutineModel` (exact-copy override detection), and both `resolvedTemplates` Tier-3 fallback arms. Cold-restart resume's last-ditch fallback in `WorkoutResumeService.swift:218-232` also reads it
- **Pre-Phase-3.1 legacy slots** carry a backfilled `SlotPrescription` with all-nil fields (`hasContent == false`) and therefore resolve via Tier 3 today. Removing the field strands those slots with **empty template arrays** unless a backfill ships first
- **9-A audit (backfill design) confirmed the hydration priority order**: when populating an empty `SlotPrescription`, mine first from `RoutineExercise.setTemplates` (Tier 1 explicit overrides), then from `Exercise.defaultTemplates` (Tier 3 — where most legacy user customization lives), and only fall back to `AppSettings` defaults when both are empty. The existing `makeDefaultPrescription` factory is **not sufficient** as the legacy backfill: it reads only `AppSettings`, so using it as-is would silently replace user-customized exercise defaults with generic app defaults. New-slot creation paths (`RoutineEditor.appendBlock`, `SupersetDetailNoRest.addExercise`) already produce content-bearing prescriptions via `makeDefaultPrescription` and don't need changes
- Phase 9 work splits into **five implementation sub-slices** (9-A through 9-E) preceded by three small **pre-9 prep steps** (one of which has shipped): backfill prescription content → eliminate non-Tier-3 reads → remove Tier-3 arms → remove editor UI → drop the model field. Each is independently revertible. At least one app release should sit between 9-A (backfill ship) and 9-C (Tier-3 removal) so the backfill runs on real devices first

**Removal of `Exercise.defaultTemplates` requires a backfill / compatibility plan.** Do not start Phase 9 implementation work without first shipping (a) the regression-pinning tests for both `resolvedTemplates` helpers, and (b) the launch-time backfill that hydrates empty `SlotPrescription` rows from each slot's `setTemplates` → `Exercise.defaultTemplates` → `AppSettings` defaults.

**Sub-slice roadmap (all implementation work pending):**

**Pre-9 prep:**

- [x] **9-pre cleanup (shipped as Phase 8-C, 2026-05-20):** Removed dead `persistDefaultsOnlyForCurrentExercises` write-back helper — see Phase 8-C entry above. Confirmed zero callers; eliminated the only active-workout write path into `Exercise.defaultTemplates`
- [x] **9-pre tests (shipped 2026-05-21):** Added `LogTests/SlotPrescriptionResolutionTests.swift` (25 cases on `SwiftDataTestHarness`, 0 production LOC) pinning the three-tier order for **both** helpers (`Entities.swift:547 resolvedTemplates()` and `RoutineExercise+Helpers.swift:43 resolvedTemplates(in: ctx)`): Tier 1 wins over Tier 2 + Tier 3; Tier 1 preserves `order` and (on the `(in: ctx)` variant) renormalizes duplicate/out-of-range orders; Tier 2 fires when `prescription.hasContent` is true; Tier 2 produces correct rep-based **and** time-based templates; **Tier 3 fires both when prescription is nil AND when prescription exists but `hasContent == false`** (the legacy-slot gap 9-A must backfill); Tier 3 preserves `order`; all-empty returns `[]`; nil-`exercise` slot returns `[]`. Also pins the building blocks (`SlotPrescription.hasContent` truth table; `generateTemplates()` count clamp + repMax/repMin/8 and durationMax/durationMin/60 precedence rules). **Bonus:** added the previously-uncovered `WorkoutResumeService.planFromWorkoutItems` defaults-fallback case (no logs + no `PlannedPrescriptionSnapshot` → `Exercise.defaultTemplates`), and the superset working-set-count rule used by `SupersetPicker.setCount(for:)` (private to the View, so the underlying `defaultTemplates.filter { .working }.count` is pinned instead). Full suite: 184/184 passing (was 159). **9-C may now touch either `resolvedTemplates` helper** with this regression net in place; 9-C's own checklist still requires updating these tests once Tier 3 is removed
- [ ] **9-pre diagnostic — recommended before 9-C, REQUIRED before 9-E (TestFlight only, no UI, no AppState field, no production behavior change):** one-shot `os.Logger` count at `BootstrapRoot.body.task` of:
  - (a) `RoutineExercise` rows with `prescription == nil` post-`backfillPhase3_1` AND post-`hydrateEmptySlotPrescriptions` (should be zero — non-zero signals the 9-A2 backfill missed a case)
  - (b) rows with `prescription?.hasContent == false` after both backfills (same — should be zero)
  - (c) **9-A.5 weight loss metric:** `Exercise.defaultTemplates` rows where `targetWeight != nil AND > 0`, broken down by whether the parent `Exercise` is referenced by at least one `RoutineExercise` with empty `setTemplates` (the at-risk Class-B population)
  - (d) **9-A.5 warmup/dropset loss metric:** `Exercise.defaultTemplates` rows where `kind != .working`, broken down by the same at-risk-Class-B filter
  - **Promotion rationale:** the 9-A.5 audit (2026-05-21) elevated this from "optional helper for 9-A" to "load-bearing for 9-E" — counters (c) and (d) are the inputs to the pre-9-E one-shot migration decision. Counters (a) and (b) validate 9-A2's hydration completeness, which is the implicit input to 9-C's "no slot is stranded" guarantee
  - Ship + observe for one release. Remove the logger in the same PR as 9-E (or earlier if all counters are stable at zero / negligible). **9-C may proceed without this** if 9-A2 monitoring otherwise suggests the hydration is complete; **9-E MAY NOT proceed without it** because the migration-vs-accept decision for (c) and (d) requires real numbers

**9-A — Backfill empty `SlotPrescription` content (✅ complete — 9-A1 service shipped 2026-05-21, 9-A2 bootstrap wiring shipped 2026-05-21):**

**9-A1 — Hydration service + tests (shipped 2026-05-21, commit `053ccfe`):**

- [x] Added `BackfillService.hydrateEmptySlotPrescriptions(in: ctx)` (`Log/Services/BackfillService.swift`) — sibling of the existing `backfillRoutineVariantIDs(in:)`. Walks every `RoutineExercise` whose `prescription?.hasContent == false`. **Hydration priority (per 9-A audit):** (1) mine from `re.setTemplates` if non-empty (Tier 1); (2) else from `re.exercise?.defaultTemplates` (Tier 3 — typical legacy data); (3) else fall back to `AppSettings.defaultSets` / `defaultRepMin` / `defaultRepMax` / `defaultRestBetweenSets`. **Critical:** `makeDefaultPrescription` was deliberately not reused — it skips the Tier 1 → Tier 3 mining and would silently overwrite user customization, and reusing it would entangle new-slot defaults with migration behavior. Mapping factored into a private `hydrate(_ p: SlotPrescription, from re: RoutineExercise)` pure helper
- [x] **Field mapping implemented as specified (per 2026-05-21 audit refinement)** — given a non-empty source `[SetTemplate]` and the slot's `exercise.isTimeBased`:
  - `working = source.filter { $0.kind == .working }.sorted { $0.order < $1.order }` (warmup and dropset rows do NOT contribute to `sets`)
  - `p.usesDuration = re.exercise?.isTimeBased ?? false` (Exercise owns its mode; nil-exercise defaults to rep-based)
  - **Rep-based** (`!usesDuration`): `p.repMin / p.repMax` = min/max of working `targetReps > 0`; both nil → AppSettings fallback (`defaultRepMin` / `defaultRepMax`)
  - **Time-based** (`usesDuration`): `p.durationMinSeconds / p.durationMaxSeconds` = min/max of working `durationSeconds > 0`; both nil → hardcoded **60s** (no `AppSettings.defaultDuration` exists today — see 9-A.5)
  - `p.sets = max(1, working.count)` when `working` non-empty, else `AppSettings.defaultSets`
  - `p.restSecondsBetweenSets = working.compactMap(\.restSecondsAfter).first { $0 > 0 } ?? AppSettings.defaultRestBetweenSets` (first positive — avoids locking to a longer late-set rest)
  - `p.restSecondsAfterExercise` set only when **`source.isEmpty` AND `AppSettings.defaultRestAfterExercise > 0`** (full AppSettings fallback path)
  - **Never mined**: `rir` / `rpe` / `tempo` (templates carry no autoreg; adding values the user never set would be a behavior change). Deliberate divergence from `makeDefaultPrescription`
  - **Never synthesized in 9-A**: `warmupScheme` and `techniquePlans`. See 9-A.5 audit below
- [x] Idempotency: `hasContent` guard at the top short-circuits already-populated slots; second-run is a verified no-op (test `testIdempotentSecondRunNoChange`)
- [x] Overwrite-safety: never modifies a prescription where `hasContent == true`; never touches `re.setTemplates`; never touches `Exercise.defaultTemplates`; single `try? ctx.save()` at end, gated by a `dirty` flag (mirrors `backfillRoutineVariantIDs`)
- [x] Defensive `prescription == nil` branch: creates a `SlotPrescription`, inserts, attaches to slot, then hydrates. Pinned by `testCreatesPrescriptionIfNil` so the branch cannot silently drift if `backfillPhase3_1` is ever retired
- [x] Added `LogTests/HydrateEmptySlotPrescriptionsTests.swift` — **16 cases on `SwiftDataTestHarness`** (one over the original 15-case spec; the extra is the golden behavior preservation case below):
  - hydrates from Tier 1 setTemplates (rep-based)
  - hydrates from Tier 1 setTemplates (time-based, `isTimeBased=true`)
  - hydrates from Tier 3 defaultTemplates (rep-based)
  - hydrates from Tier 3 defaultTemplates (time-based)
  - Tier 1 wins over Tier 3 when both present
  - AppSettings fallback when all sources empty (`sets=3`, `repMin=8`, `repMax=12`, `restSecondsBetweenSets=90`)
  - skip when `prescription.hasContent == true` (object identity AND value contents preserved)
  - idempotent: second run produces zero state change
  - working-set filter ignores warmup / dropset rows when computing `sets`
  - first positive `restSecondsAfter` wins for `restSecondsBetweenSets`
  - create-if-nil: `prescription == nil` → creates one and hydrates
  - nil `exercise` slot with empty `setTemplates` → falls to AppSettings (rep-based)
  - never mutates `re.setTemplates` (canonical sort by `.order`, then field-by-field equality — SwiftData `@Relationship` arrays don't preserve `PersistentModel` identity or iteration order across `context.save()`, so `===` was dropped during the slice in favor of value equality)
  - never mutates `re.exercise?.defaultTemplates` (same comparator)
  - superset slots hydrate independently (Tier 1 slot + Tier 3 slot in same block, no bleed)
- [x] **Golden behavior preservation test**: for a Class-B legacy slot (`hasContent == false`, `setTemplates` empty, uniform `defaultTemplates` non-empty), `resolvedTemplates(in: ctx)` returns matching templates before vs. after backfill on `kind` + `targetReps` + `restSecondsAfter`. `targetWeight` is intentionally excluded — it has no `SlotPrescription` landing field, and is the explicit gap the 9-A.5 audit must address before Tier 3 is removed in 9-C

**9-A2 — Bootstrap wiring (shipped 2026-05-21, commit `5bfee05`):**

- [x] Wired `BackfillService.hydrateEmptySlotPrescriptions(in: ctx)` into `BootstrapRoot.body.task` immediately after `backfillPhase3_1()`. **Final bootstrap order:** `backfillPhase1()` → `backfillPhase3_1()` → `BackfillService.hydrateEmptySlotPrescriptions(in: ctx)` → `BackfillService.backfillRoutineVariantIDs(in: ctx)` → `validateActiveSession()`. The new call is purely interstitial — every existing step runs at its original relative position; the splash-duration minimum and UI-test data-reset paths are untouched. Doc comment in `BootstrapRoot.swift` documents why the placement is load-bearing (post-3.1 so the defensive create-if-nil branch is normally cold; pre-variantIDs is cosmetic — the two services touch disjoint entity surfaces and are functionally order-independent)
- [x] Added `BackfillServiceTests.testBootstrapOrder_HydrateThenVariantIDsLeavesBothStatesConsistent` (~50 LOC composition test) — builds a representative legacy store (Class-B slot with empty `SlotPrescription`, unlinked `Workout`, `Routine` with one `RoutineVariant`), runs the two `BackfillService` entry points in the documented order, asserts both states (slot now content-bearing from `Exercise.defaultTemplates`, workout linked to `Default` variant) plus second-run idempotency. The dedicated `BootstrapRoot.body.task` is intentionally NOT tested directly: it lives in a SwiftUI `.task` and calls private instance methods that would require View instantiation; the composition test + per-service unit tests cover every callable surface, leaving "did the one-line wiring call the right function in the right place" verified by the build + the 11-line diff
- [x] **Shipped 9-A2 standalone** as designed: 1-line production change (+ 8-line doc comment) + 1 composition test. No diagnostic, no reader changes, no UI removal bundled. Full suite 201/201 (was 200; +1). Tier 3 remains intact through 9-C, so a missed slot is still not a regression

**9-A.5 — Pre-9-C loss audit (✅ decisions recorded 2026-05-21; diagnostic + migration items remain pending):**

The audit traced every read site for `SetTemplate.targetWeight`, `kind != .working` rows in `Exercise.defaultTemplates`, and the time-based duration fallback hardcoded by 9-A. Key finding: **9-A2 has already silenced most routine-flow Tier-3 surfacing for Class-B legacy slots** (the slots whose `setTemplates` is empty AND whose `prescription.hasContent` was false at bootstrap), because the hydrated prescription's `generateTemplates()` only emits `.working` rows with `targetWeight: nil`. The data on disk is intact through 9-D; the regression is a silent loss of *surface*, not of storage. Recorded decisions:

- [x] **`targetWeight` — accept routine-flow loss, do not add `SlotPrescription.targetWeight`.** Per-set weights are not a "prescription" concept (one value per slot vs. one per set), so a schema addition would only solve the uniform-weight case. The remaining at-risk paths are: (a) routine-flow Class-B slots — already silenced by 9-A2, no further action; (b) `ActiveWorkoutView.swapExercise` mid-workout swap — handled by 9-B2; (c) `WorkoutResumeService.planFromWorkoutItems` orphan fallback (`WorkoutResumeService.swift:218-232`) — handled by 9-C's deliberate fallback rewrite. **9-E (data deletion) gates on a diagnostic measuring at-risk weights**; if the population is non-trivial, ship a one-shot pre-9-E migration that copies `defaults[i].targetWeight` into a fresh `re.setTemplates[i]` row so Tier 1 carries the value across the field deletion
- [x] **Warmup / dropset kind loss — accept routine-flow loss, do not synthesize `WarmupScheme` / `TechniquePlan` from `SetTemplate` rows.** The current authoring path for per-slot warmup and techniques is `WarmupSchemeEditor` / `TechniquePlanEditor` writing directly to `SlotPrescription.warmupScheme` / `techniquePlans`; the `Exercise.defaultTemplates` kind picker (`ExercisesView.swift:840-851`) is a vestigial authoring path the new editor doesn't expose. Like `targetWeight`, the routine-flow surface for these rows was silenced by 9-A2. **9-C's cold-resume fallback rewrite must be deliberate** about not carrying warmup/dropset rows from `defaultTemplates` (seed from `PlannedPrescriptionSnapshot` only). **9-E gates on the same diagnostic** counting `kind != .working` rows; if non-trivial, the 9-E pre-flight migration can also copy them into `re.setTemplates` for at-risk slots (or accept the loss and document in release notes)
- [x] **Hardcoded 60s duration fallback — keep; defer `AppSettings.defaultDurationSeconds` indefinitely.** The fallback in `BackfillService.hydrate(_:from:)` matches `SlotPrescription.generateTemplates()`'s internal 60s fallback at `Entities.swift:517`, so the two compose consistently. The fallback fires only on first hydration of a Class-D time-based slot with no source data (exotic); thereafter `hasContent == true` short-circuits it. Adding a setting would need a Settings-tab UI to be discoverable; better scoped as Phase 10 polish alongside the existing Exercise UI work. **Blocks nothing in Phase 9**
- [x] **Audit decision summary** (recorded for 9-B / 9-C / 9-E gating):
  - **9-B is unblocked** by this audit
  - **9-C is softly blocked** on (a) the optional 9-pre diagnostic running clean (zero residual empty-content slots post-hydration) AND (b) the cold-resume fallback rewrite being deliberate about not carrying warmup/dropset kinds
  - **9-E is softly blocked** on the diagnostic counts for at-risk `targetWeight` and at-risk non-working-kind rows being non-trivial — if either is, ship a pre-9-E one-shot migration first
  - **No model changes required** before 9-B (no new fields on `SlotPrescription`, no new `AppSettings` keys)

**9-B — Eliminate non-Tier-3 reads of `defaultTemplates` (9-B1 routine-editor reads ✅ shipped 2026-05-21; 9-B2 ActiveWorkout swap path still pending):**

**9-B1 — Routine-editor reads (shipped 2026-05-21, commit `bcf7fc9`):**

- [x] **`RoutineEditor.appendBlock` superset count gate** — removed entirely (along with its `showSupersetCountAlert` / `supersetCountMessage` `@State` and the alert presentation modifier). Pre-slice considered replacing `ex.defaultTemplates.filter { .working }.count` with `(slot.prescription?.sets ?? AppSettings.defaultSets)`, but at superset-create time no `RoutineExercise` exists for the candidates, so the only honest replacement value is `AppSettings.defaultSets` uniformly — the matching-counts check would be trivially true for every selection. Per the 9-A.5 audit's authoring-guardrail-loss acknowledgement, the gate was deleted rather than replaced with a vacuous test. New superset slots still receive AppSettings-derived prescription via `makeDefaultPrescription` (existing code below the removed gate), so created supersets have uniform working-set counts by construction
- [x] **`SupersetPicker` row badge + footer + per-pick validation machinery** — removed (`setCount(for:)`, `isCompatible(_:)`, `refSetCount` state, the "×N" row badge, the matching-counts footer Section, and the togglePick guard-and-set logic). Same rationale as `appendBlock`: every row would show the same constant, every pick would validate, every footer would be vacuously true. `togglePick` collapsed to plain add/remove on the `picked` set; picker now lets users select any combination
- [x] **`RoutineEditor.normalizeRoutineModel` exact-copy detection** — replaced `ex.defaultTemplates` (Tier 3) comparison with `re.prescription?.generateTemplates()` (Tier 2) comparison, gated by `prescription.hasContent`. The "clear redundant overrides" UX still fires, just against the new canonical "what would Tier 2 produce" baseline. Field-by-field semantics preserved (`kind` / `targetReps` / `targetWeight` / `restSecondsAfter` / `durationSeconds`); the `hasContent` gate ensures we never strip a slot's only template source if the prescription is somehow empty (defensive — should not happen post-9-A2)
- [x] **No tests added — rationale recorded.** The 9-A.5 audit speculatively suggested `LogTests/SupersetCountGateTests.swift`. When actually writing them, all three target sites are private methods on SwiftUI View structs (`RoutineEditor.appendBlock`, `RoutineEditor.normalizeRoutineModel`, `SupersetPicker.togglePick`) — not callable from XCTest without instantiating the View, and there is no existing precedent for that in this codebase. The two practical options were: (a) refactor first — extract the exact-copy comparison into a pure helper and test that, adding ~30 LOC of extraction + ~50 LOC of tests for a slice whose actual production change is "delete vacuous code + swap one comparison" (poor cost/coverage ratio); or (b) skip tests, document the rationale, lean on the full suite (201/201 unchanged) + manual smoke. Chose (b). If 9-B2 extracts a comparable helper for its swap-defaults test, the exact-copy comparator can be folded into that slice's target retroactively
- [x] **Shipped 9-B1 standalone as designed.** Net diff: 2 files (`Log/Main/Routines/RoutineEditor.swift`, `Log/Main/Routines/ExercisePickers.swift`); 3 `defaultTemplates` read sites eliminated from routine-editor scope; `grep -rn "defaultTemplates" Log/Main/Routines/` now returns zero matches. `Exercise.defaultTemplates` and both `resolvedTemplates` Tier-3 arms remain intact. Remaining production `defaultTemplates` reads live only in `ExercisesView` (9-D target), `ActiveWorkoutView.swapExercise` (9-B2 target), and `WorkoutResumeService.planFromWorkoutItems` (9-C target)

**9-B2 — ActiveWorkout swap path:**

- [ ] `ActiveWorkoutView.swapExercise` (`~L1908`): replace the `newEx.defaultTemplates.sorted...map` template-seed block. The swapped-in exercise typically doesn't have a `RoutineExercise` for this slot yet (the slot belongs to the routine, not to `newEx`), so the rewrite likely sources defaults from `makeDefaultPrescription(isTimeBased: newEx.isTimeBased, in:)` semantics: `sets=AppSettings.defaultSets`, `repMin/repMax=AppSettings.defaultRepMin/Max`, `restSecondsBetweenSets=AppSettings.defaultRestBetweenSets`, no `targetWeight` (audit recorded this loss as accepted)
- [ ] Pin the new swap-defaults behavior with a focused test (extend `ActiveWorkout`-adjacent tests or add a new one): swapping in an Exercise with non-empty `defaultTemplates` produces a PlanExercise whose templates derive from `AppSettings` defaults, NOT from `newEx.defaultTemplates`. Specifically assert `targetWeight == nil` so the audit's documented loss is enforced as the new contract
- [ ] Manual regression: swap mid-workout into a previously-unused exercise and verify the set list renders with the expected default count + rest; weight column is blank until the user enters a value; subsequent suggestions come from logged-history paths as before
- [ ] **Ship 9-B2 standalone.** Higher-risk than 9-B1 because the swap path is user-facing and the `targetWeight` change is the most visible 9-A.5 consequence. Tier 3 in `resolvedTemplates` is still intact, so swap-back to the routine slot's original exercise still resolves via prescription / Tier 1; nothing else regresses

**9-C — Remove Tier 3 from `resolvedTemplates` + resume fallback:**

- [ ] Strip the Tier 3 arm from `Entities.swift:547 RoutineExercise.resolvedTemplates()` and `RoutineExercise+Helpers.swift:43 resolvedTemplates(in: ctx)`. Both functions return `[]` for the formerly-Tier-3 case
- [ ] Update `WorkoutResumeService.swift:218-232` last-ditch fallback (item has no logs AND no `plannedPrescriptionSnapshot`): seed from `PrescriptionSnapshotPayload` only, or return empty templates that the active workout UI then prompts the user to fill via "Unprogrammed slot" UX
- [ ] Add "Unprogrammed slot" UX in routine editor (clear visual state + quick-fill buttons like "3×8", "5×5") for slots that somehow end up empty post-9-A (should be zero, but defend against it)
- [ ] Update `SlotPrescriptionResolutionTests` (added in 9-pre tests) to remove the Tier-3 positive cases and add negative tests pinning that the formerly-Tier-3 branch now returns empty
- [ ] **Gating (per 9-A.5 audit):** requires 9-A to have shipped on TestFlight for at least one release so the backfill has hydrated real-user legacy slots before this slice strands them; AND requires 9-B (both 9-B1 and 9-B2) shipped so no non-Tier-3 read site still depends on `Exercise.defaultTemplates`. The 9-pre diagnostic is **recommended but not strictly required** before 9-C — its counters (a) and (b) (residual empty-content slots post-hydration) would catch a missed Class-B slot, but if other monitoring suggests the hydration is complete, 9-C can proceed. If the diagnostic IS available and counters (a)/(b) are non-zero, **block 9-C until the backfill is fixed**
- [ ] **Cold-resume fallback rewrite must be deliberate** (per 9-A.5 audit): when updating `WorkoutResumeService.swift:218-232`, seed templates from `PlannedPrescriptionSnapshot` only — do NOT carry `kind != .working` rows from `Exercise.defaultTemplates`. The audit recorded this loss as accepted; the test for this branch should pin that warmup/dropset rows are absent from the resumed plan so the contract is enforced

**9-D — Remove the Exercise-tab defaults editor UI:**

- [ ] Strip the entire `Sets` section from `ExercisesView.ExerciseDetailView` (~17 read+write sites, ~200 LOC): the SwiftUI Sets list + `sanitizeTemplates` + `normalizeTemplateOrderIfNeeded` + `normalizeTemplatesForMode` + `sortedTemplates` + `moveTemplates` + `resetSetOrder` + the "Add Set" button block
- [ ] Reframe `ExerciseDetailView` to edit only `name` / `bodyPart` / `notes` / `isTimeBased`. Phase 10 may add equipment/setup fields later
- [ ] Optional: replace the Sets section with a read-only "Used in N routines" summary
- [ ] Manual regression: open any exercise, verify editor shows only the retained fields and saves cleanly

**9-E — Drop the model field + cleanup orphan `SetTemplate` rows:**

- [ ] **REQUIRED pre-flight (per 9-A.5 audit):** the 9-pre diagnostic must have shipped on TestFlight and reported counters (c) `targetWeight`-bearing `defaultTemplates` rows in at-risk slots and (d) non-working `defaultTemplates` rows in at-risk slots. Based on the numbers:
  - If both counters are negligible → proceed directly with field deletion; document the loss in release notes
  - If counter (c) is non-trivial → ship a one-shot pre-flight migration that copies `Exercise.defaultTemplates[i].targetWeight` into a fresh `re.setTemplates[i]` row for each at-risk `RoutineExercise` so Tier 1 carries the weight across the field deletion. The migration must run BEFORE the field deletion in the same release (or, safer, in the release immediately before 9-E)
  - If counter (d) is non-trivial → the same migration can also copy `kind != .working` rows into `re.setTemplates`, OR accept the loss and release-note it
  - **Do NOT proceed with field deletion until this decision is made on real numbers**
- [ ] Delete `@Relationship(deleteRule: .cascade) var defaultTemplates: [SetTemplate] = []` from `Entities.swift:20-21 Exercise`. SwiftData lightweight migration drops the field
- [ ] Add a one-shot orphan-`SetTemplate` sweep in `BootstrapRoot.body.task` that deletes any `SetTemplate` no longer referenced by any `RoutineExercise.setTemplates`. Idempotent (runs every launch but no-ops once the orphans are gone)
- [ ] Verify `SetTemplate` model itself stays — still used by `RoutineExercise.setTemplates` (Tier 1)
- [ ] Update `SwiftDataTestHarness.swift` `Schema` list if needed (no entity removal required since `SetTemplate` stays; re-verify ordering)
- [ ] Add migration acceptance test verifying old data + new schema produces zero orphan `SetTemplate` rows after the sweep
- [ ] Final cumulative manual regression: full app smoke on a clean install + an upgrade-from-pre-9-A install + an upgrade-skipping-versions install
- [ ] Remove the 9-pre diagnostic logger in this same PR (its job is done once the field is gone)

Phase 9 is **not closed** — 9-B2 / 9-C / 9-D / 9-E are still pending. Shipped so far: pre-9 cleanup (8-C), 9-pre regression tests, **9-A** in full (9-A1 hydration service + 9-A2 bootstrap wiring), **9-A.5 audit decisions** (planning), and **9-B1** routine-editor `defaultTemplates` read removal. Sub-slices are independently revertible. Recommended ship spacing: **9-pre tests** ✅ → **9-pre diagnostic** (TestFlight; recommended before 9-C, REQUIRED before 9-E) → **9-A1** ✅ → **9-A2** ✅ → **9-A.5 audit decisions** ✅ → **9-B1** ✅ → **9-B2** (ActiveWorkout swap path) → release gap + observe diagnostic → **9-C** → **9-D** → **9-E pre-flight migration decision** (gated on diagnostic counters c/d) → **9-E field deletion**.

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

`ActiveWorkoutView.swift` (started at ~3,850 LOC) and `RoutinesView.swift` (~2,540 LOC) had grown to hold multiple concerns each. Phase 11 splits them into focused subview / helper / model / utility files in a **strictly behavior-preserving** refactor.

**Phase 11 ground rules — every slice:**

- **Move code only.** No logic changes, no model-schema changes, no rest-planning changes, no routine-editing-flow changes. If a slice would require a logic edit to compile, stop and re-scope.
- **Preserve type names and public APIs.** Access levels stay `private` unless a cross-file consumer requires module-internal — in which case the bump from `private` / `fileprivate` to default-internal is the only permitted access change, and it's called out explicitly in the slice's report.
- **Build + tests required after every slice.** `xcodebuild build` must succeed; `xcodebuild test` must report `115/115 pass` (or the post-slice equivalent; no test edits unless an `@testable` symbol's visibility shifts).
- **Manual smoke test required** when an `ActiveWorkoutView` or `RoutinesView` UI surface is touched — launch app, exercise the affected flow end-to-end (start workout, log a set, edit a routine, etc.).
- **Volatile internals stay put.** The body of `ActiveWorkoutView` and its `@ViewBuilder` methods that capture `@State` are deferred to Phase 12 (MVVM / viewmodel) — see the "Deferred to Phase 12" subsection below.

**Completed (11.1 — top-level active-workout support type lift):**

- [x] `ActiveWorkoutGuard` (`@MainActor final class … : ObservableObject`, ~80 LOC) lifted from `Log/Main/ActiveWorkoutView.swift` to `Log/Services/ActiveWorkoutGuard.swift`. Singleton (`static let shared`), `@MainActor` isolation, every `@Published` property (`lockedExerciseIDs`, `lockedRoutineIDs`, `activePlan`, `activeWorkoutID`, `sessionStart`, `inputsCache`, `loggedCache`), every lock helper (`lockExercises`, `unlockExercises`, `isLocked`, `lockRoutine`, `unlockRoutine`, `isRoutineLocked`), and the lifecycle helpers (`beginSession(plan:)`, `endSession()`) preserved verbatim. Singleton identity guaranteed because `static let` is statically initialized once per module per process; relocation is invisible to callers
- [x] `SessionPlan` (`Codable` value type, ~77 LOC) lifted from `Log/Main/ActiveWorkoutView.swift` to `Log/Models/SessionPlan.swift`. All 12 stored properties, both initializers (`init()`, `init(from snapshot: PrescriptionSnapshotPayload, notes: String?)`), `primarySummary`, and `secondarySummary(autoregMode:)` preserved verbatim. Codable conformance remains synthesized — on-disk encoding via `AppState` round-trips unchanged
- [x] `Collection.safe` subscript lifted from `Log/Main/ActiveWorkoutView.swift` to `Log/Utilities/Collection+Safe.swift`. **Access changed**: `fileprivate subscript(safe:)` → default-internal `subscript(safe:)`. The single permitted access bump per the Phase 11 rules; required because the extension now lives in a separate file. Body (`indices.contains(i) ? self[i] : nil`) unchanged; all 10+ existing call sites in `ActiveWorkoutView.swift` (`plan.blocks[safe:]`, `block.exercises[safe:]`, `templates[safe:]`, etc.) resolve to the relocated extension via module-wide lookup
- [x] **New folder `Log/Utilities/` created** under the `Log` `PBXFileSystemSynchronizedRootGroup` — auto-discovered by the build, no `project.pbxproj` edit needed (matches the pattern used by every Services / Models addition since Phase 7). A bridge comment was added to `ActiveWorkoutView.swift`'s top mapping each lifted type to its new file, so the source remains self-documenting
- [x] **No behavior changes**: `ActiveWorkoutView` body / build methods / persistence flows / SwiftData models / `RestPlanner` / draft stores / `RoutinesView` / `ExercisesView` / `HistoryView` all untouched. Build green; full XCTest suite **115/115 pass in ~0.63s** (composition unchanged from pre-slice). `ActiveWorkoutView.swift` line count: **3,849 → 3,695 (−154)**. The three new files together carry 89 + 92 + 14 = 195 LOC — slightly more than the deletion delta because of per-file imports + doc-comments, paid once

**Completed (11.2 — Routines pass 1: pickers + warmup editor + prescription fields):**

- [x] Extracted `ExercisePickerSingle` + `SupersetPicker` (151 LOC after per-file imports) to `Log/Main/Routines/ExercisePickers.swift`. `SupersetPicker` bumped from `private` → default-internal so `RoutineEditor` (still in `RoutinesView.swift` until 11.5) can present it across files. `ExercisePickerSingle` was already default-internal (also consumed by `ActiveWorkoutView.swift` for the in-workout swap flow)
- [x] Extracted `WarmupSchemeEditor` + `WarmupStepRow` + `WarmupStepEditSheet` (231 LOC) to `Log/Main/Routines/WarmupSchemeEditor.swift`. `WarmupSchemeEditor` bumped from `private` → default-internal so `SlotPrescriptionSection` (now in `PrescriptionFields.swift`) can navigate to it via `NavigationLink`. `WarmupStepRow` + `WarmupStepEditSheet` remain `private` — used only within `WarmupSchemeEditor.swift`
- [x] Extracted `SlotPrescriptionSection` + `PrescriptionFields` + `TempoEditorView` + the `makeDefaultPrescription` factory (277 LOC after co-location) to `Log/Main/Routines/PrescriptionFields.swift`. `SlotPrescriptionSection` bumped from `private` → default-internal (called by `RoutineBlockDetailView` + `SupersetDetailNoRest` still in `RoutinesView.swift`). `makeDefaultPrescription` bumped from `fileprivate` → default-internal as the audit anticipated (called by `RoutineEditor.appendBlock` + `SupersetDetailNoRest.addExercise` still in `RoutinesView.swift`, plus `SlotPrescriptionSection.ensurePrescription` now in the new file). `PrescriptionFields` stays `private` (used only by `SlotPrescriptionSection` in the same file); `TempoEditorView` was already default-internal (also consumed by `ActiveWorkoutView.swift` for the session-plan editor)
- [x] **One unplanned access bump** beyond the audit's "only access change in this slice" line: `TechniquePlanEditor` (still in `RoutinesView.swift` until 11.3) bumped from `private` → default-internal because `SlotPrescriptionSection` (now in `PrescriptionFields.swift`) navigates to it via `NavigationLink`. A bridge comment was added at the declaration explaining the temporary cross-file dependency until 11.3 ships
- [x] **Actual `RoutinesView.swift` reduction: 2,543 → 1,896 LOC (−647 LOC, −25%)** — slightly better than the ~1,940 estimate. The three new files together carry 151 + 231 + 277 = 659 LOC, ~12 LOC more than the deletion delta because of per-file `import SwiftData` / `import SwiftUI` + MARK headers, paid once
- [x] **No behavior changes**: `RoutineEditor` body + `RoutineBlockDetailView` + `SupersetDetailNoRest` + locked-routine `.disabled(isLocked)` cascade + superset add/remove/reorder + save flows + all initializer signatures preserved verbatim. Build green; full XCTest suite **115/115 pass in ~0.68s** (composition unchanged from pre-slice). Pre-existing `moveSteps` warning ("value 'scheme' was defined but never used" inside `WarmupSchemeEditor.moveSteps`) confirmed present in `HEAD:Log/Main/RoutinesView.swift:1448-1454` of the pre-slice tree — preserved byte-for-byte
- [x] Manual smoke (passed): opened routine editor → Add Exercise → Add Superset → edited prescription fields on a normal block → opened warmup editor → added/edited/reordered/deleted steps → re-opened superset and confirmed per-exercise `SlotPrescriptionSection` rows still render with `hideSetsField` + `hideRestFields`

**Completed (11.3 — Routines pass 2: technique editor + block detail views + model helpers):**

- [x] Extracted `TechniquePlanEditor` + `TechniquePlanRow` + `TechniqueTypePickerSheet` + `TechniqueParamEditView` (598 LOC after per-file imports — the biggest single move in Phase 11) to `Log/Main/Routines/TechniquePlanEditor.swift`. `TechniquePlanEditor` is the one declaration already bumped to default-internal in 11.2 (it had a Phase-11.2 bridge comment explaining the temporary cross-file dependency); that comment was simplified post-move because the declaration is now permanently cross-file by design. `TechniquePlanRow`, `TechniqueTypePickerSheet`, and `TechniqueParamEditView` remain `private` — used only inside the new file
- [x] Extracted `RoutineBlockDetailView` + `SupersetDetailNoRest` (346 LOC) to `Log/Main/Routines/BlockDetailViews.swift`. Both bumped from `private` → default-internal because `RoutineEditor.blockRowView(for:)` (still in `RoutinesView.swift` until 11.5) instantiates them from another file. Locked-routine plumbing (`isRoutineLocked` on both, `SupersetDetailNoRest`'s per-control `.disabled` / `.moveDisabled` / `.deleteDisabled` cascade, the inline comment about not wrapping the List body in `.disabled` because it would block iOS scroll, the load-bearing `block.exercises = survivors` detachment, and the min-2-exercises alert + tombstone-cascade documentation) all moved byte-for-byte
- [x] Extracted `extension RoutineExercise { safeExercise(in:), normalizeOrderIfNeeded(_:) [private], resolvedTemplates(in:) }` (71 LOC) to `Log/Models/RoutineExercise+Helpers.swift`. `safeExercise(in:)` and `resolvedTemplates(in:)` were already module-internal; cross-file callers in `ExercisesView.swift`, `StartWorkoutFromRoutineView.swift`, `WorkoutResumeService.swift`, and the relocated `BlockDetailViews.swift` resolve via module-wide lookup, unchanged. The three-tier resolution order (Tier 1 explicit `setTemplates` → Tier 2 `prescription.generateTemplates()` → Tier 3 `Exercise.defaultTemplates`) is preserved verbatim, as is `normalizeOrderIfNeeded`'s order-stable repair plus `try? ctx.save()` write-back
- [x] **One required import correction caught by the build**: the new helpers file needs `import Foundation` (not just `import SwiftData`) because `safeExercise(in:)` uses the `#Predicate` macro, which lives in `Foundation` even though the rest of the file lives in `SwiftData`-land. The original `Entities.swift` carries both imports; the helpers file now matches. Build failed first with `no macro named 'Predicate'`, fixed, then green
- [x] **`BlockRow` + `LockBadge` (~40 LOC) intentionally left in `RoutinesView.swift`** — the planned `Log/Main/Routines/BlockRow.swift` was attempted, but Swift rejects top-level type-name collisions across files regardless of access level. `ExercisesView.swift` already declares a file-private `LockBadge` with `.font(.dsCaption.weight(.semibold))`; the `RoutinesView` version uses `.font(.caption2.weight(.semibold))`. The two badges are visually distinct **by design** (different caption sizes in different list densities) and must not be merged. Promoting either to default-internal yields `invalid redeclaration of 'LockBadge'` at compile time — verified empirically on this slice. Resolving this requires either a rename of one of the two `LockBadge`s (out of scope for behavior-preserving file-decomposition) or a redesign-style decision to unify the two badge variants (UI redesign — explicitly forbidden by the slice ground rules). A documentation comment was added to `RoutinesView.swift` at the badge declaration explaining the deferral. **The `BlockRow` + `LockBadge` extraction is now a Phase-11 deferred item** — see the "Deferred badge cleanup" subsection below
- [x] **Actual `RoutinesView.swift` reduction: 1,896 → 913 LOC (−983 LOC, −52% on this slice; cumulative from pre-Phase-11 baseline of 2,543 → 913 is −1,630 LOC, ~64%)** — matches the roadmap's "After 11.3 ≈ 970" target within ~6%. The four destinations carry 598 + 346 + 71 = 1,015 LOC; the +32 LOC overhead vs. the deletion delta is per-file `import` headers plus the explanatory bridge comment in `RoutinesView.swift`
- [x] **No behavior changes**: `RoutineEditor` body / save flows / locked-routine semantics / superset add/remove/reorder / technique conflict logic (AMRAP↔Dropset mutual exclusion, intensity-finisher-per-set rule, dropset-effort `fixedReps` overlap check, duration-incompatibility set, per-index conflict messages) all preserved verbatim. Build green; full XCTest suite **115/115 pass in ~0.91s** (composition unchanged from pre-slice). Manual smoke (passed): added a technique to a slot → picked technique type → edited dropset (`dropCount` / `dropPercent` / `restSeconds` / `dropsetEffort`) and cluster (`rounds` / `reps` / `restSeconds`) params → roundtrip verified; confirmed locked-routine path (lock badge + scrollable-but-disabled detail views) still works; verified `safeExercise(in:)` fallback for renamed / deleted exercises in routine + history rows

**Completed (11.4 — ActiveWorkout supporting private structs):**

- [x] Moved the 9 supporting private subview structs out of `ActiveWorkoutView.swift` into a new `Log/Main/ActiveWorkout/` directory (auto-discovered via `PBXFileSystemSynchronizedRootGroup` — no `project.pbxproj` edit needed, matches the 11.1 `Log/Utilities/` and 11.2/11.3 `Log/Main/Routines/` pattern):
  - `SetRows.swift` (164 LOC) — `SetEntryRow` + `TimeSetEntryRow`
  - `DropLogRow.swift` (86 LOC) — `DropLogRow`
  - `TechniqueChipsViews.swift` (152 LOC) — `TechniqueIndicatorRow` + `SetTechniqueChipsRow` + `TechniqueDetailSheet`
  - `RestOverlayScreen.swift` (50 LOC) — `RestOverlayScreen`
  - `ExerciseNotesEditSheet.swift` (68 LOC) — `ExerciseNotesEditSheet`
  - `EditSessionPlanSheet.swift` (140 LOC) — `EditSessionPlanSheet` + its private `intStepperRow`, `doubleStepperRow`, `optionalString` helpers (the helpers stay `private` because they are nested members; the parent struct is what bumped)
- [x] Confirmed during inspection that each struct is **already presented to `ActiveWorkoutView` via plain initializers** (`Binding`s, value types, `let` props, `@escaping` closures); none captures `ActiveWorkoutView` instance state or reads private `ActiveWorkoutView` properties via implicit `self`. The private `Field` focus enums inside `SetEntryRow` / `TimeSetEntryRow` / `DropLogRow` do not collide (each is nested in its own type)
- [x] **Nine identical access bumps**: each moved struct went from `private struct` to default-internal `struct` (same access pattern as 11.2 / 11.3). Verified by `grep -r` across `Log/` that no caller outside `ActiveWorkoutView.swift` references any of the nine symbols, so the bumps don't widen the public surface beyond what the file split requires. No other helpers or methods needed access changes
- [x] **No `@ViewBuilder` section methods moved.** The four `@State`-capturing `@ViewBuilder`s (`buildSetRow`, `buildWarmupRow`, `buildDropSection`, `buildWorkingSetGroup`) and the ~60 private methods on `ActiveWorkoutView` (persistence / swap / snapshot / superset / technique helpers) stay in `ActiveWorkoutView.swift` — those belong to Phase 11.6 (extension-file split) and Phase 12 (viewmodel hoist) respectively
- [x] **Actual `ActiveWorkoutView.swift` reduction: 3,695 → 3,061 LOC (−634 LOC, −17% this slice; cumulative from pre-Phase-11 baseline of 3,849 is −788 LOC, ~−20%)** — matches the roadmap's "After 11.4 ≈ 3,100" target within ~1.3%. The six new files together carry 660 LOC; the +26 LOC overhead vs. the deletion delta is per-file `import SwiftData` / `import SwiftUI` headers plus per-section `// MARK:` headers plus the expanded multi-line Phase-11.4 bridge comment now at the top of `ActiveWorkoutView.swift` (replacing the three single-line 11.1 comments with a unified 11.1 + 11.4 reference block)
- [x] **No behavior changes**: row interaction (Log / Undo / Start buttons, label text, `Field` focus enum, `Int(reps) ?? template.targetReps` parse fallback, Units/DSColor styling); `DropLogRow`'s `.padding(.leading, 20)` indent and `↩ suggest` reset button visibility (only when `onResetWeight` is non-nil); `RestOverlayScreen`'s 96pt rounded countdown + optional ProgressView when `total > 0` + close button + `.transition(.opacity)`; `ExerciseNotesEditSheet`'s `originalNotes` capture-on-`onAppear` + Cancel-restore semantics + trimmed-empty → nil normalization on Done; `EditSessionPlanSheet`'s duration/reps section toggle + RIR↔RPE paired-stepper conversion via `{ 10 - $0 }` + `TempoEditorView` integration + sentinel-based optional-clear semantics — all preserved verbatim. No callback signatures changed (every `onLog` / `onUndo` / `onClose` / `onStart` / `onTap` / `onResetWeight` kept its `@escaping` shape). No focus / advance / rest side effects altered. Draft persistence (`parentDraftStore` / `dropWeightDraftStore`) lives in `ActiveWorkoutView`'s `@ViewBuilder` closures (Phase 12 scope) and was not touched. Warmup / dropset / superset / RIR / RPE / tempo / history flows untouched
- [x] **Technique chip behavior**: the move preserves the **pre-existing** wiring exactly — `SetTechniqueChipsRow` still takes the same `onTap: (TechniquePlanSnapshot) -> Void` closure and `ActiveWorkoutView`'s same `.sheet(item: $expandedTechnique)` still presents `TechniqueDetailSheet` for the tapped snapshot. **No interactivity was added or removed by this slice**; whether tapping a chip opens the detail sheet at runtime depends on the existing wiring inherited from Phase 3.8, not from 11.4. Smoke verified the moved files render and dismiss correctly; deeper UX verification of the chip-tap flow is **not** an 11.4 outcome and is not being marked as completed-by-this-slice
- [x] Build green on first attempt; full XCTest suite **115/115 pass in ~0.67s** (composition unchanged from pre-slice). Manual smoke (passed): normal set log/undo; time-based set log/undo; dropset parent + drop row behavior; rest overlay countdown + close button; Exercise Notes edit sheet Done saves / Cancel reverts; `EditSessionPlanSheet` Close dismisses with edits persisted via the `@Binding`; force-quit/resume restores cleanly

**Completed (11.5 — RoutineEditor extraction):**

- [x] Extracted `struct RoutineEditor: View` (538 LOC pre-move; 542 LOC after per-file imports) from `RoutinesView.swift` to `Log/Main/Routines/RoutineEditor.swift`. The entire struct moved as one unit — its nested `private struct DeletePrompt`, the @State surface (`deletePrompt`, `showAddExercise`, `showAddSuperset`, `showSupersetCountAlert`, `supersetCountMessage`, `showLockedBlockAlert`, `blockedBlocks`, `showOverrideActiveAlert`, `startLinkActive`), the `@Bindable var routine: Routine`, the `@Query(sort: \Exercise.name) allExercises`, the `@Environment(\.modelContext)`, and the `@ObservedObject activeGuard` all relocated as struct members without promotion. All 16 private helpers (`addSection`, `blocksContent`, `emptyBlocksSection`, `blocksSection`, `deleteBlocksFromEdit`, `blockRowView`, `blockSwipeActions`, `moveBlocks`, `normalizeRoutineModel`, `routineIsStartable`, `blockIsInvalidSuperset`, `blockTitle`, `blockContainsLockedExercise`, `endActiveSessionIfAny`, `deleteBlockSafely`, `appendBlock`) stayed `private` inside the new file, as the audit anticipated
- [x] **One access bump**: `BlockRow`: `private struct` → default-internal `struct` (in `RoutinesView.swift`). Required because the only caller — `RoutineEditor.blockRowView(for:)` — is now in another file. Verified by `grep -r BlockRow` across `Log/` that no other call sites exist, so the bump is the minimum required for the file split. `LockBadge` access **unchanged** (stays file-private in `RoutinesView.swift`): `BlockRow.body`'s `LockBadge()` lookup resolves at the definition site, which is still inside `RoutinesView.swift`, so cross-file callers of `BlockRow` don't need to see `LockBadge` directly
- [x] The bridge comment in `RoutinesView.swift` was rewritten this slice to document the new state — `BlockRow` is now internal (so `RoutineEditor` can reach it), `LockBadge` stays private for the Phase-11.3 collision reason, and the file's `LockBadge()` lookups (at lines 124 and 194 inside `RoutinesView`, plus inside `BlockRow.body`) all resolve to the local private declaration
- [x] **Actual `RoutinesView.swift` reduction: 913 → 380 LOC (−533 LOC, −58% this slice; cumulative from pre-Phase-11 2,543 → 380 is −2,163 LOC, ~−85%)** — slightly **better** than the ~430 estimate (~12% under), thanks to a leaner bridge-comment block. The new `RoutineEditor.swift` carries 542 LOC; the +9 LOC overhead vs. the deletion delta is `import SwiftData` + `import SwiftUI` + the file's section MARK header
- [x] **No behavior changes**: `body` byte-for-byte (same toolbar `EditButton` + Start `play.fill` button, same four `.alert` modifiers in the same order, same two `.sheet` presentations, same `.onAppear(perform: normalizeRoutineModel)`, same `.navigationDestination` to `StartWorkoutFromRoutineView`); `appendBlock` preserved (superset working-set-count match check with the exact "Selected exercises have working set counts: …. All must match." message, `makeDefaultPrescription` call for new slots, `nextOrder` derivation, `RoutineBlock` initializer args); `normalizeRoutineModel` preserved (orphan cleanup → superset-tombstone cascade → exact-copy override detection with per-index `kind`/`targetReps`/`targetWeight`/`restSecondsAfter`/`durationSeconds` comparisons → per-superset RE order renumber → final block-order renumber → 3 sequential `try? ctx.save()` checkpoints); `deleteBlockSafely` preserved (`@MainActor` + 0.25s `withAnimation` removal + 0.15s `DispatchQueue.main.asyncAfter` SwiftData delete + cascade + order renumber + success haptic); `endActiveSessionIfAny` preserved (workout `.completedAt` write, `BootstrapRoot.fetchOrCreateAppState`, `RestTimer.stableNotificationID` reconstruction, `RestTimer.clearPersistedStateAndNotifications`, AppState reset order, final `activeGuard.endSession()`); `blockRowView` + `blockSwipeActions` + `moveBlocks` + `deleteBlocksFromEdit` + `routineIsStartable` + `blockTitle` + `blockContainsLockedExercise` all preserved verbatim. Locked-routine behavior preserved: the routine stays scrollable/readable, mutation controls (Add Exercise / Add Superset / EditButton / move handle / swipe-delete / swipe-`In use`) remain disabled-or-guarded individually. Add / remove / reorder behavior for supersets preserved at the `SupersetDetailNoRest` callsite via `RoutineEditor.blockRowView`'s `routineLocked:` plumbing
- [x] Build green on first attempt; full XCTest suite **115/115 pass in ~1.29s** (composition unchanged from pre-slice). Manual smoke (passed): full routine-editor flow — added block, edited block, added superset, edited superset details, reordered blocks, deleted a block (with `In use` lock alert on the locked block), swapped an exercise, locked a routine while a workout was active and verified edit mutation surfaces remained disabled while the List itself stayed scrollable

**Phase 11.6 — ActiveWorkoutView per-concern decomposition (lowest priority; A/B/C sub-slices)**

The Phase-11.6 audit found that the original "single big extension-file split" framing understated a Swift access-control reality: `private` members of `ActiveWorkoutView` are invisible to extensions in other files, so any per-concern extension move would force a large fraction of the ~25 `@State` vars and ~60 `private` helpers to bump to default-internal. The audit therefore re-stratified 11.6 into three risk-graded sub-slices. **11.6-A has shipped; 11.6-B and 11.6-C remain Pending**. See "Phase 11 closure" note at the end of this section for whether 11.6-C is mandatory to close Phase 11.

**Completed (11.6-A — pure utility lift, very low risk):**

- [x] Created `Log/Main/ActiveWorkout/ActiveWorkoutHelpers.swift` (67 LOC) holding four module-internal free functions lifted out of `ActiveWorkoutView`:
  - `roundWeight(_:)` — pure (reads only `Units.weightIsKg`)
  - `formatWeight(_:)` — pure
  - `defaultTemplate(for:at:)` — pure constructor reading the parameter's `currentExerciseID`
  - `activeRestNotificationID(workoutID:slotID:)` — renamed from `restNotificationID(slotID:)`; `workoutID` is now an explicit `UUID?` parameter that callers thread through as `workout?.id` rather than the helper reading `self.workout?.id`. The `workoutID == nil` branch keeps the `"rest.unknown.<slotID>"` fallback shape byte-for-byte (load-bearing — `RestTimer` keys pending `UNUserNotificationCenter` requests off this string; substituting `UUID()` would orphan in-flight notifications)
- [x] **One required isolation annotation**: `activeRestNotificationID` is `@MainActor`. The original method inherited that isolation implicitly from `ActiveWorkoutView` (a SwiftUI `View`, which is `@MainActor`); the underlying `RestTimer.stableNotificationID(workoutID:slotID:)` is a `static` on the `@MainActor`-isolated `RestTimer` class, so a non-isolated free function couldn't call it. Caught by the first build attempt (`Cannot call main actor-isolated static method ... in a synchronous nonisolated context`) and fixed before the green run. All 3 call sites are already inside `@MainActor` `ActiveWorkoutView` methods, so the annotation is invisible at the call sites
- [x] **Zero access bumps on `ActiveWorkoutView`'s `@State` surface.** None of the four moved helpers read any `private` member of `ActiveWorkoutView`; `workout?.id` is threaded through `activeRestNotificationID`'s parameter list. The other ~25 `@State private var`s and ~60 `private func`s on the view keep their existing access — this is the whole point of the 11.6-A framing
- [x] **Call sites changed**: 3 `restNotificationID(slotID: …)` callsites (in `restoreStableRestID`, `startRestWithPersistence`, `resumeRestFromAppState`) rewritten to pass `workout?.id` explicitly. The 6 `defaultTemplate(for:at:)` callsites and the 1 `formatWeight(roundWeight(…))` callsite unchanged textually — free-function dispatch matches the prior method-dispatch shape
- [x] **`ActiveWorkoutView.swift` reduction: 3,061 → 3,027 LOC (−34 LOC, −1.1%)** — matches the audit's "~30 LOC" estimate. The new helpers file carries 67 LOC; the +33 LOC overhead is per-file `import Foundation` + section MARK headers + the multi-paragraph doc comments + the expanded Phase-11.6-A entry in the top-of-`ActiveWorkoutView.swift` bridge comment
- [x] **No behavior changes**: rest scheduling, rest cancellation, force-quit/cold-resume restoration, drop-set weight rounding/formatting, and the "extra-set" lightweight template fallback all preserved byte-for-byte. Build green on second attempt; full XCTest suite **115/115 pass in ~0.60s** (composition unchanged from pre-slice). Manual smoke (passed): normal set log → rest overlay countdown → notification fires at the correct time; drop sub-log with manual weight override + ↩ suggest reset; session-plan edit that pushes sets above the snapshot's template count and verifies the synthetic extra row renders

**Completed (11.6-B — `SessionPlanResolver` service, low risk; mirrors `RestPlanner`):**

- [x] Created `Log/Services/SessionPlanResolver.swift` (139 LOC) — pure `enum` namespace with five `static` functions that take `sessionPlan: SessionPlan?` + `snapshot: PrescriptionSnapshotPayload?` + (where relevant) `template: PlanSetTemplate` or `resolvedTemplates: [PlanSetTemplate]` as value parameters:
  - `SessionPlanResolver.effectiveSetCount(sessionPlan:snapshot:resolvedTemplates:) -> Int`
  - `SessionPlanResolver.plannedRepTarget(sessionPlan:snapshot:template:) -> Int`
  - `SessionPlanResolver.plannedDurationTarget(sessionPlan:snapshot:template:) -> Int?`
  - `SessionPlanResolver.plannedRestBetweenSets(sessionPlan:snapshot:) -> Int?`
  - `SessionPlanResolver.plannedRestAfterExercise(sessionPlan:snapshot:) -> Int?`
- [x] **Zero access bumps** on `ActiveWorkoutView` — exactly as the audit promised. The service takes everything by value; it never touches any `ActiveWorkoutView` member. The 5 wrapper methods on `ActiveWorkoutView` stay `private`. No other code in the module needed access changes
- [x] **Fallback behavior preserved byte-for-byte** against the pre-slice private methods (`HEAD~1:Log/Main/ActiveWorkoutView.swift:1073-1141`): three-tier precedence (sessionPlan → snapshot → template / count clamp / nil); `> 0` filter on both stored-sets fields for `effectiveSetCount`; the load-bearing `max(1, resolvedTemplates.count)` clamp on the template fallback (UI must render ≥1 row); the `??` chain on `(repMax ?? repMin)` and `(durationMaxSeconds ?? durationMinSeconds)` that treats nil as "fall through" but accepts any stored Int including `0`; the `> 0` filter on both `restSecondsBetweenSets` and `restSecondsAfterExercise` at both tiers; independence of `plannedRestBetweenSets` and `plannedRestAfterExercise` (verified by a dedicated cross-helper test)
- [x] **Refactor approach: thin wrappers retained** to minimize call-site churn. Rather than rewriting all ~48 call sites to invoke `SessionPlanResolver.*` directly, the 5 methods on `ActiveWorkoutView` stay in place as one-line forwarders that pull `sessionPlans[exercise.routineSlotID]` + `exercise.prescriptionSnapshot` out of the view's `@State` and hand them to the pure resolver. Same pattern as `RestPlanner` (`ActiveWorkoutView.restSecondsAfterCurrentLog` is itself a wrapper around `RestPlanner.*`). The pre-slice 13-line method bodies became 10-line wrapper bodies plus a multi-paragraph MARK header explaining the new layering
- [x] **Trade-off**: the wrapper approach means `ActiveWorkoutView.swift` LOC did **not** meaningfully decrease — actual delta is `3,027 → 3,030 LOC` (**+3 LOC**), well short of the audit's `~−80` estimate. The audit estimate assumed full direct-call-site rewrites; with wrappers, the rewrite is mechanical and skippable. **A future "direct call-site rewrite" sub-slice can shave ~50–60 LOC at any time** if call-site brevity becomes preferable — the resolver is already in place, tested, and decoupled. **The win of this slice is logic extraction + test coverage**, not LOC reduction
- [x] Added `LogTests/SessionPlanResolverTests.swift` (368 LOC) with **23 pure XCTest cases** (no SwiftData harness) covering: `effectiveSetCount` (7 — sessionPlan wins / snapshot fallback / sessionPlan-with-sets-nil-but-other-fields-set / template count fallback / `max(1, …)` clamp on empty templates / sessionPlan.sets=0 cascades / snapshot.sets=0 cascades); `plannedRepTarget` (5 — repMax wins / repMin used when repMax nil / snapshot fallback / template fallback / stored `0` is accepted and does NOT cascade through `??`); `plannedDurationTarget` (4 — sessionPlan max wins / snapshot fallback / template fallback / nil-all-tiers); `plannedRestBetweenSets` (3 — sessionPlan wins / snapshot used when sessionPlan is `0` / nil-when-both-zero-or-missing); `plannedRestAfterExercise` (3 — same pattern); plus a cross-helper invariant pinning that `plannedRestAfterExercise` and `plannedRestBetweenSets` use independent fields. Suite count: **115 → 138 tests (+23)**
- [x] **Test infrastructure note**: the test file adds a small test-only memberwise `init` extension on `PrescriptionSnapshotPayload` (whose production inits both require SwiftData instances). The extension delegates to the existing `init(from: PlannedPrescriptionSnapshot)` — `PlannedPrescriptionSnapshot` is a SwiftData `@Model` final class whose compiler-generated init can be invoked **without** a `ModelContext`, so the suite stays SwiftData-free. First attempt tried direct `self.field = …` assignment in the extension init — Swift forbids that pattern (`'self' used before 'self.init' call`) and the test build failed. Switching to delegation fixed it. This pattern is reusable for any future tests that need a `PrescriptionSnapshotPayload` value
- [x] **No behavior changes**: no @ViewBuilder methods moved; no @State exposed to the service; active-workout logging, rest, focus, undo, draft persistence, warmup, dropset, superset, notes, RIR/RPE, tempo, history, routine-editing — all preserved verbatim. Production build green on first attempt; full XCTest suite **138/138 pass in ~0.85s** (115 pre-slice + 23 new). Manual smoke (passed): Edit Plan → changed `sets` / `repMin` / `repMax` / `restBetweenSets` / `restAfterExercise` → verified body recomputed with the new values and the rest decision after the next log used the new `plannedRestBetweenSets` / `plannedRestAfterExercise`

**Deferred to Phase 12 (11.6-C — per-concern extension files; owner decision 2026-05-20):**

This slice was originally Pending in Phase 11.6 but was **explicitly deferred to Phase 12 by owner decision on 2026-05-20**, after 11.6-B shipped. Rationale: the slice is no longer a simple low-risk file-move — it requires widening many `private` `@State` and helper members of `ActiveWorkoutView` to default-internal (Swift's top-level type rule: `private` members are invisible to extensions in other files). The access-surface decision is better made together with the Phase-12 viewmodel hoist, since both touch the same `@State` graph. The cluster plan below is preserved verbatim as a Phase-12 starting point.

- [→ Phase 12] Move clustered private helpers onto `extension ActiveWorkoutView` declarations in dedicated files. Ship one cluster per sub-slice; the order below is recommended (least surface-widening first):
  - `Log/Main/ActiveWorkout/ActiveWorkoutView+SupersetHelpers.swift` — `lastRoundIndex`, `supersetRoundComplete`, `allExercisesLogged`, `advanceForSupersetAfterLog`, `isAtLast` (~5 helpers, ~80 LOC)
  - `Log/Main/ActiveWorkout/ActiveWorkoutView+Persistence.swift` — `updateAppState`, `persistRestState`, `clearPersistedRestState`, `persistSessionPlans`, `restoreSessionPlansFromAppState`, `restorePositionFromAppState`, `persistPosition`, `restoreStableRestID`, `startRestWithPersistence`, `resumeRestFromAppState`, `restoreDropWeightDrafts` (~11 helpers, ~180 LOC)
  - `Log/Main/ActiveWorkout/ActiveWorkoutView+Swap.swift` — `performPendingSwap`, `swapExercise`, `applyExerciseSwapsToRoutine` (~3 helpers, ~200 LOC)
  - `Log/Main/ActiveWorkout/ActiveWorkoutView+Snapshot.swift` — `populateSnapshotFields`, `rebuildItemsByExerciseID`, `ensureInputsInitializedFromPlan`, `rehydrateFromWorkoutIfPresent`, `syncFromGuardCachesIfAny`, `syncToGuardCaches` (~6 helpers, ~175 LOC)
  - `Log/Main/ActiveWorkout/ActiveWorkoutView+Logging.swift` — `appendSetLog`, `appendTimeSetLog`, `undoSetLog`, `appendDropLog`, `undoDropLog`, `suggestedDropWeight` (~6 helpers, ~250 LOC)
  - `Log/Main/ActiveWorkout/ActiveWorkoutView+Techniques.swift` — `techniquesApplying`, `dropsetTechniqueApplying` (~2 helpers, ~75 LOC)
- [→ Phase 12] **Required access-control trade-off**: Swift's `private` is invisible from extensions in other files. Each sub-slice must bump exactly the `@State`-or-helper members it reads/writes from `private` to default-internal. The bumps likely include `currentBlockIndex`, `currentExerciseIndex`, `loggedByExercise`, `dropsLoggedByExercise`, `dropWeightInput`, `dropRepsInput`, `dropWeightUserEdited`, `sessionPlans`, `itemsByExerciseID`, `inputsByExerciseID`, `workout`, `plan`, `preEditRepStrs`, `preEditDurStrs`, `rest`, `setTimer`, `showRestOverlay`, plus the helpers `isWorkingSetComplete`, `currentBlock`, `currentExercise`, `fetchWorkout`, `fetchExercise`. In Phase 12 these access-surface decisions can be re-examined alongside the viewmodel hoist (some members may move *onto* the viewmodel rather than being bumped to internal on the view)
- [→ Phase 12] **No `@ViewBuilder` methods move under 11.6-C even when revisited.** The four `@State`-capturing `@ViewBuilder`s (`buildSetRow`, `buildWarmupRow`, `buildDropSection`, `buildWorkingSetGroup`) plus `planSummarySection` and `buildTechniqueChips` are separate Phase-12 viewmodel-hoist candidates (see "Deferred to Phase 12" section below)
- [→ Phase 12] Expected `ActiveWorkoutView.swift` reduction if eventually shipped: ~3,030 → ~2,150–2,300. The body itself (~475 LOC) + the six `@ViewBuilder` methods (~1,014 LOC combined) + struct properties (~64 LOC) form the structural floor regardless of whether the cluster split happens
- [→ Phase 12] Manual smoke per sub-slice (shape to the cluster — persistence: force-quit / cold-resume / rest-notification flow; swap: normal swap + locked-routine swap + dirty-plan swap; snapshot: cold-resume from a routine that no longer exists; logging: parent log + drop log + undo path for both; superset helpers: 3-exercise superset with a dropset on round 2; techniques: per-set technique chips + multi-index applies-to)

**Deferred to Phase 12 (11.6-D — `restSecondsAfterCurrentLog` extraction; owner decision 2026-05-20):**

This slice was an optional follow-up to 11.6-C and **carried into Phase 12 by the same 2026-05-20 owner decision**. It depends on 11.6-C's access bumps (or the Phase-12 viewmodel hoist that replaces them), so it cannot ship before that work.

- [→ Phase 12] `restSecondsAfterCurrentLog(setIndex:template:block:exercise:)` is already a thin shell over `RestPlanner.*` calls. Its body reads `currentBlockIndex`, `plan`, and calls `effectiveSetCount` (now in `SessionPlanResolver` after 11.6-B ✓), `plannedRest*` (same ✓), `lastRoundIndex` (still on the view; relocates with `+SupersetHelpers` when that ships), `dropsetTechniqueApplying` (same, with `+Techniques`). Becomes a candidate for `Log/Main/ActiveWorkout/ActiveWorkoutView+RestDecisions.swift` once its dependencies are reachable from another file (whether via 11.6-C-style access bumps or via Phase-12 viewmodel hoist)
- [→ Phase 12] Expected reduction: ~−160 LOC if eventually extracted; behavior-preserving since the planner already owns the decision tree

**Phase 11 — COMPLETE (2026-05-20)**

All in-scope Phase-11 file-decomposition work has either **shipped** (11.1, 11.2, 11.3, 11.4, 11.5, 11.6-A, 11.6-B) or been **explicitly deferred to Phase 12** (11.6-C, 11.6-D — owner decision 2026-05-20; see entries above). The behavior-preserving file-decomposition objective is closed; what remains in `ActiveWorkoutView.swift` and `RoutinesView.swift` is dominated by `@ViewBuilder` `@State`-capturing methods + view bodies, which are Phase-12 viewmodel-hoist work by design. The Phase-11 progress snapshot at the bottom of this section freezes at its post-11.6-B values.

**Deferred badge cleanup (carried out of 11.3 — needs a redesign-style decision):**

- `BlockRow` + `LockBadge` are still file-private inside `RoutinesView.swift`. The planned move to `Log/Main/Routines/BlockRow.swift` was attempted in 11.3 and rolled back after a build failure: Swift's top-level namespace is module-wide regardless of access level, so promoting `LockBadge` to default-internal collides with the file-private `LockBadge` in `ExercisesView.swift:1032` (`invalid redeclaration of 'LockBadge'`)
- The two `LockBadge`s differ visually by design — `ExercisesView` uses `.font(.dsCaption.weight(.semibold))`, `RoutinesView` uses `.font(.caption2.weight(.semibold))` — so a behavior-preserving merge is not possible without redesign
- **Unblock options** (any one is enough; none fits Phase-11 ground rules so they are out of scope for further pure decomposition slices):
  - Rename the `ExercisesView` variant (e.g. `ExerciseLockBadge`) — pure identifier change, no UI impact, but renames a top-level Swift type
  - Unify the two badges into one design (`LockBadge` with a single font choice) — a UI redesign decision, not file decomposition
  - Move both `LockBadge` implementations into a single new file with one renamed (e.g. `RoutineLockBadge` + `ExerciseLockBadge`)
- Tracker: ~40 LOC will move out of `RoutinesView.swift` once unblocked. The actual post-11.5 `RoutinesView.swift` count (380 LOC) already excludes this delta, so unblocking only matters for cosmetic consolidation of the badge variants
- **Phase 11.5 update**: `BlockRow` was bumped from `private` → default-internal this slice so the relocated `RoutineEditor.blockRowView(for:)` can reach it across files. `LockBadge` stays file-private — the collision rationale is unchanged. The remaining unblock work is purely about whether/how to consolidate `LockBadge` across files
- Not a Phase-12 (viewmodel) concern — purely a naming / design call. Listed here for visibility, not blocking any later slice

**Deferred to Phase 12 (MVVM / viewmodel) — NOT Phase 11 file decomposition:**

Phase 11 closed on 2026-05-20 with the following items carried forward. Together they form the Phase-12 starting backlog:

- **`ActiveWorkoutView`'s `@ViewBuilder` methods that capture `@State`**: `buildSetRow(block:exercise:idx:template:)`, `buildWarmupRow(block:exercise:step:)`, `buildDropSection(block:exercise:parentSetIndex:)`, `buildWorkingSetGroup(block:exercise:idx:template:)`. These methods read `inputsByExerciseID`, `loggedByExercise`, `dropsLoggedByExercise`, `parentDraftStore`, `dropWeightDraftStore`, `currentExerciseIndex`, `currentBlockIndex`, plus session-plan, draft, and rest-firing side effects. Splitting them across files without breaking the SwiftUI `@State` capture model requires either hoisting state into an `ObservableObject` viewmodel or passing dozens of `Binding`s / closures — that's a logic refactor, not a file split. Also includes `planSummarySection` and `buildTechniqueChips` (smaller but same `@State`-capture profile)
- **Phase 11.6-C — per-concern extension-file split / `@State` access-surface decision**: clustered private helpers on `ActiveWorkoutView` (Superset / Persistence / Swap / Snapshot / Logging / Techniques) that would each force `@State` bumps to default-internal. Originally a Pending Phase-11 slice; deferred to Phase 12 on 2026-05-20 so the access-surface decision can be revisited alongside the viewmodel hoist (some members may move *onto* the viewmodel rather than bumping on the view). Full cluster inventory + suggested file names + required-bump list preserved in the "Deferred to Phase 12 (11.6-C …)" entry above
- **Phase 11.6-D — `restSecondsAfterCurrentLog` extraction**: optional follow-up to 11.6-C, also deferred to Phase 12 on 2026-05-20. Already a thin shell over `RestPlanner.*` calls; reachable from another file once its remaining `ActiveWorkoutView`-private dependencies (`lastRoundIndex`, `dropsetTechniqueApplying`, `currentBlockIndex`, `plan`) are either bumped to internal (11.6-C path) or moved onto a viewmodel (Phase-12 path). Full detail in the "Deferred to Phase 12 (11.6-D …)" entry above

**Phase-11 progress snapshot:**

| Target file | Pre-11.1 | Post-11.1 | After 11.2 | After 11.3 | After 11.4 | After 11.5 | After 11.6 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ActiveWorkoutView.swift` | 3,849 | **3,695** | 3,695 | 3,695 | **3,061** | 3,061 | **3,030** † |
| `RoutinesView.swift` | 2,543 | 2,543 | **1,896** | **913** | 913 | **380** | 380 |

(Estimates assume each Pending slice ships to the audit's spec. Actual deltas may vary by ±10% depending on per-file imports / doc-comment density.)

† Final Phase-11 value: **`ActiveWorkoutView.swift` 3,030 LOC** (post-11.6-B; 11.6-C and 11.6-D deferred to Phase 12 by owner decision on 2026-05-20). 11.6-A moved 4 pure helpers out (−34 LOC, 3,061 → 3,027); 11.6-B shipped the `SessionPlanResolver` service with thin wrappers retained on the view (+3 LOC, 3,027 → 3,030 — the audit's ~−80 estimate assumed direct call-site rewrites that were deliberately deferred since the resolver is in place and trivially inline-able later). Cumulative Phase-11 delta: **3,849 → 3,030 LOC (−819, −21%)**. Further reduction (toward the ~2,150–2,300 ceiling) is Phase-12 viewmodel-hoist work — the `body` (~475 LOC) + the six `@ViewBuilder` methods (~1,014 LOC combined) + struct properties (~64 LOC) form the structural floor.

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

# CLAUDE.md
Gym Log — Architecture v2 (SwiftUI + SwiftData)
Branch: refactor/architecture-v2

## Core Directive
You are allowed — and expected — to make extensive structural changes when they improve:
- correctness
- data integrity
- maintainability
- production readiness
- performance

However, you must implement changes incrementally, with compile-safe commits and migration safety.

This project is transitioning from “functional prototype” → “production-grade app.”

---

## Definition of “Production-Ready” (What you must optimize for)

### A) Data integrity & invariants (must never break)
1) Templates are not silently mutated during workouts.
2) Sessions are snapshotted from templates at start and are append-only history.
3) History grouping uses stable IDs/relationships, not strings.
4) Slot identity is stable and unique per slot (not derived from Exercise.id).
5) Deleting routines/exercises does NOT delete completed history by default.

### B) Safety & reliability
- No force unwraps.
- No hidden side effects.
- Explicit error handling where failure is possible.
- Deterministic state transitions for workout lifecycle.
- No “barely functional” code; avoid hacks that only work in happy-path.

### C) Performance expectations
- Avoid heavy grouping/sorting/filtering in SwiftUI `body`.
- Prefer queries, caching, precomputed summaries, and lightweight view models/services.
- No O(n²) work in rendering paths for history screens.

### D) Developer experience
- Keep the repo buildable at each step.
- Provide clear diffs and file summaries.
- Prefer clear naming and cohesive architecture over minimal edits.

---

## Allowed Scope of Change (Explicit Permission)
You MAY:
- introduce new models/entities (RoutineVariant, Prescription, etc.)
- rename models to clarify responsibilities (e.g., Workout → WorkoutSession)
- split responsibilities into services/stores (WorkoutStore, HistoryIndex, etc.)
- redesign relationships + delete rules to protect history
- refactor UI flows to align with new invariants
- add tests and helper utilities

You SHOULD choose the best architecture for long-term maintainability even if it requires multiple files changing.

You MUST do it incrementally (see “Execution Rules”).

---

## Execution Rules (How you must work)

### 1) Never do a “big bang” rewrite
Do not attempt to complete the entire refactor in one step.

Work phase-by-phase. Each phase must compile and preserve user data.

### 2) Each phase must be reversible
After each phase:
- commit changes with a clear message
- keep the app building
- do not leave dead code paths or incomplete migrations

### 3) Migration strategy: additive first
- Add new entities/fields as optional with safe defaults.
- Backfill existing objects lazily or with controlled migration code.
- Do not remove old fields until compatibility is proven stable.

### 4) History protection is priority
Current model uses `.cascade` heavily. This is unsafe.

Whenever you change relationships:
- default to preserving history
- avoid cascading deletion from templates/exercises into workouts
- if links must break, keep readable snapshots in history

### 5) Template vs Session vs Exercise: strict boundaries
- Exercise = definition-level info (name/bodyPart/etc.)
- Routine slot (template) = structured prescription + per-template notes
- Session item = what happened today + snapshots and performed results

Session completion must NOT mutate Exercise or Routine by default.

### 6) “Apply changes to…” must be explicit
During an active workout, edits default to “this workout only.”
If applying back:
- template updates must be explicit and targeted using `routineSlotID`
- exercise defaults updates are optional and must be narrowly scoped

### 7) Communication format during work
Before editing:
- list files likely to be touched
- state the invariants preserved
- state any migration/backfill plan

After editing:
- summarize changes
- list files changed
- note migration impacts
- note how to verify in app

---

## Known Current Violations (Must be removed during refactor)
From current code (e.g., ActiveWorkoutView):
- finishing a workout writes back to `Exercise.notes`
- finishing a workout updates `Exercise.defaultTemplates`
- exercise swaps can apply back to `Routine` silently
- history grouping uses `Workout.routineName: String?`

These behaviors conflict with Architecture v2. They must be replaced with explicit flows.

---

## Minimum Test Suite (3–5 tests)
1) Starting a session snapshots prescription into session items + stores routineSlotID.
2) Session edits do not mutate template unless explicit apply action is invoked.
3) Finishing a workout produces immutable history and clears active state.
Optional:
4) Resume active session after app restart (persisted activeSessionID).
5) History grouping by RoutineVariant relationship survives name changes.

---

## Primary References
- Follow `REFACTOR_PLAN.md` as the high-level blueprint.
- Treat this file (CLAUDE.md) as the rules of engagement.
# Entry #11 Design & Release Plan

**Working Title:** Design Polish, Real-Device Testing & Personal/Internal Milestone Readiness  
**Date Range:** 2026-06-09 → TBD

> **Scope note:** Log is currently built primarily for **personal use** and as an
> **extracurricular / portfolio project** — a working iOS gym log tested directly
> on my own iPhone. Release readiness here means **personal/internal milestone
> readiness**, not public App Store readiness. **TestFlight is optional / deferred**
> for the current scope and is **not a blocker** for finishing Entry #11. External
> tester invitation is not part of this milestone; TestFlight remains available as
> a **future distribution smoke test** if external distribution later becomes a goal.

---

## Goal

This phase moves Log from feature-building into **design polish, real-device
validation, and release preparation**. The core architecture and the major feature
slices are already shipped and test-covered (see `REMAINING_WORK_PLAN.md` — no hard
blockers remain). The job now is to make the app feel **clear, trustworthy, and
smooth in real gym use**, and to confirm that existing data survives an upgrade —
not to add major new functionality.

Entry #11 should read as the "getting ready for real personal use" phase:
tightening visual clarity and validating on a physical device. Direct iPhone
workout testing is the main validation method for this milestone. The TestFlight
upgrade smoke is an **optional / deferred** future distribution check, not a
required step before finishing Entry #11; no public App Store / external-testing
promotion is in scope right now.

---

## Guiding Principles

- Avoid major new features unless real testing reveals a concrete problem.
- Prioritize **real-device usability** over simulator-only impressions.
- Keep changes **small and individually testable** (one polish slice at a time).
- Preserve existing architecture invariants (immutable snapshots, no silent
  template mutation, stable slot IDs, append-only history).
- Prefer **polish and validation over refactors**.
- Do **not** start high-risk `ActiveWorkoutView` architecture work (e.g. the
  Phase 12 view-model hoist) unless a real problem forces it.
- When in doubt, document the friction first, then decide if a code change is
  warranted.

---

## Design Polish Areas

> Walk each surface with fresh eyes (ideally right after a real workout). Check the
> box only once the surface reads clearly and needs no change, **or** a follow-up
> slice has been logged for it.

### Active Workout

- [ ] Visual hierarchy — eye lands on the current set first
- [ ] Set cards — reps/weight/log clearly grouped and tappable
- [ ] Warm-up rows — visually distinct from working sets
- [ ] Dropset cards — sub-rows clearly nested under their parent set
- [ ] Back / Next / Finish controls — obvious, reachable, not crowded
- [ ] Keyboard behavior — appears/dismisses predictably, doesn't cover inputs
- [ ] Note fields — easy to find, draft commits feel reliable
- [ ] Prefilled values readability — distinguishable from typed/logged values
- [ ] Rest timer visibility — clear when running, clear when done

### Routine Editor

- [ ] Block card clarity — block vs. superset visually distinct
- [ ] Exercise slot layout — name + prescription summary readable at a glance
- [ ] Prescription fields — sets/reps/rest/effort understandable without docs
- [ ] Warm-up editor clarity — add vs. edit mode obvious
- [ ] Technique editor clarity — allowed/blocked combinations make sense to the user
- [ ] Superset layout — membership and round-rest clear
- [ ] Empty states — empty routine / empty block read sensibly
- [ ] Destructive action clarity — delete vs. duplicate vs. locked/in-use styling

> Completed: BlockRow title/subtitle/Details typography now uses DS font tokens
> (`.dsSection` / `.dsCaption` / `.dsBodySecondary`). See Completed Design Polish.

### History

- [ ] Workout list readability — date / routine / summary subtitle scannable
- [ ] Workout detail readability — sets grouped per exercise clearly
- [ ] Metric picker clarity — available metrics make sense per exercise type
- [ ] Bodyweight metric labels — Reps / Best Reps / load metrics labeled clearly
- [ ] Deleted exercise/routine fallback labels — snapshot names read correctly
- [ ] Progress chart readability — axes/points legible on device

### Exercises

- [x] Exercise detail layout — sections ordered logically
- [x] Notes / setup notes clarity — purpose of each field obvious
- [ ] "Bodyweight counts as load" toggle — explanation is understandable
- [ ] Equipment / body part picker clarity — canonical vs. custom values clear

### Settings

- [ ] Bodyweight input clarity — purpose, decimals, "empty = not set" understood
- [ ] Unit display — current unit shown consistently
- [ ] Data management / destructive actions — import/export/delete clearly labeled
- [ ] TestFlight / debug-only information, if any — hidden or clearly marked

### Completed Design Polish

- **Exercise Detail section grouping** — split the single "Info" section into
  **Basics**, **Setup & Notes**, and **Options**, with footer text clarifying
  Setup defaults vs. Notes. Layout/style-only: bindings, focus logic,
  `commitDrafts`/`seedDrafts`, lock behavior, Time-based, and
  Bodyweight-counts-as-load behavior all preserved.
  (`design(exercises): clarify exercise detail sections`)
- **Routine BlockRow typography** — title/subtitle/Details now use DS font tokens
  (`.headline → .dsSection`, `.caption → .dsCaption`,
  `.subheadline → .dsBodySecondary`). `BlockDetailViews.swift` was left unchanged
  (no direct system text-font usages to replace safely); SF Symbol and LockBadge
  font usages were left unchanged intentionally.
  (`style(routine-editor): use DS font tokens in BlockRow`)
- **Shared StatusPill foundation** — added a reusable `StatusPill` component in
  `Log/UI/UIComponents.swift` and adopted it only for HistoryView's active-workout
  row "In Progress" label (wording unchanged). Visual/component-only: History
  calculations, metric picker, chart, delete behavior, and active-workout detection
  untouched; both `LockBadge` implementations left unchanged (unification deferred).
  (`design(ui): add StatusPill for history state`)
- **Invalid superset warning restyle** — in `Log/Main/Routines/RoutineEditor.swift`,
  the raw red emoji caption ("⚠️ Tap Details to set Rest after round") became a
  native SwiftUI `Label` (`exclamationmark.triangle`, `.dsCaption`,
  `.foregroundStyle(.orange)`) with the same wording — more native, minimal, and
  less harsh. The gating condition `blockIsInvalidSuperset(block)` and all
  superset/rest-after-round/navigation/edit logic were unchanged.
  (`style(routine-editor): restyle invalid-superset warning as native Label`)
- **Superset minimum delete-state clarity** — in `SupersetDetailNoRest`
  (`BlockDetailViews.swift`), the per-child swipe Delete now reflects the
  two-exercise minimum: a local `canRemoveChild = block.exercises.count > 2`
  greys out and disables child Delete when a superset has exactly two exercises,
  and keeps it red/available with 3+. The existing `removeExercise(at:)` min-two
  guard and the explanatory footer were unchanged; no helper text added.
  (`design(routines): show disabled delete state for minimum supersets`)
- **History metric selector redesign** — the **first screenshot-based redesign
  slice**. The cramped segmented metric Picker (up to six options truncating in a
  pill row) was switched to a native Menu-style picker (`.pickerStyle(.menu)`) that
  shows the selected metric clearly. Same label ("Metric"), options (`m.title`),
  and `$metric` binding. History calculations, `availableProgressMetrics` /
  metric availability, the metric-reset-on-exercise-change, chart data/rendering,
  bodyweight effective-load logic, recent workout rows, and swipe/delete were all
  unchanged. (`design(history): replace cramped metric pills with native selector`)
- **History chart visual quieting** — in `ProgressChart` only: softened the chart
  chrome (explicit `.chartXAxis`/`.chartYAxis` with `DSColor.border`-tinted
  gridlines and quieter `.dsCaption` / `DSColor.textSecondary` axis labels;
  default tick positions and label formatting preserved) and made the PR marker
  subtler (dropped the filled badge + ring, regular weight, `.yellow.opacity(0.8)`,
  accessibility label kept). Empty state left unchanged. Chart data, `computePoints`,
  calculations, metric availability, filtering, recent rows, and swipe/delete all
  unchanged; no interactivity added. (`design(history): quiet chart presentation`)
- All seven shipped as small, reversible Entry #11 design/UX slices via dedicated
  branches merged into `main`. **Build passed** and **manual testing passed** for
  each. No models, persistence, active-workout, history, or routine logic changed.
- Real-device workout tests are **complete** (three end-to-end sessions; see
  Real-Device Testing Notes) — direct iPhone testing is the main validation method
  for this milestone. The TestFlight upgrade smoke (see below) is **optional /
  deferred** for the current personal/internal scope and has **not** been run (and
  is **not required** to finish Entry #11).

> Note: the count of completed **visual design** slices remains **seven**. The
> item below is a separate **workout-usability** feature, not an eighth design
> slice.

### Completed Workout Usability

- **Exclude recovery/deload workouts from future prefill** — surfaced while
  planning a full-body **recovery session**: last-performance prefill seeds new
  workouts from the most recent completed workout containing the same exercise,
  which is right for normal training but wrong for recovery/deload days. Those
  sessions use intentionally reduced load and/or sets, so finishing one normally
  would pollute the **next** normal workout's prefill values. A recovery/deload
  workout should stay in **History** but should not necessarily overwrite future
  training prefill. The new **"Use for future prefill"** toggle solves this, and
  **default behavior is unchanged** because the toggle is **ON by default** (all
  existing and normal workouts remain included).
  - **Implementation summary:**
    - Additive `Workout.excludedFromPrefill: Bool = false` flag (migration-safe;
      existing workouts default to included).
    - **Active Workout** toggle — appears in the active-workout info List after
      Session Notes, so a recovery/deload workout can be marked OFF before
      finishing.
    - **History workout detail** toggle — appears in `WorkoutDetailView` Overview
      for completed workouts, so the setting can be corrected after the fact.
    - `LastPerformancePrefillService` now skips completed workouts where
      `excludedFromPrefill == true` for **both** parent-set and dropset prefill,
      **falling back to the next newest included completed workout**. Incomplete
      workouts are still ignored as before, and current-active-workout exclusion
      still works as before.
  - **Not changed:** History charts/metrics, PR logic, e1RM, Volume, Best Weight,
    Best Reps, Reps, Duration, bodyweight effective-load logic, metric
    availability, recent rows, swipe/delete, routine templates, exercise
    defaults, rest timer, and Live Activity.
  - **Validation:** build succeeded; full test suite passed (**859 tests, 0
    failures**) including **7 new `LastPerformancePrefillService` exclusion
    tests**; phone manual testing confirmed.
    (`feat(prefill): exclude marked workouts from last-performance prefill`)

- **Active Workout switch-exercise consistency** — a **workout-tested** follow-up
  (not a visual redesign slice): surfaced from **real-device workout testing**
  (Setup Notes not refreshing when switching exercises, Test 2), then expanded
  into a small consistency pass once related stale-state bugs were found on
  device. Fixes:
  - **Blank Switch Exercise sheet** — the picker sometimes opened as a blank
    white sheet on first tap; now item-driven sheet state guarantees it opens
    with a valid swap target.
  - **Stale Equipment & Setup after switching** — now resolves from the
    **session-start snapshot for non-swapped** exercises and the **live
    current/switched-in exercise for swapped** exercises.
  - **Switched-in prefill** — a swapped-in exercise now prefills from **its own**
    last-performance history, still honoring the existing priority order (logged →
    persisted draft → in-memory cache → last-performance → prescription default)
    and still respecting `excludedFromPrefill`.
  - **Bodyweight ↔ Barbell field visibility** — resolved active equipment now
    drives the parent weight-field visibility, so Bodyweight → Barbell shows the
    weight field and Barbell → Bodyweight hides it.
  - **Stale Bodyweight dropset suppression** — resolved active equipment also
    gates dropset support, so a Bodyweight exercise suppresses dropset UI at
    runtime (including stale/test Bodyweight + Drop Set combinations) without
    deleting or mutating the underlying technique/template.
  - **Not changed:** no model/SwiftData schema changes; no History, chart, PR,
    rest timer, Live Activity, or routine-template changes.
  - **Validation:** build succeeded; full test suite passed (**875 tests, 0
    failures**) including **16 tests in the new `SwitchExerciseConsistencyTests`
    suite**; manual device testing confirmed the Switch Exercise sheet opens,
    Equipment & Setup updates to the switched-in exercise, switched-in prefill
    works, Bodyweight → Barbell shows the weight field, Barbell → Bodyweight
    hides it, stale Bodyweight dropsets are suppressed, and Save & Exit / Resume
    and Finish → History still work.
    (`fix(active-workout): refresh switched exercise info and prefill`)

---

## Screenshot-Based Redesign Findings

A screenshot critique confirmed the app is functionally strong but still reads as
**visually too hard/dense and somewhat prototype-like**. The root cause is
**visual-treatment density, not information density**: too many surfaces feel
equally important, labels/values/helper text compete, some controls look cramped,
and permanent helper paragraphs add noise.

**Direction: Native Minimal + Focused Workout Surfaces.** Keep most screens mostly
native iOS (Routines, Exercises, Exercise Detail, Settings, History list); reserve
focused custom surfaces for where attention matters most (Active Workout current
set, History chart). Establish a clear type hierarchy
(numbers / active input > labels > metadata > helper text), one primary action per
screen, and no flashy fitness decoration. Preserve behavior and stability — not a
one-shot redesign.

Per-screen notes:

- **Routines / Exercises lists** — read as separated floating cards; should feel
  like calm native grouped lists. The name anchors the row; body part / equipment /
  summary metadata should be quieter.
- **Routine detail** — Add Exercise / Add Superset compete with content; block
  titles should anchor, metadata recede. (Warning restyle + disabled-delete
  affordance already shipped.)
- **Superset detail** — dense helper text + repeated stepper rows feel like a
  settings/debug panel; the exercise list should feel central. Static helper
  paragraphs may later move behind info/disclosure — not an immediate behavior change.
- **Exercise Detail** — already improved (Basics / Setup & Notes / Options); keep
  mostly native, change conservatively.
- **History metric selector** — the most prototype-looking element (options
  truncate/cramp); prefer a calm native Menu / compact selector over the cramped
  pill row. Calculations and chart behavior untouched.
- **History chart** — ✅ quieted: softer gridlines/axis labels and a subtler PR
  marker; no interactivity (and none added).
- **Active Workout** — highest impact, highest risk: the working-set input + Log
  button should become visually dominant; warmups, tags, notes, plan, and
  equipment/setup should recede. Keyboard state feels cramped. Do **not** change
  section order, layout, or behavior until real-device workout testing.
- **Settings** — already calm; keep native, use as the reference for calm Forms.

**Prioritized redesign plan:**

1. Fix the History metric selector (**✅ done** — segmented pill row → native Menu picker).
2. Continue low-risk Routines / Exercises visual simplification (native-list calmness).
3. Reduce permanent helper-text density where safe (progressive disclosure).
4. History chart visual quieting (**✅ done** — softer gridlines/axis labels, subtler PR marker).
5. Later: Active Workout visual hierarchy — only after real-device workout testing.

Real-device workout testing is **complete** (three end-to-end sessions) and is the
main validation method for this milestone. The Active Workout redesign remains
**not complete / not required right now**. The TestFlight smoke is **optional /
deferred** (a future distribution smoke test, not required for Entry #11), and
Release Readiness is scoped as **personal/internal milestone readiness** rather
than public App Store readiness.

---

## Real-Device Testing Notes

> Full per-workout logs (checklists, friction, bugs, follow-ups) now live in
> **[`ENTRY_11_WORKOUT_TESTING_NOTES.md`](ENTRY_11_WORKOUT_TESTING_NOTES.md)** to
> keep this plan high-level. Summary below.

**Three workout tests completed** on a real device (iPhone 13 Pro), 6/14–6/17/2026.

**Status: complete.** All three were real-device, end-to-end passes covering the
full workout flow — start workout, last-performance prefill, logging sets,
keyboard/input, rest timer, Save & Exit / Resume, and Finish → History.

**What passed:** the core workout loop worked on device across all three
sessions, including Finish → History in every test.

**Remaining issues / follow-up (usability, not flow gaps):**

- Weight / rep field switching not smooth on the first instance, somewhat random
  (Test 1, recurred in Test 3) — needs a confirmed repro before any fix.
- Setup Notes not updating when switching exercises (Test 2); want proper refresh
  of exercise info on switch, plus prefill from history when available.

See `ENTRY_11_WORKOUT_TESTING_NOTES.md` for the detailed notes and consolidated
follow-up.

---

## TestFlight Upgrade Smoke (Optional / Deferred)

> **Status: optional / deferred for the current personal/internal milestone.**
> This is **not required** before finishing Entry #11 and is **not marked
> complete**. It validates that real user data survives an upgrade (SwiftData
> migration safety); local on-device validation already passed. Treat it as an
> **optional distribution smoke test** and a **future external-testing path** —
> worth running later if external distribution becomes a project goal, but not a
> blocker now. The checklist below is retained for that future run.

**Set up state on an older build first:**

- [ ] Install older build
- [ ] Create exercises
- [ ] Create routine
- [ ] Complete a workout
- [ ] Confirm History exists
- [ ] Set bodyweight in Settings
- [ ] Create bodyweight and weighted exercise data

**Upgrade and verify:**

- [ ] Upgrade through TestFlight
- [ ] Confirm routines survive
- [ ] Confirm exercises survive
- [ ] Confirm history survives
- [ ] Confirm settings survive
- [ ] Confirm bodyweight load metrics still work
- [ ] Confirm last-performance prefill still works
- [ ] Confirm active workout start / resume / finish still works
- [ ] Confirm no migration crash

---

## Release Readiness Checklist (Personal / Internal Milestone)

> A quick end-to-end pass to confirm the core loop is intact for **personal/internal
> milestone readiness**. This does **not** imply public App Store readiness, and no
> external testers have been invited. The core workout flow has already been
> validated through **direct iPhone use** (three completed real-device sessions);
> this checklist is a final self-check, not a public-promotion gate.

- [ ] App launches cleanly
- [ ] Create exercise
- [ ] Edit exercise
- [ ] Create routine
- [ ] Edit routine
- [ ] Start workout
- [ ] Log normal set
- [ ] Log bodyweight set
- [ ] Log time-based set
- [ ] Log dropset
- [ ] Log superset
- [ ] Save and exit workout
- [ ] Resume workout
- [ ] Finish workout
- [ ] View history
- [ ] Delete exercise without destroying history
- [ ] Keyboard behavior acceptable
- [ ] No known hard blockers

---

## Known Monitor-Only Issues

### Floating Back/Next panel after warm resume

- **Status:** monitor-only
- Not consistently reproducible
- Suspected cause: stale keyboard safe-area inset at the window/scene level
- **Do not mark fixed** — no blind layout change without a confirmed repro
- **Action:** if it recurs, document exact reproduction steps (device, OS, what was
  focused before resume, whether keyboard was visible) before attempting a fix

### New issues found during real-device testing

> Log anything discovered during the workout tests above. One short entry each:
> what happened, how to reproduce, suspected cause, and whether it blocks release.

-
-
- ***

## Deferred / Not for Entry #11

Do **not** start these unless a clear, tested need appears:

- `ActiveWorkoutView` MVVM / view-model hoist (Phase 12 — high-risk)
- Rest-Pause / Cluster runtime rest semantics
- Large analytics / History redesign
- Workout-history CSV import (deliberately skipped — violates append-only history)
- Broad architecture cleanup / deprecations
- Speculative new features

---

## Entry #11 Draft Angle

The likely devlog story for Entry #11:

- After a feature-heavy stabilization phase (Entry #10), the app moved into
  **personal/internal milestone readiness**.
- The focus shifted from building to **design clarity and real-world validation**.
- The goal is to make Log feel **trustworthy, not just functional** — clear screens,
  predictable input, data you can rely on.
- **Real-device direct testing** on my own iPhone guided small, targeted polish
  fixes (rather than another feature wave) and is the main validation method for
  this milestone.
- **TestFlight is deferred:** the app is validated for personal use on device;
  the TestFlight upgrade smoke is kept as an **optional distribution smoke test**
  and **future external-testing path** rather than a step taken for this milestone.

Keep it honest: this is a "tightening and validating" entry, not a "we added X"
entry. Note anything still monitor-only.

---

## Possible Screenshots / Evidence

- [ ] Active workout screen
- [ ] Routine editor
- [ ] History metrics
- [ ] Settings bodyweight
- [ ] Last-performance prefill in action
- [ ] Installed on-device build (TestFlight build optional / only if external testing later happens)
- [ ] Before/after design polish (if any polish slices ship)

---

## First Suggested Work Order

1. Run 2–3 real workouts and fill out the testing notes. *(Done — three completed.)*
2. Identify the actual UI friction from real use (not guesses).
3. Do small, individually-testable design polish slices.
4. *(Optional / deferred)* Run the TestFlight upgrade smoke only if external
   distribution becomes a goal — not required for this personal/internal milestone.
5. Write Entry #11 from the gathered evidence.

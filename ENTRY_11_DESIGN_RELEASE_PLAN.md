# Entry #11 Design & Release Plan

**Working Title:** Design Polish, Real-Device Testing & Release Preparation  
**Date Range:** 2026-06-09 → TBD

---

## Goal

This phase moves Log from feature-building into **design polish, real-device
validation, and release preparation**. The core architecture and the major feature
slices are already shipped and test-covered (see `REMAINING_WORK_PLAN.md` — no hard
blockers remain). The job now is to make the app feel **clear, trustworthy, and
smooth in real gym use**, and to confirm that existing data survives an upgrade —
not to add major new functionality.

Entry #11 should read as the "getting ready for real users" phase: tightening
visual clarity, validating on a physical device, and running the upgrade smoke
before any TestFlight / App Store promotion.

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
- All six shipped as small, reversible Entry #11 design/UX slices via dedicated
  branches merged into `main`. **Build passed** and **manual testing passed** for
  each. No models, persistence, active-workout, history, or routine logic changed.
- Still outstanding: real-device workout tests and the TestFlight upgrade smoke
  (see below) have **not** been run.

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
- **History chart** — gridlines/axis labels may be quieted later; no interactivity yet.
- **Active Workout** — highest impact, highest risk: the working-set input + Log
  button should become visually dominant; warmups, tags, notes, plan, and
  equipment/setup should recede. Keyboard state feels cramped. Do **not** change
  section order, layout, or behavior until real-device workout testing.
- **Settings** — already calm; keep native, use as the reference for calm Forms.

**Prioritized redesign plan:**
1. Fix the History metric selector (**✅ done** — segmented pill row → native Menu picker).
2. Continue low-risk Routines / Exercises visual simplification (native-list calmness).
3. Reduce permanent helper-text density where safe (progressive disclosure).
4. Later: History chart visual quieting.
5. Later: Active Workout visual hierarchy — only after real-device workout testing.

History **chart** redesign, Active Workout redesign, real-device workout testing,
TestFlight smoke, and Release Readiness all remain **not complete**.

---

## Real-Device Testing Notes

> Fill these in from actual workouts on a physical iPhone. Capture friction while
> it's fresh — these notes drive the polish slices and the Entry #11 story.

### Workout Test 1
- Date:
- Routine:
- Device:
- What felt smooth:
- What felt confusing:
- Bugs noticed:
- Design issues noticed:
- Follow-up actions:

### Workout Test 2
- Date:
- Routine:
- Device:
- What felt smooth:
- What felt confusing:
- Bugs noticed:
- Design issues noticed:
- Follow-up actions:

### Workout Test 3
- Date:
- Routine:
- Device:
- What felt smooth:
- What felt confusing:
- Bugs noticed:
- Design issues noticed:
- Follow-up actions:

---

## TestFlight Upgrade Smoke

> Validates that real user data survives an upgrade (SwiftData migration safety).
> **This is a soft pre-promotion recommendation, not a hard release blocker** —
> local validation already passed; this widens the sample before public promotion.

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

## Release Readiness Checklist

> A quick end-to-end pass to confirm the core loop is intact before promotion.

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
-

---

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
  **release-readiness**.
- The focus shifted from building to **design clarity and real-world validation**.
- The goal is to make Log feel **trustworthy, not just functional** — clear screens,
  predictable input, data you can rely on.
- **Real-device testing** guided small, targeted polish fixes (rather than another
  feature wave).
- The **TestFlight upgrade smoke** validated that existing user data survives an
  upgrade safely.

Keep it honest: this is a "tightening and validating" entry, not a "we added X"
entry. Note anything still monitor-only.

---

## Possible Screenshots / Evidence

- [ ] Active workout screen
- [ ] Routine editor
- [ ] History metrics
- [ ] Settings bodyweight
- [ ] Last-performance prefill in action
- [ ] TestFlight build / installed build
- [ ] Before/after design polish (if any polish slices ship)

---

## First Suggested Work Order

1. Run 2–3 real workouts and fill out the testing notes.
2. Identify the actual UI friction from real use (not guesses).
3. Do small, individually-testable design polish slices.
4. Run the TestFlight upgrade smoke.
5. Write Entry #11 from the gathered evidence.

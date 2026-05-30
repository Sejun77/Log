# Remaining Work Plan

Gym Log — Architecture v2

**Purpose:** A focused extract of the still-open / still-relevant work from
`REFACTOR_PLAN.md`, so the next implementation targets can be chosen without
re-reading the full (1,800-line) refactor ledger.

**This document does NOT replace `REFACTOR_PLAN.md`.** That file remains the
authoritative blueprint and full history. This is a derived summary of the
*remaining* work only, generated 2026-05-27 and reconciled against the
remaining-work audit on 2026-05-27 (host-less `LogTests` conversion moved from
Performance/Testing to Archive; the archive set is confirmed complete).
Updated 2026-05-27: **routine name editing shipped** (§2.1) and its two
rename-verification items are now closed (§4); **multi-select exercise add is
complete** (§2.2) across normal-block add, existing-superset add, and new-superset
creation (`SupersetPicker` removed); the **"Used in Routines" Exercise-detail
summary shipped** (§2.3) — read-only, lists routine names with per-routine slot
context; an **input/navigation focus-bug fix shipped** (§2.4) — navigating into
Exercise Detail / Routine Editor now clears the add-field focus, and navigating
out of Exercises search dismisses search mode, so the keyboard no longer reappears
on return and Edit/Reorder controls come back. Updated 2026-05-28: the first
intentional UI-polish slice shipped — **routine row summary subtitles** (§2.5), a
read-only slot/superset glance line on Saved Routines rows (pure `RoutineSummary`
helper, full suite 399/399). Also updated 2026-05-28: the **search UX consistency
slice** (§2.6 A–D) **shipped** (`0422c2d`) — *visible search bars, keyboard
dismissal, and search-return state*: pinned-bar (`.always`) placement across all
four `.searchable` surfaces, a uniform `.onSubmit(of:.search) { dismissKeyboard() }`
plus a compact keyboard Done/checkmark fallback, and stabilized ExercisesView
search-return (full suite 399/399, manual regression passed). The
**empty-after-delete Search key** is closed as an **accepted SwiftUI/UIKit
limitation** (the inert blue key cannot be greyed safely; Done/checkmark + scroll
are the reliable dismissals — see §2.6 C). A separate future-optional "send
Exercise to top/bottom" idea is tracked under §2.6 sub-item E for traceability.
Updated 2026-05-29: **Exercise list section headers shipped** (§2.7) — the
Body Part and Equipment sort modes now render one `Section` per group (pure
`ExerciseSorter.sections(_:mode:)` helper + `ExerciseSection` type, trailing
"Unspecified" bucket); Manual and Alphabetical intentionally stay flat;
grouped modes are read-only views over the sorted data (no `Exercise.order`
mutation outside the existing manual-reorder path); full suite **408/408**.
Also updated 2026-05-29: **History row summary subtitles shipped** (§2.8) —
Recent Workouts rows now show a compact read-only `WorkoutSummary` subtitle
("6 exercises · 24 sets"; exercises = `items.count`, sets = non-warmup
`SetLog` count); same pure-helper + once-per-render-map pattern as
`RoutineSummary`. Bundled with a small History blocked-delete styling fix
(in-progress delete swipe is now gray, not red, matching the app-wide
red=available / gray=blocked convention). No model/schema change; full suite
**421/421**. Also updated 2026-05-29: **RoutineEditor block prescription
summaries shipped** (§2.9) — each block row now shows a compact read-only
subtitle from structured `SlotPrescription` fields (normal: "3 × 8–12 · 90s
rest" / "Not set"; superset: "Superset · 3 exercises · 3 sets" with max-child
sets), via a pure `BlockPrescriptionSummary` helper that never dereferences
`RoutineExercise.exercise`; no model/schema change; full suite **441/441**.
Also updated 2026-05-29: **Routine duplication shipped** (§2.10) — Saved
Routines rows can now be duplicated (swipe "Duplicate" + a long-press context
menu that also works in edit mode) via a pure copied-name helper + a tested
deep-copy `RoutineDuplicator` service (fresh `Routine`/variant/block/slot IDs,
shared `Exercise` refs, deep-copied prescriptions / setTemplates /
techniquePlans / warmup schemes; source never mutated). Duplicate is allowed
for in-use routines (read-only on source) while Delete stays blocked; no
model/schema change; full suite **460/460**. There is now no "implement now"
product/UX item — every remaining item is optional / future / deferred. Routine
*variant* rename UI remains deferred (§2.1a).

**Status of the refactor as a whole:** Phases 0–10 are shipped. Phase 11
(file decomposition) is closed with two clusters explicitly carried to Phase 12.
Phase 9 (remove `Exercise.defaultTemplates`) is complete and the field no longer
exists in the schema. What's left is optional polish, deferred structural work,
backlog product features, and a handful of gated/blocked items.

---

## 1. Must Fix Before Release

**No hard release blockers remain.**

- The architecture-v2 invariants (no silent template mutation, immutable
  snapshots, stable slot IDs, `.nullify` history protection, durable lifecycle
  + rest timer) are all in place and test-covered.
- The Phase 9-E2 SwiftData property-drop migration risk — the last real
  release concern — was validated locally (Phase 9-E2 local upgrade-from-old-store
  smoke, 2026-05-26: no migration crash, no orphan `SetTemplate`/`defaultTemplates`
  crash). That gate is cleared.

**One soft pre-release recommendation (not a blocker):**

| Item | Detail |
|---|---|
| **TestFlight 9-E2 real-user upgrade** | Source: Phase 9-E. Status: recommended, **explicitly downgraded from merge blocker to App-Store-promotion recommendation** after the local smoke passed. Why it matters: SwiftData has had property-drop migration bugs across iOS releases that a single local-sim sample can't fully rule out. Recommendation: **keep optional** (do it before public App Store promotion; not required to keep building/merging). Risk: **low** (local validation already passed; this is belt-and-suspenders for a broader installed base). |

---

## 2. Recommended Next Product / UX Work

Useful, realistic, user-facing items worth implementing soon.

### 2.1 Routine name editing — ✅ SHIPPED (2026-05-27)
- **Source:** §6 Backlog ("routine name editable"); also Phase 6.B Slice C.
- **Status:** **Done.** `RoutineEditor` now has a `Section("Routine")` with a
  routine-name `TextField` that commits on submit / focus loss. Validation: trims
  leading/trailing whitespace + newlines; empty/whitespace reverts to the previous
  valid name; a case-insensitive duplicate of another routine is rejected (self
  excluded by `id`); changing only the casing of the same routine is allowed. A
  valid rename mutates **only** `Routine.name` and saves — `Workout.routineName` /
  `routineID` / `routineVariantID` and `RoutineVariant.name` are never touched.
  Rename is disabled while the routine is locked / in use. Pure logic lives in
  `RoutineNameValidator`. No model/schema change. Build green; full suite
  **357/357**; manual regression passed. (Files: `RoutineEditor.swift`,
  `RoutineNameValidator.swift`, `RoutineNameValidatorTests.swift`,
  `RoutineLabelResolverTests.swift`.)
- **Unblocked:** the two §4 rename-verification items — now closed (see §4).

### 2.1a Routine *variant* rename UI — DEFERRED
- **Source:** Planning audit (Slice B).
- **Current status:** **Deferred.** There is still no variant-management UI, and
  every routine has only a hidden "Default" variant (created by the launch
  backfill), so variant rename has no surface and near-zero user value today.
  `RoutineLabelResolver` already supports the "Routine — Variant" display, so this
  becomes cheap once a variant list/feature exists.
- **Recommendation:** **defer** until a variant-management feature is actually
  planned.
- **Risk:** **low** (additive when it happens).

### 2.2 Multi-select exercise add — ✅ COMPLETE (Slice A + Slice B, 2026-05-27)
- **Source:** §6 Backlog ("multi-select exercise add").
- **Status:** **Done across all three add surfaces.** All routine-editor add
  flows now use the shared `ExerciseMultiPicker` — an ordered, duplicate-capable
  multi-select (tap appends; a second tap adds a second entry; "Selected (N)"
  summary with swipe-to-remove; `×N` count badges; search that never
  clears/reorders the selection; **Add (N)** disabled when empty; Cancel = no
  mutation):
  - **Normal-block "Add Exercise"** (Slice A) — confirm adds **N separate
    single-exercise blocks in tap-selection order** via `RoutineBlockBuilder`.
  - **Existing-superset "Add Exercise"** (Slice B) — confirm appends **N slots to
    the superset in tap order** via `RoutineBlockBuilder.addExercisesToSuperset`;
    new slots inherit the superset's shared set count.
  - **New-superset creation** (Slice B) — "Add Superset" now uses
    `ExerciseMultiPicker` too (the old `Set<UUID>`-based `SupersetPicker` was
    removed); creation supports tap order and duplicate selections.
- **Invariants preserved everywhere:** existing blocks/slots untouched, contiguous
  order after the current max, each `RoutineExercise` gets its own `slotID`,
  duplicate picks become distinct slots, default/shared prescription per slot,
  locked-routine gating intact. No model/schema change. Build green; full suite
  **380/380**; manual regression passed. (Files: `ExercisePickers.swift`,
  `RoutineEditor.swift`, `BlockDetailViews.swift`, `ExerciseMultiSelection.swift`,
  `RoutineBlockBuilder.swift`, `ExerciseMultiSelectionTests.swift`,
  `RoutineBlockBuilderTests.swift`.)

### 2.3 "Used in Routines" summary on Exercise detail — ✅ SHIPPED (2026-05-27)
- **Source:** Phase 9-D pending bullet (deferred to Phase 10).
- **Status:** **Done.** Exercise detail now has a read-only **"Used in Routines"**
  section. The final shipped version **lists routine names**, not just a count:
  - Unused → `"Used in 0 routines"` plus helper text telling the user that adding
    the exercise to a routine will surface it here.
  - Used → `"Used in 1 routine"` / `"Used in N routines"` followed by the routine
    names beneath the count.
  - The summary counts **unique routines, not slots** — an exercise appearing more
    than once in one routine counts that routine **once**, with slot context shown
    as a suffix (e.g. `Routine Name · 2 slots`).
  - Rows are sorted to match the Routines tab (`Routine.order`, then `Routine.name`)
    and capped for readability with a `+N more` row when the list is long.
- **Read-only:** the section is purely informational — **no navigation to the
  Routine Editor was added** in this slice (deferred; see follow-up below).
- **Implementation:** new pure helper `Log/Services/ExerciseRoutineUsage.swift`
  returns plain value entries; it scans `routine.blocks` only, skips nil/deleted
  `Exercise` references safely, and matches by comparing `RoutineExercise.exercise?.id`
  to the target `Exercise.id`. UI lives in `Log/Main/ExercisesView.swift`; covered by
  `LogTests/ExerciseRoutineUsageTests.swift` (unused / one / multiple routines,
  duplicate slots in one routine, unrelated ignored, nil refs skipped, superset-block
  usage, ordering). Build succeeded; full suite **389/389**; manual regression passed.
- **Freeze bug found & fixed (2026-05-27):** the first cut placed the routines
  `@Query` **inside `ExerciseDetailView`**, which owns the Body Part / Equipment
  `NavigationLink`s. Tapping a picker hard-froze the app: the `NavigationLink` push
  and the `@Query` invalidation / `body` re-render collided mid-transition (the link's
  source re-rendered while pushing). Fix: routine querying + usage computation moved
  into **`ExerciseDetailHost`**; `ExerciseDetailView` now receives a plain value
  snapshot (`ExerciseRoutineUsage`) and no longer owns the `@Query` or scans SwiftData
  relationship graphs in `body`. Body Part / Equipment pickers open normally and
  relaunch no longer returns to a frozen detail screen. **No model/schema changes.**
- **Follow-up (optional / future):** **"Tap a listed routine to navigate to the
  Routine Editor."** Stays **optional / future**.
- **Audit decision (2026-05-27) — DEFER. No code changes made (planning only).**
  A planning audit confirmed `ExerciseRoutineUsage.Entry` already carries enough
  identity for navigation (it stores `routineID` and `routineName`), and that
  `RoutineEditor` *could* technically be pushed from the Exercises tab stack. It is
  nonetheless **not worth implementing now**; the current read-only list is a valid
  end state.
  - **Recommendation:** defer.
  - **Current behavior:** keep the section **read-only** (no navigation).
  - **Preferred future direction:** **switch to the Routines tab + deep-link** into
    `RoutinesView` at `RootTabView` level — **not** pushing `RoutineEditor` directly
    inside the Exercises tab stack.
  - **Why defer (reasons):**
    1. `RootTabView` uses **separate `NavigationStack`s per tab**.
    2. `RoutineEditor` normally belongs to the **Routines tab** stack.
    3. Pushing it from the Exercises tab would create a **duplicate editor path**.
    4. `RoutineEditor` contains a **Start Workout path**, so a workout could be
       started from inside the Exercises tab.
    5. Resume / session logic assumes the **Routines tab is the canonical
       workout-start / resume path**.
    6. The §2.3 usage-list slice already hit a **freeze bug** caused by putting the
       routine `@Query` / computation too close to `ExerciseDetailView` navigation
       (fixed by moving it into `ExerciseDetailHost`).
    7. Reintroducing routine navigation from Exercise Detail risks **similar
       navigation / query complexity**.
    8. A safer implementation (tab switch + deep-link) needs a **cross-tab
       navigation design** that is not yet settled.
  - Risk: **medium** (navigation architecture); keep optional until that design is
    settled.

### 2.4 Add-field keyboard / search-focus polish — ✅ SHIPPED (2026-05-27)
- **Source:** Bug surfaced during manual testing of the Exercises / Routines list
  screens (input/navigation polish).
- **Bug:** Lingering focus leaked across navigation:
  - **Exercises** — with the new-exercise add field focused, opening an Exercise
    Detail and returning could **re-show the keyboard**.
  - **Routines** — with the new-routine add field focused, opening a Routine Editor
    and returning could **re-show the keyboard**.
  - **Exercises search** — searching for an exercise, opening it, and returning
    dismissed the keyboard but left **search mode still active/focused**, which hid
    the Edit / Reorder controls.
- **Status:** **Done.** Final behavior:
  - Navigating into Exercise Detail clears the add-field focus; navigating into the
    Routine Editor clears the add-field focus.
  - Returning to Exercises / Routines no longer auto-shows the keyboard, and any
    typed add-field draft is **preserved**.
  - Navigating from Exercises search results dismisses search mode and clears the
    search presentation; returning shows the normal Exercises list with Edit /
    Reorder controls visible again.
  - Tapping an Exercise / Routine row still opens detail / editor on the **first
    tap** (no double-tap). Add via Return / Add, duplicate-name alerts, exercise
    sort/search/reorder, routine reorder, and routine rename / multi-select add all
    remain unaffected.
- **Rejected approach:** the first attempt used row-level `.simultaneousGesture` on
  the `NavigationLink`, but that **competed with NavigationLink activation** and
  caused navigation failures when text was typed. The shipped fix avoids gesture
  competition entirely and clears focus / search through safer navigation and
  list-state handling instead.
- **No model/schema change.** Build succeeded; full suite **389/389**; manual
  regression passed. (Files: `Log/Main/ExercisesView.swift`,
  `Log/Main/RoutinesView.swift`.)

### 2.5 Routine row summary subtitle — ✅ SHIPPED (2026-05-28)
- **Source:** Product/UI polish audit (2026-05-28) — top-ranked next improvement
  for moving from refactor cleanup into intentional UI polish.
- **Nature:** a small **UX / glanceability** improvement, **not** a new data-model
  feature. Read-only display; no new persisted state.
- **Status:** **Done.** Saved Routines rows now show a read-only subtitle under the
  routine name so routines are distinguishable without opening them:
  - `"Empty routine"` (no slots)
  - `"1 exercise"` / `"5 exercises"` (slots, no supersets)
  - `"5 exercises · 1 superset"` / `"8 exercises · 2 supersets"` (slots + supersets)
- **Counting rules:** exercises = total `RoutineExercise` slots across
  `Routine.blocks` (slots, not unique exercises — duplicates count separately;
  superset members included); supersets = blocks with `isSuperset == true`.
  `RoutineVariant.blocks` are **not** counted (the editor operates on
  `Routine.blocks`, matching `ExerciseRoutineUsage`). A **nil/deleted** exercise
  reference still counts structurally as a slot and never crashes — the scan reads
  `block.exercises.count` and never dereferences `re.exercise`.
- **Implementation:** new pure value helper `Log/Services/RoutineSummary.swift`
  (`init(routine:)`, value-in `init(exerciseCount:supersetCount:)`, `subtitle`, and
  `map(for:)` to precompute one summary per routine keyed by `id`). `RoutinesView`
  builds the map **once per render** and each row reads its subtitle from it —
  same once-per-render discipline as History's `RoutineLabelResolver`, keeping the
  block scan out of each row `body` on a `@Query`-owning push source.
- **No model/schema change.** Build succeeded; full suite **399/399** (10 new
  `RoutineSummaryTests`); manual regression passed. (Files:
  `Log/Services/RoutineSummary.swift`, `LogTests/RoutineSummaryTests.swift`,
  `Log/Main/RoutinesView.swift`.)

### 2.6 Search UX consistency: visible search bars, keyboard dismissal, and search-return state — ✅ SHIPPED A–D (2026-05-28)
- **Source:** Discovered while adding `.searchable` to the History progression
  exercise picker; manual testing surfaced related inconsistencies across every
  other `.searchable` surface in the app.
- **Status:** **Shipped (A–D)** in commit `0422c2d` *fix(search): standardize
  search visibility and dismissal behavior*. Build succeeded, full suite
  **399/399**, manual regression passed. The empty-after-delete Search-key
  dead-end (C) is closed as an **accepted system limitation** with a reliable
  fallback (keyboard Done/checkmark + scroll) — see C. Sub-item **E remains
  future-optional** and was not bundled.
- **Why one umbrella item:** the sub-items share root cause (default `.searchable`
  placement is auto-hiding; the system Search-key enabled state is not directly
  controllable from SwiftUI; entering/leaving "search presentation" is implicit
  and toggles whether title / Edit / Reorder are visible) and a consistent policy
  across them avoids whack-a-mole fixes.

#### A. History progression picker search polish — ✅ DONE
- Search **filtering works**.
- Search bar **visibility fixed** by `.navigationBarDrawer(displayMode: .always)`
  on the picker's `.searchable`.
- Keyboard dismissal via `.scrollDismissesKeyboard(.immediately)`
  + `.onSubmit(of: .search) { dismissKeyboard() }` (shared helper) for non-empty
  submit, plus the compact `.keyboard` `KeyboardDismissButton` for the
  empty-after-delete case (see C).

#### B. ExercisesView search-return state — ✅ DONE
- After searching, opening an Exercise Detail, and returning, the keyboard is
  dismissed and the search term is cleared (§2.4) but the screen could still
  feel "stuck in search" because the auto-hiding bar remained scrolled off.
- Shipped: the Exercises search bar is pinned with
  `.navigationBarDrawer(displayMode: .always)` — same direction as the History
  picker. Removes the entire "auto-hidden bar after return" failure mode and
  makes Edit/Reorder toggle purely off `isSearchPresented`, not scroll position.
  Replaces an earlier ScrollViewReader/scrollTo first-pass that was reverted.
- Confirmed: on return from an Exercise Detail the search is cleared, the
  keyboard stays hidden, and the Edit/Sort controls come back. Always-visible
  is the app-wide default (see D).

#### C. App-wide searchable keyboard-dismiss policy — ✅ DONE (with accepted limitation)
- **Shipped policy:** every `.searchable` surface uses
  `.onSubmit(of: .search) { dismissKeyboard() }` (non-empty submit resigns
  focus) **plus** a compact `.keyboard`-placement `KeyboardDismissButton` as the
  deterministic fallback. Wired at History progression `ExercisePicker`,
  `ExercisesView` (gated on `isSearchPresented` so it scopes to the search field,
  not the Add-Exercise field), `ExercisePickerSingle`, and `ExerciseMultiPicker`.
  Shared helper `dismissKeyboard()` lives in `Log/UI/UIComponents.swift`.
- **Accepted limitation — empty-after-delete Search key (do not re-litigate):**
  - Field initially empty → Search **grey/disabled**.
  - Field non-empty → Search **blue** → tap dismisses keyboard. ✅
  - Field typed-then-deleted-back-to-empty → Search **stays blue/enabled** but
    tapping it **does not fire any submit**, so `.onSubmit(of: .search)` never
    runs and the key is **inert**.
  - Standard SwiftUI/UIKit exposes **no safe way** to force the `.searchable`
    Search key grey/disabled in this state: there is no SwiftUI modifier for the
    search field's return-key trait; the field already behaves as
    `enablesReturnKeyAutomatically == true`; the stuck-blue case is a UIKit
    refresh defect on the private search text field. Rejected as fragile /
    private / out-of-scope: introspection, `UITextField.appearance()`
    (`enablesReturnKeyAutomatically` is not a `UI_APPEARANCE_SELECTOR` property,
    is global, and wouldn't fix the refresh defect), and a custom
    `inputView`/keyboard. The app uses **none** of these.
  - **Accepted resolution:** leave the key as-is; the **keyboard Done/checkmark**
    and **scroll-to-dismiss** are the reliable dismissal paths. The rationale and
    rejected routes are documented at `dismissKeyboard()` in `UIComponents.swift`.
- **Search-presentation sub-rule** (shipped): scrolling dismisses the *keyboard*
  but does **not** exit search presentation by itself. Presentation toggling
  (which controls whether title / Edit / Reorder are visible) stays driven by
  `isPresented`:
  - Navigating away from a search row → clear `isPresented` + `search` (§2.4).
  - Manual scroll → keyboard down only; search text remains so the user keeps
    their filter while browsing.
  - Explicit iOS Cancel / x → exits presentation (system-provided).

#### D. Apply always-visible search placement consistently — ✅ DONE
- The pinned bar (`.navigationBarDrawer(displayMode: .always)`) shipped in A and
  B as the right default and was applied to the remaining `.searchable` surfaces:
  - `ExercisePickerSingle` (routine editor) — was default `.automatic`, now
    pinned to `.always`.
  - `ExerciseMultiPicker` (routine editor) — was `.navigationBarDrawer` without
    explicit `displayMode` (effectively auto-hide), now pinned to `.always`.
- All four `.searchable` surfaces now use `.always`. No exceptions identified —
  no surface benefits from collapsing-on-scroll behavior.

#### E. Future optional: Exercise list send-to-top / send-to-bottom action
- **Scope-separation note:** unrelated to search UX, **future / optional**.
  Tracked here only because it surfaced during the same manual testing pass;
  must **not** block A–D shipping.
- **Idea:** in `ExercisesView`, add per-row "Send to top" / "Send to bottom"
  actions (swipe action or context menu) so the user can manually reorder a
  long library without dragging across many screens. Only meaningful in
  `.manual` sort mode (the other sort modes are derived); already gated by the
  existing `.moveDisabled(sortMode != .manual || !search.isEmpty)` rule.
- **Risk:** **low** — additive `Exercise.order` rewrites (same idempotent
  renumber the existing drag-reorder uses); no model change.
- **Recommendation:** **keep optional** — implement only on user demand after the
  search-UX slice is closed.

---

**Recommendation:** A + B + C + D shipped as a single search-policy commit
(`0422c2d`) so the contract is uniform; the empty-after-delete Search key is
closed as an accepted system limitation (C). E (Exercise list
send-to-top/bottom) remains a separate, future, optional slice — implement only
on user demand; do not bundle.

### 2.7 Exercise list section headers (Body Part / Equipment sort) — ✅ SHIPPED (2026-05-29)
- **Source:** Product/UI polish audit — the next readability improvement after the
  §2.5 / §2.6 polish slices. The Exercises list already supported four sort modes
  (Manual / Alphabetical / Body Part / Equipment) but the grouped modes rendered a
  visually flat list, so the user couldn't tell where one body-part / equipment
  group ended and the next began.
- **Nature:** a read-only **glanceability / readability** improvement. No new
  persisted state, no model/schema change.
- **Status:** **Done**, shipped in two slices:
  - **Slice A — pure grouping helper.** Added `ExerciseSection` (`title` + `items`,
    `Identifiable` by title) and `ExerciseSorter.sections(_:mode:)`, plus the shared
    `ExerciseSorter.unspecifiedSectionTitle = "Unspecified"` constant. The helper
    reuses the existing `sort(_:mode:)` output and partitions **contiguous runs** of
    an identical group title (not `Dictionary(grouping:)`, so ordering never depends
    on dictionary iteration). Pure: reads `bodyPart` / `equipmentType` only and never
    mutates `Exercise.order`, `bodyPart`, `equipmentType`, or `CustomOptionStore`.
  - **Slice B — view wiring.** `ExercisesView` now branches on
    `ExerciseSorter.sections(filtered, mode: sortMode)`: a `nil` result renders the
    existing flat "All Exercises" section; a non-nil result renders one `Section` per
    group with the group title as a `DSSectionHeader`. The row body was extracted
    into a shared `exerciseRow(_:)` so flat and grouped rows are byte-identical
    (navigation, focus/search clearing, lock badge, swipe behavior).
- **Sectioning applies only to Body Part and Equipment sort modes:**
  - **Body Part sort** → one section per `bodyPart`.
  - **Equipment sort** → one section per `equipmentType`.
  - Custom / legacy values (e.g. "Legs") get their own correctly-ordered section.
- **Manual and Alphabetical modes intentionally remain flat** (the helper returns
  `nil` for them — an explicit "render flat" signal). Manual stays drag-reorderable
  when search is empty.
- **"Unspecified" bucket:** nil / empty / whitespace-only `bodyPart` /
  `equipmentType` collapse into a single trailing "Unspecified" section.
- **Data-safety rules (held):**
  - No `Exercise.order` mutation except the existing manual-reorder path
    (`moveExercises`, gated on `.manual` + empty search).
  - Grouped modes are **read-only views over the sorted data** — no `.onMove` path
    exists for them, so a drag can never silently rewrite `order`.
- **Search behavior:** search filters `filtered` by name **before** grouping, so
  empty groups never appear; results stay sectioned in grouped modes; an active
  search with zero matches shows a single "No exercises match …" row instead of an
  empty list. The pinned-bar / keyboard-dismissal behavior from §2.6 is preserved.
- **Delete behavior (section-safe):** flat edit-delete resolves offsets against the
  flat `filtered` array; grouped edit-delete resolves offsets against the **section's
  own `items`** (never the global array); swipe-delete and the impact alert target
  the resolved `Exercise` instance in all paths.
- **No model/schema change.** Build succeeded; full suite **408/408** (Slice A added
  9 `ExerciseSorterTests` — grouped bodyPart / equipment output, nil/empty/whitespace
  Unspecified bucket, custom/legacy section, empty input, single item, search-filtered
  input drops empty groups, flat modes return `nil`, ordering stable regardless of
  input order); manual regression passed. (Files: `Log/Services/ExerciseSorter.swift`,
  `LogTests/ExerciseSorterTests.swift`, `Log/Main/ExercisesView.swift`.)
- **Related future-optional:** the §2.6 E "send Exercise to top / bottom" manual-order
  action is still **pending / optional** and complements this work in Manual sort.

### 2.8 History row summary subtitles (+ blocked-delete styling fix) — ✅ SHIPPED (2026-05-29)
- **Source:** Next-slice planning audit after §2.7 — chosen as the cleanest mirror of
  the §2.5 routine-row-summary pattern (pure helper → once-per-render map → tests) on
  a high-traffic screen. Recent Workouts rows previously showed only date / duration /
  routine label, so workouts weren't distinguishable at a glance.
- **Nature:** a read-only **glanceability** improvement. No new persisted state, no
  model/schema change.
- **Status:** **Done**, shipped in two slices plus a bundled styling fix:
  - **Slice A — pure helper.** Added `Log/Services/WorkoutSummary.swift`
    (`Equatable` value type: `exerciseCount`, `setCount`, value-in init,
    `init(workout:)`, `subtitle`, `map(for:)` keyed by `Workout.id`). Pure — no
    `ModelContext`, no fetches, no mutation; reads `workout.items` / `item.setLogs`
    only and **never dereferences `item.exercise`**.
  - **Slice B — view wiring.** `HistoryView.recentWorkoutsSection` builds
    `WorkoutSummary.map(for: workouts)` **once per render** (next to the existing
    `RoutineLabelResolver`) and each row renders the subtitle as a compact
    `.dsCaption` / `.secondary`, single-line-truncated line **below the routine
    label**.
- **Counting semantics:**
  - **`exerciseCount = workout.items.count`** — structural, not unique. A nil/deleted
    `exercise` reference still counts (the item is a real, snapshot-backed history row).
  - **`setCount` = non-warmup `SetLog` rows** (`kind != .warmup`): `.working` and
    `.dropset` count; `.warmup` is excluded so the headline number reflects work
    performed, not prep (no visible inconsistency — `WorkoutDetailView` has no total
    and labels warmups separately).
  - Volume / PRs intentionally **out of scope for v1**.
- **Subtitle wording:** `"Empty workout"` (0 items) · `"N exercise(s)"` (items, 0
  counted sets — set clause omitted) · `"N exercise(s) · M set(s)"`; correct
  singular/plural, `" · "` separator (matches `RoutineSummary`).
- **In-progress workouts** show the same structural summary (reflecting what's logged
  so far) while keeping the existing "In Progress" pill.
- **Bundled History blocked-delete styling fix:** the in-progress (active) workout's
  swipe-delete was still red even though deletion is blocked. It now uses the
  app-wide **gray + `lock.fill` + "In Progress"** blocked/in-use styling; completed
  workouts keep the **red + trash + "Delete"** action. The existing "Can't delete
  active workout" alert/behavior is unchanged. Aligns History with the convention
  used by locked Exercise / Routine rows (red = available, gray = blocked).
- **No model/schema change.** Build succeeded; full suite **421/421** (Slice A added
  13 `WorkoutSummaryTests` — empty / one-item / multiple, singular-plural wording,
  warmup-exclusion, working+dropset counting, all-warmup omits set clause, nil-exercise
  safety, in-progress structural summary, `map(for:)` keyed by `Workout.id`, empty-map
  input); manual regression passed. (Files: `Log/Services/WorkoutSummary.swift`,
  `LogTests/WorkoutSummaryTests.swift`, `Log/Main/HistoryView.swift`.)

### 2.9 RoutineEditor block prescription summaries — ✅ SHIPPED (2026-05-29)
- **Source:** Next-slice planning audit after §2.8 — the §4-ranked "block prescription
  summary" candidate, chosen as another `RoutineSummary`-style pure-helper slice. Block
  rows previously showed only the joined exercise names + a "Details" link, so the
  prescription (sets/reps/rest) was invisible without tapping in.
- **Nature:** a read-only **glanceability** improvement. No new persisted state, no
  model/schema change.
- **Status:** **Done**, shipped in two slices:
  - **Slice A — pure helper.** Added `Log/Services/BlockPrescriptionSummary.swift`
    (`Equatable` value type: normal + superset value-in inits, `init(block:)`,
    `subtitle`, `map(for:)` keyed by `block.slotID`). Pure — no `ModelContext`, no
    fetches, no mutation; reads `RoutineBlock` / `RoutineExercise` / `SlotPrescription`
    fields only and **never dereferences `RoutineExercise.exercise`**.
  - **Slice B — view wiring.** `BlockRow` gained an additive `subtitle: String? = nil`
    rendered as a compact `.caption` / `.secondary`, single-line-truncated line below
    the title; `RoutineEditor.blockRowView(for:)` passes
    `BlockPrescriptionSummary(block:).subtitle`.
- **Summary semantics (structured `SlotPrescription` fields = authoring intent, NOT
  `resolvedTemplates()` / per-set overrides):**
  - **Normal block** (lowest-`order` slot): `"3 × 8–12"`, equal/one-sided range →
    `"3 × 8"`, sets-only → `"3 sets"`, time-based → `"3 × 45s"`, trailing rest →
    `"3 × 8–12 · 90s rest"`, no usable sets / nil prescription → `"Not set"`.
  - **Superset block** (block-level): `"Superset · N exercises · M sets"` where
    `N = block.exercises.count` (structural — nil/deleted slots still count) and `M` =
    the **max** child `prescription.sets` (matching
    `SupersetDetailNoRest.currentSetsValue`); `M` omitted when no child has positive
    sets → `"Superset · N exercises"`.
  - Weight, RIR/RPE, tempo, and other autoregulation are **out of scope for v1**
    (tracked as future enhancements in §3.7).
- **Refresh-after-edit:** a `blockSummaryRefresh` `@State` token bumped from each block
  detail's `.onDisappear` invalidates the editor body so the subtitle recomputes on
  return. This is a deliberate **view-lifecycle** trigger, not a nested-`@Model`
  observation hack — chosen because edits to a grandchild `SlotPrescription` property
  aren't reliably observed by `@Bindable var routine` (same limitation documented on
  `SupersetDetailNoRest.displayedSets`).
- **No model/schema change.** Build succeeded; full suite **441/441** (Slice A added
  20 `BlockPrescriptionSummaryTests` — normal wording incl. range/rest/equal-bounds/
  single-bound/sets-only/time-based/no-usable-sets/rest-omission, superset uniform/
  mixed-uses-max/all-nil/nil-exercise/singular-plural, `map(for:)` keyed by `slotID`,
  empty input); manual regression passed (incl. refresh-after-edit). (Files:
  `Log/Services/BlockPrescriptionSummary.swift`, `LogTests/BlockPrescriptionSummaryTests.swift`,
  `Log/Main/RoutinesView.swift`, `Log/Main/Routines/RoutineEditor.swift`.)
- **Future-optional enhancements (pending):** weight, RIR/RPE, and tempo in the
  summary, and richer **per-slot** superset summaries (vs the current block-level
  line). See §3.7.

### 2.10 Routine duplication — ✅ SHIPPED (2026-05-29)
- **Source:** The high-value "Routine duplication" candidate flagged in the next-slice
  audits. Planned as a dedicated feature (not a casual polish slice) because it is a
  delicate deep-clone of the routine relationship graph.
- **Nature:** a new **user-facing feature** (clone a routine to base a new one on it).
  Additive behavior only — no new persisted state beyond the copied graph.
- **Status:** **Done**, shipped in four slices:
  - **Slice A — pure copied-name helper.** `RoutineDuplicator.copiedName(for:existingNames:)`
    + tests: base `"<trimmed> copy"`; case-insensitive collisions append `" 2"`, `" 3"`,
    …; trims original + existing names; empty original → `"Routine copy"`.
  - **Slice B — deep-copy service.** `@MainActor RoutineDuplicator.duplicate(_:among:in:)`
    + tests. Deep-copies the full graph and `ctx.save()`s once at the end.
  - **Slice C — swipe action.** A non-destructive blue **"Duplicate"** swipe action on
    Saved Routines rows (alongside red Delete / gray In-use).
  - **Slice C.2 — edit-mode context menu.** A long-press **"Duplicate"** context-menu
    item, added **specifically because swipe actions are unreachable while the list is
    in edit mode**; it works in both normal and edit mode and reuses the Slice-C handler.
- **Deep-copy data-safety invariants (tested):**
  - Fresh identities: new `Routine.id`, a new empty `Default` `RoutineVariant` (fresh
    id; source variants not copied), fresh `RoutineBlock.slotID` per block, fresh
    `RoutineExercise.slotID` per slot.
  - Deep-copied (independent instances): `SetTemplate`, `SlotPrescription`,
    `TechniquePlan` (raw/encoded fields copied directly), `WarmupScheme` + `WarmupStep`
    (must be copied, not shared — `WarmupSchemeEditor` mutates schemes in place).
  - **Shared intentionally:** the definition-level `Exercise` references only (never
    cloned); a deleted/unlinked source slot copies as a still-nil reference.
  - **Source routine is never mutated**; History / `Workout` / `WorkoutItem` untouched;
    no model/schema change. Mutation-isolation asserted for prescriptions, setTemplates,
    and warmup steps.
- **Behavior:** the duplicate gets a unique `"… copy"` / `"… copy 2"` name and a
  **trailing `order`** (appears at the end of Saved Routines once the `@Query`
  refreshes); a success haptic fires; **no auto-navigation** into the new routine
  (deliberate v1 choice).
- **Lock semantics:** **Duplicate is allowed for locked/in-use routines** (read-only on
  the source) via both swipe and context menu; **Delete stays blocked** for in-use
  routines (gray "In use" + locked alert).
- **No model/schema change.** Build succeeded; full suite **460/460** (8 copied-name
  `RoutineDuplicatorTests` + 11 deep-copy `RoutineDuplicatorServiceTests`: name
  collisions, trailing order, fresh identities, structural equality, shared `Exercise`,
  deep-copy isolation for prescriptions/setTemplates/techniquePlans/warmups, superset
  copy, nil-exercise / nil-prescription edge cases, source-unchanged, save/refetch);
  manual regression passed. (Files: `Log/Services/RoutineDuplicator.swift`,
  `LogTests/RoutineDuplicatorTests.swift`, `Log/Main/RoutinesView.swift`.)
- **Future-optional enhancements (pending):** a Duplicate action inside the
  `RoutineEditor` toolbar, and optionally auto-opening the duplicate in the editor after
  creation. See §3.8.

## 3. Optional / Future Features

Product ideas, not refactor blockers. Implement only on demand.

### 3.1 Technique design follow-ups (treat as future design items)
These three are explicitly **out of scope until a design pass**, per the plan.

- **Rest-Pause / Cluster sub-set logging (Phase 3.8b, optional)** — extend
  drop-style sub-set logging to Rest-Pause / Cluster. Status: not started, not
  required. Recommendation: **keep optional** (only if these techniques are
  retained and designed as multi-sub-set). Risk: **medium** (new logging model
  surface).
- **Rest-Pause / Cluster rest-timer design (Phase 3.8 follow-up)** — today
  Dropset is the *only* rest-affecting technique; Rest-Pause/Cluster `restSeconds`
  is display-only. Auto-running an intra-set rest is a new feature needing an
  explicit rest-semantics design. Recommendation: **defer** (design first). Risk:
  **medium**.
- **Dropset + technique ordering / targeting ambiguity (Phase 3.8 follow-up)** —
  a set can show both a dropset card and another technique's chip with no ordering
  clarification; per-drop technique targeting needs a model extension.
  Recommendation: **defer** (design first). Risk: **medium** (model change).

### 3.2 History sectioned grouping (Phase 6.B Slice C.2)
- **Source:** Phase 6.B Slice C.2.
- **Current status:** Explicitly deferred. C.1 (flat list with live-resolved
  labels) is shipped; C.2 would switch History to per-variant `Section` grouping
  with an "Other / Unlinked" bucket.
- **Why it matters:** Larger UX change; "should not be started without explicit
  confirmation." `RoutineLabelResolver` cache strategy is reusable if pursued.
- **Recommendation:** **keep optional** (design decision required first).
- **Risk:** **medium** (UX change; must keep grouping out of SwiftUI `body`).

### 3.3 10-F — Slot-level equipment override
- **Source:** Phase 10-F.
- **Current status:** Explicitly optional / not shipped. Would add
  `SlotPrescription.equipmentOverride: String?` (additive) and prefer it over
  `Exercise.equipmentType` in the snapshot.
- **Why it matters:** Only matters for "same Exercise, different equipment per
  routine" — no concrete use case has surfaced.
- **Recommendation:** **keep optional** — do **not** build speculatively (conflicts
  with CLAUDE.md "don't add features beyond what the task requires"). Build only on
  a concrete use case.
- **Risk:** **low** (additive field) but unjustified without a use case.

### 3.4 Additional prescription enrichment (§5 "later" candidates)
- **Source:** §5 Prescription Elements → "Additional production-grade candidates".
- **Items:** set targeting mode (straight / top-set+backoff / ramping); intensity
  guidance (%1RM, suggested-load rules); structured tempo/ROM beyond the single
  tempo string; structured grip/stance/cues; autoregulation stop/adjust rules;
  progression hints (last-time summary, suggested load increases — read-only).
- **Recommendation:** **keep optional** (explicitly "NOT part of the current
  refactor scope"; future enrichment). Weight stays session-truth — never
  auto-write to templates.
- **Risk:** **medium–high** (model surface growth; design-heavy).

### 3.5 General backlog (§6)
All **keep optional / defer**, low refactor relevance:
- preset note options — Risk: low
- pause/resume workout (may integrate with `WorkoutState`) — Risk: medium
- machine-specific weight/rep handling — Risk: medium
- separate exercise progression history UI + charts — Risk: medium
- full existing-history cleanup UI — Risk: medium
- CSV import/export — Risk: medium

### 3.6 AP Calculus showcase polish (§9 Pending / optional)
- **Source:** §9 addendum.
- **Items:** more video-friendly explanation polish; screenshot/export-friendly
  layout; a History shortcut/entry point (today lives under Settings → Showcase).
- **Recommendation:** **keep optional** — "Only pursue if the showcase graduates
  into a regular user-facing analytics feature; not required for the AP Calculus
  AB video."
- **Risk:** **low** (read-only, value-typed, no persistence per locked safety
  decisions).

### 3.7 Block prescription summary enrichment (§2.9 follow-ups)
- **Source:** §2.9 shipped block prescription summaries; these are the deferred
  v2 enhancements.
- **Items:** add **weight**, **RIR/RPE**, and **tempo** to the block subtitle (v1
  excludes them — weight pulls in `Units`, autoreg/tempo overcrowd one line); and a
  richer **per-slot** superset summary (v1 is block-level: "Superset · N exercises ·
  M sets" using max child sets, with no per-exercise rep ranges).
- **Recommendation:** **keep optional** — implement only if the compact v1 line proves
  insufficient in practice. `BlockPrescriptionSummary` is pure/value-typed, so any
  addition is an additive helper change + tests, not a model change.
- **Risk:** **low** (read-only display; no model/schema impact).

### 3.8 Routine duplication follow-ups (§2.10 follow-ups)
- **Source:** §2.10 shipped routine duplication; these are the deferred niceties.
- **Items:** a **"Duplicate" action in the `RoutineEditor` toolbar** (duplicate the
  routine you're currently viewing), and optionally **auto-opening the duplicate** in
  the editor right after creation (v1 deliberately stays on the list and does not
  navigate).
- **Recommendation:** **keep optional** — implement on demand. Both reuse the existing
  tested `RoutineDuplicator.duplicate(_:among:in:)`; the toolbar entry needs the
  routine list in scope (or a small `@Query`) and the auto-open needs the same
  value-based navigation the list already uses.
- **Risk:** **low** (additive UI over an already-tested service; no model/schema impact).

### 3.9 Future Analytics / History Insights — BACKLOG (future / optional)

> **These are backlog ideas only — not implement-now, not shipped.** None has been
> built; none is scheduled. They should be implemented **only after a focused
> design/audit pass**, because several require non-trivial aggregation rules, date
> grouping (week/month boundaries), body-part mapping, and unit/volume semantics that
> must be settled before any code is written. Listed here so the analytics direction is
> captured without committing to it.

- **Source:** Product brainstorm (2026-05-30) — extends the read-only History /
  routine glanceability slices (§2.5, §2.8, §2.9) toward richer workout insights.
- **Nature:** future analytics / reporting features over existing snapshot data
  (`Workout` / `WorkoutItem` / `SetLog`, `Routine` / `RoutineBlock`, `Exercise.bodyPart`).
  Most are read-only aggregations; a few (notes/tags, CSV export) add small surfaces.
- **Recommendation:** **keep optional / defer** — pick up only on demand and only after
  the design/audit note above. Do **not** build speculatively.
- **Risk:** **low–medium** (mostly read-only aggregation; the risk is in getting the
  aggregation / grouping / unit semantics right, not in model changes).

**User-requested backlog items:**
- **Total volume per set in History** — show per-set volume (e.g. weight × reps) on
  History set rows. Needs a unit/volume definition (bodyweight, time-based, and
  warmup-set handling).
- **Total sets per routine** — a per-routine total-set count (prescribed). Relates to
  the existing `RoutineSummary` slot/superset counting (§2.5); needs a "prescribed
  sets" rollup rule.
- **Sets per body part per week** — weekly set count grouped by body part. Needs week
  boundaries + body-part mapping from `Exercise.bodyPart`.

**Brainstormed related ideas (all future / optional):**
- **Weekly volume per body part** — volume aggregated by body part over a week window.
- **Weekly set count per exercise** — per-exercise set totals per week.
- **Recent PR summary per exercise** — surface recent personal records per exercise.
- **Estimated 1RM trend per exercise in History** — e1RM over time (needs an e1RM
  formula choice + how to treat non-straight/technique sets).
- **Best set highlight inside Workout Detail** — flag the top set per exercise in
  `WorkoutDetailView` (needs a "best" definition: by load, by volume, or by e1RM).
- **Workout density: volume per minute** — total volume ÷ workout duration.
- **Average rest time per workout** — mean logged/observed rest across sets.
- **Routine frequency: times completed per week/month** — completion counts per
  routine over a window (needs the routine-linkage already used by
  `RoutineLabelResolver`).
- **Muscle / body-part balance summary** — distribution of work across body parts to
  spot imbalances.
- **Consistency streak / completed-workout streak** — current/longest streak of
  completed workouts (needs a streak/day-boundary rule).
- **Exercise-specific history from Exercise Detail** — a per-exercise history view
  reachable from Exercise Detail (relates to the §3.5 "separate exercise progression
  history UI" backlog item).
- **Filter History by routine, exercise, or body part** — History filtering surface
  (complements the deferred History sectioned grouping in §3.2).
- **Export workout history as CSV** — overlaps the §3.5 / §6 CSV import/export backlog;
  cross-referenced rather than duplicated.
- **Workout notes / tags for fatigue, soreness, or performance** — optional per-workout
  notes/tags. This is the only group member that adds **persisted state**, so it needs
  an explicit additive-model design pass before any work.

---

## 4. Blocked Items

_No currently blocked items._ Both items that were blocked on routine rename UI
are now resolved — routine name editing shipped 2026-05-27 (§2.1). They are kept
here, marked done, for traceability.

### 4.1 Live rename → History/WorkoutDetail label verification — ✅ DONE (2026-05-27)
- **Source:** Phase 6.B Slice C ("Pending — verification gated on rename UI").
- **Status:** **Verified.** With rename shipped, `RoutineLabelResolver` resolves
  the live routine name whenever the routine still exists, and History's `@Query`
  re-renders on rename with no persisted-field rewrite. Pinned by
  `RoutineLabelResolverTests.testRenameUpdatesResolverLabelAfterSaveAndRefetch`
  (rename → save → refetch → new label; `Workout.routineName` / `routineID` /
  `routineVariantID` asserted unchanged). Default-variant collapse to the routine
  name confirmed. Manual: rename → History label updates without relaunch.
- **Risk:** n/a (closed).
- **Note:** the non-Default *variant* rename cases (rename to/from "Default") are
  not exercisable in the UI yet because variant rename UI is deferred (§2.1a); the
  resolver already supports them and they are covered at the model/unit level.

### 4.2 History labels / grouping by RoutineVariant survive name changes — ✅ DONE (2026-05-27)
- **Source:** Phase 7 (optional coverage gap).
- **Status:** **Done.** Covered by
  `RoutineLabelResolverTests.testRenamedThenDeletedRoutineFallsBackToSnapshot`
  (renamed-then-deleted routine falls back to the frozen `Workout.routineName`
  snapshot) plus the rename-after-save/refetch test above; grouping IDs
  (`routineID` / `routineVariantID`) asserted stable across rename.
- **Risk:** n/a (closed).

---

## 5. Performance / Testing Follow-ups

Optional tests / audits. None block any product work.

### 5.1 End-to-end cold-restart resume test
- **Source:** Phase 7 (optional). Status: *partially covered* —
  `WorkoutResumeServiceTests` covers the plan-rebuild side and `AppStateLifecycleTests`
  covers the `activeBlockIndex`/`activeExerciseIndex`/`sessionPlansJSON` round-trip.
  The end-to-end flow (`RootTabView.checkForActiveSession` reading those fields and
  wiring `ActiveWorkoutGuard.beginSession`) remains view-coupled.
- **Why it matters:** Full cold-restart fidelity is currently manual-test only.
- **Recommendation:** **keep optional** (would require view extraction or a UI test).
- **Risk:** **low**.

### 5.2 Performance: summary-field caching for History
- **Source:** Phase 7. Status: **verified not needed at current scale (2026-05-26)** —
  grouping is a pure O(n)/O(n log n) function over one workout's items, label
  resolution is O(1) per row from a once-per-body resolver; no O(n²) path found.
- **Why it matters:** Only relevant on a real-user perf signal (very large history).
- **Recommendation:** **keep optional / defer** — revisit only on a measured signal.
- **Risk:** **low**.

### 5.3 `RestTimer.stableNotificationID` nil-slotID coverage
- **Source:** Phase 7.4. Status: gated on an API change — would extend the
  production signature to accept `slotID: UUID?` and add nil-aware tests.
- **Why it matters:** No caller passes nil today; "the API change should not be
  made speculatively."
- **Recommendation:** **defer** (only if a real nil-slot consumer appears).
- **Risk:** **low**.

> Host-less `LogTests` conversion was previously listed here. It has been moved to
> §7 (Archive) — see §7.4 — because it was attempted and reverted and should not be
> treated as active testing work.

---

## 6. Architecture / Deprecation Follow-ups

Structural cleanup. Most are **defer** — they touch load-bearing or large surfaces
and should not be done casually. Per guidance, Phase 8 removals are **not**
recommended absent a strong safety reason.

### 6.1 `RoutineExercise.setTemplates` — reframed, do NOT prune
- **Source:** Phase 8 (broader, pending).
- **Current status:** After Phase 9 removed `Exercise.defaultTemplates`,
  `setTemplates` became the **load-bearing Tier 1** explicit template source in
  `resolvedTemplates` (Tier 3 is gone).
- **Why it matters:** It is no longer a simple deprecation candidate. Must NOT be
  removed without a fresh design pass that re-homes any Tier-1 consumers onto
  `SlotPrescription`.
- **Recommendation:** **defer** — treat as a design investigation, not a quick
  prune. No safety reason to remove it now.
- **Risk:** **high** (load-bearing resolution path).

### 6.2 Deprecate `Workout.routineName` as primary grouping link
- **Source:** Phase 8 (broader, pending).
- **Current status:** `routineName` is now a display fallback only;
  `RoutineLabelResolver` already prefers `routineVariantID` → `routineID` → the
  `routineName` snapshot. Formal deprecation not done.
- **Why it matters:** Cleanup of legacy string-based linkage; keep as display
  fallback.
- **Recommendation:** **defer** (no functional pressure; resolver already routes
  around it).
- **Risk:** **medium**.

### 6.3 Migration tool + stable-fallback policy for device data cleanup
- **Source:** Phase 8 (broader, pending) — two items: "consider migration tool for
  existing device data cleanup" and "keep fallback read-only until migration is
  proven stable across updates."
- **Recommendation:** **defer** (no current need; bootstrap backfills already run
  idempotently at launch).
- **Risk:** **medium**.

### 6.4 `PlanSetTemplate.targetWeight` remains `Int?`
- **Source:** Phase 3.9a (deferred, structural).
- **Current status:** Prescribed-default target weights are integer in the
  session-plan snapshot type. User-entered decimals are unaffected
  (`SetLog.weight` is `Double?` end-to-end).
- **Why it matters:** Only matters if decimal *prescribed* defaults become a
  requirement; widening to `Double?` is a snapshot/model design change.
- **Recommendation:** **defer** (revisit only if decimal prescribed defaults are
  needed).
- **Risk:** **medium** (snapshot/model change).

### 6.5 Fold `RoutineBlock.restAfterSeconds` into slot-level rest fields
- **Source:** §5 Prescription Elements (rest semantics, future).
- **Current status:** Slot-level rest fields + `supersetRoundRestSeconds` are
  wired; `RoutineBlock.restAfterSeconds` is retained for compatibility (superset
  transition rest + legacy non-superset additive).
- **Why it matters:** Long-term consolidation of the rest model.
- **Recommendation:** **defer** (the current decomposition works and is tested;
  consolidation is a design pass).
- **Risk:** **medium**.

### 6.6 Phase 12 — MVVM / viewmodel hoist (carried from Phase 11)
- **Source:** Phase 11 "Deferred to Phase 12".
- **Current status:** Phase 11 file decomposition closed; three clusters carried
  forward, all needing a logic refactor (not a pure file move):
  - **11.6-C** — per-concern extension files (Superset / Persistence / Swap /
    Snapshot / Logging / Techniques helpers); each would force `@State` access
    bumps to default-internal.
  - **11.6-D** — `restSecondsAfterCurrentLog` extraction (thin shell over
    `RestPlanner.*`); depends on 11.6-C's access surface.
  - **`@ViewBuilder` methods that capture `@State`** (`buildSetRow`,
    `buildWarmupRow`, `buildDropSection`, `buildWorkingSetGroup`, `planSummarySection`,
    `buildTechniqueChips`) — require hoisting state into an `ObservableObject`
    viewmodel.
- **Why it matters:** `ActiveWorkoutView.swift` floor (~3,030 LOC) is dominated by
  these; further reduction (~2,150–2,300) needs the viewmodel hoist.
- **Recommendation:** **defer** (Phase 12; logic refactor, behavior-preserving but
  not trivial; decide access surface alongside the viewmodel).
- **Risk:** **high** (touches the active-workout `@State` graph — the app's most
  behavior-critical view).

### 6.7 `LockBadge` badge-cleanup consolidation
- **Source:** Phase 11.3 "Deferred badge cleanup".
- **Current status:** `BlockRow` is default-internal; two visually-different
  `LockBadge` types stay file-private (one in `RoutinesView`, one in `ExercisesView`)
  because Swift's module-wide top-level namespace collides on a default-internal
  promotion. ~40 LOC consolidation pending.
- **Why it matters:** Purely cosmetic consolidation; not blocking anything.
- **Recommendation:** **keep optional** — a naming/redesign call (rename one,
  unify designs, or move both to one file), not a Phase-12 concern.
- **Risk:** **low**.

### 6.8 Stale doc-comment cleanup pass
- **Source:** Phase 9-E (deferred).
- **Current status:** Partial — files touched by 9-E were updated; historical
  `Exercise.defaultTemplates` references in several other files were intentionally
  kept as audit trail.
- **Recommendation:** **keep optional** ("comments cost zero runtime"; skipping is
  acceptable).
- **Risk:** **low**.

---

## 7. Archive / Stale / Superseded

No longer actionable as written — later phases removed their preconditions. Do not
implement these as specified.

### 7.1 Phase 9-E1.5 — conditional pre-flight `defaultTemplates` migration
- **Source:** Phase 9-E1.5 (4 unchecked items: add
  `migrateAtRiskDefaultTemplatesToTier1`, wire into bootstrap, add a test, ship as
  its own release).
- **Why archived:** All reference `Exercise.defaultTemplates`, which **no longer
  exists** (deleted in 9-E2). The 9-E diagnostic returned **all zeros** on real
  local data, so there was nothing at-risk to migrate; the sub-slice was
  explicitly marked "⊘ NOT NEEDED." Only re-activates if a future *broader*
  observation surfaces at-risk rows on a build that still had the field — i.e. not
  on current `main`.
- **Recommendation:** **archive.**
- **Risk:** n/a.

### 7.2 Optional integration test pinning `diagnoseDefaultTemplatesRisk(...).slotsNeedingTier3 == 0`
- **Source:** Phase 9-C2 (deferred optional test).
- **Why archived:** `BackfillService.diagnoseDefaultTemplatesRisk(in:)` and the
  `DefaultTemplatesDiagnostics` type were **deleted in 9-E2**. The test cannot be
  written as specified. The underlying "no slot stranded" invariant is now covered
  by hydration + `PurgeOrphanSetTemplatesTests`.
- **Recommendation:** **archive.**
- **Risk:** n/a.

### 7.3 "Unprogrammed slot" routine-editor UX (gated on `slotsOrphanedNoSource`)
- **Source:** Phase 9-C (deferred optional).
- **Why archived:** Gated on the diagnostic ever showing non-zero
  `slotsOrphanedNoSource`. That diagnostic was removed in 9-E2 and observed zero
  before removal; bootstrap hydration populates every empty-content slot at every
  launch, so the "unprogrammed slot" state should be statistically unreachable.
- **Recommendation:** **archive** (revisit only if real-user reports of empty
  slots ever appear — which would be a new investigation, not this item).
- **Risk:** n/a.

### 7.4 Host-less `LogTests` conversion
- **Source:** Phase 7.5.
- **Current status:** **Attempted and reverted** — clearing `TEST_HOST` /
  `BUNDLE_LOADER` caused ~30 undefined-symbol link errors (iOS app targets aren't
  frameworks). A path forward exists only via extracting the testable code into a
  separate framework / SwiftPM module.
- **Why archived:** The only loss from staying app-hosted is cosmetic CoreData log
  noise (documented as expected in CLAUDE.md). Not worth the structural cost.
- **Recommendation:** **archive** — do not pursue unless a major framework / module
  split happens for other reasons.
- **Risk:** medium (structural project restructuring) — but archived, so not active.

### 7.5 §5 "equipment/setup is future Phase 10" note
- **Source:** §5 Prescription Elements ("`equipmentType` + `setupDefaults` —
  **future** (Phase 10; currently on SlotPrescription, migrating out)").
- **Why archived:** Stale wording. Phase 10 **shipped** — equipment/setup now live
  on `Exercise`, the `SlotPrescription` fields were removed in 10-E, and the
  snapshot reads from `Exercise`. The "future / migrating out" framing no longer
  describes reality.
- **Recommendation:** **archive** (descriptive staleness in the source doc; nothing
  to implement).
- **Risk:** n/a.

---

## 8. Recommended Implementation Order

Highest-value next items, in order:

1. ✅ **Routine name editing UI** (§2.1) — **SHIPPED 2026-05-27.** Also closed the
   two rename-verification items (§4.1 + §4.2).
2. ✅ **Multi-select exercise add** (§2.2) — **SHIPPED 2026-05-27** across all three
   add surfaces (normal-block add, existing-superset add, new-superset creation).
3. ✅ **"Used in Routines" Exercise-detail summary** (§2.3) — **SHIPPED 2026-05-27**
   (read-only; lists routine names with per-routine slot context; freeze bug fixed
   by moving the `@Query` into `ExerciseDetailHost`).

✅ **Add-field keyboard / search-focus polish** (§2.4) — **SHIPPED 2026-05-27** as a
reactive fix found in manual testing (not a planned ordered item): clears add-field
focus and Exercises search mode on navigation so the keyboard no longer reappears and
Edit/Reorder controls return; the rejected `.simultaneousGesture` approach is recorded
in §2.4.

✅ **Routine row summary subtitle** (§2.5) — **SHIPPED 2026-05-28** as the first
intentional UI-polish slice: read-only slot/superset subtitle on Saved Routines rows
(glanceability, not a data-model feature). Computed via a pure `RoutineSummary` helper
built once per render; full suite **399/399**.

✅ **Search UX consistency** (§2.6 A–D) — **SHIPPED 2026-05-28** (`0422c2d`). One
uniform policy across every `.searchable` surface (History progression picker,
ExercisesView, routine-editor exercise pickers): bars pinned with
`.navigationBarDrawer(displayMode: .always)`, every `.onSubmit(of: .search)`
routed through a shared `dismissKeyboard()` helper, a compact keyboard
Done/checkmark fallback for the empty-after-delete case, and stabilized
ExercisesView search-return (keyboard stays hidden, Edit/Sort return). Full
suite **399/399**, manual regression passed. **Accepted limitation:** the
empty-after-delete system Search key stays blue but inert and cannot be greyed
via standard SwiftUI/UIKit APIs — Done/checkmark + scroll are the reliable
dismissals (no introspection/appearance/custom-keyboard hacks; see §2.6 C). E
(Exercise list send-to-top/bottom) is a future-optional scope-separated note
under §2.6; do not bundle.

✅ **Exercise list section headers** (§2.7) — **SHIPPED 2026-05-29** in two slices.
Slice A added the pure `ExerciseSorter.sections(_:mode:)` helper + `ExerciseSection`
type + `unspecifiedSectionTitle` constant (contiguous-run partition over the existing
sort, no `Dictionary(grouping:)`, no mutation). Slice B wired it into `ExercisesView`:
Body Part and Equipment sort now render one `Section` per group (trailing
"Unspecified"), Manual and Alphabetical stay flat, grouped modes are read-only
(no `.onMove`), search filters before grouping with empty groups dropped and a
"No exercises match …" row, and edit-delete resolves offsets section-safely. Full
suite **408/408**, manual regression passed.

✅ **History row summary subtitles** (§2.8) — **SHIPPED 2026-05-29** in two slices.
Slice A added the pure `WorkoutSummary` helper + 13 tests (exercises = `items.count`,
sets = non-warmup `SetLog` count, structural / nil-exercise-safe, `map(for:)` keyed
by `Workout.id`). Slice B wired it into `HistoryView.recentWorkoutsSection` as a
compact read-only subtitle below the routine label, built once per render next to
`RoutineLabelResolver`; in-progress workouts show the same line alongside the "In
Progress" pill. Bundled a small blocked-delete styling fix: the in-progress
workout's swipe-delete is now gray (`lock.fill` + "In Progress") instead of red,
matching the app-wide red=available / gray=blocked convention; completed workouts
stay red. No model/schema change; full suite **421/421**, manual regression passed.

✅ **RoutineEditor block prescription summaries** (§2.9) — **SHIPPED 2026-05-29** in
two slices. Slice A added the pure `BlockPrescriptionSummary` helper + 20 tests
(normal blocks from structured `SlotPrescription` fields = authoring intent, not
`resolvedTemplates()`; supersets block-level with max-child sets; never dereferences
`RoutineExercise.exercise`; `map(for:)` keyed by `block.slotID`). Slice B wired it
into `BlockRow` (additive `subtitle`) via `RoutineEditor.blockRowView`, with a
`blockSummaryRefresh` view-lifecycle token (bumped on detail `onDisappear`) so the
subtitle refreshes after a sets/reps/rest edit. No model/schema change; full suite
**441/441**, manual regression passed. Weight / RIR/RPE / tempo / per-slot superset
detail are future-optional (§3.7).

✅ **Routine duplication** (§2.10) — **SHIPPED 2026-05-29** in four slices. Slice A:
pure `copiedName(for:existingNames:)` helper + tests. Slice B: tested deep-copy
`RoutineDuplicator.duplicate(_:among:in:)` (fresh `Routine`/Default-variant/block/slot
IDs, shared `Exercise` refs, deep-copied setTemplates / prescriptions / techniquePlans /
warmup schemes; source never mutated). Slice C: blue non-destructive "Duplicate" swipe
action. Slice C.2: long-press context-menu Duplicate that also works in **edit mode**
(where swipe actions are unavailable). Duplicate allowed for in-use routines (read-only
on source); Delete stays blocked. Duplicate gets a unique "… copy" name + trailing
order, no auto-navigation. No model/schema change; full suite **460/460**, manual
regression passed. Editor-toolbar Duplicate + auto-open are future-optional (§3.8).

**No "implement now" product/UX item remains.** The three top refactor-era
recommendations plus the polish slices (§2.5, §2.6, §2.7, §2.8, §2.9) and the routine
duplication feature (§2.10) have shipped. Everything else is optional / future /
deferred:

- **"Tap a listed routine → Routine Editor"** (§2.3 follow-up) is the only new
  user-facing option, and it stays **optional/future**. A planning audit (2026-05-27)
  recommended **defer**: keep the section read-only; the preferred future direction is
  a `RootTabView`-level **tab switch + deep-link** into `RoutinesView`, not pushing
  `RoutineEditor` inside the Exercises tab. **No code changes made.**
- Routine *variant* rename UI (§2.1a) stays **deferred** until a variant-management
  feature is actually planned (no variant UI exists today).
- Technique design follow-ups (§3.1) and prescription enrichment (§3.4) need design
  passes first.
- The Phase 12 viewmodel hoist (§6.6) is the big structural item but is high-risk
  and not urgent.
- Phase 8 deprecations (§6.1–6.3) should stay deferred absent a concrete safety
  reason.
- Do the TestFlight upgrade (§1) before public App Store promotion.

---

*Generated from `REFACTOR_PLAN.md` on 2026-05-27. For full history, rationale, and
shipped-slice detail, see `REFACTOR_PLAN.md`.*

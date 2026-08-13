# Alternative Exercises — Design

> **Status: design only.** No code, schema, migration, or behavior change is
> proposed by this document itself. Phase A is this file. Everything below is a
> proposal to be sliced under the normal `CLAUDE.md` workflow.
>
> Written against the codebase as of `8deeec2` (post-Entry #12, build 7 prepared
> for TestFlight).

---

## 0. The one-paragraph answer

Alternatives belong to the **routine slot** (`RoutineExercise` /
`SlotPrescription`), are **frozen into the session plan at workout start**, and
are applied at switch time by **reusing the existing
`ExerciseSwitchPlanAdapter`** — a prepared alternative is a third `Choice` whose
`ResetSource` comes from the frozen alternative instead of `AppSettings`. Store
them as an **encoded `Codable` payload** (`SlotPrescription.alternativesData:
Data?`), following the `cardioSegmentsData` precedent, not as a new `@Model`
relationship graph. This is additive, needs no migration beyond a lightweight
optional column, and adds no behavior to routines that have no alternatives.

The user's intuition — slot-owned, not `Exercise`-owned — is **correct**, and
the codebase already states the reasoning explicitly. See §4.1.

---

## 1. Problem Statement

Switching an exercise mid-workout currently offers exactly two outcomes, both
resolved by `ExerciseSwitchPlanAdapter.outcome(choice:...)`:

| Choice | What it does today |
|---|---|
| **Keep current plan** | Preserves set count, rest, effort; adapts or clears tracking-specific fields; clears the slot note; keeps warm-ups/techniques only within the same tracking type |
| **Reset plan for this slot** | Rebuilds from `ResetSource.appDefaults(for:)` — i.e. `AppSettings` defaults for the new mode — carrying **no** warm-ups, **no** techniques, **no** target distance, **no** structured cardio plan, and **no** note |

Neither is right for the real case.

**Reset Plan erases planned prescription detail.** `ResetSource.appDefaults`
deliberately supplies no warm-up scheme, no techniques, no target distance, and
no segment plan — the doc comment is explicit that inventing them "would be
programming a session on the user's behalf." That is the correct decision *for a
default*, but it means resetting onto Machine Chest Press throws away every bit
of planning the slot had, and the app has nothing prepared to put back.

**Keep Current Plan can apply the wrong plan.** The adapter's compatibility
contract preserves set count, rest, and effort across any switch, and preserves
tempo/warm-ups/techniques within the same tracking type. Barbell Bench Press and
Machine Chest Press are both `.strength`, so **everything carries** — including a
barbell warm-up ramp expressed as `percentOfWorking`, a Drop Set technique tuned
to barbell plate math, and a rep range chosen for a free-weight movement. It is
mechanically valid and often programmatically wrong.

**Some detail cannot be rebuilt mid-workout.** The active workout can edit a
session plan through `EditSessionPlanSheet`, but that sheet covers sets, reps,
duration, rest, effort, tempo, target distance and notes — it does **not** author
warm-up schemes (`WarmupSchemeEditor`), techniques (`TechniquePlanEditor`), or
structured cardio segments (`CardioSegmentPlanEditor`). Those live in the routine
editor. So the three most expensive things to lose are exactly the three you
cannot recreate without leaving the workout.

**The active workout screen should stay execution-focused.** `ActiveWorkoutView`
is already ~4,400 lines and the Slice C performance work exists specifically to
stop the body re-rendering on a timer tick. Adding warm-up/technique/segment
authoring to it is the wrong direction. The fix is to let the user *prepare*
alternatives while authoring, and make the in-workout action a one-tap
application of prepared work.

---

## 2. User Goals

1. **Prepare before training.** While editing a routine, attach one or more
   alternative exercises to a slot, each with its own prescription.
2. **Give each alternative real programming.** Its own set count, rep or duration
   range, rest, effort target, tempo, warm-up scheme, techniques, target
   distance, structured cardio plan, and slot note.
3. **Switch in one tap.** During the workout, pick a prepared alternative from
   the switch sheet and have its prescription apply immediately.
4. **Never rebuild mid-workout.** No warm-up or technique authoring in the active
   screen.
5. **Keep the prescription honest.** An alternative prepared for a cardio
   exercise must not land its distance target on a bench press; the existing
   mode-compatibility rules still apply on top of the prepared plan.
6. **Fail safe.** A deleted exercise, a corrupt payload, or an alternative that
   equals the current exercise degrades to something harmless, never a crash and
   never a wrong prescription.
7. **Understand the cost of switching.** Switching currently **deletes the
   slot's logged sets** (see §8.6) — a prepared-alternative flow makes switching
   easier and therefore makes that consequence more likely to be hit by accident.

---

## 3. Naming

| Candidate | Assessment |
|---|---|
| **Backup Exercises** | Implies emergency fallback. Users program alternatives deliberately ("machine day"), not only when a rack is busy. Also collides conceptually with data backup/export, which this app has. |
| **Alternative Exercises** | Planned, neutral, reads correctly in a routine editor section header. Slightly long but unambiguous. |
| **Substitutions** | Accurate gym vocabulary, but it names the *act*, not the *thing you prepared*. "Substitutions: 2" reads oddly on a slot row. |
| **Exercise Alternatives** | Same meaning as Alternative Exercises; worse as a section header because it sorts/reads as being about the exercise definition rather than the slot. |
| **Replacement Exercises** | Implies the original is being retired. The original stays the primary. |

**Recommendation: "Alternative Exercises"**, matching the user's preference, with
"alternative" as the singular noun in body text ("Use this alternative").

Avoid the word "backup" entirely — `RoutineTransfer` export/import is already
described to users in backup/share terms and the overlap would be confusing.

### Suggested labels

| Context | English |
|---|---|
| Routine editor section header | `Alternative Exercises` |
| Empty state | `No alternatives added` |
| Add button | `Add Alternative` |
| Switch sheet group header | `Prepared Alternatives` |
| Switch sheet apply action | `Use Alternative Plan` |
| Switch sheet fallback group | `Other Options` |
| Existing keep action | `Keep Current Plan` |
| Existing reset action | `Reset to Defaults` |
| Unavailable row | `Exercise unavailable` |

Two of these rename existing strings: today the dialog uses `Keep current plan`
and `Reset plan for this slot`. Recommend adopting `Keep Current Plan` /
`Reset to Defaults` **in the same slice** that adds the alternatives group, so
the three options read as one set. That is a `Localizable.xcstrings` change with
Korean translations and `KoreanLocalizationTests` coverage — see §6.5.

---

## 4. Data Ownership / Source of Truth

### 4.1 Where alternatives live — verified against the code

| Option | Verdict |
|---|---|
| **1. `Exercise` (global)** | **Rejected.** Same replacement needs different programming per routine. |
| **2. `Routine`** | **Rejected.** Alternatives are per-movement; a routine-level list cannot say *which* slot it replaces. |
| **3. Routine slot** (`RoutineExercise` / `SlotPrescription`) | **Recommended.** |
| **4. `SessionPlan` only** | **Rejected as the source of truth** — it is in-memory + `AppState` JSON, wiped at session end. But it *is* the correct carrier (see §4.2). |
| **5. Combination** | **This is the answer**: slot owns, session freezes. |

The user asked to verify rather than assume. The codebase already contains the
argument, in `ActiveWorkoutView.performPendingSwap`:

> A structured plan is a property of the *routine slot*
> (`SlotPrescription.cardioSegmentsData`), not of an `Exercise` — there is no
> such column on the exercise, because the same treadmill is programmed
> differently in different routines.

Structured cardio faced exactly this question one slice ago and resolved it the
same way. Three further confirmations:

- **`SlotPrescription` is already the per-slot prescription owner** and already
  holds slot-scoped-but-exercise-flavored data: `targetDistanceMeters`,
  `cardioSegmentsData`, `warmupScheme`, `techniquePlans`.
- **`Exercise` deliberately holds only definition-level data** — name, bodyPart,
  `equipmentType`, `setupDefaults`, flags. Phase 10-E *removed* `equipment` /
  `setupNotes` from `SlotPrescription` to push definition-level data up to
  `Exercise`; putting prescriptions down onto `Exercise` would reverse that
  boundary.
- **The architecture rule in `CLAUDE.md`** states it directly: "Exercise =
  definition-level … Routine slot (template) = prescription + slot notes."

A future "global alternatives library" (§16) can be layered on later as a
*source to copy from*, without changing this ownership.

### 4.2 Freeze at start, like everything else

Starting a workout builds a `WorkoutPlan` of value types (`PlanExercise`,
`PrescriptionSnapshotPayload`, `WarmupStepSnapshot`, `TechniquePlanSnapshot`) —
no live SwiftData references. Alternatives must ride the same path:

```
SlotPrescription.alternatives        (authoring truth, SwiftData)
        │  frozen at makePlan(from:)
        ▼
PlanExercise.alternativesSnapshot    (value types, in the WorkoutPlan)
        │  persisted for cold resume
        ▼
AppState.sessionPlansJSON            (alongside SessionPlan)
```

Why this matters, concretely:

- **Editing a routine mid-workout must not mutate the session.** Non-negotiable
  rule 4 ("No silent template mutation from sessions") and its converse. The
  frozen plan already guarantees this for prescriptions; alternatives get it for
  free by using the same freeze.
- **Deleted exercises degrade safely.** The frozen snapshot carries the
  alternative's `exerciseName`, so a slot whose alternative was deleted from the
  library mid-session still renders a name and can be disabled rather than
  vanishing mid-list.
- **Duplication and transfer stay predictable.** Value types deep-copy for free
  (§12).
- **History reflects what happened.** `WorkoutItem.plannedPrescriptionSnapshot`
  is frozen at item creation; applying an alternative rewrites the *session*
  plan and therefore the snapshot the item freezes — not the routine.

### 4.3 What an alternative owns

| Field | Rationale |
|---|---|
| `id: UUID` | Stable identity for ordering, edit, delete, and test assertions. Survives transfer. |
| `exerciseID: UUID` | Reference to `Exercise.id`, resolved at read time. |
| `exerciseName: String` | Snapshot for display when the reference cannot resolve. |
| Prescription payload | The whole point (§5). |
| `note: String?` | Optional "why/when to use this" — distinct from the prescription's slot note. |
| `order: Int` | User-controlled ordering in both editor and switch sheet. |
| `isEnabled: Bool` | Hide from the switch sheet without deleting the prepared work. Cheap, and the alternative to it is users deleting and re-authoring. |

---

## 5. Proposed Data Model

Sketches, not final code.

### 5.1 The core question: `@Model` relationship vs encoded payload

| | `@Model` + `@Relationship` | Encoded `Codable` payload (`Data?`) |
|---|---|---|
| Schema cost | New entity (+ nested warm-up/technique entities, or reuse of existing ones) | One optional column on `SlotPrescription` |
| Migration | Additive entity; must be added to `LogApp.swift` `.modelContainer(for:)` **and** `SwiftDataTestHarness`'s `Schema(...)` | Lightweight optional column, nil default |
| Deep copy (`RoutineDuplicator`) | Must hand-write copy for every nested type; this is where `purgeOrphanSetTemplates`-class bugs come from | Free — copy the `Data` |
| Delete rules | Needs cascade discipline across ≥3 levels | None |
| Ordering | Manual `order` discipline plus re-sorting on every read | Array order in the payload |
| Querying | Queryable independently | Not queryable |
| Corrupt data | A bad row is a bad row | Tolerant decode → "no alternatives" |
| Exercise reference | Free `nullify` on delete | Manual resolve by `exerciseID`, with `exerciseName` fallback |
| Freeze to value types | Requires a mapping layer | Payload *is already* the value type |

**Recommendation: encoded payload.** The decisive arguments are specific to this
codebase:

1. **The precedent is explicit and recent.** `SlotPrescription.cardioSegmentsData`
   chose `Data?` over a `@Model` graph with this exact reasoning: "segments are
   never queried independently, so rows would buy nothing and cost cascade rules,
   ordering discipline, deep-copy, and an orphan sweep — the class of bug
   `BackfillService.purgeOrphanSetTemplates` exists to clean up." Alternatives
   are never queried independently either.
2. **The value types already exist.** `PrescriptionSnapshotPayload`,
   `WarmupStepSnapshot`, and `TechniquePlanSnapshot` are `Codable` value mirrors
   of exactly the three things an alternative must carry. A `@Model` design would
   store the model form, then convert to these anyway at plan-build time. The
   payload design stores the destination format directly.
3. **Nesting depth.** A relationship design needs `AlternativePrescription` →
   `SlotPrescription`-like → `WarmupScheme` → `WarmupStep`, plus `TechniquePlan`.
   That is a 4-level cascade to get right in `RoutineDuplicator`, the transfer
   importer, and the deletion paths. The payload has none.

The one real cost — a deleted `Exercise` does not auto-nil — is handled
explicitly in §8.7, and is arguably **better**: `RoutineTransfer` already
references exercises *by name* rather than ID, so a name-carrying payload matches
the format the app already uses for portability.

### 5.2 Shape sketch

```
// Value types — Codable, Equatable, no SwiftData.

struct SlotAlternative {
    var id: UUID
    var order: Int
    var isEnabled: Bool          // default true
    var exerciseID: UUID
    var exerciseName: String     // display fallback
    var note: String?
    var prescription: AlternativePrescriptionPayload
}

struct AlternativePrescriptionPayload {
    // Mirrors PrescriptionSnapshotPayload's field set:
    //   sets, repMin/Max, restSecondsBetweenSets, restSecondsAfterExercise,
    //   rir/rpe (+ effortModeRaw, rir/rpeStart|End),
    //   tempo, durationMin/MaxSeconds, usesDuration,
    //   targetDistanceMeters, targetDistanceUnitRaw
    // Plus the two things ResetSource cannot express today:
    var warmupSteps: [WarmupStepSnapshot]
    var techniques: [TechniquePlanSnapshot]
    // Structured cardio, as the nested plan (not a nested blob):
    var cardioSegments: CardioSegmentPlan?
    var slotNotes: String?
}

struct SlotAlternativesPayload {   // the encoded root
    var version: Int               // 1
    var alternatives: [SlotAlternative]
}
```

Storage:

```
extension SlotPrescription {
    var alternativesData: Data?    // new optional column, nil default
}
```

Read/write **only** through normalizing accessors, mirroring
`SlotPrescription+StructuredCardio.swift`:

```
var slotAlternatives: [SlotAlternative]     // tolerant decode; [] on failure
func setSlotAlternatives(_ list: [SlotAlternative])   // empty ⇒ clears column
```

**One representation of "none."** A nil payload, an empty array, and an
unreadable payload all read as `[]`. This is the same rule
`structuredCardioPlan` uses and it means no view checks three states.

`CardioSegmentPlan` is embedded as a nested structure rather than a nested
base64 blob, matching `RoutineTransferCardioSegmentsDTO`'s reasoning: a blob
inside a payload is opaque to inspection and doubles the decode surface.

### 5.3 Migration risk

- **Additive optional only.** One `Data?` column with a nil default on an
  existing `@Model`. This is the same shape as `cardioSegmentsData` (Slice 12C)
  and `targetDistanceMeters` (Slice 5), both of which migrated lightweightly.
- **No new `@Model`** ⇒ no `LogApp.swift` / `SwiftDataTestHarness` schema list
  change ⇒ no class of "every test that touches the new entity fails to fetch."
- **Old routines decode safely** because they have no column value at all;
  `slotAlternatives` returns `[]`.
- **Existing routines behave identically.** Every new code path is gated on a
  non-empty alternatives list. A routine with none must produce a byte-identical
  `WorkoutPlan` and an identical switch dialog. This is a required test (§13).
- **Forward tolerance.** The payload carries `version`. An unknown future
  version decodes what it can; unknown keys are ignored by synthesized
  `Codable`. A payload this build cannot read at all resolves to `[]`, costing
  the alternatives and never the routine.

---

## 6. Routine Editor UX

### 6.1 Placement

The slot prescription editor (`PrescriptionFields.swift`) is already dense —
sets, reps, rest, effort, tempo, duration, target distance, warm-up scheme,
techniques, cardio segments. Alternatives must not become a tenth inline section.

**Recommendation:** a single navigation row at the **bottom** of the slot's
prescription section, below techniques:

```
Alternative Exercises              2  ›
```

pushing a dedicated `SlotAlternativesEditor` screen. Rationale: this mirrors how
warm-up schemes, techniques, and cardio segments already push to their own
editors rather than expanding inline, and it keeps the cost of the feature at
exactly one row for the ~100% of slots that will never use it.

### 6.2 The alternatives list screen

```
Alternative Exercises

  Machine Chest Press                        ›
  3 sets · 8–12 reps · 90s rest · warm-ups

  DB Bench Press                             ›
  3 sets · 8–12 reps · 90s rest

  + Add Alternative

  Alternatives appear when you switch this
  exercise during a workout.
```

- **Empty state:** `No alternatives added`, plus the same one-line footer
  explaining where they show up.
- **Summary line:** reuse `BlockPrescriptionSummary` / `SlotPrescription`
  summary helpers so the compact text matches the rest of the app instead of
  inventing a fourth summary format. Append `· warm-ups`, `· techniques`,
  `· Cardio Plan` as presence flags only — no counts, no detail.
- **Delete / reorder:** standard `.onDelete` / `.onMove`, matching the existing
  technique and segment lists.
- **Disabled:** an `isEnabled == false` row renders dimmed with a trailing
  `Off`. Toggle lives in the alternative's detail screen, not as a swipe action.

### 6.3 Adding one

1. `+ Add Alternative` presents the existing exercise picker
   (`ExercisePickers.swift`), the same one the swap flow uses.
2. On pick, create the alternative **seeded from the app's default prescription
   for the picked exercise's tracking mode** — i.e. exactly what
   `makeDefaultPrescription(isTimeBased:isCardio:in:)` /
   `ResetSource.appDefaults(for:)` would produce. Not seeded from the primary
   slot: the whole premise is that the primary's plan may be wrong for it.
   - Offer **`Copy from current plan`** as an explicit secondary action inside
     the detail editor for the case where it *is* a good starting point.
3. Push straight into the alternative's prescription editor so the user lands
   where the work is.

### 6.4 Editing the prescription — reuse, don't fork

**Reuse `PrescriptionFields` and its child editors.** They already encode every
rule the app needs: `CardioRoutineRules` gating, tempo suppression for duration
slots, Tempo Override incompatibility, technique conflict rules, distance-unit
handling, duration ceilings and clamping.

The obstacle is that those editors are written against a live
`SlotPrescription` `@Model`, while an alternative is a value payload. Two ways
out:

| Approach | Assessment |
|---|---|
| **A. Bind to a scratch `SlotPrescription`** — materialize an unattached `SlotPrescription` (plus `WarmupScheme` / `TechniquePlan` children) in the editor, bind existing views to it, encode back to the payload on save; discard the scratch objects on cancel | **Recommended.** Zero duplication of editor logic and rules. Cost: the scratch graph must be inserted-then-deleted or built in a throwaway context, and that deletion must be reliable, or it becomes the orphan-row bug class. Contain it in one `AlternativeDraftStore`-style helper with a single tested lifecycle. |
| **B. Generalize the editors over a protocol** | Cleaner in principle; in practice it means touching ~2,000 lines of working, shipped editor code to add a feature, with regression risk to authoring paths that are currently correct. Rejected for MVP. |

If A proves fragile in Phase D, the fallback is a **reduced** alternative editor
(sets/reps/duration/rest/effort/tempo/distance only, no warm-ups/techniques/
segments) for MVP, with the full editor deferred. That would still solve the
Bench → Machine case partially, but it forfeits the three fields §1 identifies
as the expensive ones — so treat it as a fallback, not a plan.

### 6.5 Korean localization

- Every new string goes through `String(localized:)` and gets a Korean value in
  `Localizable.xcstrings`, with coverage added to `KoreanLocalizationTests`
  following the existing per-feature test pattern
  (`testCardioDetailsStringsLocalizeToKorean` and siblings).
- Suggested Korean: `대체 운동` for "Alternative Exercises" — standard, short
  enough for a section header and a navigation row, and it does not collide with
  `교체` (swap/replace), which better suits the *action*.
- Compound labels like `Use Alternative Plan` should be authored as whole strings,
  not concatenated fragments — Korean word order will not survive
  interpolation-by-parts.
- The switch sheet is the tightest space: `Prepared Alternatives` / `준비된 대체
  운동` should be verified on the narrowest supported device, and the summary
  line must be allowed to truncate rather than wrap to three lines.

---

## 7. Start Workout Preview

`StartWorkoutFromRoutineView`'s Blocks section is deliberately minimal — block
type plus exercise names. (A stale `Rest after: Ns` line was removed from it
immediately before this design precisely because it was noise.)

| Option | Assessment |
|---|---|
| Compact `Alternatives: 2` per slot | Adds a line to every slot that has any; mostly noise pre-workout |
| Hide entirely until switching | Zero cost, but the user cannot confirm their prep survived duplication/transfer without starting a workout |
| Inside expanded slot details | The preview has no expandable detail today; building one for this is disproportionate |

**Recommendation: hide from the preview** for MVP, and instead surface the count
in the **routine editor** slot row (`Alternative Exercises  2 ›`), which is where
the user authored it and where they would look to confirm it. If beta feedback
asks for pre-workout visibility, add a single unobtrusive glyph (e.g.
`arrow.triangle.swap`) to the slot line rather than a text row.

---

## 8. Active Workout Switch UX

### 8.1 Sheet structure

Today the flow is: swap picker sheet → on dismiss → `confirmationDialog` with two
buttons. A confirmation dialog cannot express a list with summaries, so this
becomes a **sheet**:

```
Switch Exercise — Bench Press

PREPARED ALTERNATIVES
  Machine Chest Press                        ›
  3 sets · 8–12 reps · 90s rest · warm-ups
  DB Bench Press                             ›
  3 sets · 8–12 reps · no warm-ups

OTHER OPTIONS
  Choose another exercise…
  Keep Current Plan
  Reset to Defaults
```

- Tapping a prepared alternative applies immediately (one tap, per goal 3). No
  second confirm — except in the logged-sets case (§8.6).
- `Choose another exercise…` leads to today's picker, and *that* path still ends
  in the two-option `Keep Current Plan` / `Reset to Defaults` choice.
- When the slot has **no** alternatives, this sheet must not appear at all — the
  flow stays byte-identical to today. This is both a UX rule and a required
  regression test.

### 8.2 What applying an alternative does

1. Resolve the alternative's `exerciseID` to a live `Exercise`. Fail → §8.7.
2. Build a `ResetSource` from the frozen alternative payload.
3. Run `ExerciseSwitchPlanAdapter.outcome(choice: .useAlternative, ...)` with
   `oldMode` from the slot and `newMode` from the resolved exercise (§9).
4. Apply via the existing `applySwitchOutcome(_:slotID:newExercise:)` and
   `swapExercise(planExercise:with:keepCardioDrafts:)` — **no new apply path**.
5. Warm-ups and techniques from the alternative replace the slot's snapshots,
   after passing the existing `retainedTechniques(from:isBodyweight:usesDuration:)`
   filter so an alternative cannot introduce a combination the routine editor
   would reject.
6. Cardio drafts and segment checklist ticks follow the existing
   `keepCardioDrafts` verdict (§10).
7. Incompatible drafts clear exactly as they do today, through the same
   `modeChanged` cleanup in `swapExercise`.
8. Rest state: `cancelStaleRestAfterExerciseSwitch()` runs unchanged.
9. Slot note: the alternative's own note applies if it has one; otherwise the
   note is cleared. The *replaced* exercise's note is never inherited — that rule
   is already load-bearing in the adapter.

### 8.3 Distinct from Keep and Reset

The prepared alternative is neither: it is a **third source of truth** that
happens to flow through the reset-shaped code path. Unlike `appDefaults` it
carries warm-ups, techniques, distance, segments, and a note.

### 8.4 Tracking-mode differences

The mode rules stay entirely with the adapter — an alternative gets no exemption:

| Case | Behavior |
|---|---|
| Alternative mode == current mode | Full payload applies |
| Strength → timed hold | Reps dropped, duration applied from payload, tempo cleared, techniques re-filtered by the duration gate |
| Strength → cardio | Effort cleared (cardio shows no effort control), distance + segments applied from payload |
| Cardio → strength | Distance, segments, and typed cardio drafts cleared; reps applied from payload |
| Cardio → cardio | Distance and segments applied from the payload — **replacing**, not merging, the current ones |

An alternative whose *authored* mode no longer matches its exercise's current
mode (the exercise was edited to `isTimeBased` after the alternative was written)
resolves by the **exercise's live mode**, with payload fields that have no
landing place dropped. Same rule the adapter already applies to a reset source.

### 8.5 Same-exercise alternative

If the alternative resolves to the exercise **already in the slot**, do not
perform a swap. Two candidate behaviors:

- **Apply prescription only** (no exercise change) — useful ("same lift, back-off
  scheme"), but it quietly turns the feature into a second plan-preset system.
- **Hide the row** from the switch sheet for that slot.

**Recommendation: hide it**, and additionally warn at authoring time
(`This is already the slot's exercise`) rather than blocking. Plan presets are a
separate feature with a separate UI; conflating them here would make the switch
sheet mean two different things.

### 8.6 Logged sets — the sharp edge

**This behavior exists today and must be preserved, not extended.** Switching a
slot deletes that slot's `WorkoutItem` and every `SetLog` under it, and can
cascade to a superset partner via round ordering. `cancelStaleRestAfterExerciseSwitch`
exists specifically because a rest timer outlived those deleted sets.

Making switching one tap makes accidental data loss more likely. Therefore:

> If the slot has **any logged sets**, tapping a prepared alternative must show a
> destructive confirmation naming the count — `Switch to Machine Chest Press?
> This removes 2 logged sets for this slot.` — before applying.

This confirmation should apply to the existing Keep/Reset paths too. It is
arguably a **pre-existing bug worth fixing independently of this feature**, and
if so it should ship as its own small slice *before* Phase F, so the alternatives
work does not have to carry it.

### 8.7 Degradation matrix

| Situation | Behavior |
|---|---|
| Alternative's exercise was deleted | Row renders as `Machine Chest Press — Exercise unavailable`, disabled, non-tappable. Never hidden silently: the user prepared it and deserves to see why it is not offered. The frozen `exerciseName` makes this possible. |
| Payload corrupt / unreadable | Whole slot reads `[]` alternatives; the sheet falls back to today's two-option flow. Costs the feature, never the session. |
| One alternative malformed inside a valid payload | Dropped during normalization at decode; the rest are offered. |
| Alternative == current exercise | Hidden (§8.5). |
| `isEnabled == false` | Not shown in the switch sheet; still shown in the routine editor. |
| Alternative references an exercise that exists but changed tracking mode | Applied under the live mode with incompatible fields dropped (§8.4). |
| Slot has alternatives but all are unavailable | Show the `PREPARED ALTERNATIVES` group with the disabled rows, so the state is legible. |

---

## 9. Compatibility With Existing Switch Logic

**Do not add a second adapter.** `ExerciseSwitchPlanAdapter` already owns the
compatibility contract and has 22+ value-level tests
(`ExerciseSwitchPlanAdapterTests`, `CardioExerciseSwitchTests`,
`SwitchExerciseConsistencyTests`, `SwitchExerciseResumeConsistencyTests`,
`SwitchExerciseTempoAndPrefillTests`, `StructuredCardioSessionPlanTests`).

The extension point is already there. `ResetSource` is a value-type prescription
source injected by the caller, and its own documentation anticipates this
feature:

> A caller with a real reset source (a routine slot) may supply one through the
> initializer.

and `performPendingSwap` says the same thing about segments:

> The adapter *does* apply a reset source's plan when one is supplied … so the
> day a caller has a real replacement plan to offer — a routine-slot-sourced
> reset — the checklist will show it with no change here.

### 9.1 Recommended shape

Add a third `Choice` case rather than a new `ResetSource` flavor:

```
enum Choice: Equatable {
    case keepCurrentPlan
    case resetPlan
    case useAlternative        // NEW
}
```

`useAlternative` routes to `resetPlan(current:newMode:resetSource:)` — the
existing private function — because the semantics are identical: *replace the
plan from a supplied source, adapted to the new mode*. What differs is only the
source's richness.

`ResetSource` gains three optional fields, all defaulted so every existing call
site and test compiles unchanged:

```
var warmupSteps: [WarmupStepSnapshot] = []
var techniques:  [TechniquePlanSnapshot] = []
var providesWarmupsOrTechniques: Bool { !warmupSteps.isEmpty || !techniques.isEmpty }
```

And `Outcome` needs the warm-up/technique payload to travel with it, because
today `keepWarmupSteps` / `keepTechniques` are booleans meaning "keep the
*existing* ones" — an alternative needs "*replace* with these":

```
var replacementWarmupSteps: [WarmupStepSnapshot]? = nil   // nil ⇒ use the flags
var replacementTechniques:  [TechniquePlanSnapshot]? = nil
```

Non-nil replacement wins over the boolean flags; `nil` preserves today's exact
semantics. This keeps every existing test valid and makes the new behavior
purely additive — the same additive-first discipline the rest of the app uses.

### 9.2 Outcome comparison

| Source | Sets/rest/effort | Reps/duration | Tempo | Warm-ups | Techniques | Distance | Segments | Note |
|---|---|---|---|---|---|---|---|---|
| Keep Current Plan | from current | from current, if mode unchanged | same type only | kept if mode unchanged | kept if mode unchanged, re-filtered | cardio→cardio only | cardio→cardio only | cleared |
| Reset to Defaults | `AppSettings` | app defaults | none | cleared | cleared | none | none | cleared |
| **Use Alternative** | **from alternative** | **from alternative** | **from alternative, mode-gated** | **replaced from alternative** | **replaced, then re-filtered** | **from alternative, cardio only** | **from alternative, cardio only** | **from alternative** |

---

## 10. Interaction With Structured Cardio

Structured cardio is the strongest argument for this feature — a Cardio Plan is
the single most expensive thing to lose on a switch and the single hardest to
rebuild mid-workout — and the plumbing is already in place.

- **Target distance:** carried on the payload; applied only when the resolved
  exercise is `.cardio`, per the existing Slice 6 rule.
- **Cardio Plan segments:** carried as a nested `CardioSegmentPlan`; encoded to
  `cardioSegmentsData` when building the `ResetSource`, so the adapter's existing
  reset branch applies it with no change. Its tolerant decoder handles unknown
  kinds, clamping, and bad segments.
- **Cardio Set aggregate logging:** unchanged. A bout is still one aggregate set.
  This design touches planning only.
- **Cardio → cardio:** the alternative's plan **replaces** the current one.
  Checklist ticks reconcile against the new plan through the existing path —
  ticks naming segments that no longer exist are dropped.
- **Cardio → strength:** distance, segments, drafts, and ticks all clear, exactly
  as today.
- **Strength → cardio:** the alternative's distance and plan apply; effort clears.
  This is the case that is impossible to achieve today without leaving the
  workout, and the clearest user win.
- **Transfer:** structured cardio inside an alternative round-trips using the
  same `RoutineTransferCardioSegmentsDTO` tolerant wrapper (§12).

**Explicit non-goals**, unchanged from `STRUCTURED_CARDIO_DESIGN.md`: no
segment-level actual logging, no repeat-authoring UI.

---

## 11. History Behavior

`WorkoutItem` carries `exercise`, `exerciseNameSnapshot`, `routineSlotID`, and
`plannedPrescriptionSnapshot`. There is **no** "originally planned exercise"
field, and switching today deletes and recreates the item — so History already
records only what was performed.

**Recommendation: keep it that way for MVP.**

| Question | Recommendation |
|---|---|
| Which exercise does History show? | **The actual exercise performed.** Machine Chest Press appears as Machine Chest Press. |
| "Switched from Bench Press" text? | **Not in MVP.** It requires a new persisted field on `WorkoutItem` (schema change), and it is genuinely ambiguous after two switches. Revisit once there is real usage. |
| Which Cardio Plan does History show? | **The one in `plannedPrescriptionSnapshot`** — which, after applying an alternative, is the alternative's plan, because `adaptedSnapshot` rewrites tier 2 from the adapted session plan. No change needed; this falls out of the existing design. |
| Does prefill learn from the actual exercise? | **Yes, already correct.** `LastPerformancePrefillService` keys on the switched-in exercise's own history — the Entry #12 draft-only prefill behavior. An alternative is just another switch to it. |

This keeps the feature **schema-additive on the routine side only** and leaves
History and the workout-logging model completely untouched, which is what the
task constraints require.

---

## 12. Routine Duplication / Transfer / Export

### 12.1 `RoutineDuplicator`

With the payload design this is nearly free: `copySlot` copies
`SlotPrescription` field-by-field, so it copies `alternativesData` as a value.
Requirements:

- Alternative `id`s: **regenerate** on duplicate. They identify a prepared
  alternative *within a slot*, and the duplicate's slots already get fresh
  `slotID`s. Keeping them would make two routines' alternatives indistinguishable
  in future features (e.g. per-alternative usage stats).
- `exerciseID` references are **shared**, exactly like the slot's own `Exercise`
  reference — duplication shares definition-level exercises by design.
- Order preserved verbatim.

There is precedent for getting this wrong: `8337219 fix(routines): duplicate
cardio target distance with the prescription` was a duplicator field-copy miss.
A round-trip test is mandatory (§13).

### 12.2 Transfer / export / import

Follow the Slice 12E structured-cardio precedent exactly:

- Add `alternatives: [RoutineTransferAlternativeDTO]?` to
  `RoutineTransferSlotPrescriptionDTO` — optional with a nil default, so older
  documents decode via synthesized `decodeIfPresent` and the encoder omits the
  key entirely when nil (a routine without alternatives exports byte-identically
  to today).
- **No `schemaVersion` bump.** `validateSupportedSchemaVersion` *rejects*
  documents newer than the reader, so bumping would make older builds refuse a
  whole routine rather than import it minus alternatives. Nothing about an older
  document became invalid. This is the reasoning Slices 5, 9, and 12E all
  recorded.
- **Reference exercises by name**, matching the rest of the format
  (`exerciseName` + `exerciseBodyPart` / `exerciseEquipmentType` /
  `exerciseIsTimeBased` hints), so import can resolve or stub-create. This is
  where the payload's `exerciseName` earns its place.
- Wrap the nested `CardioSegmentPlan` in the existing
  `RoutineTransferCardioSegmentsDTO` so a malformed plan costs the plan, not the
  routine.
- **Corrupt alternatives array** ⇒ import the slot with no alternatives rather
  than failing the document, matching the wrapper's stated failure philosophy.
- Import assigns fresh alternative `id`s.

### 12.3 CSV

**No change** to Exercise CSV or Workout History CSV. Alternatives are routine
authoring data; the history CSV records performed sets and already names the
actual exercise. There is no strong reason to touch either, and both have
compatibility tests that would need renegotiating for no user benefit.

---

## 13. Testing Plan

Following the repo convention of pure value-level tests wherever possible, with
SwiftData tests via `SwiftDataTestHarness` only where persistence is the subject.

**Value types / payload (pure)**
1. Round-trip encode/decode of `SlotAlternativesPayload`.
2. Nil payload, empty array, and corrupt bytes all read as `[]`.
3. One malformed alternative inside a valid payload is dropped; siblings survive.
4. Unknown future `version` degrades without throwing.
5. Setting an empty list clears the column (no empty-payload representation).
6. Ordering is stable across encode/decode.

**Adapter (pure)**
7. `.useAlternative` applies sets/reps/rest/effort/tempo from the source.
8. Warm-ups and techniques are **replaced** (not merged, not inherited from the
   replaced exercise).
9. Replacement techniques are re-filtered: a Drop Set alternative onto a
   bodyweight exercise drops it; rep-dependent techniques drop on a duration
   target.
10. Cardio distance + segments apply on `.cardio`, and are cleared for every
    other mode.
11. Effort clears when the alternative's exercise is cardio.
12. Tempo clears on any duration target, including duration → duration.
13. The alternative's note applies; the replaced exercise's note never does.
14. `adaptedSnapshot` writes the alternative's values into tier 2, so resolver
    tiers agree.
15. **Existing `Choice` cases produce byte-identical outcomes** — the full
    existing adapter suite must pass unmodified.

**Authoring / persistence (SwiftData)**
16. Create, edit, delete, reorder alternatives on a slot.
17. Enable/disable round-trips.
18. Deleting the slot's prescription does not orphan anything (no rows to orphan).
19. Duplicating a routine copies alternatives, with fresh `id`s and shared
    `Exercise` references.
20. Transfer export → import round-trips alternatives including warm-ups,
    techniques, and a Cardio Plan.
21. A pre-alternatives transfer document imports with `[]` and no error.
22. A document with a corrupt alternatives array imports the routine without them.
23. Import resolves an alternative's exercise by name; stub-creates when missing.

**Session carry-through (SwiftData)**
24. Starting a workout freezes alternatives into the plan.
25. Editing the routine's alternatives **after** start does not change the active
    session's alternatives.
26. Alternatives survive Save & Exit → Resume, and a cold restart.
27. A slot with no alternatives produces a plan byte-identical to today.

**Switch behavior (SwiftData + value)**
28. Applying an alternative sets the exercise and its full prescription.
29. Warm-ups, techniques, rest, distance, and Cardio Plan all land.
30. Incompatible drafts clear; cardio drafts and checklist ticks follow the
    existing verdict.
31. Deleted alternative exercise ⇒ row disabled, no crash, session unaffected.
32. Same-exercise alternative is not offered.
33. Logged sets present ⇒ destructive confirmation precedes application.
34. Rest timer cancellation still fires (regression on
    `StaleRestAfterExerciseSwitchTests`).

**No-regression**
35. A routine with no alternatives shows the *old* two-option dialog, not the
    new sheet.
36. Full existing suite green (currently 1,944 unit + 2 UI).

**Localization**
37. Every new string localizes to Korean; English unchanged
    (`KoreanLocalizationTests` pattern).

---

## 14. Manual Test Plan

1. Create a routine; add Barbell Bench Press with warm-ups, a technique, and
   90s rest.
2. Add two alternatives: Machine Chest Press (own warm-ups, 3×10) and DB Bench
   Press (no warm-ups).
3. Reorder them; disable one; re-enable it; delete one and re-add it.
4. Start the workout. Confirm the top-level flow is unchanged for slots without
   alternatives.
5. Switch to a prepared alternative **before logging**. Confirm exercise, set
   count, reps, rest, warm-ups, and techniques all match what was prepared.
6. Log a set, then switch again. Confirm the destructive confirmation appears and
   names the correct count; confirm Cancel leaves everything intact.
7. Strength → timed hold alternative: confirm duration fields, no reps, no tempo.
8. Strength → cardio alternative: confirm distance target and Cardio Plan
   checklist appear, effort control disappears.
9. Cardio → cardio alternative with a different Cardio Plan: confirm the
   checklist reflects the *new* plan and stale ticks are gone.
10. Save & Exit, reopen, Resume: alternatives still offered, applied plan intact.
11. Force-quit mid-session and cold-resume: same.
12. Edit the routine's alternatives while the workout is active; confirm the
    active session is unaffected.
13. Finish the workout. Confirm History shows the exercise actually performed,
    with the alternative's Cardio Plan under Planned where applicable.
14. Delete an exercise used as an alternative; reopen the routine and start a
    workout; confirm the disabled row and no crash.
15. Duplicate the routine; confirm alternatives copied and independent (edit one,
    verify the other is unchanged).
16. Export → import the routine on a clean install; confirm alternatives arrive
    with warm-ups, techniques, and Cardio Plan.
17. Import a routine exported by the **current** build (pre-alternatives) and
    confirm it opens normally.
18. Korean UI pass over the editor, the switch sheet, and the disabled/empty
    states; check truncation on the narrowest device.

---

## 15. Implementation Phases

| Phase | Goal | Likely files | Tests | Risk | Schema? |
|---|---|---|---|---|---|
| **A. Design** | This document | `docs/ALTERNATIVE_EXERCISES_DESIGN.md` | — | None | No |
| **B. Value types** | `SlotAlternative`, `AlternativePrescriptionPayload`, payload root, normalization, tolerant decode | new `Log/Services/SlotAlternatives.swift` | 1–6 | Low | No |
| **C. Persistence** | `alternativesData` column + accessors | `Entities.swift`, new `SlotPrescription+Alternatives.swift` | 16–18 | **Medium** — the only schema change | **Yes** (additive optional) |
| **D. Routine editor** | List screen, add/edit/delete/reorder, scratch-prescription binding | `PrescriptionFields.swift`, new `SlotAlternativesEditor.swift`, `ExercisePickers.swift` | 16–17, 37 | **High** — largest UI surface; §6.4 risk | No |
| **E. SessionPlan carry-through** | Freeze into `PlanExercise`; persist for resume | `StartWorkoutFromRoutineView.swift`, `SessionPlan.swift`, `WorkoutResumeService.swift`, `AppState.swift` | 24–27 | Medium | No |
| **F. Adapter + switch UI** | `Choice.useAlternative`, `ResetSource` fields, `Outcome` replacements, new switch sheet | `ExerciseSwitchPlanAdapter.swift`, `ActiveWorkoutView.swift` | 7–15, 28–34 | **High** — touches the most-tested logic in the app | No |
| **G. Degradation polish** | Deleted/corrupt/disabled/same-exercise handling | switch sheet, editor | 31–32, 35 | Low | No |
| **H. Duplication + transfer** | Duplicator copy, DTO, export/import | `RoutineDuplicator.swift`, `RoutineTransferDTO.swift`, `RoutineTransfer.swift`, `RoutineTransferImport.swift` | 19–23 | Medium | No |
| **I. Docs + guide** | `USER_GUIDE.md` (EN + KO), design doc "as built" | docs | — | Low | No |
| **J. Regression** | Full suite, manual plan, Korean pass | — | 36–37 + §14 | Low | No |

**Suggested pre-phase:** the logged-sets confirmation (§8.6) as its own slice
before F, since it is a pre-existing data-loss gap and shipping it separately
keeps its regression surface distinct.

Phases B, C, E, and H are independently shippable and leave the app with no
user-visible change — safe to land incrementally toward TestFlight. Phases D and
F are the ones that change behavior and should not be merged mid-beta without a
full regression pass.

---

## 16. Risks / Open Questions

| # | Question | Current lean |
|---|---|---|
| 1 | `@Model` vs encoded payload | **Payload** (§5.1). Revisit only if alternatives ever need independent querying. |
| 2 | Scratch-`SlotPrescription` binding for the editor | Highest-uncertainty item. Needs a spike in Phase D; fallback is a reduced editor (§6.4). |
| 3 | How much prescription editing inside the active workout? | **None beyond today's `EditSessionPlanSheet`.** Preparation belongs to authoring. |
| 4 | Per-slot vs reusable alternative templates | **Per-slot** for MVP. A "save as reusable" library is a clean later addition and does not change ownership. |
| 5 | Show the original exercise in History? | **No** for MVP (§11) — it needs a `WorkoutItem` schema field. |
| 6 | Deleted alternative exercises | Disabled row with snapshot name (§8.7). Alternative: a periodic sweep that prunes them — rejected, silent deletion of prepared work. |
| 7 | Alternatives inside supersets | **Supported for free** — alternatives hang off `RoutineExercise`, and a superset member *is* one. Needs explicit test coverage for the round-order cascade on logged sets. |
| 8 | Per-block-member alternatives | Same as 7: each member is a slot, so each gets its own. No extra design. |
| 9 | Routine editor complexity | One navigation row per slot (§6.1). Watch total slot-section height in Phase D. |
| 10 | Migration | One additive optional column; no new entity, so no `Schema(...)` list change. |
| 11 | Does one-tap switching need an undo? | Open. Switching is destructive to logged sets; §8.6 confirmation is the MVP answer, but undo may be the better long-term one. |
| 12 | Interaction with routine **variants** | `RoutineVariant` is currently an empty grouping container and `Routine.blocks` is the startable source — so no interaction today. Re-check if variants ever become real. |

---

## 17. Recommended MVP

The user's proposed MVP is close to right. Three refinements, all narrowing:

**Ship:**
- Alternatives attached to individual routine slots, stored as an encoded payload
  on `SlotPrescription`.
- Each alternative: one exercise + one full prescription (sets, reps/duration,
  rest, effort, tempo, warm-ups, techniques, target distance, Cardio Plan, note).
- Routine editor: add / edit / delete / reorder, behind one navigation row.
- Start freezes alternatives into the session plan; resume restores them.
- Switch sheet lists prepared alternatives above Keep / Reset.
- Applying an alternative routes through `ExerciseSwitchPlanAdapter` via a new
  `Choice.useAlternative` — no parallel apply logic.
- Duplication and transfer preserve alternatives.
- History records the exercise actually performed.

**Refinements to the proposed MVP:**
1. **Add the `isEnabled` flag** even though it is not in the original list. It is
   one `Bool` and it prevents the "delete and re-author" cycle that otherwise
   makes the feature feel expensive to use.
2. **Ship the logged-sets confirmation (§8.6) first, separately.** It is a
   pre-existing data-loss gap; one-tap switching makes it materially more likely.
   Landing it independently keeps the alternatives slices from inheriting its
   regression surface.
3. **Hide alternatives from the Start Workout preview** (§7) rather than adding a
   count line — the preview was just cleaned up and should stay minimal.

**Explicitly not in MVP:**
- Global / reusable alternative templates.
- A full prescription editor inside the active workout.
- "Switched from X" in History (needs a `WorkoutItem` schema field).
- Applying an alternative back to the routine template (violates the
  no-silent-template-mutation rule; would need its own explicit gated UI).
- Any CSV change.
- Segment-level actual logging or repeat-authoring UI.

**Why this is the smallest thing that solves the real problem:** the Bench Press
→ Machine Chest Press case fails today because the only two options are "wrong
plan" and "no plan." One prepared alternative per slot, applied through the
existing adapter, fixes it. Everything above that — libraries, templates,
history provenance, in-workout authoring — is a second feature.

---

## 18. Phase B — as built

**Shipped:** `Log/Services/SlotAlternatives.swift` (one file, pure value types)
+ `LogTests/SlotAlternativesTests.swift` (37 tests). No schema change, no
`alternativesData` column, no UI, no adapter change, no session carry-through,
no transfer, no History, no CSV. Nothing in the app reads these types yet.

One change outside the new file: `WarmupStepSnapshot` and
`TechniquePlanSnapshot` in `StartWorkoutFromRoutineView.swift` gained
`Equatable`. Synthesized conformance has to sit with the declaration, and both
are carried inside an `Equatable` payload. Behavior-neutral — it adds a `==`
and changes no existing code path.

### Types

| Type | Responsibility |
|---|---|
| `AlternativePrescriptionPayload` | The prepared plan: `PrescriptionSnapshotPayload`'s field set, plus `warmupSteps`, `techniques`, `cardioSegments`, `slotNotes` |
| `SlotAlternative` | `id` / `order` / `isEnabled` / `exerciseID` / `exerciseName` / `note` / `prescription`, exactly as §4.3 and §5.2 |
| `SlotAlternativesPayload` | The encoded root: `version` (1) + `alternatives` |
| `SlotAlternativeDecodingError` | Typed refusal reason for one alternative. `Equatable`; never surfaces to a caller — the payload decoder catches it and drops the element |
| `SlotAlternatives` | The codec namespace: `decode(from:)`, `encode(_:)`, `normalize(_:idGenerator:)` |

### Reuse

`WarmupStepSnapshot`, `TechniquePlanSnapshot` and `CardioSegmentPlan` are reused
verbatim, the cardio plan nested as a structure rather than a blob per §5.2.

`PrescriptionSnapshotPayload` is **mirrored, not embedded** — three reasons, all
mechanical: it is not `Codable`; it carries `equipment` / `setupNotes`, which are
definition-level data resolved from the `Exercise` (Phase 10-E) and must not be
frozen into an authoring payload; and it holds structured cardio as an opaque
`Data` blob, which §5.2 rejects for this payload. Every field the two share
keeps the same name, so the Phase F bridge is a field-for-field copy.

### Decoding rules

The §5.3 / §8.7 tolerance, made specific:

| Input | Result |
|---|---|
| nil `Data`, empty `Data`, corrupt bytes, non-object JSON | `[]` |
| Valid payload, empty `alternatives` | `[]` |
| Alternative with no `exerciseID` | that alternative dropped, siblings kept |
| Alternative whose `prescription` is unreadable | dropped |
| Alternative whose `prescription` key is present but `{}` | **kept**, with an all-nil plan |
| Alternative with a blank `exerciseName` | **kept** — the reference may still resolve |
| One malformed warm-up step or technique | that element dropped, alternative kept |
| Unknown keys at any level | ignored |
| Unknown `version`, including a future one | decoded exactly like the current one |

Two decisions the design did not settle:

- **Which fields make an alternative "malformed."** Only `exerciseID` and a
  readable `prescription`. Both are required because the value that would
  result without them is actively *wrong* rather than merely incomplete: no
  exercise reference is not an alternative at all (and inventing one is out of
  scope), and an unreadable prescription would apply an **empty plan** on
  switch — worse than not offering the row. Everything else falls back to a
  default.
- **`version` is not a gate.** Every field is optional at the wire level and
  unknown keys are ignored, so "decode what you can" always yields at least the
  alternatives a future build would recognize; rejecting on version would
  discard readable prepared work for no gain. A payload this build genuinely
  cannot parse fails `JSONDecoder` outright and resolves to `[]`. Re-encoding
  always writes `currentVersion` — the value in hand is a v1 value whatever it
  was read from.

### Encoding rules

- Empty list ⇒ `nil` `Data`, so Phase C's setter clears the column rather than
  storing an empty payload (§5.2 "one representation of none").
- `.sortedKeys`, so the same list always encodes to the same bytes.
- Absent values are omitted rather than written as null, and empty
  `warmupSteps` / `techniques` / an empty cardio plan are omitted entirely —
  the common alternative encodes to a handful of keys. `usesDuration` is
  written unconditionally: `false` is a positive assertion that the alternative
  is rep-based.
- The list is normalized before encoding, so `encode(decode(x)) == encode(x)`.

### Normalization

Deliberately minimal — §"do not over-normalize". `normalize(_:)` only:

1. sorts by `order`, ties broken by incoming position (the sort is made stable
   explicitly, since `sorted(by:)` is not),
2. rewrites `order` to `0..<count` — it is positional metadata, not an authored
   value, and dense is what an `.onMove` handler writes back,
3. reissues **duplicate ids**, keeping the first occurrence's. Two rows sharing
   an id break `Identifiable` diffing in a `ForEach`, but the prepared work is
   still the user's, so duplicates are repaired rather than dropped. The
   `idGenerator` parameter exists purely so tests can pin the reissued value,
4. trims `exerciseName`, and collapses blank `note` / `tempo` / `slotNotes` to
   nil,
5. collapses an empty `CardioSegmentPlan` to nil.

No prescription **value** is changed. Clamping durations, suppressing tempo on a
duration target, and dropping a distance on a strength exercise are
compatibility rules that belong to the adapter (Phase F); applying them here
would silently rewrite what the user authored.

---

## 19. Phase C — as built

**Shipped:** one additive column on `SlotPrescription`, one accessor file
(`Log/Models/SlotPrescription+Alternatives.swift`), and
`LogTests/SlotAlternativePersistenceTests.swift` (26 tests).

**Not shipped, and not visible anywhere in the app:** no routine editor UI, no
switch UI, no `SessionPlan` carry-through, no transfer/import/export, no
duplication support, no History, no CSV. Nothing authors or reads alternatives
yet — the column is nil for every existing and every newly-created
prescription, and no code path outside the new accessors mentions it.

### Storage

```
@Model final class SlotPrescription {
    var alternativesData: Data? = nil   // NEW
}
```

Exactly the shape §5.3 called for, and field-for-field the same decision as
`cardioSegmentsData` (Slice 12C) and `targetDistanceMeters` (Slice 5):

- **Additive optional, nil default** ⇒ SwiftData lightweight migration. No
  custom migration plan, no `VersionedSchema`, no backfill.
- **No new `@Model`** ⇒ no `LogApp.swift` `.modelContainer(for:)` change and no
  `SwiftDataTestHarness` `Schema(...)` change. `SlotPrescription` is already in
  both lists, so adding a property to it needs neither.
- **Not in the initializer**, matching `cardioSegmentsData`: the column is set
  through its accessor, never as a construction argument.

### Accessors

`SlotPrescription+Alternatives.swift`, mirroring
`SlotPrescription+StructuredCardio.swift` method for method. The names are the
ones §5.2 proposed.

| API | Behavior |
|---|---|
| `var slotAlternatives: [SlotAlternative]` | The only intended read path. nil column, empty data, empty list, corrupt payload and a payload this build cannot parse all read as `[]`; a malformed alternative inside a valid payload is dropped and its siblings survive |
| `func setSlotAlternatives(_:)` | Normalizes, then encodes. An empty list — and an encode failure — clear the column rather than storing an empty payload |
| `func clearSlotAlternatives()` | Explicit clear, for call sites where `setSlotAlternatives([])` would read as an accident |
| `var hasSlotAlternatives: Bool` | Any prepared alternative, **including disabled ones** — they are still prepared work and still shown in the editor (§8.7). "Does this slot have anything to offer *now*" is Phase F's question and filters on `isEnabled` plus whether the exercise still resolves |

**No codec logic lives in the model layer.** Every rule is the Phase B
`SlotAlternatives.decode` / `encode` / `normalize`, so the routine column, a
future transfer document and the frozen session plan share one implementation
rather than three. The practical consequence worth stating: normalization
happens on **write**, so the stored payload is a fixed point — ordering is
dense and stable, ids are unique, and re-writing what was just read produces
byte-identical `Data`.

### `RoutineDuplicator` — deliberately untouched

`copyPrescription` copies fields explicitly, so a duplicated routine currently
does **not** carry `alternativesData`. That is correct for this phase and costs
nothing: no UI can author an alternative yet, so there is nothing to lose. The
one-line copy plus the §12.1 fresh-`id` rule belongs to Phase H, where it can
land with the transfer work and its own round-trip test.

---

## 20. Phase D — as built

**Shipped:** authoring. A routine slot can now add, edit, reorder, delete,
enable and disable alternatives, each with a full prescription.

**Still inert.** Nothing reads an alternative outside the routine editor: no
session freeze, no switch sheet, no adapter case, no Start Workout preview
change, no duplication, no transfer, no History, no CSV, no schema change. A
user who authors alternatives today sees them only where they authored them —
which is why `USER_GUIDE.md` is deliberately not updated yet.

### Files

| File | Role |
|---|---|
| `Log/Services/SlotAlternativeSummary.swift` | Pure row wording |
| `Log/Models/AlternativeDraft.swift` | `AlternativeDraftStore` (the scratch slot) + `SlotAlternativeAuthoring` (list operations) |
| `Log/Main/Routines/SlotAlternativesEditor.swift` | The row, the list screen, the detail editor |
| `Log/Main/Routines/PrescriptionFields.swift` | +8 lines: the row, and a `showsAlternatives` flag |
| `Log/Localizable.xcstrings` | 7 new keys, Korean |

### Placement

One navigation row at the bottom of the slot's tools group — after `Warmup`
and `Techniques`, above `Slot notes` — reading `Alternative Exercises   2 ›`,
or `None` when there are none. Shown for **every** tracking mode: an
alternative replaces a treadmill as readily as a bench press. Always visible,
because it is the only way to author the first one.

### The editor: full reuse, no fallback

§6.4 approach A worked, and the reduced fallback was not needed. The detail
screen renders the **existing** `SlotPrescriptionSection` — the same editor the
routine slot itself uses — bound to a scratch `RoutineExercise` /
`SlotPrescription` / `WarmupScheme` / `TechniquePlan` graph. So an alternative
is authored with every rule the app already enforces (cardio gating, tempo
suppression on duration, technique conflict filtering, distance-unit handling,
duration ceilings), and every child editor — `WarmupSchemeEditor`,
`TechniquePlanEditor`, `CardioSegmentPlanEditor` — is reached unchanged.

Editable: sets, reps or duration, rest between sets and after exercise, effort
(mode + values), tempo, warm-up scheme, techniques, target distance, structured
cardio plan, slot notes — plus the alternative's own enabled flag and usage
note. That is the full §17 MVP field list.

### How the scratch slot cannot leak

§6.4 flagged this as the phase's real risk: an inserted-then-deleted scratch
graph is the orphan-row bug class `BackfillService.purgeOrphanSetTemplates`
exists to clean up.

The scratch graph is built in its **own in-memory `ModelContainer`**, and the
detail screen injects that container's context into the prescription section's
subtree with a single `.environment(\.modelContext, store.context)`. Every
insert those editors make lands in the throwaway store. The deletion is not
made reliable — it is made unnecessary: there is no code path by which a
scratch object reaches the user's database, not a forgotten delete, not an
early return, not a crash mid-edit. The one invariant that keeps it true is
that the draft never holds an app-store object: the scratch `Exercise` is a
copy of the picked exercise's definition fields. Two tests assert the app store
gains no `SlotPrescription` / `Exercise` / `RoutineExercise` / `WarmupScheme` /
`WarmupStep` / `TechniquePlan` row while a draft is built and edited.

### Seeding

A new alternative is seeded from **the app's defaults for the picked
exercise's tracking mode** (§6.3) by running the real
`makeDefaultPrescription` factory inside a throwaway draft store — so "an
alternative's defaults" and "a new routine slot's defaults" cannot drift apart.
It is never seeded from the primary slot's plan; §6.3's `Copy from current
plan` secondary action is **not** in this phase.

### Commit model

Immediate, like every other routine-editor screen, and therefore **no Cancel**:
adding one here would make this the only place in the app where backing out
discards an edit. Metadata (enabled, note) commits on change; the prescription
commits whenever the draft's payload value changes, which is what a back-swipe
or a push into a child editor is safe under. Every write goes through
`SlotAlternativeAuthoring` → `setSlotAlternatives`, so it is normalized, and it
replaces exactly one alternative addressed by `id` — the slot's own
prescription and the sibling alternatives are untouched.

### Deviations from the design sketch

- **Presence flags use the app's existing words.** §6.2 sketched
  `· warm-ups · techniques · Cardio Plan`; the summary says
  `· Warmup · Techniques · Structured Cardio`, reusing the exact row titles the
  prescription editor one screen up already uses (and their existing Korean).
  A second name for the same tool in the same screen would be worse than a
  slightly longer line.
- **The zero state reads `None`, not a hidden row.** Matching the Warmup /
  Techniques / Structured Cardio rows beside it.
- **Same-exercise alternatives are allowed and warned**, per §8.5: authoring one
  shows `This is already the slot's exercise.` The switch sheet hides it —
  Phase F/G.

### Known limitations for later phases

- A technique's `repMin` / `repMax` / `durationSeconds` do not survive the
  payload round trip, because `TechniquePlanSnapshot` has no such fields. That
  is the same loss the session freeze already takes when it snapshots a
  routine's own techniques, so an alternative carries exactly what a slot
  carries into a workout — but if those fields ever matter, the snapshot type
  is where to add them.
- An alternative whose exercise was deleted still opens in the editor, using
  the stored `exerciseName` and a tracking mode inferred from the payload. The
  disabled-row treatment (§8.7) belongs to the switch sheet, Phase G.
- The count row and the summaries read the payload on every render (a JSON
  decode per row). Fine for an authoring screen with a handful of rows; if the
  switch sheet ever renders this hot, cache at the call site.

---

## 21. Phase E — as built

**Shipped:** the freeze. Starting a workout copies each slot's prepared
alternatives into the session, and they survive Save & Exit, a cold resume, and
an exercise switch.

**Still inert.** Nothing reads them: no switch sheet, no `Choice.useAlternative`,
no `ResetSource` fields, no Start Workout preview change, no History, no CSV, no
duplication, no transfer, no schema change, no user-guide change. This phase
carries data and nothing else.

### The three hops

```
SlotPrescription.alternativesData        authoring truth (Phase C)
        │  frozen by StartWorkoutFromRoutineView.makePlan(from:)
        ▼
PlanExercise.alternativesSnapshot        [SlotAlternative], default []
        │  copied by ActiveWorkoutView.initializeSessionPlans()
        ▼
SessionPlan.alternatives                 persisted in AppState.sessionPlansJSON
```

`WorkoutResumeService.planFromRoutine` mirrors `makePlan` and re-reads the
routine, exactly as it already does for warm-ups and techniques — but that read
is a **fallback**, not the session's truth: `restoreSessionPlansFromAppState`
runs after `initializeSessionPlans` and overlays the persisted `SessionPlan`, so
a routine edited mid-session cannot rewrite what the session holds. The template
read only matters for a cold resume of a session that never persisted a plan
(the JSON is written on plan edits and switches, not at start).

### The field, and why it is optional

```
struct SessionPlan {
    var alternativesSnapshot: [SlotAlternative]? = nil   // stored
    var alternatives: [SlotAlternative] { get set }      // nil / [] collapse
}
```

The obvious `var alternatives: [SlotAlternative] = []` is wrong here, and
subtly: **synthesized `Decodable` calls `decode`, not `decodeIfPresent`, for a
non-optional property even when it has a default value.** Every `SessionPlan`
persisted by every earlier build lacks this key, so that shape would throw
`keyNotFound` on resume and take the user's entire in-session plan — every
edited set count, rest and note — down with it. `Optional` decodes with
`decodeIfPresent`; the computed `alternatives` restores the non-optional API and
collapses nil / missing / empty to `[]`, the same "one representation of none"
rule the routine-side accessor uses. Writing an empty list stores nil, so a slot
with no alternatives encodes byte-identically to before this phase.

### A switch keeps the slot's alternatives

`applySwitchOutcome` replaces the slot's `SessionPlan` wholesale with the
adapter's output, which would have discarded the frozen list on the first
switch. Alternatives belong to the **slot**, not to the exercise currently in
it — after Bench Press → Machine Chest Press, the prepared DB Bench Press is
still prepared — so they are carried across the replacement (three lines, no
visible effect until Phase F). The adapter itself is untouched.

### Testability note

`makePlan(from:)` became `static` (it read no view state). That is what lets the
freeze be tested against the real start path instead of a copy of it reproduced
in the test file, which is how `CardioDistanceOnlyTargetTests` had to do it.
Behavior is unchanged; the three call sites now say `Self.makePlan(from:)`.

---

## 22. Phase F1 — as built

**Shipped:** the feature works. A prepared alternative can be applied mid-workout
in one tap, and it brings its whole plan — warm-ups, techniques, distance,
Cardio Plan, note — with it.

**Still outstanding:** duplication (Phase H), transfer/import/export (Phase H),
History provenance (deferred — §11 keeps it out of MVP), `USER_GUIDE.md` (a
final docs slice, once duplication and transfer land), and the full manual
regression pass (Phase J).

### The flow

```
Switch Exercise
   │
   ├─ slot has an offerable alternative ─▶ Prepared Alternatives sheet
   │        ├─ tap one ──────────────────▶ requestPendingSwap(.useAlternative)
   │        └─ Choose another exercise… ─▶ ┐
   │                                        │
   └─ no offerable alternative ────────────▶ existing picker
                                             └─▶ existing Keep / Reset dialog
                                                  └─▶ requestPendingSwap(.keep/.reset)
                                                            │
                                                            ▼
                                          existing logged-set confirmation
                                                            │
                                                            ▼
                                                  performPendingSwap
```

The sheet is a sheet, not a `confirmationDialog`, for the reason §8.1 gives: an
alternative needs a name, a summary, a note and a disabled state to be worth
tapping, and a dialog is a stack of button titles.

§8.1's sketch put `Keep Current Plan` / `Reset to Defaults` in the sheet's
`Other Options`, which cannot work — both answer "what plan should the exercise
you just picked use?", and no exercise has been picked yet. `Choose another
exercise…` leads to today's picker, and *that* path still ends in today's
two-option dialog, exactly as §8.1's own prose says. The existing dialog and its
two strings are untouched.

**A slot with nothing to offer sees no new screen.** The picker opens directly
and the flow is byte-identical to pre-F1 — a UX rule and a test.

### What is offered

`PreparedAlternatives.offers(from:currentExerciseID:availableExerciseIDs:)`, a
pure function over the slot's **frozen** `SessionPlan` list (never the routine's
current one):

| Case | Behavior |
|---|---|
| `isEnabled == false` | Hidden. Still listed, with `Off`, in the routine editor |
| `exerciseID == the slot's current exercise` | Hidden. Includes the alternative the user *just applied*, which correctly drops out while its siblings stay switchable. No mid-workout warning — the authoring screen already gave one (§8.5) |
| Exercise deleted from the library | **Shown, disabled**, reading `Exercise unavailable` (§8.7). A `List` row makes this clean, so the design's preferred treatment was implementable; the frozen `exerciseName` is what makes the row legible |
| Otherwise | Offered, in authored order, with the same summary the routine editor shows |

### What applying one does

`ExerciseSwitchPlanAdapter.Choice.useAlternative(AlternativePrescriptionPayload)`
routes to the **existing** `resetPlan` branch with a richer source
(`ResetSource.alternative(_:)`). There is no second application path:

- **Set count, rep/duration range, rests, tempo, note** — from the alternative,
  through the reset branch's existing mode gating.
- **Effort** — from the alternative, *always*, via the new
  `ResetSource.replacesEffortTarget`: an alternative authored with no effort
  target must not inherit "RIR 2" from the exercise it replaced. A progression
  (start/end) rides on `Outcome.appliedAlternative` into `adaptedSnapshot`,
  because a `SessionPlan` carries only a single value and would drop it.
- **Warm-ups and techniques** — `Outcome.replacementWarmupSteps` /
  `replacementTechniques`, the design's §9.1 shape as computed views over
  `appliedAlternative`. They **replace** rather than survive, including with an
  empty list, and are still run through `retainedTechniques` so an alternative
  cannot introduce a combination the routine editor would have rejected.
- **Distance and Cardio Plan** — from the alternative, and only when the
  switched-in exercise is cardio *today*. That is the same gate a reset uses, so
  an alternative whose exercise was later edited into another mode degrades
  instead of smuggling a stale field through (§8.4).
- **Everything else** — drafts, checklist ticks, templates, the superset
  cascade, the rest-timer cancellation — is the existing switch path, unchanged.

The one adapter-adjacent change at the call site: `applySwitchOutcome` now reads
the three-way warm-up/technique rule (replace / keep / clear) instead of the
two-way one.

### Destructive confirmation

Inherited, not re-implemented. A prepared alternative calls the same
`requestPendingSwap` as the two plan choices, so the logged-set gate, its copy,
its superset partner count and its Cancel semantics are literally the same code.
Nothing is applied until the confirmation passes — cancelling clears the pending
state and leaves exercise, plan, logged sets, drafts and rest timer untouched.

### After the switch

The slot keeps its alternatives (Phase E's carry-across in
`applySwitchOutcome`), so a second switch can offer the rest of the list — minus
the one now in the slot. `persistSessionPlans` runs on the switch, so Save &
Exit → Resume restores the applied prescription *and* the list, and the session
never re-reads the routine.

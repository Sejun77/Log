# Cardio System Design

**Status:** design only — no app code written for this document.
**Date:** 2026-08-02
**Supersedes:** the "structured cardio metrics" entry under Deferred Feedback in
`ENTRY_12_TESTFLIGHT_FEEDBACK.md`.
**Companion:** [`STRUCTURED_CARDIO_DESIGN.md`](STRUCTURED_CARDIO_DESIGN.md) —
structured cardio (segments and intervals), design-complete as Slice 12A,
unimplemented. This document covers Phase 1, Slices 1–11, all shipped.

---

## 1. Where we are today

The Friends & Family Beta answered the cardio request with the primitives the
app already had:

- Cardio is a **duration-based exercise** (`Exercise.isTimeBased == true`).
- The `Cardio` body part already existed and is Korean-localized (유산소).
- The catalogue seeds Walking, Treadmill Run, Treadmill Walk, Stationary Bike,
  Elliptical, Stair Climber, and Rowing Machine as duration-based.
- Exercise duration accepts up to 6 hours, rest up to 60 minutes.
- Distance, speed, incline, resistance, and heart-rate zone go in **notes**.

That is genuinely usable, and it should stay usable during and after this work.
The gap is that notes are not queryable: you cannot chart weekly distance, you
cannot compare two 5k runs, and you cannot export cardio to anything useful.

### The constraint that shapes everything

`Exercise.isTimeBased` is a `Bool` read at **95 sites** across models, routine
editing, active workout, History, CSV, and the exercise-switch adapter. It is
the app's most load-bearing type flag after `SetKind`.

Any design that turns that `Bool` into a three-case enum is a 95-site refactor
touching the exact code paths that produced the P0/P1 TestFlight crashes and the
P1 exercise-switch inconsistency. That is the single largest risk in this
feature, and the recommended design exists mostly to avoid it.

---

## 2. Recommended design

### 2.1 Cardio is a *facet* of duration, not a sibling of it

**Answer to design question 1.** Cardio is an **extension of duration-based
exercises**, expressed as one additive flag:

```swift
// Exercise
var isTimeBased: Bool = false   // unchanged, still the load-bearing flag
var isCardio: Bool = false      // NEW — additive, nil-safe default
```

Which gives three states:

| `isTimeBased` | `isCardio` | Meaning | Example |
|---|---|---|---|
| `false` | `false` | Strength: reps + weight | Bench Press |
| `true` | `false` | Timed hold: duration only | Plank, Wall Sit |
| `true` | `true` | Cardio: duration + metrics | Treadmill Run |

`isCardio == true` implies `isTimeBased == true`. That invariant is enforced at
the two write sites (the Exercise Detail toggle and the CSV importer) and
asserted in tests; nothing else needs to know.

#### Implementation notes (settled in Slice 2)

**The invariant lives in two model methods, not in the views.** Slice 2 ships
`Exercise.setTimeBased(_:)` and `Exercise.setCardio(_:)` alongside the derived
`trackingMode`. `setTimeBased(false)` also clears `isCardio`; `setCardio(true)`
is refused (and any stale `true` cleared) when the exercise is not time-based.
The Exercise Detail toggles bind through these rather than to the stored
properties, so a second write site — the CSV importer in Slice 7 — inherits the
enforcement instead of restating it. Direct assignment to `isTimeBased` stays
valid at construction time (seeding, CSV import, routine transfer), where
`isCardio` is already `false`.

Because the project has no view models for Exercise Detail and the single
`LogUITests` flow does not reach that screen, these two methods are also where
the toggle's *behavior* is tested.

**The Cardio row is hidden, not disabled, when Time-based is off.** Strength is
the overwhelming majority case and a permanently greyed-out control there is
noise; the row appearing when Time-based flips on is also the clearest possible
statement that cardio is a facet of duration.

**Why this and not an enum.** Cardio inherits every duration invariant for free
and at zero cost:

- no reps/weight fields — already true for `isTimeBased`
- no tempo, no Tempo Override — already true for `isTimeBased`
- the exercise-switch adapter's duration ↔ non-duration compatibility table
  already covers cardio ↔ strength; cardio ↔ Plank becomes a *same*-tracking-type
  switch, which the adapter already treats as the safe case
- all 95 `isTimeBased` sites keep compiling and keep behaving identically

The cost is one `Bool` and a discipline rule. The enum's benefit — exhaustive
`switch` at call sites — is recovered without the migration by a **derived**
read-only view:

```swift
enum TrackingMode { case strength, timedHold, cardio }

extension Exercise {
    var trackingMode: TrackingMode {
        guard isTimeBased else { return .strength }
        return isCardio ? .cardio : .timedHold
    }
}
```

New code switches on `trackingMode`. Old code keeps reading `isTimeBased`. There
is no migration because there is no storage change to migrate.

**Answer to product direction "keep Plank separate from cardio".** This design
keeps them separate at the level that matters — Plank is `.timedHold`, Treadmill
is `.cardio` — while keeping them identical everywhere their behavior genuinely
is identical (no reps, no tempo, duration input, rest handling).

### 2.2 Field model

**Answer to design questions 2, 3, 4.**

Metrics describe a *performed bout*, so they live on `SetLog` — the same place
`durationSeconds` already lives.

| Field | Storage | Required | Entry | Phase |
|---|---|---|---|---|
| duration | `durationSeconds: Int?` *(exists)* | **Yes** | manual | done |
| distance | `distanceMeters: Double?` | No | manual | 1 |
| distance unit | `distanceUnitRaw: String?` | No¹ | manual | 1 |
| average heart rate | `avgHeartRate: Int?` | No | manual | 1 |
| calories | `calories: Int?` | No | manual | 1 |
| incline | `inclinePercent: Double?` | No | manual | 1 |
| resistance / machine level | `resistanceLevel: Double?` | No | manual | 1 |
| heart-rate zone | `hrZoneRaw: String?` | No | manual | 1 |
| **pace** | *not stored* | — | **derived** | 1 |
| **speed** | *not stored* | — | **derived** | 1 |
| notes | existing exercise / setup / session notes | No | manual | done |

¹ Required only when `distanceMeters != nil`; written automatically from the
user's current unit preference.

**Duration is the only required field.** It already is: the Log button guards
`d > 0`. Everything else is optional because a treadmill console does not always
show everything, and a logging flow that demands six numbers will not be used
mid-session. A cardio set with only a duration is a valid, complete cardio set —
this is what keeps Phase 1 from regressing today's behavior.

**Every field is manual entry only.** No sensor, no watch, no estimation.

**Pace and speed are derived, never stored.** Both are `distance / duration`.
Storing them creates a row that can contradict itself (a stored pace that
disagrees with the stored distance and duration is unresolvable — which one is
the truth?). They are computed at render time from the two stored values and
shown as `4:50 /km` and `12.4 km/h` (`4:50 /mi` and `12.4 mph` in miles).

**Distance is stored canonically in meters** with the entry unit recorded
alongside. This is deliberately *better* than what weight does today
(`Units.weightIsKg` is a global display flag, so a history logged in lb and read
in kg is silently reinterpreted). Distance is more unit-ambiguous than weight
and has no bodyweight-style anchor to sanity-check it, and a weekly-distance
chart aggregating mixed km/mi rows would be quietly wrong. Canonical meters
makes aggregation correct by construction; `distanceUnitRaw` records what the
user typed, for export and backward compatibility.

A new `AppSettings.distanceIsMetric` (default: follow `Locale`) supplies the
unit for both entry and display, matching the existing `weightIsKg` pattern.
Unlike `weightIsKg` it reinterprets nothing when it changes, because the stored
value is meters rather than a bare number — see §2.37 for the full policy.

**Heart-rate zone** is a small closed enum (`z1`…`z5`), not free text, so it can
be grouped and charted. It is independent of `avgHeartRate` — users have one or
the other depending on what their equipment shows.

#### Implementation notes (settled in Slice 1)

**Out-of-range cardio metrics are rejected to `nil`, not clamped.** This is a
deliberate divergence from `DurationLimits`, which clamps. A duration arrives
from a *bounded picker* or from imported/legacy rows, so clamping repairs a
value that is known to be well-intentioned. Cardio metrics are typed free-hand
and have no legacy rows at all, so an out-of-range entry is a typo — and
clamping "1500 bpm" to "300 bpm" would store a fabricated vital sign that looks
entirely legitimate in a chart. Rejecting leaves the field visibly empty so the
user retypes it. Bounds: distance `(0, 1000 km]`, heart rate `[20, 300]`,
calories `(0, 100000]`, incline `[-30, 100]`, resistance `(0, 100]`.

**Incline is signed, to support treadmill decline.** Consumer treadmills that
support decline typically reach about −3%, with −6% at the extreme; −30 leaves
headroom for unusual equipment while still rejecting a number typed into the
wrong field. Decided while the cardio UI was still unbuilt, which is the
cheapest point to widen a range — the entry field in Slice 4 is built signed
from the start rather than retrofitted.

**Zero means "not recorded" everywhere except incline.** A set explicitly logged
as flat (0%) is meaningful and distinct from a set with no incline recorded;
a zero distance, calorie, heart-rate, or resistance value is not. Incline could
not use the "0 means unset" shortcut in any case: for a signed field, 0 is an
ordinary interior value, so "not recorded" has to be `nil` and nothing else.

**A distance unit is dropped when there is no distance**, so the two fields can
never disagree about whether a distance was recorded.

**`HRZone` labels are not localized yet.** Slice 1 ships `number` and a
language-neutral `shortLabel` ("Z3"). The UI slice that first renders a zone
adds a localized display name with its own string-catalog entries, rather than
seeding the catalog with strings nothing displays.

#### Implementation notes (settled in Slice 3)

**The columns are read through one accessor, never individually.**
`SetLog.cardioMetrics` runs every stored value back through `CardioMetrics`'
normalizing initializer and the tolerant `DistanceUnit.from(raw:)` /
`HRZone.from(raw:)` lookups, and `SetLog.applyCardioMetrics(_:)` is the matching
write site. A row holding a negative distance, a 900 bpm heart rate, or a
`hrZoneRaw` of `"z9"` therefore yields nil for that field instead of reaching a
formatter or a chart. Direct column access is for persistence tests only.

**`SetLog.init` is deliberately unchanged.** The columns are declared with nil
defaults and no initializer parameters, so every existing construction site —
active workout, resume, prefill, fixtures — keeps producing metric-free sets
with no edits, and no call site can accidentally populate cardio data before the
Slice 4 entry UI exists.

**History's duration segment is the literal `"\(seconds)s"`.**
`CardioHistorySummary.text(for:fallbackUnit:)` returns exactly that string for a
duration-only set, so every timed hold and every pre-Slice-3 beta cardio log
renders byte-identically to before — structurally, not by coincidence. It
returns nil for a strength set, which falls through to `HistoryView`'s untouched
weight/reps path. This is the guarantee `CardioHistorySummaryTests` pins first.

**Summary format.** Segments joined by `" · "` in a fixed order, absent values
omitted entirely — never a placeholder dash, which would imply the user failed
to record something rather than that the field does not apply:

```
2700s · 6.2 km · 7:15 /km · 3% incline · level 8 · 142 bpm · Z3 · 410 kcal
```

The order runs: what was done (duration, distance, pace), how the machine was
set (incline, resistance), then the body's response (heart rate, zone, energy).
Numbers reuse `CardioDerived.formatDistance`, so trailing zeros are trimmed
("6.2 km", not "6.20 km") and distance reads consistently with weight.

**Two localized words, `incline` and `level`.** Everything else is a
language-neutral abbreviation (`km`, `mi`, `bpm`, `kcal`, `%`, `Z3`, `/km`). A
bare "3%" next to the other numeric segments is ambiguous, and a machine level
is unitless, so those two need a word; decline reuses the same key with a sign
("-3% incline") rather than adding a second one.

**An invalid raw unit is a non-event.** `distanceUnitRaw` is never read for
display (see §2.37): the summary renders in `AppSettings.distanceUnit` and shows
the distance whatever the raw column holds — the value is stored canonically in
meters, so the number is correct in whichever unit it is rendered. An invalid
`hrZoneRaw` has no such fallback and is simply omitted: there is no correct
value to recover, and inventing a zone would be worse than showing none. The
display unit is a parameter, not a global read, so the formatter stays pure and
its tests do not depend on the tester's locale.

### 2.3 Prescription (target) fields

The routine side gets exactly **one** new pair:

```swift
// SlotPrescription + PlannedPrescriptionSnapshot
var targetDistanceMeters: Double?
var targetDistanceUnitRaw: String?
```

Target duration already exists (`durationMin/MaxSeconds`) and covers "run for 30
minutes". Target distance covers "run 5k". Those are the two things people
actually program.

Target incline, target resistance, and target heart-rate zone are **not** added.
They are setup details, not programming intent — they belong in setup notes,
which is where they already are and where they work fine. Adding them would
double the routine editor's cardio section to serve a case the beta has not
reported.

#### Implementation notes (settled in Slice 5)

**The pair is carried on four types, not two.** `SlotPrescription` (the
template), `PlannedPrescriptionSnapshot` (frozen at session start),
`PrescriptionSnapshotPayload` (the value-type copy in the plan) and
`SessionPlan` (the session-scoped editable copy). All four nil-default, so every
existing routine, snapshot and persisted session plan migrates untouched, and a
`SessionPlan` written by an earlier build decodes with nil through synthesized
`decodeIfPresent`.

**`CardioTargetDistance` is the read path**, the programming-side mirror of
`CardioMetrics`. Every read runs the stored meters back through
`CardioMetrics.normalizedDistanceMeters`, so a negative, absurd or hand-edited
value degrades to nil instead of reaching a formatter.
`SlotPrescription.applyTargetDistance` is the matching write site and always
writes **both** columns, so a unit can never be orphaned from its distance.

**A target has no unit of its own — see "Unit policy" below.** Every read takes
a `displayUnit:` and renders in it; `targetDistanceUnitRaw` is written but never
read on the display path.

**Target and performed distance are different fields on different models.** A
5 km target logged as 4.2 km has to stay visibly different from a 4.2 km target,
and nothing about logging a set may rewrite the routine that prescribed it —
the same silent-mutation invariant the rest of the app is built on.

**`CardioRoutineRules` owns the visibility policy.** The prescription editor is
a `View` and cannot be instantiated in a unit test, so every rule it applies is
a pure function on `TrackingMode` instead: which controls show, what a new slot
defaults to. `.strength` and `.timedHold` cases are not placeholders — they are
the assertion that this type changed nothing for them.

**Suppression never deletes.** Cardio hides warm-up schemes, techniques, tempo
and the combined RIR/RPE control, but a slot that already carries any of them
keeps it, hidden and intact, so switching the slot back to a strength exercise
restores the programming. There is deliberately **no** "heal" pass for cardio,
unlike the duration heal that clears stale tempo: silently deleting a user's
warm-up because they ticked the Cardio box would be a far worse bargain than a
hidden field.

**A new cardio slot does not seed an effort value.** The control is hidden, but
`BlockPrescriptionSummary` reads the stored `rir`/`rpe` directly and never
dereferences `re.exercise`, so a seeded value would make a fresh cardio block
sprout an "RIR 2" that cannot be seen or removed in the editor. Not seeding is
the difference between hidden and hidden-but-leaking. Cardio slots created
*before* this slice may still carry one; they are left alone, per "nothing
converts silently".

**Routine transfer is additive, with no `schemaVersion` bump.** The two keys
join `RoutineTransferSlotPrescriptionDTO` with nil defaults, so an older export
decodes them as nil and nothing about it became invalid. Import **re-normalizes**
rather than trusting the document — an imported file is outside data — and drops
the unit with the distance when the distance does not survive.

**A distance-only cardio slot keeps `hasContent == false`, on purpose.** "Run
5k, however long it takes" is a valid prescription, but `hasContent` answers a
narrower question — *can `generateTemplates()` produce meaningful
`SetTemplate`s?* — and `SetTemplate` has no distance field. Widening it would
route the slot into the generator's `durationMaxSeconds ?? durationMinSeconds
?? 60` fallback and manufacture a **60-second duration target the user never
programmed**, which would then prefill the active-workout row; it would also
change `resolvedTemplates()` and the routine editor's
template-vs-prescription comparison as collateral. An empty template list is the
honest answer, and the row still renders because
`SessionPlanResolver.effectiveSetCount` reads `sets` from the snapshot rather
than counting templates.

> The one caller that needed the wider reading is
> `BackfillService.hydrateEmptySlotPrescriptions`, which runs on **every
> launch** and skipped only `hasContent == true`. It therefore read a
> distance-only cardio slot as empty and rewrote it — three sets, default rest,
> and that invented 60-second duration — silently, on the next launch. Found in
> pre-merge review of Slice 5 and fixed with a second, deliberately narrow
> predicate, `SlotPrescription.hasHydratableContent` (`hasContent ||
> targetDistanceMeters != nil`), used by the backfill guard and nowhere else.
> `CardioDistanceOnlyTargetTests` walks the shape end to end; nine of its
> assertions fail if the guard is reverted.

#### Implementation notes (settled in Slice 4)

**`TimeSetEntryRow.cardioDraft` is an optional `Binding`, and nil means "not
cardio".** A timed hold passes nil and renders the row it always has — no
disclosure, no extra height, no behavior change — so Plank's immunity is
structural rather than something every future edit has to remember to preserve.
This is the same nil-means-unchanged shape Slice 3 used for the History row.

**Entry text lives in `CardioEntryDraft`, not `CardioMetrics`.** A user mid-typing
has "6." in the distance field and "-" in the incline field; round-tripping
through a normalizing type on every keystroke would delete both. The draft holds
raw strings, sanitizes keystrokes (digits, one separator, a leading minus for
decline), and normalizes exactly once — at log time, via `metrics`. An invalid
optional field is therefore dropped silently and **never blocks the Log button**,
whose gate remains `duration > 0`.

**Which slots are cardio is cached, not fetched per row.** `cardioSlotIDs` is
rebuilt at session start and after an exercise switch, reading `trackingMode`
from the live `Exercise` behind `PlanExercise.currentExerciseID`. Reading the
model rather than denormalizing a flag onto `PlanExercise` means a slot swapped
to or from a cardio exercise is picked up for free, **without touching the
exercise-switch adapter** (extended for cardio in Slice 6, §2.35). A per-row
fetch inside `body` would
violate the CLAUDE.md performance rule.

**Drafts persist through `ParentDraftStore`, which gained cases rather than a new
layout.** New `Field` cases mint new `<slotID>_<setIndex>_<field>` keys; every
pre-existing `reps` / `weight` / `duration` key keeps its exact spelling, and the
prefix-matching `clear` sweeps old and new alike. An in-flight draft written by a
previous build reads back unchanged with the cardio fields simply absent. On
resume the precedence mirrors the existing rehydrate: a persisted `SetLog` wins,
else the persisted draft, else nothing.

**Metrics are applied unconditionally at log time**, including when empty. That
is what makes Undo → re-log clear a previous attempt's distance instead of
leaving it attached to a set the user has since changed.

**Post-log editing is deferred, deliberately.** The row has never supported
editing a logged value — reps, weight, and duration are all `.disabled(isLogged)`
with Undo as the only route — so making cardio metrics the one editable
post-log field would be both inconsistent and a new editing system this slice
does not need. Details fields follow the same rule. Undo restores the in-memory
draft intact, so correcting a set costs two taps.

**Pace and speed appear only when derivable.** No placeholder row, no dash: with
no distance, no duration, or a zero duration, the preview simply does not exist.
Speed reads "8.3 km/h", pace "7:15 /km", both derived at render time and neither
stored. In miles the same two read "5.1 mph" and "11:40 /mi": the speed unit
comes from `DistanceUnit.speedUnitSymbol`, which spells the imperial case out
rather than composing "mi/h", while pace stays composed from the bare symbol
("min/km" / "min/mi").

#### Pre-merge patch (manual review of Slice 4)

Four UX problems found on review, all fixed before merge.

**The Details section is a button + conditional block, not a `DisclosureGroup`.**
`DisclosureGroup` animates its own expansion, and inside a List row that
animation re-laid out the whole row — the set label, duration field, Start and
Log buttons all slid vertically while the section opened. It now toggles inside
a `Transaction` with `disablesAnimations = true`, so the section appears in one
frame and the primary logging controls never move. No animation beats an awkward
one on a data-entry surface.

**The collapsed summary is capped at three segments**, prioritized distance →
average heart rate → calories, with incline / resistance / zone filling only the
slots those three leave empty. Pace and speed never appear — pace has its own
preview row in the expanded section, duration is already the row's primary
field. Showing every metric overflowed the label and ellipsized it, which is
strictly worse than showing fewer things legibly when the full set is one tap
away.

**History groups metrics onto secondary lines** instead of packing up to eight
segments onto the row's trailing edge, where they wrapped into an unreadable
block. Duration stays the primary trailing value so the eye lands in the same
place on every row:

```
2. Working Set                                        2700s
6.2 km · 7:15 /km
3% incline · level 8
142 bpm · Z3 · 410 kcal
```

(The row label read "2. Working" when this patch shipped; the post-merge polish
below replaced it.)

Line 1 is what was covered, line 2 how the machine was set, line 3 the body's
response. An empty group produces no line, so a duration-only row is still a
single unchanged line.

**RIR/RPE is not shown for cardio.** RIR is "reps in reserve", meaningless for a
30-minute run. The app exposes RIR and RPE through *one* control governed by a
single `AppSettings.autoregMode` preference, so they cannot be separated at the
UI without splitting that preference — hiding the whole control for cardio is
the honest reading of today's architecture. The rule lives in
`WorkoutEffortTargetResolver.isEffortApplicable(to:)`; all three display sites
(per-set row labels, Plan card summary, Edit Plan sheet) route through it.

> Suppression is **display-only**. `SlotPrescription`,
> `PlannedPrescriptionSnapshot` and `SessionPlan` keep whatever effort values
> they hold, so a slot switched back to a strength exercise still has its
> targets, and the resolver itself is untouched.

**Cardio-specific RPE is deliberately deferred, not rejected.** Perceived
exertion *does* make sense for cardio — a rower reporting "RPE 7" is meaningful
in a way that "RIR 2" is not. Re-enabling it requires decoupling RPE from RIR in
the autoreg preference so a cardio slot can offer RPE while a strength slot in
the same session offers RIR. That is a change to the effort system, not to
cardio, and it should be taken on its own terms. Until then cardio shows no
effort field. Timed holds keep the control: "two seconds in reserve" is a
stretch, but it is what the app has always offered for a plank, and this patch
does not change unrelated behavior.

#### Post-merge polish (manual review of merged Slice 4)

Three more issues found after the merge, fixed before Slice 5 starts.

**History set rows name their stored set kind.** The row label was
`kindRaw.capitalized` — "1. Working", "1. Dropset" — with warm-ups on a separate
"Warmup 1" spelling. Every row now reads *number, then the kind's name*:

```
1. Working Set                                        2700s
6.2 km · 7:15 /km
```

| Stored `SetKind` | History row | Active-workout row |
|---|---|---|
| `.working` | "1. Working Set" | *(no label)* |
| `.warmup` | "1. Warm-up Set" | "Warmup" |
| `.dropset` | "1. Drop Set" | "Drop Set" |

The label is a function of `SetLog.kind` and `SetLog.indexInExercise` and of
**nothing else** — not the exercise, not its tracking mode, not what the set
recorded. The rule lives in `SetKind.historyRowLabel` (the vocabulary) and
`HistorySetRowLabel` (the numbering), pulled out of `HistoryView` so it is
assertable without a SwiftUI host.

> **Cardio is deliberately not special-cased.** An interim patch gave cardio
> rows a neutral "1. Set", on the reasoning that a cardio bout might be a
> warm-up jog, the main effort, or a cooldown. That is true, but it is an
> argument for cardio *set kinds*, not for a label that contradicts the kind the
> app already stored — and it made two rows holding identical data read
> differently depending on their exercise. Cardio has no structured warm-up /
> cooldown kinds yet; when it gets them they arrive as `SetKind` cases and every
> row label follows for free. Until then a cardio `.working` set is a working
> set, exactly like a plank's and a bench press's.

**The active-workout row labels are untouched.** `SetKind.activeRowLabel` is a
separate, intentionally different vocabulary: mid-workout the surrounding row
already establishes the context, so `.working` draws no label at all there.
History is read long after the fact, out of that context, which is why there the
unlabelled row is the ambiguous one. `.dropset` is the one case where both
surfaces want the same words, and it reuses the same string key.

Because the label reads only the set, it is unaffected by exercise deletion —
History rows survive it (`exerciseNameSnapshot`), and so does their numbering
and wording.

**The pace field names its unit: "Pace (min/km)" / "Pace (min/mi)".** The value
format is unchanged ("5:00 /km"), and so is the arithmetic — pace is still
`durationSeconds ÷ distance`, derived at render time and never stored. What
changed is only that the label now says what the number is. `DistanceUnit`
owns both the label and the `min/km` symbol, so the two cannot drift, and both
labels are localized. "time/km" is explicitly rejected as user-facing wording:
it reads like a spreadsheet column heading rather than a quantity.

**Cardio hides the weight-based warm-up options.** "Fixed Weight" and "% of
Working" describe nothing a treadmill or a rower can do. Cardio now takes the
same path bodyweight has taken since Slice 1: `.percentage` is dropped from the
kind picker, `.fixedReps` loses its weight field and reads "Reps", and any
weight on a saved step is cleared. The shared predicate is
`warmupHidesWeight(isBodyweight:isCardio:)`, so a future third reason to hide
weight is added in one place.

> This is **not** a cardio warm-up/cooldown system and not structured intervals;
> it only removes options that could never have worked. Note also that basic
> duration exercises (timed holds) are *not* covered by this rule — they keep
> the weight-based options they have always had, because a weighted plank is a
> real thing. The rule keys off cardio, never off duration.

**Prefill of cardio metrics** was deferred through Slices 4–6 and **shipped in
the prefill slice** (§2.36). The split predicted here held exactly:
**setup metrics prefill, outcome metrics do not.**

| Field | Prefill? | Why |
|---|---|---|
| Distance | ✅ yes | usually the thing being repeated |
| Distance unit | ✅ yes | a per-set choice the user makes once |
| Incline / decline | ✅ yes | a machine setting, not a result |
| Resistance | ✅ yes | a machine setting, not a result |
| Average heart rate | **no** | an outcome — the body's response to *this* bout |
| Calories | **no** | an outcome, and one the machine reports |
| HR zone | **no** | an outcome, derived from heart rate |

Prefilling an outcome metric would put a number the user did not measure into a
field that reads as measured, which is worse than an empty field. The same
argument does not apply to a setting they chose last time and will probably
choose again.

> **Resolved in Slice 5** for the one open question here: the routine's *target*
> distance **does** seed the entry field, and this is not prefill. Prefill reads
> previous performance; target-distance seeding reads the routine the session
> was started from — the same source as the sets, the duration and the rest
> already showing on that row. History-based cardio prefill remains deferred,
> and the table above still governs it.

### 2.35 Exercise-switch compatibility (settled in Slice 6)

The mid-workout switch is where the Entry #12 P1 bug lived: the row changed
type, the *old* exercise's type-specific state stayed attached, and the resume
path then disagreed with the live view. Cardio adds two new ways for that to
happen — a target distance on the plan, and typed metric drafts on the row — so
both get the treatment duration and reps already had.

**The adapter takes `TrackingMode`, not `isTimeBased`.** A boolean cannot tell a
treadmill from a plank, which is precisely the distinction that decides whether
cardio-only state has anywhere to land. The old two-boolean signature is gone
rather than kept as a convenience overload: a caller holding only a `Bool` would
silently get timed-hold semantics for a cardio slot, which is the bug.

> The two axes are genuinely different, and conflating them would be its own
> bug. `TrackingMode.usesDuration` is the **field-shape** question, and
> cardio → timedHold changes mode while *keeping* its duration target, because
> both are logged by time. Only the cardio-specific state keys off mode
> equality.

| Switch | Keep current plan | Reset plan |
|---|---|---|
| cardio → cardio | sets, duration, rest, **target distance + unit**, typed metric drafts | from the reset source: its target if it has one, else cleared; drafts cleared |
| cardio → timedHold | sets, duration, rest; **target + drafts cleared** | from source; target nil; drafts cleared |
| cardio → strength | sets, rest; duration/**target**/drafts cleared | from source; target nil; drafts cleared |
| timedHold → cardio | sets, duration, rest; target nil | from source (its target, else nil) |
| strength → cardio | sets, rest; reps/tempo cleared; target nil | from source (its target, else nil) |
| non-cardio ↔ non-cardio | unchanged from Slice 0 | unchanged |

**One rule underneath it: cardio-only state survives cardio → cardio, and
nothing else.** Typed metrics survive only the *Keep* half of that — an explicit
Reset is the user asking to start over, and "5 km, 142 bpm" carried onto a
different machine describes a bout that never happened.

**`adaptedSnapshot` writes the target unconditionally from the adapted plan**,
including when the plan has none. This is the fix that matters most: the
snapshot is built from the **replaced** exercise's payload, so leaving those two
columns alone is exactly how a cardio target used to ride along onto a bench
press and then reappear through tier-2 resolution on the next resume.

**Persisted drafts are cleared, not just in-memory ones.** Slice 4 dropped
`cardioDraftsBySlotID[slotID]` on every swap but left the `ParentDraftStore`
keys in `UserDefaults`, so the typed values were still on disk and could be
restored if the slot later became cardio again.
`ParentDraftStore.clearCardio(slotID:)` sweeps every set index of the slot and
takes **only** the cardio fields — a blanket `clear` would take the duration
with them, which a cardio → timed-hold switch still needs. The cardio subset is
derived by exclusion from `Field.allCases`, so a future cardio field joins it
automatically.

**Target seeding survives a switch, and live and resume agree about it.**
`seedCardioDraftsFromTarget(slotID:)` is called from both the swap path and
`rehydrateCardioDrafts`, and only ever fills entries that are absent. The resume
path still refuses to restore a switched slot's *logs and persisted drafts*
(they belong to the replaced exercise) but now still seeds from the **adapted**
plan — skipping that too was what would have made a resume show an empty
distance where the live view showed the target. Precedence is unchanged and
still three-tier: logged set → persisted draft → routine target.

**Effort ~~is deliberately not cleared~~ *is* cleared when switching into
cardio.** Reversed by the pre-merge patch below, on evidence from manual smoke
testing: "suppression is display-only" is the right rule for a slot that was
*authored* with an effort target, but it is the wrong rule for one that
*acquired* it by switching. The carried-over value was invisible, uneditable,
and would resurface the moment the slot was switched back or the plan applied to
the routine. A new cardio slot seeds no effort (Slice 5); a switched one now
matches it.

#### Pre-merge patch (manual smoke of Slice 6)

Four findings. Three were real; one was not.

**The active Edit Plan sheet had no target-distance row** (real). Slice 5 made
the target editable in the *routine* editor and propagated it into the session,
but never gave the session a way to edit it. `SessionTargetDistanceRow` is the
sheet-side sibling of the routine editor's row — same draft-then-normalize
shape, same `CardioTargetDistance` commit, cardio only. It sits inside the
Duration section rather than one of its own, because duration and distance are
the same kind of thing: independent targets for the same bout.

> Two consequences had to follow it, or the edit would have been a dead end:
> `isSessionPlanDirty` now compares the target pair (otherwise a
> target-only edit never offered "Update slot prescription"), and
> `applySessionPlansToSlotPrescriptions` now copies it (otherwise the edit was
> silently session-only).

**Stale intensity survived a switch into cardio** (real) — see the reversal
above. Both the plan's `rir`/`rpe` and the snapshot's effort-*progression*
fields are cleared, the latter because they live only on the snapshot and would
otherwise still derive `.progression` and summarize a target the cardio row does
not display. `Outcome` gained `newMode` so `adaptedSnapshot` can apply that
without the caller passing the mode twice.

**There was no way to set intensity after switching cardio → strength** (real,
and the subtlest of the four). The Intensity section already existed, but it was
gated on the *snapshot's* derived effort mode, and rendered a **read-only**
"None" row when that mode was `.none` — which is exactly the state a slot lands
in after a switch out of cardio, since the adapted snapshot carries no effort at
all. The `.none` case now shares the editable single stepper with `.single`. An
unset stepper reads "—", which states the absence just as honestly as the
read-only row did while actually being usable. `.progression` stays read-only:
in-session progression editing is still deferred.

**Two live-update bugs followed** (found by smoke-testing the patch above), and
both had the same shape: Edit Plan wrote the `SessionPlan` correctly, but a
piece of visible state was derived from something *else* and only caught up on
the next resume.

*The cardio row's distance draft was seeded once and never re-seeded.* Reps and
duration already refresh on sheet dismissal via `applySessionPlanToInputs`;
distance had no counterpart, so a target edit was invisible until a resume
happened to re-run seeding. `resyncCardioDraftsToTarget` is that counterpart.

> The precedence question it raises — *which* drafts may be refreshed — is
> answered by a rule that already existed: **a seeded draft is never persisted,
> a typed one always is.** `ParentDraftStore` writes on every keystroke,
> including an empty string when the field is cleared, so a persisted cardio
> snapshot means "the user touched this" and its absence means "this is ours to
> refresh". A typed value is never overwritten, a cleared field is never
> refilled, and a logged set is never rewritten. That is the same discriminator
> the resume path uses, which is why live and resume land in the same state.

*The Plan card and the per-set row labels both derived effort from the immutable
snapshot.* So a freshly set intensity never appeared — and for a slot switched
out of cardio, whose adapted snapshot carries no effort at all, it could never
appear no matter what the user set. Worse, the two sites already disagreed: the
card summarized `sessionPlan.rir` while the rows resolved from the snapshot, so
even an ordinary `.single` slot updated the card and not the rows.
`WorkoutEffortTargetResolver.effectiveFields(snapshot:sessionRIR:sessionRPE:)`
is now the single answer both read — the snapshot with the session's single
override laid over it. A `.progression` snapshot is deliberately **not**
overlaid: in-session progression editing is still deferred, and overlaying would
silently flatten the ramp.

**"cardio → cardio Keep clears the target distance"** — *not reproducible*, and
the adapter rule was already correct. `testCardioToCardioKeepPreservesTargetThroughTheWholePipeline`
now walks every hop the app actually runs (routine prescription → snapshot
payload → session plan → switch → adapted snapshot → frozen `@Model` snapshot →
resume) and the target survives all of them. The one path that genuinely loses
it is a `SessionPlan` **persisted by a build older than Slice 5**: it decodes
with a nil target and then overwrites the freshly-initialized plan on resume.
That is a one-time migration artifact of an already-in-flight workout, not a
rule of the switch, and it is pinned by
`testLegacyPersistedSessionPlanHasNoTargetToPreserve`. The most likely thing the
smoke tester actually saw is the missing Edit Plan row above — opening Edit Plan
to check the target and finding nothing there.

### 2.36 Previous-performance prefill (settled in the prefill slice)

> Numbering note: the implementation-order table below lists Slice 7 as CSV v2.
> Prefill was pulled forward ahead of it and is tracked as **6b** there; it is
> the work that table's §2.3 note deferred, not a renumbering of CSV.

**A target is a plan; a previous distance is evidence.** The routine's target
says what you meant to do, the last bout says what you actually did, and for the
field that records what you are *about to* do, evidence wins. The target does
not disappear — it stays on the plan card and in Edit Plan, which is where a
plan belongs. This is the one product decision the whole slice turns on.

One precedence chain, stated once in `CardioDraftResolver`:

    logged set → user-typed draft → previous performance → routine target

**Only setup metrics prefill.** Distance, incline/decline and resistance are
decisions the user makes again; average heart rate, HR zone and calories are what
their body did during one specific bout. The split is enforced by the **type**:
`CardioPrefillSuggestion` has no field for an outcome metric, so no future call
site can reintroduce one by forgetting to filter.

The suggestion still carries the previous bout's `distanceUnit`, but §2.37's
Settings-only rule means `seededDraft` no longer restates it: the stored meters
are converted into `AppSettings.distanceUnit`, so a 3.1 mi bout prefills as
"4.99" for a user who now prefers km. The field being seeded is labelled with the
preference, so seeding the old unit would mislabel the number.

**Eligibility is shared, not restated.** `CardioPrefillService` and
`LastPerformancePrefillService` both select through
`LastPerformancePrefillService.prefillCandidates` — completed workouts, current
session excluded, `excludedFromPrefill` honored, newest first. A second copy of
that rule would be free to drift, and the promise that matters most (a deload
the user marked "don't use for prefill") is one they made a deliberate choice
about. Carry-down mirrors the strength resolver exactly, so the two prefills can
never disagree about which previous set a row corresponds to.

**`CardioDraftSource` is derived, never stored.** Slices 5 and 6 needed only
"did the user touch this?", and got it free from persistence: a seeded draft is
never written to `ParentDraftStore`, a typed one always is. Prefill adds a
*second unseeded* source, so that two-state answer stopped being enough — a
target edit may refresh what the target itself put there, but must not overwrite
evidence of what the user actually did. All four inputs (logged? persisted?
prefill? target?) survive a resume already, so the source is a pure function of
existing state; persisting it would add a second source of truth free to drift
from the drafts it describes.

| Draft source | Target edit may rewrite it? |
|---|---|
| `logged` | no — it is history |
| `userTyped` | no — including a field they cleared |
| `previousPerformance` | no — evidence, not a plan |
| `targetSeeded` | **yes** |
| `empty` | yes — nothing to protect |

**Ordering bug found and fixed in the swap path.** `swapExercise` seeded cardio
drafts at step 3a but re-pointed the slot's prefill at step 4, so switching into
cardio would have seeded from the **replaced** exercise's history — precisely
the stale-state class Slice 6 exists to prevent. Seeding now runs at step 4a,
immediately after `refreshLastPerformancePrefill`.

**Prefill writes nothing but drafts.** It never touches the routine, the
prescription snapshot, `SessionPlan.targetDistanceMeters`, or History; it is
read-only against SwiftData; and it does not parse notes.

### 2.37 The distance-unit preference (settled in the Settings slice; policy revised before merge)

Slice 1 built `AppSettings.distanceIsMetric` and every entry path has defaulted
from it since; what was missing was a way for the user to see or change it. The
Settings → Units section now offers **Distance unit: km / mi** beside the
existing weight picker.

**The picker's `@AppStorage` default is locale-resolved, not `true`.** While the
key is unset, `AppSettings.distanceIsMetric` falls back to
`defaultDistanceIsMetric()`, so a hardcoded `true` would have shown "km" to a US
tester whose entry fields were already defaulting to miles — a control
describing a preference the app was not using.

**Settings is the only user-facing distance-unit control.** This is the revised
policy; the paragraphs below record what it replaced and why.

*What shipped first.* The slice treated the preference as a *default for new
entries only*, and left three km/mi pickers in place: the ones Slice 5 put in the
routine prescription editor and the active-workout Edit Plan sheet, and the
per-set one Slice 4 put on the active-workout Details row. Manual review before
merge found the consequence: those pickers made a **routine prescription (or a
single set) override the Settings preference**. A user who set km in Settings
still saw — and could still author — a target in miles, with no way to make the
routine follow the preference short of re-editing every slot. Two controls for
one concept, with the narrower one winning. All three pickers are gone; the unit
now appears beside each field as a static suffix.

*The rule now.* **No distance carries a unit of its own — targets, drafts and
performed sets alike.** Distance is stored canonically in meters throughout and
rendered in `AppSettings.distanceUnit` wherever it appears, so this is a
rendering decision, never a data one:

| Read path | Unit used |
|---|---|
| Routine target distance (display + edit) | **the preference** |
| Active Edit Plan target distance (display + edit) | **the preference** |
| Block / plan summary target | **the preference** |
| Active-workout Details distance (display + edit) | **the preference** |
| Target-distance seeding into a draft | **the preference** |
| Previous-performance prefill | **the preference** — the stored meters are converted into it |
| A logged set re-read into its own row | **the preference** |
| A draft restored after Save & Exit | **the preference**, converted from the unit it was typed in |
| An in-flight draft when the preference changes | **the preference**, re-expressed live |
| An empty new field | **the preference** |
| History row (performed `SetLog`) | **the preference** — distance *and* pace |

`targetDistanceUnitRaw` is **not removed** from `SlotPrescription`,
`PlannedPrescriptionSnapshot`, `PrescriptionSnapshotPayload` or `SessionPlan`:
existing rows keep it, routine transfer/import keeps round-tripping it, and
`applyTargetDistance` keeps writing it — with the unit the target was entered in,
i.e. the preference at write time. What changed is that **no display path reads
it**. Removing the column is a later, separate decision; keeping it costs
nothing and keeps this patch migration-free.

Switching the preference therefore re-expresses every target distance —
`5 km` becomes `3.11 mi` — while `targetDistanceMeters` never moves. Nothing is
rewritten, converted, or migrated; the stored meters are the truth and the unit
is a lens. The routine and Edit Plan rows show the unit as a static suffix beside
the field and re-seed from the stored meters when the preference changes, so a
half-typed "6." can never be reinterpreted as the other unit.

The Settings footer explaining the old "applies to new entries" rule is
**removed**: it described the superseded policy, and under the new one there is
nothing surprising left to explain. The Units section is a label and a segmented
picker.

Deliberately not offered: meters, yards, a custom unit system, and separate pace
units. Pace already follows the unit of the row it belongs to
(`DistanceUnit.paceFieldLabel`), which is the only sensible answer.

**There are no exceptions left, including History.** An earlier revision of
this patch kept History rendering in each row's own `distanceUnitRaw`, on the
reasoning that a completed set is a record and restating it would be the app
claiming you ran a number you never saw. That argument does not survive contact
with the screen: it produced a History list mixing `3.1 mi` and `5 km` rows for
one user, which cannot be scanned or mentally totalled, and it made the unit a
user sees depend on which build they happened to log a set under. Nobody logs a
distance intending to fix its *presentation* forever.

The number that was recorded is `distanceMeters`, and that never moves. The unit
is a lens over it, and the lens belongs to the reader. So History converts, pace
included — `4.99 km · 6:01 /km` for a bout logged as `3.1 mi` — and a list is
readable in one unit again.

**`distanceUnitRaw` stays on `SetLog`, written and never read for display.** It
still records what the set was entered in, which CSV export and any future
importer can use, and it is what an older build would read if a store were
opened by one. Removing it would be a migration; keeping it costs nothing.
Nothing on any display path consults it — `CardioHistorySummary.secondaryLines`
takes a `displayUnit:` and uses it unconditionally, so a row holding `"mi"`,
`"kilometres"`, `""` or nothing renders identically.

**Two mechanisms, not one.** Following the preference takes different work
depending on where the unit lives, and both bugs shipped before being caught:

1. *Views that read the preference directly.* `AppSettings.distanceUnit` is a
   plain `UserDefaults` lookup, so SwiftUI records no dependency and a body
   reading it renders the right unit **once**. History showed a stale unit until
   the page was rebuilt. Every view that displays distance now holds
   `@AppStorage(AppSettings.Keys.distanceIsMetric)` and derives its unit through
   `AppSettings.distanceUnit(isMetric:)`.
2. *State that carries a unit.* `CardioEntryDraft.unit` is per-set state seeded
   when the draft is built, so the active-workout rows stayed stale even though
   `ActiveWorkoutView` was observing the preference correctly — re-rendering
   stale state changes nothing. `.onChange(of: distanceUnit)` resyncs the drafts
   through the pure `CardioEntryDraft.converted(to:)`.

**Converting a draft means parse → convert → reformat**, because a draft holds
text rather than meters. Text that parses to a usable distance is converted and
reformatted; empty text stays empty; text with no usable number (`"."`, `"abc"`,
`"0"`, out-of-range) keeps its exact keystrokes and only the unit moves, since
there is nothing to convert and inventing a number would be worse. Every one of
those strings already means "no distance" to `metrics`, so nothing downstream
can misread the preserved text.

A trailing separator is deliberately **not** in that group: `Double("6.")` is
`6.0`, so `"6."` is a usable 6 km and converts to `"3.73"` mi. Someone mid-way
through typing "6.25" loses their keystrokes. That is the accepted cost — the
alternative leaves `"6."` under a `mi` label, silently restating 6 km as 6 mi,
which is the exact reinterpretation this section exists to forbid. The number
stays true to what the user meant; only their cursor position does not.

**The resync does not persist, and does not need to.** It writes the draft
dictionary directly rather than through the binding that mirrors into
`ParentDraftStore` — changing a display preference is not the user editing their
workout. Correctness across Save & Exit comes from the store recording the text
*with the unit it was typed in*, so
`CardioEntryDraft.init(snapshot:displayUnit:)` converts on resume exactly as the
live resync did. A draft typed as "5" km reads "3.11" mi whether the app stayed
open or was force-quit in between. (The persisted unit is thus read as a
*conversion source*, never as a display override — the same distinction
`targetDistanceUnitRaw` gets, arrived at for the same reason.)

**Why performed entry and display follow the preference too.** The alternative —
a per-set unit picker on the Details row — was what shipped first, and it had the
same defect as the per-target pickers: a second control for one concept, and a
field whose number could disagree with the label beside it. Since distance is
stored canonically in meters, unit is purely a question of *how this user reads
and types numbers*, which is settings-shaped, not per-set and not per-row.

### 2.38 CSV / transfer compatibility (settled in Slice 9)

> Numbering note: this is the slice the implementation-order table calls **7**
> (CSV v2); it shipped ninth in execution order, after 6b and 6c.

**The rule the whole slice rests on: never move a column, never consume a
version.** Every one of the three formats is something a user already has on
disk or in a share sheet. A change that reorders a column, inserts one in the
middle, or bumps a schema version turns their existing file into an error
message. So all three changes are strictly *append optional fields to the end*,
and all three older formats keep importing untouched.

**Exercise CSV v2.** One column, `isCardio`, appended after `notes`. There is no
version-marker column — **the header row itself identifies the format**, which
is precisely what lets a v1 file keep importing. `ExerciseCSV.Format` resolves
the header (v2 first, then v1) with the existing trimmed/case-insensitive
comparison, and everything downstream keys off the resolved format's column
count, so a v1 file's six-column rows still validate against six.

| | v1 | v2 |
|---|---|---|
| Columns | 6 | 7 (v1 + `isCardio`) |
| Written by | builds before Slice 9 | export, always |
| Read by | still accepted | accepted |
| `isCardio` for a v1 row | — | `false` |

`isCardio` parses through the same lenient boolean the `isTimeBased` cell uses
(true/false, yes/no, 1/0, blank → false), and an unparseable value **rejects the
row** with a `.invalidIsCardio` reason carrying the raw text. That is the
existing `isTimeBased` behavior, deliberately: a value the user typed and we
cannot read is an error worth surfacing in the import preview, not one to
quietly reinterpret as "not cardio".

**Cardio is normalized up, not down.** A row claiming `isCardio` without
`isTimeBased` is the impossible state §2.1 rules out. `ExerciseCSVRow`'s
initializer resolves it by setting `isTimeBased = isTimeBased || isCardio`, and
`ExerciseCSVImporter` writes through `Exercise.setTimeBased` then
`setCardio` — the model's own write sites — rather than assigning the two flags.
The alternative (letting `trackingMode` degrade it to `.strength`) would import
a file the user explicitly marked as cardio and silently produce a strength
exercise. Both layers agree, so neither can drift.

Nothing is inferred from a name, a body part, or notes: an exercise is cardio
only if the file says so. Catalogue seeding is untouched — that is the separate
catalogue-v3 slice.

**Workout history CSV.** Export-only — there is no history importer, by design
(history is append-only and snapshotted at session start), so there is no
old-file-compatibility question on the read side at all. Seven columns are
**appended** after `workoutNotes`, leaving all fourteen original columns at
their original indices:

`distanceMeters` · `distanceUnitRaw` · `avgHeartRate` · `hrZone` · `calories` ·
`inclinePercent` · `resistanceLevel`

Rows are read through `SetLog.cardioMetrics`, the only intended read path, so a
value that could only have come from a hand-edited store is normalized away
rather than written into a file the user may hand to a spreadsheet. Strength and
timed-hold rows yield an empty `CardioMetrics` and therefore seven blank cells.

**Blank is not zero.** A missing optional exports as an empty cell, never `0`.
The two are different facts, and for `inclinePercent` the difference is load-
bearing: 0 is an ordinary interior value meaning "recorded as flat", and a
signed field also has to keep negative decline (`-3`) with its sign rather than
blanking or absolutizing it.

**`distanceMeters` is canonical; `distanceUnitRaw` is metadata.** The meters
column is what was stored and the only column safe to aggregate — a weekly total
summed across mixed km/mi rows would be quietly wrong, which is the whole reason
storage is canonical. `distanceUnitRaw` records which unit the user typed the
bout in and exists for compatibility and provenance only. **It does not control
display anywhere** — display follows the Settings preference (§2.37) — and a
consumer summing distance should ignore it entirely.

**Routine transfer.** Slice 5 already added `targetDistanceMeters` /
`targetDistanceUnitRaw` to `RoutineTransferSlotPrescriptionDTO` as additive keys
with nil defaults, so Slice 9 added no payload fields — only the end-to-end
proof: model → export → real JSON bytes → decode → import → model, in both
units, plus a literal pre-Slice-5 payload that still decodes and imports with no
target. `currentSchemaVersion` stays **1**; nothing about an older document
became invalid, so consuming a version would have been a cost paid for nothing.

`targetDistanceUnitRaw` is kept (removing a field is a migration, and this slice
is additive-first) and stays compatibility metadata on this side too: a routine
exported in miles renders in km for a reader whose Settings say km, and flips the
moment that preference changes. Nothing stored moves.

### 2.39 Catalogue v3 and the assisted migration (settled in Slice 10)

The last Phase 1 slice, and the only one that touches data a user already has.
It has two halves that look like one feature but must not be confused: **the
catalogue teaches new installs**, **the prompt asks old ones**.

#### Catalogue v3

`ExerciseSeed` gains an `isCardio` flag and `ExerciseCatalog.currentVersion`
becomes **3**. All seven Cardio entries — Walking, Treadmill Run, Treadmill
Walk, Stationary Bike, Elliptical, Stair Climber, Rowing Machine — ship
`isTimeBased = true, isCardio = true`; nothing else in the catalogue changes.
Plank stays a timed hold, every strength entry stays strength, and no new names
were added.

The invariant is enforced twice on the way in. `ExerciseSeed.init` normalizes
`isCardio` to `isTimeBased && isCardio`, so a malformed catalogue edit cannot
even *describe* the impossible state; the seeder then writes through
`Exercise.setTimeBased` / `setCardio` rather than assigning the stored
properties, so the model layer would reject it a second time.

What v3 deliberately does **not** do is touch an existing install. The seeder's
per-name dedupe skips every name already in the store, so a v2-era user's
"Treadmill Run" keeps `isCardio == false` after the pass — including all their
edits, notes, and equipment. That asymmetry is the whole reason the prompt
exists, and it is pinned by test
(`testV3ReSeedDoesNotOverwriteUserEditedCardioRow`).

#### Candidate rule

`CardioMigrationService.isCandidate` matches an exercise when **all three** hold:

| Condition | Why |
|---|---|
| `bodyPart` is Cardio (trimmed, case-insensitive) | The user already classified it; legacy rows and CSV imports carry casing/whitespace variants of the canonical string |
| `isTimeBased == true` | Cardio is a facet of duration (§2.1); a reps-and-weight row is not a mis-filed cardio bout |
| `isCardio == false` | Nothing to do otherwise |

**Names are never read.** A "Treadmill Run" filed under Legs is not a candidate,
and neither is Plank, a wall sit, or any other timed hold outside Cardio. The
rule is intentionally narrow: a false negative costs one toggle in Exercise
Detail, a false positive silently changes how someone's exercise behaves.

#### Prompt behavior

`BootstrapRoot` presents a plain SwiftUI `.alert` after the splash clears — never
during it, where the loading overlay blocks hit testing:

| | |
|---|---|
| Title | "Update Cardio Exercises" |
| Message | "Log now supports dedicated cardio tracking. Older exercises in the Cardio category can be updated to use distance, pace, heart rate, calories, incline, and resistance fields." |
| Primary | "Mark as Cardio" → `markCandidatesAsCardio` |
| Secondary (cancel) | "Not Now" → `resolvePrompt`, converts nothing |

All four strings are in `Localizable.xcstrings` with Korean translations, pinned
by `KoreanLocalizationTests`. The check itself is read-only and failure-tolerant
— an empty or unreadable store yields no candidates — so it can never block or
corrupt launch. It is skipped entirely under `--ui-testing`.

#### Presentation timing (pre-merge patch)

The first cut evaluated the offer **once**, at the end of the launch `.task`,
and assigned `isPresented = true` immediately after `isLoading = false`. Manual
smoke found the alert never appearing against a store full of valid candidates.

The root cause is that a single presentation attempt is not reliable. iOS's
notification-permission alert owns the presentation context during launch and
swallows ours; SwiftUI does **not** reset `isPresented` when a presentation is
dropped, so the flag stayed stuck `true` and no later assignment of `true` could
produce the false→true edge SwiftUI acts on. One dropped attempt was permanent.
Requesting the presentation inside the same transaction as the splash cross-fade
made it worse. Reproduced 3/3 launches on a simulator with the permission alert
pending.

What ships instead separates *owing* the offer from *presenting* it:

| State | Meaning |
|---|---|
| `hasPendingCardioMigration` | The service says an offer is owed. Survives a dropped presentation. |
| `showCardioMigrationPrompt` | The alert's `isPresented` binding. Assumed unreliable. |

`offerCardioMigration()` re-asks `shouldOfferPrompt`, waits ~400 ms for the
current transaction to settle, and then presents — **re-arming** (`false`, yield,
`true`) when the binding is already `true`, so a swallowed attempt still gets a
fresh edge. It runs after the splash clears **and** on every `scenePhase`
transition to `.active`, which is the signal iOS gives when a system alert is
dismissed. It cannot nag or loop: it never resolves the flag itself, and
`shouldOfferPrompt` answers `false` the moment the user taps either button.

Deliberately **not** gated on `scenePhase == .active` inside the function: an
`@Environment` value read from a captured closure can be a stale `.inactive`
long after the scene went active, and a gate that is stale in the "skip"
direction would drop the offer with nothing left to retrigger it. Presenting
while inactive is harmless — if the system swallows it, the next `.active`
retries. Verified on device: with the app **resumed rather than relaunched**
(same PID, launch `.task` never re-run), the alert appears on the return to
`.active`.

#### Prompt persistence: one-time **per catalogue version**

The flag `cardioMigrationPromptVersion` stores an `Int` — the
`ExerciseCatalog.currentVersion` under which the prompt was last resolved — not a
`Bool`. Under v3 the prompt is offered at most once: either button resolves it,
so "Not Now" ends the nagging for good on this version. A future catalogue
version that adds cardio entries may offer it once more to a user who still has
candidates, which is why the version was chosen over a bool — one-time-forever
would permanently strand anyone who dismissed the prompt before creating their
cardio exercises.

The offer is a question about the **store**, never about what a given launch
did: `shouldOfferPrompt` reads the flag and the candidates, and nothing from the
seeding path. A launch where `seedIfNeeded` short-circuits on its own version
flag still offers the migration.

**Only the user resolves the flag.** No launch-path code writes it — a rule
learned the hard way, see the patch note below.

The prompt still cannot appear when it has nothing to do, because
`shouldOfferPrompt` re-reads the store every time:

- **Fresh installs** are silent because catalogue v3 seeds cardio rows with
  `isCardio == true`, so the candidate rule finds nothing. No flag write is
  needed to achieve that, and none happens.
- **Converted stores** are silent for the same reason: a user who flipped the
  toggles manually in Exercise Detail stops being asked.

#### Patch note: the seeder must not pre-resolve the flag

The first cut resolved the flag whenever the seeder ran against an empty store,
reasoning that a fresh v3 install has nothing to migrate. True at that instant,
and wrong a moment later. Install the build, then import your exercise CSV — the
documented way to bring a library across — and genuine legacy Cardio rows land
in a store whose flag already reads "resolved". On device this produced
`versionGate=BLOCKED promptVersionRaw=3` against seven valid candidates: the
offer was dead before it was ever asked for, permanently.

The suppression bought nothing the candidate rule did not already provide, so it
is gone. One edge case is accepted deliberately in exchange: a user who builds a
time-based Cardio exercise by hand and leaves the Cardio toggle off is offered
the migration once. That is a fair question to ask, and far cheaper than
silently stranding an imported library.

`CardioMigrationService.diagnostics(in:defaults:)` (DEBUG only) prints every
input to the gate plus the reason it answered as it did, because
"pending=false, candidates=6" is a symptom, not a diagnosis.

#### What conversion writes, and what it preserves

`markCandidatesAsCardio` sets exactly one field per candidate, via `setCardio`,
then saves once. Preserved verbatim: `id`, name, body part, notes, equipment
type, setup defaults, `order`, `isCustom`, routine slots and their `slotID`s,
prescriptions, `WorkoutItem` / `SetLog` history rows, and workout snapshots. No
exercise is created, deleted, or recreated; no `SetLog` is rewritten; no CSV or
export format changed. Routines change only in the derived sense that their slots
now resolve to `trackingMode == .cardio` and therefore follow the cardio routine
rules (§2.3) from the next edit onward.

There is **no SwiftData migration** in this slice: `isCardio` has existed since
Slice 2, and this is an ordinary field write on existing rows.

### 2.40 History cardio charts (settled in Slice 11)

Cardio gets chart metrics of its own, inside the History **Progression** chart
that already exists. No new screen, no second chart component: the metric picker
gains cardio entries, and `ProgressChart` gains four cases.

#### Metrics

| Metric | Value plotted | Source |
|---|---|---|
| Distance | session total, in the Settings unit | `SetLog.distanceMeters` |
| Duration | session total, seconds | `SetLog.durationSeconds` (the pre-existing `.totalDuration` path, untouched) |
| Pace | session total duration ÷ total distance, seconds per unit | derived via `CardioDerived` |
| Calories | session total, kcal | `SetLog.calories` |
| Avg HR | duration-weighted mean, bpm | `SetLog.avgHeartRate` |

Incline and resistance stay History-row-only, as planned. Speed is computed by
`SessionTotals.speedUnitsPerHour` but is **not** offered as a chart option — it
is pace's reciprocal, and two axes for one quantity is clutter.

#### Aggregation (`CardioProgressAnalytics`)

One point per session per exercise, matching how the strength chart has always
grouped. All of an exercise's sets in that session are summed, **warm-ups
included** — the same rule `.totalDuration` already used, and the one that keeps
the chart agreeing with the History row the user is reading.

- Distance and duration are plain sums; absent ⇒ 0 ⇒ **no point**, never a zero
  point.
- Pace is **weighted**, never a mean of per-set paces: averaging rates weights a
  400 m stride the same as a 10 km run and reports a pace nobody ran. It needs
  both totals positive, so a distance-only or duration-only session is simply
  absent from the pace chart.
- Calories and heart rate stay optional. A blank field is excluded from the
  series and from the average — not treated as zero.
- Heart rate is duration-weighted when any reading carries a duration; untimed
  readings sit out of that weighting rather than entering at weight 0. With no
  timed readings at all it falls back to a plain mean.
- Nothing filters on `SetKind` or on exercise type: a strength set carries no
  distance and no duration, so it contributes 0 by construction. That is the
  mechanism keeping strength rows out of cardio charts.

#### Separation from strength

`availableProgressMetrics` checks cardio **first** (cardio implies time-based, so
the duration-only rule would otherwise swallow it) and returns only cardio
metrics. A cardio exercise is never offered e1RM, volume, best weight, or reps; a
strength exercise is never offered distance, pace, calories, or heart rate; a
non-cardio timed hold is still duration-only. In the other direction,
`WorkoutHistoryAnalytics`'s `weight > 0 && reps > 0` gate already excludes cardio
from the strength/volume series — §3.4 called that "existing protection to
preserve", and it is now pinned by test rather than assumed.

#### Units and presentation

Distance and pace render in `AppSettings.distanceUnit`. `ProgressChart` declares
`@AppStorage(AppSettings.Keys.distanceIsMetric)` and recomputes on change, so
flipping km ↔ mi re-plots an open chart — the Slice 8 rule, applied to charts.
Stored meters never move.

Two presentation details that would be wrong if taken from the strength chart
unchanged:

- **Pace is plotted in seconds per unit** (the only linear form) with axis ticks
  formatted `m:ss`. Neither "330" nor the decimal "5.5" is a pace anyone reads.
- **The PR rosette follows the minimum for pace**, the maximum for everything
  else. Marking the slowest run as a personal record is a lie the chart would
  tell at a glance.

Each cardio metric has its own empty state naming the missing field, because for
cardio "no data" usually means one field was left blank, not that the exercise
was never trained.

#### Not built, deliberately

Weekly distance / weekly duration roll-ups and the pace chart's distance
secondary axis (both sketched in §3.4) are **not** in this slice. The §3.4 pace
caveat stands and is unmitigated: a 400 m interval session and a 10 km run share
one axis. What reduces the harm is that each point is a *session total* pace
rather than a per-set pace, and distance is one tap away in the same picker. If
testers find it misleading, the secondary axis is the fix — the aggregation
layer already returns everything it needs.

### 2.4 Deferring HealthKit

**Answer to design question 5. Yes — explicitly deferred, and not to Phase 3
either.** HealthKit is not a feature increment; it changes what the app is:

- requires a HealthKit entitlement and privacy-policy review
- requires read *and* write authorization flows and their denial states
- requires dedupe against manual entries (the same run imported twice)
- requires background delivery and its lifecycle edge cases
- requires unit conversion at the boundary, again
- changes App Store review posture for a project that is currently a personal
  TestFlight beta

Manual logging is the product for the foreseeable phases. GPS, route tracking,
watch import, and live HR are deferred with it, for the same reason.

---

## 3. Feature behavior

### 3.1 Routines

**Answer to design question 6.** A cardio slot is a duration slot plus target
distance:

- **Sets** default to `1` for cardio (versus `AppSettings.defaultSets`). One
  30-minute bike ride is one set, not three.
- **Duration target** — unchanged, uses the existing 6h picker.
- **Distance target** — new optional field, shown only for `.cardio`.
- **Rest** — defaults to none for cardio slots. There is usually no
  between-set rest on a single continuous bout.
- **Effort (RIR/RPE)** — ~~kept~~ **suppressed.** Revised by the Slice 4 polish:
  RPE genuinely is meaningful for cardio, but the app exposes RPE only through
  the *same* control as RIR, governed by one `AppSettings.autoregMode`
  preference. Offering it would mean offering "reps in reserve" for a 30-minute
  run. Cardio-specific RPE needs that preference split first and is deferred on
  its own terms, not rejected.
- **Warm-up scheme** — **suppressed** for cardio. "50% of working weight" has no
  cardio meaning. (Timed holds keep it; only `.cardio` suppresses.)
- **Techniques** — **suppressed** for cardio. Every technique type is
  rep-structured; the duration filter already removes most, and the rest are
  noise on a treadmill.
- **Tempo** — suppressed, as it already was for every duration slot.

All four suppressions are display-only; see the Slice 5 implementation notes.

**Block summary line.** The distance target joins the existing block subtitle
rather than replacing it, so the segment order stays sets → duration → distance
→ rest → effort and nothing about a strength or timed-hold block moves:

| Cardio slot | Subtitle |
|---|---|
| 1 set, 30 min | `1 × 1800s` |
| 1 set, 5 km | `1 × 1800s · 5 km` |
| 1 set, distance only | `1 set · 5 km` |
| 1 set, neither | `1 set` |

An absent value contributes no segment — never a placeholder dash. The duration
still renders in seconds (`1800s`), which is the pre-existing format for every
duration block and is deliberately not changed here. The same distance segment
is appended to `SessionPlan.primarySummary`, so the target is visible on the
Plan card during the workout too.

### 3.2 Active workout logging

**Answer to design question 7.** This is the highest-risk surface and gets the
most conservative treatment.

**The primary path does not change.** A cardio set logs exactly like a duration
set today: type a duration (or accept the target), tap Log. If the user does
nothing else, Phase 1 behaves identically to the current beta.

Metrics are entered through a **collapsed "Details" disclosure** on the cardio
row, containing only the optional fields, and are **editable after logging**.
This matters: people read distance and calories off the console *after* they
stop, not before. Forcing pre-log entry would be wrong for the actual activity.

```
#1                                    [✓]
[  1800  ] 30m                    [Start] [Log]
▸ Details                    5.2 km · 142 bpm
```

Expanded, `Details` shows distance (+ unit), avg HR, HR zone, calories, incline,
and resistance — all optional, all blank by default, all validated the same way
duration is (non-negative, sane ceilings, empty resolves to nil).

Derived pace/speed render live under the fields as the user types, so a typo in
distance is visible before it is committed.

### 3.3 History

**Answer to design question 8.** The cardio item renders a one-line summary
built from whatever is present:

```
Treadmill Run
45m · 6.20 km · 4:50 /km · 142 bpm · 410 kcal
```

Rules:

- Segments with no value are omitted entirely — no `—` placeholders.
- A cardio row with only a duration renders exactly as it does today. **This is
  the compatibility guarantee for every existing cardio log.**
- Pace/speed are computed at render; a row with distance but no duration (or
  vice versa) simply omits the derived segment.
- Distance displays in the row's own `distanceUnitRaw`, not the current global
  setting, so history does not shift meaning when the user changes units.

### 3.4 Charts

**Answer to design question 9.** e1RM and volume are meaningless for cardio and
must not be extended to it. Cardio gets its own series, keyed off the same
`WorkoutHistoryAnalytics.ExerciseKey` so deleted-exercise fallback keeps working:

| Series | Y axis | Notes |
|---|---|---|
| Session duration | minutes | works for every cardio log, including old ones |
| Session distance | km / mi | only sessions with distance |
| Weekly distance | km / mi | the number most people actually track |
| Weekly duration | minutes | the fallback when distance is unlogged |
| Average pace | min/km | **see caveat** |

**Pace caveat.** Pace is only comparable at comparable distances — a 400m pace
and a 10k pace on one axis is a misleading chart. The pace series therefore
always renders distance on a secondary axis (or as a point annotation), so a
"faster" point that is also a much shorter session is visibly so. If that proves
hard to read, pace is dropped to Phase 3 and the distance/duration series ship
alone; they are the ones that carry the value.

**Existing protection to preserve:** `WorkoutHistoryAnalytics.hasValidWorkingSet`
requires `weight > 0 && reps > 0`, so cardio sets already fall out of the
strength series naturally. This must be verified by test, not assumed — it is
the thing that keeps a 45-minute walk from appearing as a bench press data point.

✅ **Shipped in Slice 11**, with the scope trimmed — see §2.40 for what was
built and why. Per-session distance, duration, pace, calories, and average heart
rate ship inside the existing Progression chart. The **weekly** distance and
duration roll-ups do **not**, and neither does the pace chart's distance
secondary axis; the pace caveat above therefore stands unmitigated and is
documented as such. The `hasValidWorkingSet` protection is now pinned by
`CardioProgressChartTests.testCardioWorkoutsAreInvisibleToStrengthAnalytics`.

### 3.5 Import / export

**Answer to design question 10.** Three formats, three different compatibility
situations. All three are **settled in Slice 9** — see §2.38 for what was built
and why.

**`ExerciseCSV`** — round-trips, and the importer previously *required exactly*
the v1 header `name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes`.
Adding a column naively would reject every previously exported file.

> **v2 header** appends `isCardio`. The importer accepts **both** v1 and v2
> headers; a v1 file imports with `isCardio = false`. The exporter emits v2.
> Header detection is by column count + name match, consistent with the existing
> trimmed/case-insensitive comparison.

**`WorkoutHistoryCSV`** — export-only, so new columns are purely additive.
Appends `distanceMeters`, `distanceUnitRaw`, `avgHeartRate`, `hrZone`,
`calories`, `inclinePercent`, `resistanceLevel` after the existing 14 columns.

**`RoutineTransferDocument`** — `currentSchemaVersion` gates *newer* documents
with a hard reject; older-or-equal is accepted, and unknown fields decode via
`decodeIfPresent`. Target distance is additive and optional, so **no version
bump.** An older build reading a newer export silently drops the distance target
rather than refusing the whole routine — the better failure for a personal app
shared between two phones. Documented, not accidental.

---

## 4. Migration

**Answer to design questions 11 and 12.**

### The rule: nothing converts silently

`isCardio` defaults to `false`. **Every existing exercise stays exactly what it
is.** Plank does not become cardio. Treadmill Run does not become cardio. No
backfill pass runs at bootstrap.

Cardio is opted into per exercise by a toggle in Exercise Detail, shown only when
`isTimeBased` is on.

### The one assisted path

Because the beta already told users to log cardio as duration exercises, leaving
them to flip seven toggles by hand is poor. The concession is a **one-time,
explicitly confirmed suggestion**, never an automatic rewrite:

> **Rule.** On first launch after the cardio update, if any exercise has
> `bodyPart == "Cardio" && isTimeBased == true && isCardio == false`, offer a
> single dismissible prompt listing those exercises with a "Mark as cardio"
> action. Declining is remembered. Nothing is written unless the user taps the
> action.

This satisfies "do not silently convert unless there is a clear migration rule"
by having a rule that is explicit *and* user-gated.

✅ **Shipped in Slice 10** as `CardioMigrationService` + a `BootstrapRoot`
alert — see §2.39 for the candidate rule, the prompt copy, the
one-time-per-catalogue-version persistence policy, and the exact list of what
conversion preserves. Two details settled during implementation: the alert does
**not** list the affected exercises by name (an alert cannot, and a sheet was
more UI than this earns — the body part *is* the list), and the body-part match
is trimmed and case-insensitive so legacy and CSV-imported rows are not missed.

### Old history is immutable

New `SetLog` fields are optional with nil defaults. Every existing `SetLog` keeps
rendering as it does today, forever. **Notes are never parsed to backfill
metrics** — a regex over free text that guesses "5k" meant 5000 meters would be
wrong often enough to poison the charts, and it would be silent data invention.
Users who want their old cardio notes as structured data re-enter them; the
notes stay where they are either way.

### Catalogue

Bump `ExerciseCatalog.currentVersion` to 3 and mark the cardio seeds
`isCardio = true`. The seeder's per-name dedupe **skips names that already
exist**, so an install that already has "Treadmill Run" from v2 will *not* have
it rewritten — that install picks the exercise up via the assisted prompt
instead. Fresh installs get it correct from the start. This asymmetry is
intentional and must be covered by test.

✅ **Shipped in Slice 10**, exactly as written, and the asymmetry is covered by
`CardioCatalogMigrationTests`. The seeder writes the catalogue and nothing else:
an addition that pre-resolved the migration prompt on a fresh seed was tried and
reverted before merge, because it silently stranded libraries imported after
install (§2.39, "the seeder must not pre-resolve the flag").

### Migration risk register

| Risk | Severity | Mitigation |
|---|---|---|
| `isCardio == true` with `isTimeBased == false` | Med | Enforce at both write sites; assert in tests; `trackingMode` reads `isTimeBased` first so the impossible state degrades to `.strength` rather than crashing |
| Exercise-switch adapter leaves cardio metrics on a strength slot | **High** | Add cardio fields to the adapter's existing compatibility table in the same slice; extend `SwitchExerciseConsistencyTests` |
| CSV v1 files rejected after header change | **High** | ✅ Slice 9: dual-header import, tested against literal v1 fixtures end to end (parse **and** importer) |
| Mixed km/mi aggregation | Med | Canonical meters storage |
| Old cardio logs render differently | Med | Summary omits absent segments; test asserts a duration-only row is byte-identical to today |
| Field bloat on `SetLog` slows strength logging | Low | All fields nil for strength; no new relationship, no extra insert |

---

## 5. Phases

### Phase 1 — Manual cardio metrics

The whole point of the feature. Ships alone if Phases 2–3 never happen.

**User-facing behavior**
- Exercise Detail gains a **Cardio** toggle (visible only when Time-based is on).
- Cardio slots in routines offer a target distance; sets default to 1; rest
  defaults to none; warm-ups and techniques are hidden.
- The active-workout cardio row gains a collapsed **Details** section for
  distance, avg HR, HR zone, calories, incline, resistance — all optional, all
  editable after logging.
- Live derived pace/speed under the entry fields.
- History shows a cardio summary line.
- Settings gains a distance unit (km / mi).
- The assisted "mark these as cardio" prompt, once.

**Data model changes**
- `Exercise.isCardio: Bool = false`
- `SetLog`: `distanceMeters`, `distanceUnitRaw`, `avgHeartRate`, `calories`,
  `inclinePercent`, `resistanceLevel`, `hrZoneRaw` — all optional, nil default
- `SlotPrescription` + `PlannedPrescriptionSnapshot`: `targetDistanceMeters`,
  `targetDistanceUnitRaw`
- `SessionPlan` (Codable): matching optional fields
- New: `CardioMetrics` value type (parse/normalize/derive), `HRZone` enum,
  `DistanceUnit` enum, `AppSettings.distanceIsMetric`
- `ExerciseCatalog.currentVersion` → 3

All additive with nil defaults; no SwiftData migration beyond lightweight.

**Migration risks** — the register in §4. The two High rows (switch adapter,
CSV header) are the ones that can lose user data or reject user files.

**UI changes**
`ExercisesView` (toggle) · `PrescriptionFields` (target distance, hide
warmup/techniques) · `SetRows` (new `CardioSetEntryRow`) · `ActiveWorkoutView`
(route cardio rows, post-log edit) · `HistoryView` (summary line) ·
`SettingsView` (distance unit) · `BlockPrescriptionSummary` · `EditSessionPlanSheet`

**Tests needed**
- `isCardio` implies `isTimeBased`; impossible state degrades safely
- metric parsing: negative rejected, empty → nil, above-max clamped, non-numeric
  → nil (mirroring `DurationInputTests`)
- pace/speed derivation, including divide-by-zero and missing-operand cases
- meters ↔ km/mi round-trip at both units
- cardio ↔ strength and cardio ↔ timed-hold switching clears/preserves the right
  fields (extends `SwitchExerciseConsistencyTests`,
  `ExerciseSwitchPlanAdapterTests`)
- **a duration-only cardio log renders exactly as it does today**
- Plank stays `.timedHold` through every path
- catalogue v3 seeds cardio flags on fresh installs and does **not** rewrite
  existing rows
- assisted prompt: identifies candidates, writes nothing until confirmed
- CSV v1 and v2 headers both import; v2 round-trips
- history CSV appends columns without disturbing the existing 14
- cardio sets stay out of the strength e1RM/volume series
- Korean localization for every new string, including the HR zone labels

**Docs needed**
`USER_GUIDE.md` + `UserGuideView.swift` (EN + KO — cardio section rewritten from
"details in notes" to the real fields, with notes still offered for anything
unstructured) · `ENTRY_12_TESTFLIGHT_FEEDBACK.md` (move structured metrics out of
Deferred, record what shipped) · this document (mark Phase 1 done) ·
`REFACTOR_PLAN.md` slice entries

**What must NOT be included in Phase 1**
HealthKit · GPS · watch import · any chart work · interval/structured cardio ·
cardio PRs · time-in-zone · target incline/resistance/HR in routines · per-set
cardio notes · converting `isTimeBased` to an enum · any automatic conversion of
existing exercises · parsing old notes.

---

### Phase 2 — Cardio History and charts

Only worth doing once Phase 1 data exists, because a chart of an empty table
teaches nothing.

**User-facing behavior**
- Cardio exercises become selectable in the analytics exercise picker.
- Series: session duration, session distance, weekly distance, weekly duration,
  and (if it reads well) average pace with distance context.
- History gains simple per-session cardio totals.
- Empty states matching the existing "no completed history" pattern.

**Data model changes**
None expected. If aggregation proves slow, a precomputed weekly summary may be
added — but only after measurement, per the CLAUDE.md "no heavy work in body"
rule.

**Migration risks**
Low. Read-only over existing data. The one real risk is **cardio contaminating
strength series** — guarded by test in Phase 1 and re-asserted here.

**UI changes**
`AnalyticsView` (cardio series + picker) · `HistoryView` (session totals) ·
possibly a cardio-specific detail screen

**Tests needed**
- weekly bucketing across month/year boundaries and DST
- mixed-unit history aggregates correctly (the canonical-meters payoff)
- sessions with partial metrics are included where valid, excluded where not
- cardio and strength series never cross-contaminate in either direction
- empty and single-point series render without crashing

**Docs needed**
`USER_GUIDE.md` + `UserGuideView.swift` charts section (EN + KO) · this document

**What must NOT be included in Phase 2**
Predictive/fitness modelling · VO2 estimates · training-load or ACWR scores ·
cross-exercise cardio comparison · HealthKit.

---

### Phase 3 — Optional advanced work

Nothing here is committed. Each item is independently justifiable or droppable.

**Candidates, roughly by value-to-risk**
1. **Interval / structured cardio** — repeats of work/rest bouts. The largest
   and most genuinely requested; also close to a second prescription system, so
   it deserves its own design document rather than a phase bullet.
   ✅ **Design complete (Slice 12A) — see [`STRUCTURED_CARDIO_DESIGN.md`](STRUCTURED_CARDIO_DESIGN.md).**
   The recommendation is an optional ordered list of planned segments encoded on
   `SlotPrescription` (no new `@Model`, no migration), rendered in the workout as
   a read-only checklist, with **logging left aggregate** — one cardio `SetLog`
   per bout, so History, the Slice 11 charts, prefill, and CSV are untouched.
   Repeat intervals and per-segment actuals are designed for and deliberately
   deferred. Implementation is Slices 12B–12F; none of it is built.
2. **Cardio PRs** — fastest 5k, longest ride. Needs a distance-bucketing rule to
   be meaningful.
3. **Time in heart-rate zone** — needs per-interval HR, which manual entry
   cannot supply honestly. Probably blocked behind a sensor integration, i.e.
   effectively deferred.
4. **Per-set cardio notes** — cheap, low value while exercise/session notes exist.

**Explicitly not in any phase:** HealthKit, GPS/route recording, watch or
third-party import, live heart-rate, automatic activity detection.

---

## 6. Alternatives considered

**A. `TrackingMode` enum replacing `isTimeBased`.**
The clean model: one stored enum, exhaustive switches, no invariant to enforce.
*Rejected.* It rewrites 95 call sites across the exact paths that produced this
project's P0 crashes and P1 switch bug, requires a real SwiftData migration, and
delivers no user-visible value on its own. The derived `trackingMode` property
recovers the ergonomics at call sites for none of the risk. Worth revisiting only
if a fourth tracking type ever appears.

**B. Separate `CardioLog` entity related to `SetLog`.**
Keeps `SetLog` clean; metrics live in their own table.
*Rejected.* It adds a second insert and a nullable relationship traversal to the
active-workout logging path — the most reliability-sensitive code in the app —
and complicates History, CSV export, and the snapshot invariant, all to avoid
seven nil columns. `SetLog` already carries `weight` (nil for bodyweight) and
`durationSeconds` (nil for strength); flat optional fields are the established
pattern here.

**C. A distinct `CardioExercise` model separate from `Exercise`.**
Maximum modelling purity.
*Rejected outright.* It forks routines, blocks, snapshots, History, analytics,
CSV, and the switch adapter — two parallel systems for one app. This is the
"overbuild" the product direction warns against.

**D. Structured key–value metrics (`[String: Double]` on the log).**
Infinitely extensible without migrations.
*Rejected.* Unqueryable without string keys everywhere, untypeable, unvalidatable,
and it turns unit handling into a convention. It is notes with extra steps.

**E. Keep notes, add parsing.**
Zero model change; extract `5k`, `142bpm` from free text.
*Rejected.* Silent data invention with no correction path, and it fails the
moment someone writes "felt like 5k". Notes stay unparsed, deliberately.

---

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Exercise-switch adapter leaks cardio state into a strength slot | Reintroduces the P1 bug the beta just fixed | Cardio fields join the adapter's existing compatibility table in the same slice; extend the existing switch test suites before shipping |
| `ExerciseCSV` header change rejects users' old exports | Users lose the ability to re-import their own data | ✅ Slice 9: dual-header import, tested against literal v1 fixtures end to end (§2.38) |
| Cardio pollutes strength charts | Silently wrong e1RM/volume | Existing `weight > 0 && reps > 0` filter, pinned by test rather than assumed |
| Active-workout logging regresses | Highest-severity area in the app | Primary path unchanged; metrics strictly additive behind a disclosure; duration-only flow tested as byte-identical |
| Scope creep into intervals | Phase 1 never ships | Intervals are explicitly Phase 3 and get their own design document |
| Field/unit ambiguity across history | Charts quietly wrong | Canonical meters + per-row entry unit |
| Korean strings lag the English UI | Family testers see mixed-language screens | Every new string localized in the same slice, per existing `KoreanLocalizationTests` |
| Invariant `isCardio ⇒ isTimeBased` broken by import | Impossible state in the store | Enforced at both write sites; `trackingMode` degrades safely; asserted in tests |

---

## 8. Suggested implementation order

Each item is one slice under the CLAUDE.md Slice Workflow: buildable, testable,
independently committable, additive-first.

| # | Slice | Why here |
|---|---|---|
| 1 | ✅ `CardioMetrics` / `HRZone` / `DistanceUnit` value types + `AppSettings.distanceIsMetric` | Pure, fully testable, zero UI risk — same shape as the `DurationInput` slice |
| 2 | ✅ `Exercise.isCardio` + derived `trackingMode` + Exercise Detail toggle | Smallest possible model change; establishes the invariant before anything depends on it |
| 3 | ✅ `SetLog` metric fields + History summary line | Storage and read-back, no logging-path change yet; proves old rows are untouched |
| 4 | ✅ Active-workout cardio row (Details disclosure) — post-log edit deferred, see §2.4 | The risky slice, entered with the model already proven |
| 5 | ✅ Prescription target distance + cardio routine rules (sets 1, no rest, hide warmup/techniques/tempo/effort) | Programming surface, once logging works |
| 6 | ✅ Exercise-switch adapter compatibility for cardio fields | Immediately after 5, while the field table is fresh; do **not** defer this |
| 6b | ✅ Cardio previous-performance prefill (§2.36) | Needs the target-vs-actual distinction Slice 5 established, and Slice 6's draft rules |
| 6c | ✅ Distance-unit Settings control, Settings-only policy (§2.37) | The Slice 1 preference had no UI; exposing it is independent of everything below. Patched before merge to remove the per-target unit pickers that overrode it |
| 7 | ✅ CSV v2 (dual-header import, history export columns) + routine-transfer compatibility (§2.38) | Isolated, high test value. Shipped ninth in execution order, after 6b and 6c |
| 8 | ✅ Catalogue v3 + assisted "mark as cardio" prompt (§2.39) | Last in Phase 1 — it is the only slice that touches existing user data |
| 9 | ✅ Cardio History charts (§2.40) — per-session series; weekly roll-ups still open | After real cardio data exists |
| 12A | ✅ **Design only** — structured cardio, see [`STRUCTURED_CARDIO_DESIGN.md`](STRUCTURED_CARDIO_DESIGN.md) | Phase 1 is complete and real cardio data now exists to design against |
| 12B | ✅ Structured cardio **pure value types** — `StructuredCardioPlan.swift`: segments, groups, bounds, expansion, summaries. No persistence, no UI, no export | Pure-first, exactly like Slice 1: the type is proven before anything depends on it |
| 12C | ✅ Structured cardio **persistence + routine authoring** — `cardioSegmentsData` on `SlotPrescription`/`PlannedPrescriptionSnapshot`, the Structured Cardio editor, duplication. Nothing in-workout, in History, or in any export | The one schema-touching slice of the structured plan; additive optional columns, lightweight migration verified on a real store |
| 12D | ✅ Structured cardio **in the workout** — `SessionPlan` carry-through, the frozen session snapshot, the read-only Cardio Plan checklist, tick persistence, exercise-switch rules. **Logging is untouched: still one aggregate cardio `SetLog`** | No schema change; the plan the user authored in 12C finally does something during a workout, without the log gaining a single row |
| 12E | ✅ Structured cardio **after the workout** — History "Planned" section from the frozen snapshot, additive `cardioSegments` on the routine transfer payload (no `schemaVersion` bump). Planned segments only; no tick state, no per-segment actuals, no CSV or chart change | Reads what 12C/12D already froze; History rows, cardio metrics and the Slice 11 charts all still come from the aggregate `SetLog` |

Slices 1–8 are Phase 1. Slice 6 is the one most tempting to defer and the one
most likely to reintroduce a known bug; it ships with Phase 1 or Phase 1 does not
ship.

---

## 9. Open questions

Resolve before Slice 1, not during:

1. **Default sets for a cardio slot: 1, or `AppSettings.defaultSets`?** This
   document assumes 1. If users build interval-ish cardio out of multiple sets
   today, that assumption is wrong and should be checked against beta feedback.
2. ~~**Is the assisted migration prompt worth its complexity?**~~ **Resolved:
   yes, and it cost less than feared.** Slice 10 shipped it as one service
   (~130 lines, no UI of its own) plus a four-string `.alert`, because the
   candidate rule turned out to be three field comparisons and the prompt state
   one `UserDefaults` integer. The user-guide line was written anyway — the two
   are complements, not alternatives: the prompt catches the seven beta
   exercises once, the guide explains the toggle forever.
3. **Does the pace chart read well enough to ship in Phase 2?** ~~Deferrable to
   Phase 2 itself, since distance and duration series carry the value alone.~~
   **Shipped in Slice 11, and still open as a question for testers.** Pace is a
   chart option alongside distance and duration, plotted from session totals
   with `m:ss` ticks. What the design feared — a 400 m interval session next to
   a 10 km run on one axis — is not solved, only made honest: each point is a
   real session pace, and distance sits one tap away in the same picker. The
   secondary-axis mitigation is still the fix if beta feedback says it misleads.
4. **Should `hrZone` and `avgHeartRate` both exist?** They serve different
   equipment. If beta testers only ever use one, drop the other in Slice 3.
5. ~~**Should decline (negative incline) be supported?**~~ **Resolved: yes.**
   `inclinePercent` accepts `[-30, 100]`. Settled during Slice 1, before any
   cardio UI existed, so the entry field is built signed rather than retrofitted.

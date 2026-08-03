# Cardio System Design

**Status:** design only — no app code written for this document.
**Date:** 2026-08-02
**Supersedes:** the "structured cardio metrics" entry under Deferred Feedback in
`ENTRY_12_TESTFLIGHT_FEEDBACK.md`.

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
shown as `4:50 /km` and `12.4 km/h`.

**Distance is stored canonically in meters** with the entry unit recorded
alongside. This is deliberately *better* than what weight does today
(`Units.weightIsKg` is a global display flag, so a history logged in lb and read
in kg is silently reinterpreted). Distance is more unit-ambiguous than weight
and has no bodyweight-style anchor to sanity-check it, and a weekly-distance
chart aggregating mixed km/mi rows would be quietly wrong. Canonical meters
makes aggregation correct by construction; `distanceUnitRaw` preserves what the
user typed so their own history reads back the way they entered it.

A new `AppSettings.distanceIsMetric` (default: follow `Locale`) supplies the
entry unit, matching the existing `weightIsKg` pattern.

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

**Fallback for an invalid raw unit.** When `distanceUnitRaw` is missing or
unparseable the summary falls back to `AppSettings.distanceUnit` and still shows
the distance, rather than dropping it — the value is stored canonically in
meters, so the number is correct in whichever unit it is rendered. An invalid
`hrZoneRaw` has no such fallback and is simply omitted: there is no correct
value to recover, and inventing a zone would be worse than showing none. The
fallback unit is a parameter, not a global read, so the formatter stays pure and
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
exercise-switch adapter** (still Slice 6). A per-row fetch inside `body` would
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
stored.

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
- **Effort (RIR/RPE)** — **kept.** RPE is meaningful for cardio ("RPE 6 easy
  run") and the field already works.
- **Warm-up scheme** — **suppressed** for cardio. "50% of working weight" has no
  cardio meaning. (Timed holds keep it; only `.cardio` suppresses.)
- **Techniques** — **suppressed** for cardio. Every technique type is
  rep-structured; the duration filter already removes most, and the rest are
  noise on a treadmill.

Block summary line for a cardio slot: `30m` or `5.0 km` or `30m · 5.0 km`.

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

### 3.5 Import / export

**Answer to design question 10.** Three formats, three different compatibility
situations:

**`ExerciseCSV`** — round-trips, and the importer *requires exactly* the v1
header `name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes`. Adding a
column naively would reject every previously exported file.

> **v2 header** appends `isCardio`. The importer accepts **both** v1 and v2
> headers; a v1 file imports with `isCardio = false`. The exporter emits v2.
> Header detection is by column count + name match, consistent with the existing
> trimmed/case-insensitive comparison.

**`WorkoutHistoryCSV`** — export-only, so new columns are purely additive. Append
`distanceMeters`, `distanceUnit`, `avgHeartRate`, `hrZone`, `calories`,
`inclinePercent`, `resistanceLevel` after the existing 14 columns.

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

### Migration risk register

| Risk | Severity | Mitigation |
|---|---|---|
| `isCardio == true` with `isTimeBased == false` | Med | Enforce at both write sites; assert in tests; `trackingMode` reads `isTimeBased` first so the impossible state degrades to `.strength` rather than crashing |
| Exercise-switch adapter leaves cardio metrics on a strength slot | **High** | Add cardio fields to the adapter's existing compatibility table in the same slice; extend `SwitchExerciseConsistencyTests` |
| CSV v1 files rejected after header change | **High** | Dual-header import, tested against a literal v1 fixture |
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
| `ExerciseCSV` header change rejects users' old exports | Users lose the ability to re-import their own data | Dual-header import, tested against a literal v1 fixture |
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
| 5 | Prescription target distance + cardio routine rules (sets 1, no rest, hide warmup/techniques) | Programming surface, once logging works |
| 6 | Exercise-switch adapter compatibility for cardio fields | Immediately after 5, while the field table is fresh; do **not** defer this |
| 7 | CSV v2 (dual-header import, history export columns) | Isolated, high test value |
| 8 | Catalogue v3 + assisted "mark as cardio" prompt | Last in Phase 1 — it is the only slice that touches existing user data |
| 9 | Phase 2 charts | After real cardio data exists |

Slices 1–8 are Phase 1. Slice 6 is the one most tempting to defer and the one
most likely to reintroduce a known bug; it ships with Phase 1 or Phase 1 does not
ship.

---

## 9. Open questions

Resolve before Slice 1, not during:

1. **Default sets for a cardio slot: 1, or `AppSettings.defaultSets`?** This
   document assumes 1. If users build interval-ish cardio out of multiple sets
   today, that assumption is wrong and should be checked against beta feedback.
2. **Is the assisted migration prompt worth its complexity?** The alternative is
   a line in the user guide saying "turn on Cardio for your cardio exercises".
   Cheaper, slightly worse. Decide before Slice 8.
3. **Does the pace chart read well enough to ship in Phase 2?** Deferrable to
   Phase 2 itself, since distance and duration series carry the value alone.
4. **Should `hrZone` and `avgHeartRate` both exist?** They serve different
   equipment. If beta testers only ever use one, drop the other in Slice 3.
5. ~~**Should decline (negative incline) be supported?**~~ **Resolved: yes.**
   `inclinePercent` accepts `[-30, 100]`. Settled during Slice 1, before any
   cardio UI existed, so the entry field is built signed rather than retrofitted.

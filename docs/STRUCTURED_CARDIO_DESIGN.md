# Structured Cardio — Design

**Status:** design complete (Slice 12A). **Slices 12B–12E shipped** — the value
types exist, a cardio routine slot can carry a segment plan, the routine editor
authors it, the workout shows it as a read-only checklist, completed History
shows what was planned, and routine transfer carries it. **Logging is unchanged:
one aggregate cardio `SetLog` per bout**, and History still reports that
aggregate as the result. Only 12F (repeat UI, and per-segment actuals if the
gate is met) remains — see §11–§14. Companion to `CARDIO_SYSTEM_DESIGN.md`,
which covers Phase 1 (Slices 1–11, shipped).

**Scope:** how Log programs a cardio bout that has *shape* — warm-up, work,
recovery, cool-down, and eventually intervals — without becoming a running app.

---

## 0. The one-paragraph answer

Structured cardio ships as an **optional, ordered list of planned segments
attached to a cardio routine slot**, stored as an encoded `Codable` payload on
the existing `SlotPrescription` (and frozen onto `PlannedPrescriptionSnapshot`),
using the same `Data?` mechanism `warmupStepsSnapshotData` already uses. During
the workout the segments render as a **read-only checklist** beside the existing
cardio entry row. **Logging stays exactly as it is today: one aggregate cardio
`SetLog` per bout.** No new `@Model`, no SwiftData migration, no change to
History rows, charts, CSV, or prefill. Repeats and per-segment actuals are
designed for but deliberately not built first.

---

## 1. Product scope (A)

### 1.1 Named segments, repeat blocks, or both?

**Both — but the data model ships whole and the UI ships in two steps.**

The four target sessions the brief lists split cleanly:

| Example | Needs |
|---|---|
| Warm-up → main → cool-down | ordered named segments |
| 5 min warm-up / 20 min run / 5 min cool-down | ordered named segments |
| Bike session with resistance targets | ordered named segments + per-segment resistance |
| Rowing with distance or pace targets | ordered named segments + per-segment distance |
| **5 × (1 min hard / 2 min easy)** | **repeat blocks** |

Four of five need only an ordered list. One needs repeats. A flat list is a
strict subset of the repeat model — it *is* a repeat group with `repeatCount: 1`
— so the payload carries `repeatCount` from the very first implementation while
the editor pins it to 1. When interval UI ships later it writes a field that has
been in the schema, in exports, and in the decoder all along. **Nothing migrates,
because nothing changes shape.**

This is the single most important decision in this document: *design the payload
for repeats now, expose repeats later.*

### 1.2 The smallest useful implementation

A cardio slot can carry an ordered list of segments. Each segment has a kind
(warm-up / work / recovery / cool-down), an optional duration, an optional
distance, optional incline / resistance / HR-zone targets, and an optional note.
During the workout they render as a checklist. The bout is logged as one set,
exactly as today.

That is genuinely useful on its own: it turns "30 min treadmill" into "5 easy /
20 @ 1% / 5 easy", which is the thing the user currently writes in setup notes
and reads off their phone anyway. It requires **no new entity and no new logging
path**.

### 1.3 What is deferred

| Deferred | Why |
|---|---|
| Repeat/interval **UI** | Needs a second editor idiom (group rows). The payload supports it from day one |
| Per-segment **actuals** | Doubles the logging surface and forces a decision about multiple `SetLog` rows. Aggregate logging keeps every Phase 1 feature working untouched |
| Per-segment **timer** | The tempting feature that turns this into a different app. See §4.5 |
| Segment-level **charts** | Nothing to chart until per-segment actuals exist |
| **Pace / speed targets** as their own fields | A segment with both a distance and a duration target *is* a pace target ("1 km in 4:30"). See §2.4 |

### 1.4 Staying a gym log

Three rules keep this in scope:

1. **The plan is programming; the log is one aggregate result.** The app records
   what a gym log records — what you did — and gains a description of what you
   intended. It does not gain a live tracking loop.
2. **No clock the app owns.** Segments do not drive a timer, do not fire
   notifications, and do not need the app in the foreground. The treadmill has a
   clock; the user has eyes.
3. **Everything is optional.** A cardio slot with no segments is the normal case
   and must stay visually and behaviourally identical to today.

---

## 2. Data model (B)

### 2.1 Recommended shape

Pure Swift value types, `Codable`, living in `Log/Services/` (or `Log/Models/`)
beside `CardioMetrics` — no SwiftData involvement at all:

```
CardioSegmentPlan          // the whole plan for one slot
  version: Int             // payload version, for forward evolution
  groups: [CardioSegmentGroup]

CardioSegmentGroup         // one repeat unit; a flat list is one group ×1
  repeatCount: Int         // 1 in the first release; 1...20 later
  segments: [CardioSegment]

CardioSegment
  kind: CardioSegmentKind  // warmUp | work | recovery | coolDown
  durationSeconds: Int?
  distanceMeters: Double?  // canonical meters, always
  inclinePercent: Double?
  resistanceLevel: Double?
  hrZone: HRZone?
  note: String?
```

Every field except `kind` is optional, and every value is normalized through the
same rules `CardioMetrics` already enforces (`CardioLimits`), so a segment can
never hold a negative distance or a 900 bpm zone. A segment with *no* target at
all is rejected at construction — it is a row that says nothing.

### 2.2 Where it is stored

Following the precedent already in the store (`WorkoutItem.warmupStepsSnapshotData`,
`techniquePlansSnapshotData` — JSON-encoded `Codable` arrays in optional `Data?`
columns):

| Location | Property | Purpose |
|---|---|---|
| `SlotPrescription` | `cardioSegmentsData: Data?` | the editable plan |
| `PlannedPrescriptionSnapshot` | `cardioSegmentsData: Data?` | frozen at session start; what History shows |
| `SessionPlan` (in-memory, `Codable`) | `cardioSegments: CardioSegmentPlan?` | the session's editable copy |
| `WorkoutItem` | *(none needed)* | the snapshot already hangs off the item |

Two new optional columns, both `nil`-default. That is **lightweight migration
territory** — the same additive path every slice from 1 to 11 used. No
`VersionedSchema`, no `SchemaMigrationPlan`.

### 2.3 Segment kind

A **closed enum**: `warmUp`, `work`, `recovery`, `coolDown`. No `custom` case.

Free-text kinds would have to be normalized, deduped, localized, and eventually
grouped in analytics — all cost, for a need the per-segment `note` already
covers ("Hill repeat", "Zone 2 float"). A closed enum is localizable (four
strings), sortable, and future-chartable. If beta feedback demands a fifth kind,
adding an enum case to a `Codable` raw-value enum is additive; removing a
free-text field never is.

**Decoder rule:** an unknown raw kind decodes to `.work` rather than failing the
whole payload, so a plan written by a future build degrades to something sane in
an older one.

### 2.4 Segment targets — and what is not one

**In:** duration, distance, incline, resistance, HR zone, note.

**Out, with reasons:**

- **Pace / speed target.** A segment carrying both a distance and a duration
  already expresses one ("1 km in 4:30" *is* 4:30/km), and the whole system
  derives pace rather than storing it — `CardioMetrics` refuses to store pace
  for exactly this reason, and a stored target pace that disagreed with a stored
  target distance and duration would be unresolvable. If rowing testers say
  "2:00/500m" must be enterable as such, the right answer is an *entry
  affordance* that writes distance + duration, not a fourth stored field.
- **Calories.** An outcome estimated by the machine, not something a person
  programs. A calorie target would be the app inviting the user to chase a
  number their equipment invented.
- **Rest between segments.** A recovery segment *is* the rest. A separate rest
  field would create two ways to express one thing.
- **RIR / RPE.** Already suppressed for cardio app-wide (§2.3 of the Phase 1
  design); nothing here reopens that.

### 2.5 Repeats: compact, not expanded

Store `repeatCount` and expand at render time via a pure function:

```
CardioSegmentPlan.expanded() -> [ResolvedSegment]   // index, round, segment
```

Storing expanded segments would be simpler to render and worse at everything
else: editing "5 rounds" would mean rewriting five copies, the payload would
grow linearly, and the user's intent ("this is an interval workout") would be
lost the moment it was saved. Compact storage keeps the plan editable as the
thing the user thinks in.

**Bounds, enforced at construction:** `repeatCount` 1...20, segments per group
1...20, total expanded segments ≤ 60. Bounded so the checklist stays renderable
and so a future timer can never be handed a 10,000-segment plan.

### 2.6 One SetLog or many?

**One.** The bout stays a single aggregate `SetLog`, exactly as today.

This is the decision that makes the whole feature safe:

- `CardioProgressAnalytics` (Slice 11) sums `SetLog` fields — unchanged.
- History rows and the cardio summary line (Slice 3) — unchanged.
- Workout History CSV cardio columns (Slice 9) — unchanged.
- Cardio prefill (Slice 7) reads the last bout's metrics — unchanged.
- The `sets: 1` cardio routine rule (Slice 5) — unchanged, and now *more*
  clearly right: an interval session is one bout with shape, not five sets.

If segments became `SetLog` rows, every one of those would need re-deriving, and
a 5×(1/2) session would land in History as ten rows and in the distance chart as
ten points that then need re-aggregating. The aggregate model gets the same chart
for free.

**When per-segment actuals arrive** (12F, criteria in §9), the additive path is a
`segmentActualsData: Data?` on `SetLog` — one row, an optional breakdown inside
it — so totals stay the source of truth for every existing reader.

---

## 3. Recommended architecture (C)

**Encoded plan payload + aggregate logging + pure expansion.**

### 3.1 Why it is safer than the alternatives

| Alternative | Why not |
|---|---|
| New `@Model CardioSegment` + `@Relationship` | Needs cascade rules, explicit ordering discipline, deep-copy in `RoutineDuplicator`, duplication into the snapshot, and an orphan sweep. This app has already had to write `BackfillService.purgeOrphanSetTemplates` to clean up exactly this class of mistake. Rows that are never queried independently should not be rows |
| Reuse `SetTemplate` rows as segments | `SetTemplate` means *a set* — reps, weight, kind. Slice 5 deliberately reduced cardio to one set; overloading set templates re-creates the semantic muddle that removed |
| Free-text "structure" note on the slot | Zero structure, no checklist, no future intervals. This is what users do today in setup notes — the feature exists to replace it |
| Expanded segment storage | See §2.5 |
| Segment-level `SetLog` rows | See §2.6 |

### 3.2 How it preserves current cardio

Every Phase 1 behaviour is preserved by *omission*: nothing about the logged
shape changes. A slot with `cardioSegmentsData == nil` renders and behaves
identically to today, which is the state of 100% of existing routines on the day
this ships.

### 3.3 How it supports growth

`version` + all-optional fields + `repeatCount`-from-day-one means: intervals,
per-segment actuals, and per-segment analytics are each an additive change to a
payload that already decodes. The pure `expanded()` function is the single seam a
future segment timer would consume.

### 3.4 The fan-out a new prescription field must traverse

Tracing `targetDistanceMeters` (Slice 5) shows exactly what `cardioSegmentsData`
will have to touch — this is the implementation checklist, and it is why this is
a multi-slice job:

1. `SlotPrescription` (store)
2. `PlannedPrescriptionSnapshot` (frozen copy)
3. `PrescriptionSnapshotPayload` (value snapshot, `StartWorkoutFromRoutineView`)
4. `SessionPlan` (session-scoped editable copy, `Codable`)
5. `SessionPlanResolver` (read path)
6. `ExerciseSwitchPlanAdapter` (compatibility table — §7.5)
7. `EditSessionPlanSheet` (in-workout edit)
8. `ActiveWorkoutView` "apply back to routine" diff
9. `RoutineTransferDTO` (export/import)
10. `RoutineDuplicator` (deep copy)

> ⚠️ **Pre-existing defect found while tracing this.**
> `RoutineDuplicator.copyPrescription` does **not** copy `targetDistanceMeters` /
> `targetDistanceUnitRaw` — duplicating a routine silently drops the cardio
> distance target, and no test covers it. Not fixed here (design-only slice); the
> first implementation slice that touches the duplicator should fix it and add the
> regression test, so `cardioSegmentsData` does not join it in the gap.

---

## 4. UI / UX (D)

### 4.1 Where the user adds segments (question 1)

Routine editor → cardio slot → **Prescription** section gains a **Segments**
row: `Segments  ·  none` / `Segments  ·  5 min warm-up, 20 min work, 5 min cool-down`,
tapping into a dedicated editor screen.

Visibility is one new rule in `CardioRoutineRules`:

```
static func showsCardioSegments(_ mode: TrackingMode) -> Bool { mode == .cardio }
```

— matching `showsTargetDistance`. Timed holds and strength slots see nothing new.
The segment editor is a plain `List` with drag-to-reorder and swipe-to-delete,
one row per segment, and an **Add segment** menu whose four entries are the four
kinds. Editing a row opens a compact sheet with duration, distance (in the
Settings unit), incline, resistance, HR zone, note — the same controls the active
cardio row already ships, reused.

### 4.2 How repeats appear (question 2)

Not at all in the first release. When they arrive: a **Repeat ×N** header row that
visually brackets its segments, added via "Group into repeat" on a multi-select,
with the count edited in the header. Rendered in summaries as `5 × (1 min work ·
2 min recovery)`.

### 4.3 Active workout (question 3)

A collapsed **Session plan** disclosure directly above the existing cardio entry
row, showing the expanded segment list read-only:

```
▸ Session plan · 3 segments · 30:00
    1  Warm-up    5:00
    2  Work      20:00   1% incline
    3  Cool-down  5:00
```

Read-only is deliberate: mid-workout *plan* edits already have a home
(`EditSessionPlanSheet`), and a second editing surface on the main logging screen
is how the highest-risk screen in the app regresses.

### 4.4 Checkboxes (question 4)

**Yes — a tap target per segment, but it is progress state, not a logged result.**
It is stored in session-scoped state persisted alongside the other per-slot drafts
(the `CardioEntryDraft` / `ParentDraftStore` pattern), so Save & Exit and cold
resume restore the ticks, and nothing reaches `SetLog`. Ticks are cleared when the
slot's exercise is switched, exactly as cardio drafts already are.

Rationale for storing at all: an interval session is precisely where the user
loses their place. Rationale for *not* persisting to the workout: a tick is not a
measurement, and History must never imply the app observed something it did not.

### 4.5 Per-segment timer (question 5) — **deferred, deliberately**

Not now. A per-segment timer means: background execution, notification
scheduling, a Live Activity (the app has one, for rest), audio cues, pause/skip
semantics, and drift handling — every one of them a real feature with a real
failure mode, and together they are the line between "gym log" and "interval
timer app". The treadmill already has a clock.

**Revisit criteria:** beta testers report they cannot follow a plan without it,
*and* the checklist has shipped and is being used. If built, it consumes
`expanded()` and reuses `RestTimer`'s persistence patterns rather than inventing
a second timing system.

### 4.6 Warm-up / cool-down vs. strength warm-up logic (question 6)

They never meet. `CardioRoutineRules.showsWarmupScheme(.cardio) == false` stays
exactly as it is: `WarmupScheme` / `WarmupStep` describe ramp-up **sets** in reps
and percentages of a working weight, which is meaningless for a treadmill — the
existing code comment already says a cardio warm-up "is a slower first few
minutes of the same bout, not a set structure the app currently models". This
design is that model, and it lives entirely in segments. **No strength warm-up
code is touched, read, or extended.**

### 4.7 Machines (question 7)

One model covers all four; the difference is which optional targets get used:

| Equipment | Typical segment targets |
|---|---|
| Treadmill | duration, distance, incline |
| Bike | duration, resistance, HR zone |
| Elliptical | duration, resistance |
| Rower | distance, duration (⇒ pace), resistance |

No per-equipment schema, no per-equipment UI. Fields left blank simply do not
render — the same rule the cardio Details row already follows.

---

## 5. History and charts (E)

| Surface | Change |
|---|---|
| History **row** summary | **None.** Aggregate duration/distance/pace, exactly as Slice 3 built it |
| History **detail** | Adds a read-only **Cardio Plan** section from the frozen snapshot, labelled as the plan — never presented as what happened |
| Slice 11 **charts** | **None.** `CardioProgressAnalytics` sums `SetLog` fields; segments are not `SetLog`s |
| Pace / distance / duration aggregation | **None.** Session totals, unchanged |
| Calories / heart rate | **None.** Still per-bout aggregates |
| Segment-level charts | **Deferred.** There is nothing to chart until per-segment actuals exist |

The honest limitation, stated once: with aggregate logging, a 5×(1/2) interval
session charts as one average pace, which understates the hard efforts. That is
the accepted cost of not fragmenting the log, and it is the strongest argument
per-segment actuals will ever have (§9, 12F).

---

## 6. CSV / transfer (F)

| Artifact | Change | Reason |
|---|---|---|
| **Exercise CSV** | **None** | Segments live on routine slots, not on `Exercise` |
| **Workout History CSV** | **None** | The export describes what was performed; aggregates already cover it. A JSON blob in a CSV cell would be hostile to the spreadsheet this format exists for |
| **Routine transfer JSON** | **Additive** — optional `cardioSegments` on `RoutineTransferSlotPrescriptionDTO` | Structure is programming, and programming is what routine transfer carries |

**Do not bump `schemaVersion`.** It stays `1`. `RoutineTransferDocument.validate()`
*rejects* documents whose version exceeds the build's — so bumping would make
every older build refuse a routine wholesale rather than import it minus its
segments. Nothing about an older document became invalid, which is the same
reasoning Slices 5 and 9 recorded when they added target-distance fields. Swift's
`Codable` ignores unknown keys, so the degradation is automatic and partial, not
fatal.

Round-trip rules: old file → new build decodes `nil` (no segments); new file →
old build silently drops segments and imports everything else; new → new is
lossless.

---

## 7. Migration / compatibility (G)

1. **Existing cardio routines** — `cardioSegmentsData == nil`. The Segments row
   reads "none"; nothing else moves.
2. **Existing cardio history** — untouched. No `SetLog`, `WorkoutItem`, or
   `Workout` field changes at all.
3. **Do old routines need migration?** No. Nil means "no structure", which is
   both the correct interpretation and the current behaviour.
4. **Do old logs need migration?** No. The logged shape is unchanged.
5. **Exercise switch** — extends the existing table rather than adding a rule:

| Switch | Segments |
|---|---|
| cardio → cardio, **Keep current plan** | **kept** (same rule as `targetDistanceMeters` / `keepCardioDrafts`) |
| cardio → cardio, **Reset to new exercise** | replaced by the reset source's segments (usually none) |
| cardio → timed hold / strength | **dropped from the session plan**, left intact on the stored routine slot |
| strength / timed hold → cardio | none seeded; the slot starts unstructured |

The "hidden but intact" principle from `CardioRoutineRules` applies verbatim: a
switch never deletes the routine's stored segments, so switching back restores
them.

**No SwiftData migration.** Two optional `Data?` columns with nil defaults are
lightweight-migration territory, the same path taken eleven times already. If
implementation discovers otherwise, that is a stop-and-report event, not a
migration to write quietly.

---

## 8. Test plan (H)

Per future slice; every item is a unit test unless marked.

**Segment model (12B)**
1. A segment with no targets at all is rejected.
2. Out-of-range distance / incline / resistance / HR zone normalize to nil, matching `CardioLimits`.
3. `repeatCount` and segment-count bounds enforced; over-cap plans rejected.
4. Unknown segment kind decodes to `.work`, not a decode failure.
5. Round-trip encode → decode is lossless.
6. A payload missing a field added later decodes with nil.
7. `expanded()` yields `repeatCount × segments`, in order, with correct round indices.
8. `expanded()` on a flat (×1) plan is the identity.
9. Summary text ("5 × (1 min work · 2 min recovery)") in both units and both languages.

**Persistence + routine editor (12C)**
10. Save → reload a slot's segments; unchanged.
11. A slot with nil segments loads as "no structure" and renders as before.
12. `showsCardioSegments` is true only for `.cardio`.
13. `RoutineDuplicator` deep-copies segments **and** `targetDistanceMeters` (the §3.4 defect).
14. Segments survive routine rename / variant duplication.
15. Editing segments never mutates a running session's snapshot.

**Active workout (12D)**
16. Snapshot is frozen at session start; editing the routine mid-session does not change the displayed plan.
17. Checklist renders expanded segments in order.
18. Tick state survives Save & Exit → resume, and cold resume.
19. Ticks clear on exercise switch; segments follow the §7.5 table.
20. **Aggregate `SetLog` is byte-identical to a no-segments bout** — the regression that matters most.
21. A cardio slot with no segments shows no new UI.

**History + transfer (12E)**
22. History row summary unchanged for a structured bout.
23. History detail renders the frozen plan, labelled as planned.
24. Slice 11 charts produce identical points with and without segments.
25. Existing `CardioProgressChartTests` / `CardioHistorySummaryTests` unchanged and passing.
26. Transfer export → import round-trips segments.
27. A pre-12E routine JSON still imports (nil segments).
28. A 12E export imported by a `schemaVersion: 1` reader keeps everything except segments.
29. Exercise CSV and Workout History CSV byte-identical to today.

**Cross-cutting**
30. Korean localization for every new string (4 kind names, editor labels, summary formats, empty states) — via the existing `KoreanLocalizationTests` pattern.
31. Full suite green; no `xcstrings` keys removed.

---

## 9. Implementation plan (I)

The brief's 12B–12E split is sound; I recommend one extra cut, separating the
pure types from the first persistence change. That is how Slice 1 shipped, and it
means the only slice that touches the schema does nothing else.

| Slice | Contents | Touches schema? | Tests required? |
|---|---|---|---|
| **12B** ✅ | Pure `CardioSegment` / `CardioSegmentGroup` / `CardioSegmentPlan`, validation, bounds, `expandedSegments()`, summary text. No UI, no persistence — **shipped, see §11** | No | Yes (pure) |
| **12C** ✅ | `cardioSegmentsData` on `SlotPrescription` + `PlannedPrescriptionSnapshot`; `CardioRoutineRules.showsCardioSegments`; routine editor Segments screen; localization of the kind labels — **shipped, see §12** | **Yes** (2 additive optional columns) | **Yes** — schema slice |
| **12D** ✅ | `SessionPlan` carry-through, snapshot at session start, active-workout checklist + tick persistence, switch-adapter rules. Logging path untouched — **shipped, see §13** | No | Yes — session/ownership |
| **12E** ✅ | History detail "Cardio Plan" section; routine transfer payload; compatibility fixtures — **shipped, see §14** | No | Yes — transfer/compat |
| **12F** | *Conditional.* Repeat-group UI; then, only if justified, per-segment actuals | Only if actuals ship | Yes |

**12F gate.** Repeat UI ships when a tester asks for intervals twice. Per-segment
actuals ship only if all three hold: (a) structured cardio is in real use, (b)
testers say the aggregate pace misrepresents their interval sessions (§5), and
(c) a design pass has answered what it does to History rows, charts, prefill,
and CSV. Absent (c), it does not start.

**Ordering note:** 12C is the only migration-adjacent slice and should land on
its own commit with the full suite run, per the Build & Test Policy.

---

## 10. Non-goals (J)

Not built, not designed for, not partially stubbed:

- GPS, location permissions, live position
- Route maps, route pace splits, elevation profiles
- HealthKit (read or write)
- Apple Watch app, complications, workout sessions
- Automatic tracking of any kind — auto distance, auto lap/segment detection, sensor streaming, cadence, power, foot pods, ANT+/BLE equipment
- Per-segment audio/haptic cues, background segment notifications, Live Activity for segments
- A training-plan engine — periodization, week-over-week progression, plan templates
- VO₂ max, training load, TSS, fitness/fatigue modelling
- Segment-level analytics (§9, 12F gate)
- Calorie or pace **targets** as stored fields (§2.4)
- Any change to strength warm-up, techniques, tempo, or effort targets (§4.6)

---

## 11. Slice 12B — as built

**Shipped:** `Log/Services/StructuredCardioPlan.swift` (one file, pure value
types) + `LogTests/StructuredCardioPlanTests.swift` (55 tests). No SwiftData
change, no persistence, no UI, no export.

### Types

| Type | Responsibility |
|---|---|
| `CardioPlanLimits` | The three bounds: `maxRepeatCount` 20, `maxSegmentsPerGroup` 20, `maxExpandedSegments` 60 |
| `CardioPlanError` | Typed refusal reason — `segmentHasNoTarget`, `emptyGroup`, `repeatCountOutOfRange`, `tooManySegmentsInGroup`, `tooManyExpandedSegments`. `Equatable`, so the 12C editor can say *which* thing to fix |
| `CardioSegmentKind` | `warmUp` / `work` / `recovery` / `coolDown`, `from(raw:)`, and a decoder that maps an unknown raw to `.work` |
| `CardioSegment` | One planned piece. `id: UUID` (persisted), kind, and the five optional targets + note |
| `CardioSegmentGroup` | `segments` + `repeatCount`; a flat plan is one group ×1 |
| `CardioSegmentPlan` | `version` + `groups`, plus totals, expansion, and summaries |
| `ResolvedCardioSegment` | One occurrence in the expanded list: `index`, `groupIndex`, `round`, `roundCount`, `segment`, and a deterministic `id` |

`CardioSegment.id` was not in the §2.1 sketch and is deliberate: the 12D
checklist keys tick state by segment, and that state has to survive Save & Exit,
cold resume, and a reorder. An index would not — inserting a warm-up at the top
would move every tick down a row. `ResolvedCardioSegment.id` is derived
(`"<segment uuid>#<round>"`), not a fresh `UUID()`, so a SwiftUI list diffs
cleanly across recomputes and round 2 can be ticked without ticking round 1.

### The rule the whole slice turns on: authoring rejects, decoding repairs

Typed input is refused with a typed error — a person is there to fix it. A
stored or imported payload is normalized — nobody is. This is the same split
`CardioMetrics` (rejects typos) and `DurationLimits` (clamps legacy data)
already make; structured cardio adds no numeric rules of its own, it delegates
every field to those two.

| | Authoring (`init` throws) | Decoding (`init(from:)`) |
|---|---|---|
| Segment with no target | `segmentHasNoTarget` | segment dropped from its group |
| Out-of-range incline / resistance / distance | field drops to nil; segment refused if nothing remains | same |
| Duration ≤ 0 | reads as "unset" (`DurationLimits`); segment refused if nothing remains | same |
| Duration > 6 h | clamped to `DurationLimits.maxExerciseSeconds` | same |
| Unknown segment kind | n/a (typed) | `.work` |
| Unknown HR zone | n/a (typed) | field dropped, segment kept |
| `repeatCount` outside 1...20 | `repeatCountOutOfRange` | clamped into range |
| > 20 segments in a group | `tooManySegmentsInGroup` | truncated to 20 |
| > 60 expanded segments | `tooManyExpandedSegments` | groups kept as a **prefix**, stopping at the first that does not fit |
| Group with no segments | `emptyGroup` | group dropped whole |

Prefix rather than best-fit truncation: skipping an oversized middle group and
keeping the cool-down after it would silently change what the session means.

**An empty plan is valid** and means "no structure" — deleting the last segment
in the editor must not be an error state. `CardioSegmentPlan.empty` and
`isEmpty` exist so 12C can store `nil` rather than an empty payload.

### Expansion

`plan.expandedSegments() -> [ResolvedCardioSegment]` — pure, total, and
deterministic (same plan in, same array out, ids included). It cannot exceed the
60-segment bound because both construction and decoding already enforce it, so
it does not throw. The receiver cannot be mutated: every stored property is a
`let`. Groups expand in order, rounds in order, segments in order within a round
— work/recovery alternate, never grouped by kind.

`totalDurationSeconds` / `totalDistanceMeters` count every round, and are `nil`
rather than `0` when no segment carries that target.

### Summaries

Three levels, all taking `DistanceUnit` as a parameter — no pure type reads
`AppSettings`:

| API | Example |
|---|---|
| `segment.summary(distanceUnit:)` | `Work · 20m · 5 km · 1% · L8 · Z3` |
| `segment.shortSummary(distanceUnit:)` | `1m work` (leading target only) |
| `group.summary(distanceUnit:)` | `5m warm-up · 20m work` / `5 × (1m work / 2m recovery)` |
| `plan.summary(distanceUnit:)` | `10 segments · 15m · 5 km`, or `No segments` |
| `plan.structureSummary(distanceUnit:)` | `5 × (1m work / 2m recovery)` |

`plan.summary` counts **expanded** segments — what the athlete performs, not
what the author typed. Formatting is delegated: `DurationFormat.compact` for
time, `CardioTargetDistance.displayText` for distance, so a plan and a routine's
distance target can never render differently.

**Localization: deliberately not yet.** These strings are plain English,
following `SessionPlan.primarySummary`, which is the closest analogue in the app
— a pure summary of a prescription, also unlocalized, also built by
interpolation. There is no UI in this slice, so localizing now would add
`.xcstrings` keys with no render site and freeze wording that the 12C editor is
likely to change. The 12C/12D slices that first display these own the
localization, and `CardioSegmentKind.label` is the single place the four kind
names come from.

### Deferred to 12C and later

- **Persistence** — `cardioSegmentsData: Data?` on `SlotPrescription` and
  `PlannedPrescriptionSnapshot`, plus `SessionPlan` carry-through (§2.2, §3.4).
  Nothing in 12B is stored.
- **Routine editor UI** and `CardioRoutineRules.showsCardioSegments`.
- **`repeatCount` UI** — the field exists and is enforced, but the editor pins
  it to 1 until 12F.
- **Localization** of the kind labels and summaries (above).
- Active-workout checklist and tick state (12D); History display and routine
  transfer payload (12E); per-segment actuals (12F, gated).

---

## 12. Slice 12C — as built

**Shipped:** routine-level persistence and the authoring UI.

| File | |
|---|---|
| `Log/Models/Entities.swift` | `cardioSegmentsData: Data?` on `SlotPrescription` **and** `PlannedPrescriptionSnapshot` |
| `Log/Models/SlotPrescription+StructuredCardio.swift` | `structuredCardioPlan`, `setStructuredCardioPlan(_:)`, `clearStructuredCardioPlan()`, `hasStructuredCardioPlan` |
| `Log/Services/CardioRoutineRules.swift` | `showsCardioSegments(_:)` |
| `Log/Main/Routines/CardioSegmentPlanEditor.swift` | the editor screen + per-segment sheet |
| `Log/Main/Routines/PrescriptionFields.swift` | the **Structured Cardio** row, beside the distance target |
| `Log/Services/RoutineDuplicator.swift` | copies the payload |

### Persisted fields

`SlotPrescription.cardioSegmentsData: Data?` — the editable plan, JSON.

`PlannedPrescriptionSnapshot.cardioSegmentsData: Data?` — added now, **written
by nobody**. 12C is the one schema-touching slice in this plan (§9); adding the
snapshot column with its first reader in 12D would have made a second one. A
workout started today still snapshots nil.

Both optional, nil-default. **Verified on a real store**: launching the new build
against an existing simulator database added both `ZCARDIOSEGMENTSDATA` BLOB
columns by lightweight migration with 31 exercises, 5 workouts and 6 set logs
preserved and no custom `SchemaMigrationPlan`.

### One representation of "no structure"

`structuredCardioPlan` returns `nil` for a nil payload, an empty plan, an
unreadable payload, and a payload whose every segment normalizes away.
`setStructuredCardioPlan` clears the column for a nil or empty plan rather than
storing an empty payload. So the store has exactly one way to say "no
structure", no view checks three states, and **a corrupt payload costs the plan,
never the routine** — a slot whose column is garbage still opens and edits.

### Editor behavior

The prescription section gains a **Structured Cardio** row for cardio slots
only (`showsCardioSegments`), directly under the distance target, showing the
plan summary or "None". It pushes a list screen:

- **Add Segment** — a menu of the four kinds; the new row is seeded with a
  plausible duration (warm-up/cool-down 5 min, work 10 min, recovery 2 min) so
  it is valid on creation, and its editor opens immediately.
- **Tap a row** — a sheet with type, duration (`DurationFieldRow` presets +
  wheels), distance, incline/decline, resistance, HR zone, and a note. **Done is
  disabled while every field is empty**, which is how "a segment needs at least
  one target" is enforced — a disabled control rather than an alert after the
  fact.
- **Swipe to delete**, **drag to reorder** (EditButton). Order is the plan.
- Add is disabled at the segment cap, with a footer saying so.

Every mutation commits straight to the prescription; there is no unsaved state
to lose, matching how the rest of the routine editor behaves.

**Segment fields exposed: all of them.** The design's §4.1 sketch expected
incline/resistance/HR zone might have to be deferred for space; in a dedicated
per-segment sheet they cost one row each, so nothing was cut.

### Repeats: still deferred

The editor authors exactly **one group with `repeatCount == 1`**. The field is
stored, enforced, and round-tripped — a repeated plan written by 12F (or by
hand) reads and renders correctly today — but no UI produces one. Pinned by
`testEditorAuthoredPlansUseASingleUnrepeatedGroup`.

### Duplication

`RoutineDuplicator.copyPrescription` copies `cardioSegmentsData` **raw**, not
decode → re-encode: a payload this build would normalize (or cannot parse)
survives duplication byte-for-byte instead of being silently rewritten. `Data`
is a value type, so the duplicate owns its payload — editing it cannot reach the
source. The Slice 5 target-distance fields keep copying as before.

### Localization

11 new keys, Korean included: the screen and row titles, the section header, the
add button, the empty state, the two footers, the remove button, and the four
segment-type names. `CardioSegmentKind.label` is rendered through
`LocalizedStringKey`, so the four names have exactly one source.

Composed summaries ("3 segments · 30m") stay **verbatim and unlocalized**,
matching `SessionPlan.primarySummary` and every other assembled plan summary in
the app — there is no whole phrase to translate.

### Deferred to 12D and later

- **Everything in-workout**: no checklist, no ticking, no segment display on the
  active screen. A plan authored today changes nothing about running a workout.
- Snapshotting the plan at session start, `SessionPlan` carry-through, and the
  exercise-switch rules (§7.5) — the snapshot column exists but is unused.
- History display (12E), routine transfer payload (12E), repeat UI (12F).
- **User guide**: not updated. The feature is authorable but does nothing during
  a workout yet, and a guide entry would promise behavior 12D has not shipped.
  It lands with the checklist.

---

## 13. Slice 12D — as built

**Shipped:** the plan reaches the workout, and the workout shows it.
No schema change, no migration, and **not one line of the logging path**.

| File | |
|---|---|
| `Log/Main/StartWorkoutFromRoutineView.swift` | `cardioSegmentsData` + `structuredCardioPlan` on `PrescriptionSnapshotPayload`; carried in all three of its initializers and in `toModel()` |
| `Log/Models/Entities.swift` | `cardioSegmentsData` parameter on `PlannedPrescriptionSnapshot.init` and its `SlotPrescription` convenience init — the column existed already |
| `Log/Models/SessionPlan.swift` | `cardioSegmentsData` + `structuredCardioPlan` |
| `Log/Services/SessionPlanResolver.swift` | `plannedCardioSegments(sessionPlan:snapshot:)` |
| `Log/Services/ExerciseSwitchPlanAdapter.swift` | `ResetSource.cardioSegmentsData`; keep/reset rules; `adaptedSnapshot` writes the field |
| `Log/Services/CardioSegmentCheckStore.swift` | **new** — per-workout tick persistence |
| `Log/Main/ActiveWorkout/CardioSegmentChecklistSection.swift` | **new** — the checklist |
| `Log/Main/ActiveWorkoutView.swift` | resolution gate, section placement, tick state + rehydrate/reconcile/clear |
| `Log/Services/StructuredCardioPlan.swift` | `CardioSegment.shortTargetSummary` moved here from the 12C editor — two features render it now |

### Carry-through

The plan travels the §3.4 fan-out as far as the workout needs it:

```
SlotPrescription.cardioSegmentsData
  → PrescriptionSnapshotPayload.cardioSegmentsData     (plan build / resume)
      → PlannedPrescriptionSnapshot.cardioSegmentsData (frozen at session start)
      → SessionPlan.cardioSegmentsData                 (session's editable copy)
          → SessionPlanResolver.plannedCardioSegments  (session plan → snapshot)
```

**Carried as the encoded payload, never decoded and re-encoded.** A plan this
build would normalize — an out-of-range `repeatCount`, a kind it has never heard
of — rides through the session byte-for-byte, exactly as
`RoutineDuplicator.copyPrescription` copies it. Decoding happens at the read
site, through accessors that are identical in all three places
(`SlotPrescription`, `PrescriptionSnapshotPayload`, `SessionPlan`) and identical
in behaviour: **nil payload, empty plan, and unreadable payload all read as
nil.** A corrupt payload costs the checklist, never the session.

`SessionPlan` is `Codable` and `Data` encodes as base64, so the plan persists
through `AppState.sessionPlansJSON` for free. A `SessionPlan` written by an
older build decodes with nil here — synthesized `Codable` reads an `Optional`
with `decodeIfPresent`, the same compatibility the Slice 5 target-distance
fields rely on.

**The snapshot column finally has a writer.** 12C added
`PlannedPrescriptionSnapshot.cardioSegmentsData` and wrote nothing to it; the
session-start path fills it now, so a workout keeps showing the plan it was
started with even after the routine is edited mid-session.

### What did *not* change

This is the claim the slice turns on, and it is pinned by
`testAStructuredPlanDoesNotChangeAnyOtherResolvedTarget`:

- set count, duration target, distance target and the Plan-card summary resolve
  **identically** with and without segments;
- no extra sets, no extra `SetLog` rows, no change to `appendTimeSetLog`;
- a 5 × (1/2) plan still resolves to `sets: 1` — one bout with shape.

### The checklist

A **Cardio Plan** section **immediately above the Sets section** — after the
Plan card, Equipment & Setup, and Warmup — rendered only when the slot's *live*
exercise is cardio **and** its resolved plan has segments. Strength slots, timed
holds, and unstructured cardio slots construct nothing, so "no new UI for
everyone else" is structural rather than a matter of testing every path, and no
other section moved to make room.

The position is the point: it is the plan you read *while the bout is running*,
so it belongs against the rows you tick it beside. Sitting up by the Plan card
put Equipment & Setup between the checklist and the set it describes.

```
Cardio Plan
  ▾ 3 segments · 30m                                    1/3
    ✓  Warm-up      5m
    ○  Work        20m · 1%
    ○  Cool-down    5m
```

**No explanatory footer.** An earlier revision carried "A checklist for this
bout. Ticks are not saved to your history." under the section; it was removed
before merge, along with its localization key. It described the app's internals
on the one screen where the user is mid-workout and not reading, and the
behaviour it claimed is enforced in code rather than by the caption
(`CardioSegmentCheckStore` is the only writer, and it cannot reach a `SetLog`).
The User Guide is where it is explained.

- Rows are `plan.expandedSegments()` in order — the pure 12B function, so
  repeats flatten with no second implementation.
- Each row: tick, kind (localized), kind-less target summary, note. `Round 2/5`
  appears only on a repeated group, so a flat plan — every plan until 12F —
  renders exactly as it would without repeats.
- **Read-only except the ticks.** No target editing, no timer, no automatic
  progression, no gate on the Log button: the aggregate set logs from the
  duration and Details fields exactly as before, whether nothing or everything
  is ticked.
- The whole row is the tap target, not just the glyph (§15.4's open question).
- Bounded for free: `expandedSegments()` cannot exceed
  `CardioPlanLimits.maxExpandedSegments` (60), because construction *and*
  decoding enforce it.

**Deviation from §4.3, deliberate:** the section starts **expanded**, not
collapsed. §4.3 wanted it collapsed because it sketched the disclosure inline
above the cardio entry row, where a long plan would push the duration field and
Log button off screen. As its own List section above Sets, a long plan simply
scrolls — and a checklist you must open before every tick is worse than one you
scroll past. The summary row is still the disclosure control for anyone who
disagrees.

### Tick persistence

`CardioSegmentCheckStore` — a sibling of `ParentDraftStore` /
`DropWeightDraftStore`, not a field on either.

| | |
|---|---|
| Key | `"cardioSegmentChecks_<workoutUUID>"` → `[String: [String]]` |
| Per slot | `slotID.uuidString` → the ticked `ResolvedCardioSegment.id`s |
| Written | on every toggle, like the cardio draft binding — no commit point to miss |
| Cleared | workout finish/discard (`unlockAndDismiss`), and per slot on a switch |

Its own key rather than `ParentDraftStore`'s because a tick is **per slot, not
per set** — a structured plan describes one bout, and the app logs one aggregate
set for it, so there is no set index to key on. Keeping it separate also makes
the guarantee structural: **there is no code path from this store to a `SetLog`,
a `WorkoutItem`, or a `Workout`.** History cannot imply the app observed a
segment it did not.

Ids are `"<segment uuid>#<round>"`, so ticking round 1 leaves round 2 unticked,
and reordering the plan carries a tick with its segment rather than leaving it
on whatever moved into that row.

**Orphans are ignored, never repaired.** Every read filters the stored ids
against the live expanded plan (`checked(slotID:in:)`), so a tick naming a
segment that no longer exists — an edited routine, a reset plan, a slot switched
away from cardio — stops rendering and stops counting. The resume path prunes
them on disk too, so they cannot accumulate. `checked(slotID:in: nil)` is empty,
which is what makes "no plan ⇒ no checklist state" fall out rather than needing
its own rule.

### Exercise switch

The §7.5 table, implemented — the plan follows `targetDistanceMeters` exactly:

| Switch | Segment plan | Ticks |
|---|---|---|
| cardio → cardio, **Keep** | kept | kept (every id still matches) |
| cardio → cardio, **Reset** | the reset source's (app defaults carry none) | cleared |
| cardio → timed hold / strength | dropped from the session plan | cleared |
| strength / timed hold → cardio | none seeded | none to keep |

**Why Reset always drops the plan today — and why that is correct.** A
structured plan belongs to the routine *slot*, not to an `Exercise`: there is no
`cardioSegmentsData` on `Exercise`, because the same treadmill is programmed
differently in different routines. A switched-in exercise therefore brings no
plan with it, and `ResetSource.appDefaults` deliberately supplies none — the
same rule that makes Reset drop the target distance (Slice 6). "Reset" means the
values a freshly-authored slot for this exercise would have, and inventing a
session structure the user never wrote would be programming on their behalf.

The adapter *does* apply a reset source's plan whenever one is supplied, so the
day a caller has a real replacement to offer the checklist will show it with no
change to the adapter. Both directions are pinned through the resolver — the
same two-tier read the view's visibility gate uses, so a stale tier-2 payload
cannot resurrect a dropped plan:
`testResetToCardioWithAStructuredSourcePlanShowsTheReplacementPlan` and
`testResetToCardioWithoutASourcePlanHidesTheChecklist`.

`Outcome.keepCardioDrafts` gates the ticks as well as the typed metrics: the
question ("does this slot's session-scoped cardio state still describe what is
being done?") and the truth table are identical, and a second flag with the same
value would only be one more thing to keep in step. The ticks are then
reconciled against the post-switch resolved plan, so Keep preserves them by
*matching* rather than by assertion.

`adaptedSnapshot` writes `cardioSegmentsData` **unconditionally** from the
adapted plan, for the same reason it does for the distance target: `base` is the
*replaced* exercise's snapshot, so leaving it alone is precisely how a cleared
plan would reappear via tier-2 resolution on the next resume.

The routine's stored plan is never touched by a switch — "hidden but intact", so
switching back restores it.

**Stale rest, fixed with the switch (not a structured-cardio bug, but found
here).** A switch deletes the slot's `WorkoutItem` and every `SetLog` under it,
and the superset cascade can clear a partner's too — but nothing told the rest
timer, so a rest started by the just-logged set kept running and fired a
notification for a set that no longer existed. `performPendingSwap` now ends it
via the pure `shouldCancelRestAfterExerciseSwitch`, which asks **"does the
resting slot still have a logged set"** rather than "was this slot switched".
That framing covers the cascade case for free and leaves normal rest untouched:
a rest on a slot that still has its logs keeps running, so logging without
switching is unaffected. The rest's owner comes from `AppState.activeRestSlotID`
(so it works after a cold resume); an unattributable rest is left alone, and
`rest.stop()` — the existing cancellation path — cancels the pending and
delivered notification and returns the Live Activity to neutral. Rest *rules*
(prescription rest, `RestPlanner`) are untouched. This applies to every
tracking mode, not just cardio, because the defect was never cardio-specific;
cardio simply surfaces it every time, since a cardio slot prescribes no rest.

### Active Edit Plan

Unchanged, and deliberately so. The sheet edits through per-field bindings, so
`cardioSegmentsData` passes through it untouched — open it, change the target
distance, close it, and the structured plan is exactly what the session started
with. Existing target-distance behaviour is unaffected.

Segments are **not** editable there: authoring lives in
`CardioSegmentPlanEditor`, and building a second segment editor on the app's
highest-risk screen for a mid-session need nobody has reported is how that
screen regresses. Deferred, gated on a report.

`isSessionPlanDirty` deliberately does **not** compare segments, so
"Finish + Update slot prescription" never writes them back. Nothing in the
workout can change them, and after a cardio → strength switch the routine slot
must keep the plan it authored (§7.5).

### Localization

Three new keys, Korean included: the section header, the footer, and the
`Round %lld/%lld` badge. The four segment kind names come from
`CardioSegmentKind.label` rendered through `LocalizedStringKey` — the same
single source 12C introduced. Composed summaries ("3 segments · 30m") stay
verbatim, matching `SessionPlan.primarySummary` and the 12C editor.

### Deferred to 12E and later

*(All of the History and transfer items below shipped in 12E — see §14.)*

- **History**: no structured-cardio display anywhere — not in the row summary,
  not in the detail. The frozen snapshot now *carries* the plan, which is what
  12E's "Cardio Plan" section will read; nothing renders it yet.
- **Routine transfer**, CSV/export/import: unchanged, no segment payload.
- **Charts**: unchanged — `CardioProgressAnalytics` sums `SetLog` fields and
  segments are not `SetLog`s.
- **Per-segment actuals** (12F, gated), **repeat authoring UI** (12F),
  **per-segment timers** (§4.5), and every §10 non-goal.
- **In-workout segment editing** (above).

---

## 14. Slice 12E — as built

**Shipped:** the plan becomes visible after the workout, and shareable with the
routine. No schema change, no migration, no `schemaVersion` bump, and — again —
nothing touching the logging path.

| File | |
|---|---|
| `Log/Models/SlotPrescription+StructuredCardio.swift` | `PlannedPrescriptionSnapshot.structuredCardioPlan` — History's only read path |
| `Log/Services/CardioPlannedHistory.swift` | **new** — pure row/summary builder for the Cardio Plan section |
| `Log/Main/HistoryView.swift` | the Cardio Plan block, in both the singleton and superset render paths |
| `Log/Services/CardioHistorySummary.swift` | `inclineText` / `resistanceText` exposed, so planned and logged lines share one vocabulary |
| `Log/Services/RoutineTransferDTO.swift` | `cardioSegments` on the prescription DTO + `RoutineTransferCardioSegmentsDTO` |
| `Log/Services/RoutineTransfer.swift` | export mapping |
| `Log/Services/RoutineTransferImport.swift` | import mapping |

### History: the Cardio Plan section

A **Cardio Plan** block inside each exercise's History section, between
Equipment & Setup and the logged set rows:

```
Cardio Plan                                     3 segments · 21m · 2 km
Warm-up                                                             10m
2 km · 0% incline · level 5 · Z1 · Easy
Recovery                                                             1m
Z1
Cool-down                                                           10m
Z1
```

**Labelled "Cardio Plan", not "Planned".** The pre-merge label was accurate and
too vague — it named the *tense* of the section rather than what was in it. The
active checklist already calls the same list Cardio Plan, so History now uses
the same words for the same thing, and "plan" is unambiguous that these are
programmed segments rather than per-segment results. The key is the one 12D
introduced, so this cost no new localization.

**Row shape mirrors the logged set row it sits above.** Kind on the left, one
headline value on the right, detail underneath — the same three type styles
(`.dsBody` label, `.dsBodySecondary.monospacedDigit()` trailing value,
`.dsCaption` metadata, `spacing: 2`) `setLogList` uses, so planned and performed
values line up in one column and the eye lands in the same places reading
either. The only difference is what the numbers *mean*, and the header says
which.

- `primaryTargetText` is the segment's **leading** target — its duration, or
  whatever it does carry when it has none, so the headline column is never
  blank. It holds the position a logged row gives its duration.
- `secondaryText` is everything else on one line, joined with the same
  separator the logged metric lines use.
- **The note is part of that metadata line, never its own.** One rule, no length
  threshold: a short note reads as one more piece of detail instead of a
  detached fragment, and a long one wraps inside the same typography rather than
  switching style mid-row.
- Incline and resistance use the **logged row's vocabulary** ("0% incline",
  "level 5") via `CardioHistorySummary.inclineText` / `.resistanceText`, now the
  single source of those localized words. The compact forms ("1%", "L8") stay in
  the routine editor and the active checklist, where brevity earns its place;
  History sits two rows above the logged metric line, and naming the same
  quantity differently there would read as two unrelated things. Duration keeps
  the plan's own "10m" rather than the logged `"1800s"` — a *target* of 1800s is
  not how anyone programs a session.
- Rows come from the pure `CardioPlannedHistory.rows(for:distanceUnit:)`, which
  expands through the same 12B `expandedSegments()` the active checklist uses —
  one implementation, so History and the workout can never disagree about what
  the plan says. Bounded by construction at 60 rows.
- The kind travels as a **localization key** (`CardioSegmentKind.label`) and is
  rendered through `LocalizedStringKey`, so the section reads in Korean. The
  targets are verbatim, like every other composed plan summary.
- A repeated group shows `Round 2/5` beside the kind, reusing the key 12D
  introduced. No plan the current editor writes has one, so today every row
  renders without it.
- Distances follow `AppSettings.distanceUnit` at render time, so switching
  km ↔ mi re-reads History's planned rows exactly as it re-reads its logged ones.

**Planned is not performed.** There is no tick, no checkmark, and no completion
state — `CardioPlannedSegmentRow` has nowhere to put one, and there would be
nothing to put there anyway: the active checklist's ticks live in
`CardioSegmentCheckStore` (per-workout `UserDefaults`, dropped on finish) and
were never part of any workout record. History must never imply the app observed
something it did not (§4.4).

**Nothing about the aggregate changed.** Distance, duration, pace, speed,
calories, HR, incline and resistance still come from the aggregate `SetLog` via
`CardioHistorySummary`, the row summary is untouched, and the Slice 11 charts
still sum `SetLog` fields — segments are not `SetLog`s. The Planned block is
purely additive above rows it does not touch.

**Visibility is structural.** The section renders only when the frozen snapshot
decodes to a non-empty plan, and that one condition is also the cardio gate:
only a cardio slot can author segments (`showsCardioSegments` is true for
`.cardio` alone), and 12D's switch adapter writes nil onto any snapshot it
adapts to a non-cardio mode. So a strength item and a timed hold decode nil and
add zero rows without History ever asking what tracking mode the item was. A
corrupt payload decodes nil too — it costs the Cardio Plan section, never the
History row.

### Source of truth

```
SlotPrescription.cardioSegmentsData          ← the routine editor writes (12C)
  → PlannedPrescriptionSnapshot              ← frozen at session start (12D)
      → SessionPlan → the active checklist   ← what you tick (12D)
      → History "Cardio Plan"                ← what you planned (12E)
```

History reads the **frozen snapshot**, never the live routine. Reprogram the
routine tomorrow and last week's workout still reports the plan it was started
with — the same snapshot-immutability invariant Equipment & Setup relies on, and
`Data` being a value type is what makes it structural rather than careful.

### Routine transfer

An additive optional `cardioSegments` on
`RoutineTransferSlotPrescriptionDTO`, carrying the plan as **nested JSON**
rather than the stored `Data` blob — the transfer format is human-readable and
hand-edited, and a base64 column inside it would be opaque to exactly the
audience it exists for:

```json
"cardioSegments": {
  "version": 1,
  "groups": [{ "id": "…", "repeatCount": 1, "segments": [ … ] }]
}
```

Round-trips losslessly: kind, **segment `id`**, `repeatCount`, duration,
distance, incline (sign included), resistance, HR zone, and note. `repeatCount`
has no editor yet, so transfer is the only place it is proven to survive — which
is precisely why 12B put it in the payload on day one.

**`schemaVersion` stays 1.** `validateSupportedSchemaVersion` *rejects* a
document whose version exceeds the reader's, so bumping would make every older
build refuse a routine wholesale rather than import it minus its segments —
the same reasoning Slices 5 and 9 recorded. Round-trip rules: old file → new
build decodes nil; new file → old build silently drops segments and imports
everything else; new → new is lossless. A routine with no plan omits the key
entirely, so its document is byte-identical to before this slice.

**Export decodes; import re-normalizes.** Export goes through
`structuredCardioPlan`, so a stored column this build cannot parse exports as
*no plan* rather than shipping corruption to someone else's device — deliberately
unlike `RoutineDuplicator`, which copies raw because duplication stays inside one
store. Import writes through `setStructuredCardioPlan`, so an absent key, a
malformed value, and a plan whose every segment normalized away all land as the
single representation of "no structure".

**A bad key costs the plan, not the routine.** `RoutineTransferCardioSegmentsDTO`
is a transparent wrapper whose decoder absorbs a wrong-shaped value
(`try? CardioSegmentPlan(from:)`). Without it, one hand-edited key would throw
out of the synthesized decoder and the recipient would lose the entire routine.
Contents that are merely *wrong* — an unknown kind, an over-range repeat — are
repaired by the 12B decoder, matching how this format already preserves rather
than rejects unknown enum raws.

**Transfer carries authoring data only.** Tick state is not in the format, and
there is no code path to it: the document is built from the `Routine`, which has
never seen a tick.

### Localization

**No new keys.** The section reuses `Cardio Plan` ("유산소 계획") from 12D, and
the round badge and the four kind names reuse the keys 12C/12D introduced. A
`Planned` key was added and then removed again during pre-merge polish, when the
heading was renamed to match the checklist.

### Deferred to 12F

- **Repeat authoring UI** — the payload, the decoder, the expansion, the
  checklist, History and now transfer all handle `repeatCount`; only the editor
  pins it to 1.
- **Per-segment actuals**, still gated on §9's three criteria. The additive path
  remains `segmentActualsData: Data?` on `SetLog`.
- **Segment-level charts** — nothing to chart until actuals exist.
- **Per-segment timers** (§4.5), in-workout segment editing (§13), and every
  §10 non-goal.
- **Workout History CSV and Exercise CSV**: unchanged, by design (§6). The
  export describes what was performed, and aggregates already cover it.

---

## 15. Open questions for beta feedback

1. Do users want segments on the **routine slot** (programming, reusable) or
   ad-hoc on **the session** (today's plan only)? This design says the slot; the
   session already has `EditSessionPlanSheet` for one-off deviation.
2. Is the four-kind enum right, or is `work` / `recovery` enough in practice?
3. Does the aggregate-pace limitation (§5) actually bother interval users, or is
   it theoretical? This is the deciding input for 12F.
4. Is a checklist without a timer usable mid-run, or does the tick target need to
   be bigger / at the top of the screen?

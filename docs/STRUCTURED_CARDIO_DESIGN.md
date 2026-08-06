# Structured Cardio — Design

**Status:** design complete (Slice 12A). **Slices 12B and 12C shipped** — the
value types exist, a cardio routine slot can carry a segment plan, and the
routing editor authors it. Nothing is shown during a workout, in History, or in
any export yet (see §11 and §12). Companion to `CARDIO_SYSTEM_DESIGN.md`, which covers Phase 1
(Slices 1–11, shipped).

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
| History **detail** | Adds a read-only **Planned** section from the frozen snapshot, labelled as the plan — never presented as what happened |
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
| **12D** | `SessionPlan` carry-through, snapshot at session start, active-workout checklist + tick persistence, switch-adapter rules. Logging path untouched | No | Yes — session/ownership |
| **12E** | History detail "Planned" section; routine transfer payload; compatibility fixtures | No | Yes — transfer/compat |
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

## 13. Open questions for beta feedback

1. Do users want segments on the **routine slot** (programming, reusable) or
   ad-hoc on **the session** (today's plan only)? This design says the slot; the
   session already has `EditSessionPlanSheet` for one-off deviation.
2. Is the four-kind enum right, or is `work` / `recovery` enough in practice?
3. Does the aggregate-pace limitation (§5) actually bother interval users, or is
   it theoretical? This is the deciding input for 12F.
4. Is a checklist without a timer usable mid-run, or does the tick target need to
   be bigger / at the top of the screen?

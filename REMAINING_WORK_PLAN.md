# Remaining Work Plan

Gym Log — Architecture v2

**Purpose:** A focused extract of the still-open / still-relevant work from
`REFACTOR_PLAN.md`, so the next implementation targets can be chosen without
re-reading the full (1,800-line) refactor ledger.

**This document does NOT replace `REFACTOR_PLAN.md`.** That file remains the
authoritative blueprint and full history. This is a derived summary of the
*remaining* work only, generated 2026-05-27.

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

### 2.1 Routine (and variant) name editing
- **Source:** §6 Backlog ("routine name editable"); also implied by Phase 6.B Slice C.
- **Current status:** Not implemented. The Routines tab exposes no rename action.
- **Why it matters:** Highest-leverage next item. It is genuinely user-facing
  (you currently cannot rename a routine after creation), AND it **unblocks** the
  Phase 6.B Slice C live-label verification (see §4) — `RoutineLabelResolver`
  already resolves History/WorkoutDetail labels through live relationship data, so
  a rename will update labels with no persisted-field rewrite, but there is no UI
  to trigger a rename today.
- **Recommendation:** **implement now.**
- **Risk:** **low** (additive UI over an existing `name` field; no schema change;
  label resolution already reads live data).

### 2.2 Multi-select exercise add
- **Source:** §6 Backlog ("multi-select exercise add") — 4 unchecked sub-items.
- **Current status:** Not started. Picker is single-select.
  - [ ] Checkmark-based multi-select in exercise picker
  - [ ] Confirm-add action: selected exercises added in selection order
  - [ ] Name search + optional bodyPart/muscle-group filter
  - [ ] Duplicate-in-same-block: warn or silently allow (duplicates are allowed
        by design elsewhere — match that)
- **Why it matters:** Adding several exercises to a block one-at-a-time is a
  real friction point. Clear UX win.
- **Recommendation:** **implement now** (after 2.1).
- **Risk:** **low–medium** (picker UI work; must respect the existing
  duplicate-`Exercise`/`routineSlotID` slot-identity model when adding several
  at once).

### 2.3 "Used in N routines" summary on Exercise detail
- **Source:** Phase 9-D pending bullet (deferred to Phase 10, never shipped).
- **Current status:** Floated as a replacement for the removed Sets editor on the
  Exercise detail screen; deferred and not built.
- **Why it matters:** Small read-only context cue; the Exercise detail screen lost
  density when the Sets editor was removed in 9-D.
- **Recommendation:** **keep optional** (nice-to-have; build only if the Exercise
  detail screen feels empty).
- **Risk:** **low** (read-only query/count).

---

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

---

## 4. Blocked Items

Blocked by missing UI or another feature.

### 4.1 Live rename → History/WorkoutDetail label verification
- **Source:** Phase 6.B Slice C ("Pending — verification gated on rename UI").
- **Current status:** **Blocked** — the Routines tab exposes no rename action.
- **Why it matters:** `RoutineLabelResolver` (Slice C.1, shipped) resolves labels
  through live relationships, so a rename *should* update History/WorkoutDetail
  labels with no persisted-field rewrite. That behavior is unverified because
  there's no way to trigger a rename. Verification cases: (a) rename routine →
  labels update without relaunch; (b) rename non-Default variant → "Routine —
  Variant" updates; (c) rename variant to "Default" → collapses to routine name;
  (d) rename away from "Default" → expands back.
- **Recommendation:** **blocked** → unblocks immediately once **§2.1 routine/variant
  rename UI** lands.
- **Risk:** **low** (verification only; resolver logic already shipped).

### 4.2 Test: history grouping by RoutineVariant survives name changes
- **Source:** Phase 7 (optional coverage gap).
- **Current status:** **Blocked** on the same rename UI (or a manual SwiftData
  edit harness).
- **Why it matters:** Pins the live-label invariant as an automated regression net.
- **Recommendation:** **blocked** → write alongside 4.1 once rename UI exists.
- **Risk:** **low**.

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

### 5.4 Host-less `LogTests` conversion
- **Source:** Phase 7.5. Status: **attempted and reverted** — clearing
  `TEST_HOST`/`BUNDLE_LOADER` caused ~30 undefined-symbol link errors (iOS app
  targets aren't frameworks). Path forward would require extracting testable code
  into a separate framework / SwiftPM module.
- **Why it matters:** The only loss from staying app-hosted is cosmetic CoreData
  log noise (already documented as expected in CLAUDE.md).
- **Recommendation:** **keep optional / NOT recommended** — out of scope; high
  effort, cosmetic payoff.
- **Risk:** **medium** (structural project restructuring).

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

### 7.4 §5 "equipment/setup is future Phase 10" note
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

1. **Routine (+ variant) name editing UI** (§2.1) — low risk, clearly user-facing,
   and unblocks the §4 rename-verification work. Do this first.
2. **Rename-verification: History/WorkoutDetail live labels + the
   `RoutineVariant`-survives-rename test** (§4.1 + §4.2) — trivial to verify/pin
   once #1 exists; closes a long-standing blocked gap with near-zero added risk.
3. **Multi-select exercise add** (§2.2) — the next clear UX win; independent of
   #1/#2, so it can also run in parallel.

Everything below the top 3 is optional/deferred: the technique design follow-ups
(§3.1) and prescription enrichment (§3.4) need design passes first; the Phase 12
viewmodel hoist (§6.6) is the big structural item but is high-risk and not urgent;
Phase 8 deprecations (§6.1–6.3) should stay deferred absent a concrete safety
reason. Do the TestFlight upgrade (§1) before public App Store promotion.

---

*Generated from `REFACTOR_PLAN.md` on 2026-05-27. For full history, rationale, and
shipped-slice detail, see `REFACTOR_PLAN.md`.*

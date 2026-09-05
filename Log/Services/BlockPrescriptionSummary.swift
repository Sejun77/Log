import Foundation

/// Read-only one-line summary of a `RoutineBlock`'s prescription, intended as a
/// subtitle under each block row in `RoutineEditor` (Slice B). Mirrors
/// `RoutineSummary` / `WorkoutSummary` in shape and discipline.
///
/// Pure value type — no SwiftData fetches, no `ModelContext`, no mutation, and
/// it **never dereferences `RoutineExercise.exercise`** — so it is safe to
/// compute outside the SwiftUI `body` (build a `map(for:)` once per render and
/// look up by `block.slotID`) and unit-testable in isolation.
///
/// Summary rules (v1 — authoring intent, from the structured `SlotPrescription`
/// fields, *not* `resolvedTemplates()`):
///  - **Normal (non-superset) block** — summarizes the lowest-`order` slot's
///    prescription:
///    - sets + rep range → `"3 × 8–12"`; equal/one-sided range → `"3 × 8"`
///    - sets, no reps → `"3 sets"`
///    - `usesDuration` + duration → `"3 × 45s"`; no duration → `"3 sets"`
///    - trailing rest when `restSecondsBetweenSets > 0` → `"… · 90s rest"`
///    - trailing effort target when present (Slice C) → `"… · RIR 2"` (single)
///      or `"… · RIR 2 → 0"` (progression, directional arrow — never a range).
///      The metric (RIR/RPE) is supplied by the caller via `effortMetric`
///      (the app-wide autoreg setting); `nil` (autoreg off) omits the suffix.
///      The value is resolved through `EffortTargetResolver.summary`, so legacy
///      single-value prescriptions (`rir`/`rpe` with nil `effortModeRaw`) render
///      as single effort exactly as before they had a mode.
///    - trailing prepared-alternative count when the slot has any **enabled**
///      alternative (Build 10 C4) → `"… · 2 alternatives"`. Disabled
///      alternatives are excluded: this line is workout-facing
///      discoverability, and a disabled alternative is never offered mid-
///      workout. The authoring row one screen down still counts every
///      prepared alternative, disabled included — a different question.
///    - no prescription / no usable sets → `"Not set"`
///  - **Superset block** — block-level:
///    - `"Superset · N exercises · M sets"` where `N = block.exercises.count`
///      (structural — nil/deleted slots still count) and `M` = the **max**
///      child `prescription.sets` (matching `SupersetDetailNoRest.currentSetsValue`).
///    - `M` omitted when no child carries a positive `sets` → `"Superset · N exercises"`.
///    - a **marker** when at least one member carries an effort target (Build
///      10, audit L7) → `"… · 2 effort targets"`. Deliberately a count, not the
///      values: per-slot targets are ambiguous block-level, and listing four
///      members' ramps would make the row unreadable. Omitting them entirely
///      was worse — a superset member with a full custom per-set ramp looked
///      identical in the routine list to one with no target at all. Absent when
///      no member has one, so a superset without effort is worded exactly as
///      before. Prepared alternatives stay omitted: they are per-slot, and a
///      block-level count would not say which exercise they belong to.
///  - Weight and tempo remain intentionally **out of scope for v1**.
struct BlockPrescriptionSummary: Equatable {
    private enum Content: Equatable {
        case normal(
            sets: Int?,
            repMin: Int?,
            repMax: Int?,
            durationSeconds: Int?,
            usesDuration: Bool,
            targetDistance: String?,
            restSeconds: Int?,
            effort: String?,
            alternatives: Int
        )
        case superset(
            exerciseCount: Int, sets: Int?, effortTargetMembers: Int)
    }

    private let content: Content

    /// Value-in initializer for a **normal** block — exercised by wording tests
    /// without needing a SwiftData model.
    init(
        sets: Int?,
        repMin: Int? = nil,
        repMax: Int? = nil,
        durationSeconds: Int? = nil,
        usesDuration: Bool = false,
        targetDistance: String? = nil,
        restSeconds: Int? = nil,
        effort: String? = nil,
        alternatives: Int = 0
    ) {
        content = .normal(
            sets: sets,
            repMin: repMin,
            repMax: repMax,
            durationSeconds: durationSeconds,
            usesDuration: usesDuration,
            targetDistance: targetDistance,
            restSeconds: restSeconds,
            effort: effort,
            alternatives: alternatives
        )
    }

    /// Value-in initializer for a **superset** block.
    ///
    /// `effortTargetMembers` is how many of its slots carry a usable effort
    /// target in the caller's metric — 0 renders no marker at all.
    init(
        supersetExerciseCount: Int,
        maxSets: Int?,
        effortTargetMembers: Int = 0
    ) {
        content = .superset(
            exerciseCount: supersetExerciseCount, sets: maxSets,
            effortTargetMembers: effortTargetMembers
        )
    }

    /// Build from a live `RoutineBlock`. Reads `block.isSuperset`,
    /// `block.exercises`, and each slot's `prescription` only; never touches
    /// `re.exercise`.
    /// `effortMetric` is the app-wide autoreg metric (RIR/RPE) supplied by the
    /// caller; `nil` (autoreg disabled) omits any effort suffix. Effort is only
    /// summarized for **normal** blocks.
    /// - Parameter displayUnit: the unit a slot's target distance renders in.
    ///   Defaults to kilometers so the value type stays pure and its tests do
    ///   not depend on the tester's preferences; the routine editor passes
    ///   `AppSettings.distanceUnit`.
    init(
        block: RoutineBlock,
        effortMetric: EffortMetric? = nil,
        displayUnit: DistanceUnit = .kilometers
    ) {
        if block.isSuperset {
            let maxSets = block.exercises
                .compactMap { $0.prescription?.sets }
                .max()
            // Counted through the same resolver the normal branch words its
            // effort with, so "has a target" here and "shows a target" on the
            // exercise's own row can never disagree.
            let withEffort = block.exercises.filter {
                Self.effortSummary(for: $0.prescription, metric: effortMetric)
                    != nil
            }.count
            content = .superset(
                exerciseCount: block.exercises.count, sets: maxSets,
                effortTargetMembers: withEffort
            )
        } else {
            let p = block.exercises
                .sorted { $0.order < $1.order }
                .first?
                .prescription
            content = .normal(
                sets: p?.sets,
                repMin: p?.repMin,
                repMax: p?.repMax,
                durationSeconds: p.flatMap {
                    $0.durationMaxSeconds ?? $0.durationMinSeconds
                },
                usesDuration: p?.usesDuration ?? false,
                // Rendered in the caller's preferred unit. The slot's stored
                // `targetDistanceUnitRaw` is deliberately ignored: a target is
                // a plan, not a record, so it reads in whatever unit the user
                // prefers today.
                targetDistance: p?.targetDistance(displayUnit: displayUnit)?
                    .displayText,
                restSeconds: p?.restSecondsBetweenSets,
                effort: Self.effortSummary(for: p, metric: effortMetric),
                // Enabled only — see the summary rules above. Reading this is
                // a decode of the additive `alternativesData` column through
                // the tolerant Phase C accessor, so a corrupt payload counts
                // zero and never breaks the row.
                alternatives: p?.slotAlternatives.filter(\.isEnabled).count ?? 0
            )
        }
    }

    /// Resolve the one-line effort suffix for a slot's prescription, in the
    /// caller's autoreg metric. Returns nil when there's no prescription, no
    /// metric (autoreg off), or no usable effort value (mode `.none` / missing).
    /// Delegates the wording (single vs directional progression) to
    /// `EffortTargetResolver.summary`.
    private static func effortSummary(
        for p: SlotPrescription?, metric: EffortMetric?
    ) -> String? {
        guard let p, let metric else { return nil }
        // Fall back to the opposite metric via `10 - x` when the active
        // metric's field is nil — matching the editor's `doubleStepperRow`
        // display and `SessionPlan.secondarySummary`. Without this, a value
        // stored only under the other metric (a legacy single-metric slot, or
        // `makeDefaultPrescription`'s single-metric seeding before an edit
        // mirrors the pair) would render in the editor but vanish from the
        // block-row summary.
        let convert: (Double) -> Double = { 10 - $0 }
        let single, start, end: Double?
        var custom: [Double]
        switch metric {
        case .rir:
            single = p.rir ?? p.rpe.map(convert)
            start = p.rirStart ?? p.rpeStart.map(convert)
            end = p.rirEnd ?? p.rpeEnd.map(convert)
            custom = p.customRIRTargets
            if custom.isEmpty { custom = p.customRPETargets.map(convert) }
        case .rpe:
            single = p.rpe ?? p.rir.map(convert)
            start = p.rpeStart ?? p.rirStart.map(convert)
            end = p.rpeEnd ?? p.rirEnd.map(convert)
            custom = p.customRPETargets
            if custom.isEmpty { custom = p.customRIRTargets.map(convert) }
        }
        return EffortTargetResolver.summary(
            metric: metric,
            mode: p.effortMode,
            single: single,
            start: start,
            end: end,
            // Fitted to the slot's set count, so the block row states exactly
            // the targets the active workout's rows will show.
            custom: custom,
            setCount: p.sets
        )
    }

    /// Subtitle shown under the block row title.
    var subtitle: String {
        switch content {
        case let .superset(exerciseCount, sets, effortTargetMembers):
            let superset = String(localized: "Superset")
            let exercises = exerciseCount == 1
                ? String(localized: "\(exerciseCount) exercise")
                : String(localized: "\(exerciseCount) exercises")
            var parts = [superset, exercises]
            if let m = sets, m > 0 {
                parts.append(
                    m == 1
                        ? String(localized: "\(m) set")
                        : String(localized: "\(m) sets"))
            }
            // Last, and only when there is one — the marker is scanned for,
            // not read, and a superset with no effort target reads exactly as
            // it did before this slice.
            if effortTargetMembers == 1 {
                parts.append(
                    String(localized: "\(effortTargetMembers) effort target"))
            } else if effortTargetMembers > 1 {
                parts.append(
                    String(localized: "\(effortTargetMembers) effort targets"))
            }
            return parts.joined(separator: " · ")

        case let .normal(
            sets, repMin, repMax, duration, usesDuration, targetDistance, rest,
            effort, alternatives):
            guard let s = sets, s > 0 else { return String(localized: "Not set") }
            let core: String
            if usesDuration {
                if let d = duration, d > 0 {
                    core = "\(s) × \(d)s"
                } else {
                    core = s == 1 ? String(localized: "\(s) set") : String(localized: "\(s) sets")
                }
            } else if let reps = Self.repRange(min: repMin, max: repMax) {
                core = "\(s) × \(reps)"
            } else {
                core = s == 1 ? String(localized: "\(s) set") : String(localized: "\(s) sets")
            }
            var parts = [core]
            // A cardio slot's distance target sits next to the duration it
            // belongs with, before the rest and effort suffixes. Absent, it
            // contributes nothing — no placeholder.
            if let targetDistance { parts.append(targetDistance) }
            if let r = rest, r > 0 { parts.append(String(localized: "\(r)s rest")) }
            if let effort { parts.append(effort) }
            // Last: the plan itself reads first, and this is the one segment a
            // user scans for rather than reads. Reuses the count strings the
            // Exercise Detail usage line already ships (`대체 운동 N개`) rather
            // than inventing a second name for the same thing.
            if alternatives == 1 {
                parts.append(String(localized: "\(alternatives) alternative"))
            } else if alternatives > 1 {
                parts.append(String(localized: "\(alternatives) alternatives"))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Rep range string from optional min/max. Non-positive bounds are treated
    /// as absent so a stray `0` never renders as a rep target.
    ///  - both present, different → `"8–12"`
    ///  - both present, equal / only one bound → `"8"`
    ///  - neither → `nil`
    private static func repRange(min: Int?, max: Int?) -> String? {
        let lo = (min ?? 0) > 0 ? min : nil
        let hi = (max ?? 0) > 0 ? max : nil
        switch (lo, hi) {
        case let (l?, h?): return l == h ? "\(l)" : "\(l)–\(h)"
        case let (l?, nil): return "\(l)"
        case let (nil, h?): return "\(h)"
        case (nil, nil): return nil
        }
    }

    /// Precompute one summary per block, keyed by `block.slotID`, so the
    /// routine editor can build the map once per render and avoid re-scanning
    /// `block.exercises` / prescriptions inside each row's `body`.
    static func map(
        for blocks: [RoutineBlock],
        effortMetric: EffortMetric? = nil,
        displayUnit: DistanceUnit = .kilometers
    ) -> [UUID: BlockPrescriptionSummary] {
        var result: [UUID: BlockPrescriptionSummary] = [:]
        result.reserveCapacity(blocks.count)
        for block in blocks {
            result[block.slotID] = BlockPrescriptionSummary(
                block: block, effortMetric: effortMetric,
                displayUnit: displayUnit
            )
        }
        return result
    }
}

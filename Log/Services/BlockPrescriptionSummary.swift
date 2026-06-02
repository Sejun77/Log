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
///    - no prescription / no usable sets → `"Not set"`
///  - **Superset block** — block-level:
///    - `"Superset · N exercises · M sets"` where `N = block.exercises.count`
///      (structural — nil/deleted slots still count) and `M` = the **max**
///      child `prescription.sets` (matching `SupersetDetailNoRest.currentSetsValue`).
///    - `M` omitted when no child carries a positive `sets` → `"Superset · N exercises"`.
///    - effort is **not** shown for supersets (per-slot targets would be
///      ambiguous block-level); reserved for a future slice.
///  - Weight and tempo remain intentionally **out of scope for v1**.
struct BlockPrescriptionSummary: Equatable {
    private enum Content: Equatable {
        case normal(
            sets: Int?,
            repMin: Int?,
            repMax: Int?,
            durationSeconds: Int?,
            usesDuration: Bool,
            restSeconds: Int?,
            effort: String?
        )
        case superset(exerciseCount: Int, sets: Int?)
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
        restSeconds: Int? = nil,
        effort: String? = nil
    ) {
        content = .normal(
            sets: sets,
            repMin: repMin,
            repMax: repMax,
            durationSeconds: durationSeconds,
            usesDuration: usesDuration,
            restSeconds: restSeconds,
            effort: effort
        )
    }

    /// Value-in initializer for a **superset** block.
    init(supersetExerciseCount: Int, maxSets: Int?) {
        content = .superset(
            exerciseCount: supersetExerciseCount, sets: maxSets
        )
    }

    /// Build from a live `RoutineBlock`. Reads `block.isSuperset`,
    /// `block.exercises`, and each slot's `prescription` only; never touches
    /// `re.exercise`.
    /// `effortMetric` is the app-wide autoreg metric (RIR/RPE) supplied by the
    /// caller; `nil` (autoreg disabled) omits any effort suffix. Effort is only
    /// summarized for **normal** blocks.
    init(block: RoutineBlock, effortMetric: EffortMetric? = nil) {
        if block.isSuperset {
            let maxSets = block.exercises
                .compactMap { $0.prescription?.sets }
                .max()
            content = .superset(
                exerciseCount: block.exercises.count, sets: maxSets
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
                restSeconds: p?.restSecondsBetweenSets,
                effort: Self.effortSummary(for: p, metric: effortMetric)
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
        switch metric {
        case .rir:
            single = p.rir ?? p.rpe.map(convert)
            start = p.rirStart ?? p.rpeStart.map(convert)
            end = p.rirEnd ?? p.rpeEnd.map(convert)
        case .rpe:
            single = p.rpe ?? p.rir.map(convert)
            start = p.rpeStart ?? p.rirStart.map(convert)
            end = p.rpeEnd ?? p.rirEnd.map(convert)
        }
        return EffortTargetResolver.summary(
            metric: metric,
            mode: p.effortMode,
            single: single,
            start: start,
            end: end
        )
    }

    /// Subtitle shown under the block row title.
    var subtitle: String {
        switch content {
        case let .superset(exerciseCount, sets):
            let exercises =
                "\(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s")"
            guard let m = sets, m > 0 else { return "Superset · \(exercises)" }
            return "Superset · \(exercises) · \(m) set\(m == 1 ? "" : "s")"

        case let .normal(sets, repMin, repMax, duration, usesDuration, rest, effort):
            guard let s = sets, s > 0 else { return "Not set" }
            let core: String
            if usesDuration {
                if let d = duration, d > 0 {
                    core = "\(s) × \(d)s"
                } else {
                    core = "\(s) set\(s == 1 ? "" : "s")"
                }
            } else if let reps = Self.repRange(min: repMin, max: repMax) {
                core = "\(s) × \(reps)"
            } else {
                core = "\(s) set\(s == 1 ? "" : "s")"
            }
            var parts = [core]
            if let r = rest, r > 0 { parts.append("\(r)s rest") }
            if let effort { parts.append(effort) }
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
        effortMetric: EffortMetric? = nil
    ) -> [UUID: BlockPrescriptionSummary] {
        var result: [UUID: BlockPrescriptionSummary] = [:]
        result.reserveCapacity(blocks.count)
        for block in blocks {
            result[block.slotID] = BlockPrescriptionSummary(
                block: block, effortMetric: effortMetric
            )
        }
        return result
    }
}

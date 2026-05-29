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
///    - no prescription / no usable sets → `"Not set"`
///  - **Superset block** — block-level:
///    - `"Superset · N exercises · M sets"` where `N = block.exercises.count`
///      (structural — nil/deleted slots still count) and `M` = the **max**
///      child `prescription.sets` (matching `SupersetDetailNoRest.currentSetsValue`).
///    - `M` omitted when no child carries a positive `sets` → `"Superset · N exercises"`.
///  - Weight, RIR/RPE, tempo, and other autoregulation are intentionally **out
///    of scope for v1**.
struct BlockPrescriptionSummary: Equatable {
    private enum Content: Equatable {
        case normal(
            sets: Int?,
            repMin: Int?,
            repMax: Int?,
            durationSeconds: Int?,
            usesDuration: Bool,
            restSeconds: Int?
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
        restSeconds: Int? = nil
    ) {
        content = .normal(
            sets: sets,
            repMin: repMin,
            repMax: repMax,
            durationSeconds: durationSeconds,
            usesDuration: usesDuration,
            restSeconds: restSeconds
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
    init(block: RoutineBlock) {
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
                restSeconds: p?.restSecondsBetweenSets
            )
        }
    }

    /// Subtitle shown under the block row title.
    var subtitle: String {
        switch content {
        case let .superset(exerciseCount, sets):
            let exercises =
                "\(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s")"
            guard let m = sets, m > 0 else { return "Superset · \(exercises)" }
            return "Superset · \(exercises) · \(m) set\(m == 1 ? "" : "s")"

        case let .normal(sets, repMin, repMax, duration, usesDuration, rest):
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
            guard let r = rest, r > 0 else { return core }
            return "\(core) · \(r)s rest"
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
        for blocks: [RoutineBlock]
    ) -> [UUID: BlockPrescriptionSummary] {
        var result: [UUID: BlockPrescriptionSummary] = [:]
        result.reserveCapacity(blocks.count)
        for block in blocks {
            result[block.slotID] = BlockPrescriptionSummary(block: block)
        }
        return result
    }
}

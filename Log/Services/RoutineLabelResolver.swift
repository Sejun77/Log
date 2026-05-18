import Foundation

/// Builds O(1) lookup tables from a live `[Routine]` snapshot and resolves a
/// display label for a `Workout` using the live relationship data first,
/// falling back to the frozen `Workout.routineName` snapshot.
///
/// Priority:
///  1. `workout.routineVariantID` → live `RoutineVariant` (and its owning
///     `Routine`). If the variant is named "Default" (case-insensitive), show
///     the routine name alone; otherwise show "Routine — Variant".
///  2. `workout.routineID` → live `Routine.name`.
///  3. Frozen `workout.routineName` snapshot (when non-empty).
///  4. `nil` — the caller omits the label, matching pre-Slice-C behavior for
///     workouts with no resolvable routine.
///
/// Initialize once per view body and reuse across rows; iterating routines'
/// variants is O(R + V_total) and per-row resolution is O(1) lookup. Pure
/// read — no SwiftData fetches inside `label(for:)`, no mutation.
struct RoutineLabelResolver {
    private let routineByID: [UUID: Routine]
    private let variantByID: [UUID: RoutineVariant]
    private let routineByVariantID: [UUID: Routine]

    init(routines: [Routine]) {
        var byID: [UUID: Routine] = [:]
        var vByID: [UUID: RoutineVariant] = [:]
        var rByVID: [UUID: Routine] = [:]
        byID.reserveCapacity(routines.count)
        for r in routines {
            byID[r.id] = r
            for v in r.variants {
                vByID[v.id] = v
                rByVID[v.id] = r
            }
        }
        self.routineByID = byID
        self.variantByID = vByID
        self.routineByVariantID = rByVID
    }

    func label(for workout: Workout) -> String? {
        if let vid = workout.routineVariantID,
            let variant = variantByID[vid],
            let routine = routineByVariantID[vid]
        {
            if variant.name.caseInsensitiveCompare("Default") == .orderedSame {
                return routine.name
            }
            return "\(routine.name) — \(variant.name)"
        }

        if let rid = workout.routineID,
            let routine = routineByID[rid]
        {
            return routine.name
        }

        if let snapshot = workout.routineName, !snapshot.isEmpty {
            return snapshot
        }

        return nil
    }
}

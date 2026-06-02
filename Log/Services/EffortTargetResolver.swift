import Foundation

/// Which autoregulation metric an effort target is expressed in. Used only for
/// labeling (`"RIR"` / `"RPE"`) — the resolved numeric values are metric-agnostic.
enum EffortMetric: String {
    case rir
    case rpe
}

/// Pure, SwiftData-free resolver for effort targets (Slice A foundation).
///
/// Turns an `EffortMode` plus its value(s) into concrete per-set targets and
/// display strings. No `ModelContext`, no mutation, no SwiftUI — safe to call
/// outside `body` and unit-testable in isolation. UI wiring (editor preview,
/// active-workout set rows) lands in later slices and consumes this helper.
///
/// Rules:
///  - `none` → no targets, no summary.
///  - `single` → the single value repeated across every set.
///  - `progression` → linear interpolation from `start` to `end` across
///    `setCount`, each value rounded to the nearest 0.5. A progression with
///    only one of start/end behaves like `single` of that value. Reverse
///    progressions (start < end) are allowed.
///  - Missing required values → no targets / no summary.
///  - `setCount <= 0` → empty. `setCount == 1` → the start value (if any).
enum EffortTargetResolver {

    /// Resolve concrete per-set target values. Returns an array of length
    /// `setCount` (or empty when there are no usable targets).
    static func resolve(
        mode: EffortMode,
        single: Double?,
        start: Double?,
        end: Double?,
        setCount: Int
    ) -> [Double] {
        guard setCount > 0 else { return [] }

        switch mode {
        case .none:
            return []

        case .single:
            guard let value = single else { return [] }
            return Array(repeating: value, count: setCount)

        case .progression:
            // A progression with only one endpoint behaves like single of it.
            guard let lo = start ?? end, let hi = end ?? start else { return [] }
            guard setCount > 1 else { return [roundToHalf(lo)] }
            let span = Double(setCount - 1)
            return (0..<setCount).map { i in
                let t = Double(i) / span
                return roundToHalf(lo + (hi - lo) * t)
            }
        }
    }

    /// One-line summary for a block row / plan line.
    ///  - single → `"RIR 2"`
    ///  - progression → `"RIR 2 → 0"` (directional arrow, never a range)
    ///  - collapses to single form when the two endpoints render equally.
    static func summary(
        metric: EffortMetric,
        mode: EffortMode,
        single: Double?,
        start: Double?,
        end: Double?
    ) -> String? {
        let label = self.label(for: metric)

        switch mode {
        case .none:
            return nil

        case .single:
            guard let value = single else { return nil }
            return "\(label) \(format(value))"

        case .progression:
            guard let lo = start ?? end, let hi = end ?? start else { return nil }
            let loStr = format(lo)
            let hiStr = format(hi)
            if loStr == hiStr { return "\(label) \(loStr)" }
            return "\(label) \(loStr) → \(hiStr)"
        }
    }

    /// Per-set display strings, e.g. `["RIR 2", "RIR 1", "RIR 0"]`. Empty when
    /// there are no usable targets.
    static func perSetStrings(
        metric: EffortMetric,
        mode: EffortMode,
        single: Double?,
        start: Double?,
        end: Double?,
        setCount: Int
    ) -> [String] {
        let label = self.label(for: metric)
        return resolve(
            mode: mode, single: single, start: start, end: end, setCount: setCount
        ).map { "\(label) \(format($0))" }
    }

    /// Display a target value with no trailing `.0`: `2.0 → "2"`, `1.5 → "1.5"`.
    /// Matches the formatting used in `SessionPlan` / `PrescriptionFields`.
    static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    // MARK: - Private

    /// Round to the nearest 0.5 (e.g. 1.667 → 1.5, 1.25 → 1.5, 1.75 → 2.0).
    private static func roundToHalf(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }

    private static func label(for metric: EffortMetric) -> String {
        switch metric {
        case .rir: return "RIR"
        case .rpe: return "RPE"
        }
    }
}

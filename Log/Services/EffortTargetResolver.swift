import Foundation

/// Which autoregulation metric an effort target is expressed in.
///
/// No longer label-only: the automatic progression generator needs the metric
/// to know which direction "easier" is (RIR counts down, RPE counts up), which
/// is what decides how an interior set rounds. See
/// `EffortTargetResolver.progression`.
enum EffortMetric: String {
    case rir
    case rpe
}

/// Codec + resizing rules for a **custom per-set effort target list**.
///
/// Stored as a comma-separated string (`"2,1.5,1,0"`), matching
/// `TechniquePlan.appliesToSetIndicesRaw` — the app's existing pattern for a
/// small ordered list of numbers on a `@Model`. A `Data?` JSON column (the
/// pattern used by `cardioSegmentsData` / `alternativesData`) buys nothing
/// here: there is no nested structure, no versioning need, and the CSV is
/// legible in a transfer document and in a debugger.
///
/// Tolerant on read, in the same spirit as `SlotAlternatives.decode(from:)`: a
/// nil column, an empty column, and an unparseable column all read as `[]` —
/// one representation of "no custom targets" — so no caller checks three
/// states. A list is rejected **whole** rather than element-wise, because
/// dropping one malformed entry would silently shift every later set's target
/// onto the wrong set, which is worse than showing none.
enum EffortTargetList {

    /// Values outside this range cannot have been authored by the app (the RIR
    /// stepper is 0…5, the RPE stepper 5…10), so a list containing one came
    /// from a hand-edited document and is refused whole.
    private static let validRange: ClosedRange<Double> = 0...10

    /// Decode a stored raw string. `nil` / empty / malformed → `[]`.
    static func decode(_ raw: String?) -> [Double] {
        guard let raw else { return [] }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return [] }
        var values: [Double] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            guard
                let value = Double(
                    part.trimmingCharacters(in: .whitespaces)),
                value.isFinite,
                validRange.contains(value)
            else { return [] }
            values.append(value)
        }
        return values
    }

    /// Encode a list for storage, or `nil` when there is nothing to store.
    ///
    /// An empty list clears the column rather than writing `""`, so "the user
    /// never authored custom targets" and "the user cleared them" persist
    /// identically — the same rule `SlotAlternatives.encode` follows.
    ///
    /// Integral values are written without a decimal part (`2`, not `2.0`) and
    /// everything else via `String(Double)`, which round-trips exactly through
    /// `Double(_:)` — so a `1.5` authored on a half-step stepper survives
    /// storage, transfer and a session freeze **unrounded**.
    static func encode(_ values: [Double]) -> String? {
        let usable = values.filter { $0.isFinite && validRange.contains($0) }
        guard usable.count == values.count, !usable.isEmpty else { return nil }
        return usable
            .map {
                $0.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int($0)) : String($0)
            }
            .joined(separator: ",")
    }

    /// Fit a custom list to a set count.
    ///
    /// - more sets than targets → the **last** target repeats for the new sets
    ///   (Part 2 rule 5: "increasing set count should append reasonable
    ///   values"), so the added sets inherit the hardest authored target rather
    ///   than an invented one,
    /// - fewer sets than targets → the extra targets are truncated,
    /// - earlier targets are never touched.
    ///
    /// Applied on **write** by the editor and again on **read** by the
    /// resolver, so a stored list that got out of step with the set count (a
    /// routine edited by an older build, an imported document, a session frozen
    /// before a set was added) still renders one target per set.
    static func resized(_ values: [Double], to count: Int) -> [Double] {
        guard count > 0, let last = values.last else { return [] }
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: last, count: count - values.count)
    }
}

/// Pure, SwiftData-free resolver for effort targets.
///
/// Turns an `EffortMode` plus its value(s) into concrete per-set targets and
/// display strings. No `ModelContext`, no mutation, no SwiftUI — safe to call
/// outside `body` and unit-testable in isolation.
///
/// Rules:
///  - `none` → no targets, no summary.
///  - `single` → the single value repeated across every set.
///  - `progression` → the human-friendly ramp described on `progression`
///    below: exact endpoints, whole-number interiors, monotonic. A progression
///    with only one of start/end behaves like `single` of that value. Reverse
///    progressions (start < end for RIR) are allowed.
///  - `custom` → the authored per-set list, **verbatim** (half steps included),
///    fitted to the set count by `EffortTargetList.resized`.
///  - Missing required values → no targets / no summary. A `custom` mode whose
///    list is unusable degrades to the progression / single values the
///    prescription still carries rather than to nothing.
///  - `setCount <= 0` → empty. `setCount == 1` → the start value (if any).
enum EffortTargetResolver {

    /// Resolve concrete per-set target values. Returns an array of length
    /// `setCount` (or empty when there are no usable targets).
    ///
    /// - Parameter metric: the metric `single` / `start` / `end` / `custom` are
    ///   expressed in. Decides interior rounding for `progression` only.
    static func resolve(
        metric: EffortMetric,
        mode: EffortMode,
        single: Double?,
        start: Double?,
        end: Double?,
        custom: [Double] = [],
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
            return progressionValues(
                metric: metric, start: start, end: end, setCount: setCount)

        case .custom:
            let fitted = EffortTargetList.resized(custom, to: setCount)
            if !fitted.isEmpty { return fitted }
            // Degrade rather than vanish: a `.custom` slot whose list is
            // missing or corrupt still carries the start/end (or single)
            // values it was seeded from, and showing those beats showing
            // nothing. Mirrors the tolerance every other payload read in the
            // app applies.
            let ramp = progressionValues(
                metric: metric, start: start, end: end, setCount: setCount)
            if !ramp.isEmpty { return ramp }
            guard let single else { return [] }
            return Array(repeating: single, count: setCount)
        }
    }

    /// The automatic progression sequence — the heart of Part 1.
    ///
    /// Rules, in the order they apply:
    ///
    ///  1. **Endpoints are exact.** Set 1 is `start` and the last set is `end`,
    ///     never a rounded approximation — including when the user authored a
    ///     half step.
    ///  2. **Interiors are whole numbers.** Linear interpolation is rounded
    ///     *away from the hard end*: RIR rounds **up** (more reps in reserve =
    ///     easier), RPE rounds **down** (lower exertion = easier). So the app
    ///     never prescribes a harder set earlier than the ramp implies, and
    ///     never manufactures a half step the user did not ask for.
    ///  3. **Interiors stay inside the endpoints.** Clamping to
    ///     `min(start, end)…max(start, end)` is what keeps rule 2 from
    ///     overshooting on a short ramp (RIR 0.5 → 0 would otherwise round its
    ///     interiors *up* to 1, i.e. easier than set 1).
    ///  4. **Monotonic.** Guaranteed by construction: rounding and clamping are
    ///     both monotone, so the sequence never reverses direction. RIR is
    ///     non-increasing and RPE non-decreasing for a normal ramp.
    ///
    /// This replaces the previous "interpolate, round to the nearest 0.5"
    /// behavior, which produced sequences like `2, 1.5, 0.5, 0` (half steps
    /// nobody programmed) and `2, 1.5, 1.5, 0` (a duplicated half step) for the
    /// most common prescription in the app.
    ///
    /// One set collapses to `start`; zero sets is empty.
    static func progression(
        metric: EffortMetric,
        start: Double,
        end: Double,
        setCount: Int
    ) -> [Double] {
        guard setCount > 0 else { return [] }
        guard setCount > 1 else { return [start] }

        let lower = Swift.min(start, end)
        let upper = Swift.max(start, end)
        let span = Double(setCount - 1)

        return (0..<setCount).map { i in
            if i == 0 { return start }
            if i == setCount - 1 { return end }
            let raw = start + (end - start) * (Double(i) / span)
            // Snap first. `2 - 3 * (1/3)` is `2.0000000000000004` in binary
            // floating point, and rounding that up would yield 3 — a target
            // harder than the start, from arithmetic alone.
            let snapped = (raw * 1_000_000).rounded() / 1_000_000
            let rounded: Double
            switch metric {
            case .rir: rounded = snapped.rounded(.up)
            case .rpe: rounded = snapped.rounded(.down)
            }
            return Swift.min(upper, Swift.max(lower, rounded))
        }
    }

    /// One-line summary for a block row / plan line.
    ///  - single → `"RIR 2"`
    ///  - progression → `"RIR 2 → 0"` (directional arrow, never a range)
    ///  - custom → `"RIR 2/1.5/1/0"` (slash-joined, so the segment stays
    ///    distinguishable inside a `" · "`-joined summary line)
    ///  - collapses to single form when the two endpoints render equally.
    ///
    /// - Parameter setCount: when known, clips/extends a custom list to the
    ///   slot's set count so the summary states exactly what the rows will
    ///   show. `nil` summarizes the authored list as stored.
    static func summary(
        metric: EffortMetric,
        mode: EffortMode,
        single: Double?,
        start: Double?,
        end: Double?,
        custom: [Double] = [],
        setCount: Int? = nil
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

        case .custom:
            let values = setCount.map { EffortTargetList.resized(custom, to: $0) }
                ?? custom
            guard !values.isEmpty else {
                // Same degradation as `resolve`: fall back to whatever the
                // prescription still carries rather than summarizing nothing.
                return summary(
                    metric: metric,
                    mode: (start ?? end) != nil ? .progression : .single,
                    single: single, start: start, end: end)
            }
            let joined = values.map(format).joined(separator: "/")
            return "\(label) \(joined)"
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
        custom: [Double] = [],
        setCount: Int
    ) -> [String] {
        let label = self.label(for: metric)
        return resolve(
            metric: metric, mode: mode, single: single, start: start, end: end,
            custom: custom, setCount: setCount
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

    /// `progression` over optional endpoints: a ramp with only one endpoint
    /// behaves like `single` of that value, and neither endpoint is empty.
    private static func progressionValues(
        metric: EffortMetric, start: Double?, end: Double?, setCount: Int
    ) -> [Double] {
        guard let lo = start ?? end, let hi = end ?? start else { return [] }
        return progression(
            metric: metric, start: lo, end: hi, setCount: setCount)
    }

    private static func label(for metric: EffortMetric) -> String {
        switch metric {
        case .rir: return "RIR"
        case .rpe: return "RPE"
        }
    }
}

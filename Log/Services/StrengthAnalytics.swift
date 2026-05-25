import Foundation

// MARK: - StrengthAnalytics

/// Pure calculation layer for the AP Calculus AB workout-analytics showcase.
///
/// Everything here is value-typed and side-effect-free: no `ModelContext`,
/// no `@Query`, no `@Model`, no persistence. It takes plain series of
/// `(date, value)` samples and returns derived calculus quantities, mirroring
/// the established pure-helper pattern in this repo (`ExerciseSorter`,
/// `groupItemsBySourceBlock`). Safe to call from a SwiftUI `body` and from
/// unit tests with no `SwiftDataTestHarness`.
///
/// The Slice-2 extractor (not in this slice) is responsible for turning
/// `[Workout]` rows into the `SeriesPoint` / `VolumePoint` inputs used here;
/// this file deliberately knows nothing about the SwiftData models.
///
/// ## Time axis
/// All rates use a **day** axis derived from real `Date` distance
/// (`timeIntervalSince / 86_400`), because workout dates are non-uniformly
/// spaced. Per-week values (the units shown on camera) are the per-day value
/// scaled by 7; per-week² second-derivative values scale by 49.
enum StrengthAnalytics {

    // MARK: - Value Types

    /// A single strength reading (e.g. max e1RM for one session).
    struct SeriesPoint: Equatable {
        var date: Date
        var value: Double

        init(date: Date, value: Double) {
            self.date = date
            self.value = value
        }
    }

    /// One session's training volume, with a running accumulation slot that
    /// `accumulatedVolume(_:)` fills in (left at 0 by the plain initializer).
    struct VolumePoint: Equatable {
        var date: Date
        var volume: Double
        var accumulatedVolume: Double

        init(date: Date, volume: Double, accumulatedVolume: Double = 0) {
            self.date = date
            self.volume = volume
            self.accumulatedVolume = accumulatedVolume
        }
    }

    /// A finite-difference slope estimate at one sample's date.
    struct DerivativePoint: Equatable {
        var date: Date
        var slopePerDay: Double
        var slopePerWeek: Double
    }

    /// Qualitative read on the second derivative — does progress speed up,
    /// slow down, or hold steady?
    enum Concavity: String, Equatable {
        case accelerating
        case slowing
        case roughlyConstant

        /// Short human-readable label for an analytics card.
        var label: String {
            switch self {
            case .accelerating:   return "Gains accelerating"
            case .slowing:        return "Gains slowing"
            case .roughlyConstant: return "Steady progress"
            }
        }
    }

    /// Rolled-up analysis for one exercise's strength series plus its volume
    /// series. Optionals are `nil` when there aren't enough distinct points
    /// to define the quantity (empty / single-point series).
    struct AnalysisSummary: Equatable {
        var pointCount: Int
        var firstValue: Double?
        var latestValue: Double?
        var totalChange: Double?
        var averageRatePerWeek: Double?
        var recentDerivativePerWeek: Double?
        var secondDerivativePerWeekSquared: Double?
        var concavity: Concavity
        var isPlateau: Bool
        var totalAccumulatedVolume: Double
    }

    // MARK: - Constants

    static let daysPerWeek = 7.0
    static let secondsPerDay = 86_400.0

    /// Upper bound of the Epley model's valid domain. Above ~12 reps the
    /// linear `1 + reps/30` term overstates a true one-rep max, so reps beyond
    /// this cap are excluded from e1RM (but **not** from volume — see
    /// `sessionVolume(_:)`).
    static let e1RMRepCap = 12

    /// Default plateau band: |recent slope| ≤ 0.5 strength units / week reads
    /// as "flat". Caller-overridable.
    static let defaultPlateauThresholdPerWeek = 0.5

    /// Default dead-band around zero second derivative for concavity
    /// classification, in strength units / week². Caller-overridable.
    static let defaultConcavityTolerancePerWeekSquared = 0.01

    // MARK: - e1RM (Epley)

    /// Epley estimated one-rep max: `e1RM = weight · (1 + reps / 30)`.
    ///
    /// Valid domain: `weight > 0`, `0 < reps ≤ e1RMRepCap`. Returns `nil`
    /// outside it (non-positive load/reps, or a rep count past the model's
    /// validity cap), so callers can `compactMap` away unusable sets.
    static func e1RM(weight: Double, reps: Int) -> Double? {
        guard weight > 0, reps > 0, reps <= e1RMRepCap else { return nil }
        return weight * (1 + Double(reps) / 30.0)
    }

    /// Best (maximum) valid e1RM across one session's sets. Sets outside the
    /// valid domain are ignored; returns `nil` when none qualify.
    static func bestE1RM(sets: [(weight: Double, reps: Int)]) -> Double? {
        sets.compactMap { e1RM(weight: $0.weight, reps: $0.reps) }.max()
    }

    // MARK: - Time / Normalization

    /// Signed day distance `a → b` (`b` later ⇒ positive).
    static func days(from a: Date, to b: Date) -> Double {
        b.timeIntervalSince(a) / secondsPerDay
    }

    /// Sort ascending by date and coalesce exact-duplicate dates to their
    /// **max** value (one strength reading per moment — the best set of the
    /// session). This guarantees strictly increasing dates, so every
    /// finite-difference denominator below is non-zero. Empty in ⇒ empty out.
    static func normalized(_ points: [SeriesPoint]) -> [SeriesPoint] {
        guard !points.isEmpty else { return [] }
        var bestByDate: [Date: Double] = [:]
        for p in points {
            if let existing = bestByDate[p.date] {
                bestByDate[p.date] = max(existing, p.value)
            } else {
                bestByDate[p.date] = p.value
            }
        }
        return bestByDate
            .map { SeriesPoint(date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Average Rate of Change (secant slope)

    /// Average rate of change over the whole series: `(last − first) / Δt`
    /// in strength units per **day**. `nil` for fewer than two distinct dates
    /// (Δt ≤ 0 is rejected, so same-date input is safe).
    static func averageRateOfChangePerDay(_ points: [SeriesPoint]) -> Double? {
        let pts = normalized(points)
        guard let first = pts.first, let last = pts.last else { return nil }
        let dt = days(from: first.date, to: last.date)
        guard dt > 0 else { return nil }
        return (last.value - first.value) / dt
    }

    /// `averageRateOfChangePerDay` scaled to strength units per **week**.
    static func averageRateOfChangePerWeek(_ points: [SeriesPoint]) -> Double? {
        averageRateOfChangePerDay(points).map { $0 * daysPerWeek }
    }

    // MARK: - First Derivative (finite differences)

    /// Finite-difference estimate of `S′(t)` at every sample.
    ///
    /// - First point: forward difference.
    /// - Last point: backward difference.
    /// - Interior points: central difference
    ///   `(Sᵢ₊₁ − Sᵢ₋₁) / (tᵢ₊₁ − tᵢ₋₁)`.
    ///
    /// Returns `[]` for fewer than two distinct points (no slope is defined).
    static func firstDerivative(_ points: [SeriesPoint]) -> [DerivativePoint] {
        let pts = normalized(points)
        guard pts.count >= 2 else { return [] }

        return pts.indices.map { i in
            let perDay: Double
            if i == 0 {
                perDay = slopePerDay(pts[0], pts[1])              // forward
            } else if i == pts.count - 1 {
                perDay = slopePerDay(pts[i - 1], pts[i])          // backward
            } else {
                perDay = slopePerDay(pts[i - 1], pts[i + 1])      // central
            }
            return DerivativePoint(
                date: pts[i].date,
                slopePerDay: perDay,
                slopePerWeek: perDay * daysPerWeek
            )
        }
    }

    /// Slope between two samples in units/day. `normalized(_:)` guarantees a
    /// non-zero denominator in practice; the guard keeps the helper total.
    private static func slopePerDay(_ a: SeriesPoint, _ b: SeriesPoint) -> Double {
        let dt = days(from: a.date, to: b.date)
        guard dt != 0 else { return 0 }
        return (b.value - a.value) / dt
    }

    /// The most recent slope estimate (backward difference at the final
    /// sample), in units/week. `nil` when no derivative is defined.
    static func recentDerivativePerWeek(_ points: [SeriesPoint]) -> Double? {
        firstDerivative(points).last?.slopePerWeek
    }

    // MARK: - Second Derivative (rate of change of the slope)

    /// Estimate of `S″(t)` as the average rate of change of the first
    /// derivative across the series, in units/day². This "derivative of the
    /// derivative" form is robust to the non-uniform date spacing of real
    /// workout data. `nil` when fewer than two derivative samples exist.
    static func secondDerivativePerDaySquared(_ points: [SeriesPoint]) -> Double? {
        let derivs = firstDerivative(points)
        guard derivs.count >= 2,
              let first = derivs.first,
              let last = derivs.last
        else { return nil }
        let dt = days(from: first.date, to: last.date)
        guard dt > 0 else { return nil }
        return (last.slopePerDay - first.slopePerDay) / dt
    }

    /// `secondDerivativePerDaySquared` scaled to units per **week²**.
    static func secondDerivativePerWeekSquared(_ points: [SeriesPoint]) -> Double? {
        secondDerivativePerDaySquared(points).map { $0 * daysPerWeek * daysPerWeek }
    }

    /// Classify progress from the sign of `S″`, within a configurable
    /// dead-band: `> tolerance` ⇒ accelerating, `< −tolerance` ⇒ slowing,
    /// otherwise roughly constant. Undefined `S″` (too few points) reads as
    /// roughly constant.
    static func concavity(
        _ points: [SeriesPoint],
        tolerancePerWeekSquared: Double = defaultConcavityTolerancePerWeekSquared
    ) -> Concavity {
        guard let s2 = secondDerivativePerWeekSquared(points) else {
            return .roughlyConstant
        }
        if s2 > tolerancePerWeekSquared { return .accelerating }
        if s2 < -tolerancePerWeekSquared { return .slowing }
        return .roughlyConstant
    }

    // MARK: - Plateau Detection

    /// `true` when the most recent slope sits within `±thresholdPerWeek` of
    /// zero, i.e. `S′(t) ≈ 0`. `false` when no recent slope is defined.
    static func isPlateau(
        _ points: [SeriesPoint],
        thresholdPerWeek: Double = defaultPlateauThresholdPerWeek
    ) -> Bool {
        guard let recent = recentDerivativePerWeek(points) else { return false }
        return abs(recent) <= thresholdPerWeek
    }

    // MARK: - Volume

    /// One session's training volume `Σ(weight × reps)` over its sets. Only
    /// sets with `weight > 0` and `reps > 0` contribute. **No rep cap** is
    /// applied here (unlike e1RM): a high-rep working set is legitimate
    /// volume even though it's a poor one-rep-max predictor.
    static func sessionVolume(_ sets: [(weight: Double, reps: Int)]) -> Double {
        sets.reduce(0.0) { acc, set in
            guard set.weight > 0, set.reps > 0 else { return acc }
            return acc + set.weight * Double(set.reps)
        }
    }

    /// Riemann-sum-style accumulation: sort sessions by date and emit each
    /// with the running total of volume up to and including it. Negative
    /// volumes are floored at 0 so the accumulation is monotonic. Duplicate
    /// dates are **not** coalesced — every session contributes one term to
    /// the sum.
    static func accumulatedVolume(_ sessions: [VolumePoint]) -> [VolumePoint] {
        let sorted = sessions.sorted { $0.date < $1.date }
        var running = 0.0
        return sorted.map { p in
            running += max(0, p.volume)
            return VolumePoint(
                date: p.date,
                volume: p.volume,
                accumulatedVolume: running
            )
        }
    }

    // MARK: - Roll-up

    /// Combine the per-quantity calculations into one summary for a card UI.
    /// Pure: callers pass already-extracted series.
    static func analyze(
        strength: [SeriesPoint],
        volume: [VolumePoint] = [],
        plateauThresholdPerWeek: Double = defaultPlateauThresholdPerWeek,
        concavityTolerancePerWeekSquared: Double = defaultConcavityTolerancePerWeekSquared
    ) -> AnalysisSummary {
        let pts = normalized(strength)
        let accumulated = accumulatedVolume(volume)
        let totalChange: Double? = {
            guard let first = pts.first, let last = pts.last else { return nil }
            return last.value - first.value
        }()

        return AnalysisSummary(
            pointCount: pts.count,
            firstValue: pts.first?.value,
            latestValue: pts.last?.value,
            totalChange: totalChange,
            averageRatePerWeek: averageRateOfChangePerWeek(strength),
            recentDerivativePerWeek: recentDerivativePerWeek(strength),
            secondDerivativePerWeekSquared: secondDerivativePerWeekSquared(strength),
            concavity: concavity(
                strength,
                tolerancePerWeekSquared: concavityTolerancePerWeekSquared
            ),
            isPlateau: isPlateau(strength, thresholdPerWeek: plateauThresholdPerWeek),
            totalAccumulatedVolume: accumulated.last?.accumulatedVolume ?? 0
        )
    }
}

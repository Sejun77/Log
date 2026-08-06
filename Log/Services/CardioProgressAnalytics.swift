import Foundation

// ======================================================
// MARK: - Cardio progress aggregation
// ======================================================

/// Pure aggregation behind the History **cardio** charts (Slice 11).
///
/// Read-only over `WorkoutItem` / `SetLog`: no `ModelContext`, no `@Query`, no
/// mutation — the same shape as `WorkoutHistoryAnalytics`, so it is testable on
/// `SwiftDataTestHarness` and safe to call from `computePoints()`.
///
/// ## What it does not do
/// Nothing here knows about e1RM, volume, reps, or weight. Cardio and strength
/// aggregation stay in separate files on purpose: the two never share a series,
/// and a cardio bout must never reach a volume chart (nor a bench press a pace
/// chart). The only thing they share is the one-point-per-session shape.
///
/// ## Which sets count
/// **Every** set logged for the exercise in that session, warm-up included —
/// matching what the existing `.totalDuration` metric has always done. A cardio
/// warm-up is distance you actually covered, so excluding it would make the
/// distance chart disagree with the History row the user is looking at.
///
/// Sets that carry nothing usable simply contribute nothing: a strength set
/// sitting inside a cardio exercise has no distance and no duration, so it adds
/// 0 to both. That is the mechanism by which strength rows stay out of cardio
/// charts — no filtering by `kind` is needed.
enum CardioProgressAnalytics {

    // MARK: - Session totals

    /// One session's cardio totals for one exercise.
    ///
    /// Distance and duration are plain sums (absent ⇒ 0, never nil, because
    /// "nothing recorded" and "zero" mean the same thing for a sum). Calories
    /// and heart rate stay optional: `nil` means *not recorded*, which is the
    /// distinction that keeps a blank field out of an average instead of
    /// dragging it toward zero.
    struct SessionTotals: Equatable {
        var distanceMeters: Double = 0
        var durationSeconds: Int = 0
        var calories: Int?
        var avgHeartRate: Double?

        var hasDistance: Bool { distanceMeters > 0 }
        var hasDuration: Bool { durationSeconds > 0 }

        // MARK: Chart values

        /// Distance in the caller's display unit. `nil` when none was recorded,
        /// so the session drops out of the distance chart rather than plotting
        /// a zero.
        func distanceValue(in unit: DistanceUnit) -> Double? {
            guard hasDistance else { return nil }
            return unit.value(fromMeters: distanceMeters)
        }

        /// **Weighted** pace: total duration ÷ total distance, in seconds per
        /// unit. Not the mean of the per-set paces — averaging rates weights a
        /// 400 m stride the same as a 10 km run and reports a pace the athlete
        /// never ran.
        ///
        /// `nil` unless both totals are positive, so a distance-only or
        /// duration-only session is absent from the pace chart instead of
        /// plotting a fabricated value.
        func paceSecondsPerUnit(in unit: DistanceUnit) -> Double? {
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: hasDistance ? distanceMeters : nil,
                durationSeconds: hasDuration ? durationSeconds : nil,
                unit: unit)
        }

        /// Speed over the same totals, in units per hour. Same nil rules as
        /// pace — they are two readings of one quantity.
        func speedUnitsPerHour(in unit: DistanceUnit) -> Double? {
            CardioDerived.speedUnitsPerHour(
                distanceMeters: hasDistance ? distanceMeters : nil,
                durationSeconds: hasDuration ? durationSeconds : nil,
                unit: unit)
        }

        /// Total duration in seconds, or `nil` when nothing was timed.
        var durationValue: Double? {
            hasDuration ? Double(durationSeconds) : nil
        }

        var caloriesValue: Double? { calories.map(Double.init) }

        var avgHeartRateValue: Double? { avgHeartRate }
    }

    // MARK: - Extraction

    /// Totals across every set of every matching item in one session.
    static func totals(forItems items: [WorkoutItem]) -> SessionTotals {
        totals(for: items.flatMap(\.setLogs))
    }

    /// Totals across a flat list of performed sets.
    ///
    /// Reads the cardio columns through `SetLog.cardioMetrics`, never directly,
    /// so a row holding a negative distance or a 900 bpm heart rate contributes
    /// nothing instead of poisoning the series.
    static func totals(for logs: [SetLog]) -> SessionTotals {
        var distanceMeters = 0.0
        var durationSeconds = 0
        var calories: Int?

        // Heart rate is accumulated as (Σ hr·weight, Σ weight) so the weighted
        // and unweighted forms share one pass; `weightedSamples` records whether
        // any timed sample was seen, which decides between them.
        var weightedHeartRateSum = 0.0
        var heartRateWeight = 0.0
        var plainHeartRateSum = 0.0
        var plainHeartRateCount = 0

        for log in logs {
            let metrics = log.cardioMetrics
            let seconds = log.durationSeconds ?? 0

            if let meters = metrics.distanceMeters {
                distanceMeters += meters
            }
            if seconds > 0 {
                durationSeconds += seconds
            }
            if let kcal = metrics.calories {
                calories = (calories ?? 0) + kcal
            }
            if let bpm = metrics.avgHeartRate {
                plainHeartRateSum += Double(bpm)
                plainHeartRateCount += 1
                if seconds > 0 {
                    weightedHeartRateSum += Double(bpm) * Double(seconds)
                    heartRateWeight += Double(seconds)
                }
            }
        }

        // Duration-weighted when any heart-rate sample carries a duration — a
        // 40-minute steady bout should outweigh a 2-minute cool-down. Untimed
        // samples cannot be weighted, so in the mixed case they sit out rather
        // than entering at weight 0 and skewing the result. With no timed
        // samples at all, a plain mean is the only honest answer.
        let averageHeartRate: Double? = {
            if heartRateWeight > 0 {
                return weightedHeartRateSum / heartRateWeight
            }
            guard plainHeartRateCount > 0 else { return nil }
            return plainHeartRateSum / Double(plainHeartRateCount)
        }()

        return SessionTotals(
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            calories: calories,
            avgHeartRate: averageHeartRate
        )
    }
}

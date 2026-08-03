import Foundation

// ======================================================
// MARK: - SetLog ↔ CardioMetrics
// ======================================================

extension SetLog {

    /// The stored cardio columns as a validated value type.
    ///
    /// This is the **only** intended read path for the cardio fields. Every
    /// value passes through `CardioMetrics`' normalizing initializer and the
    /// tolerant `DistanceUnit.from(raw:)` / `HRZone.from(raw:)` lookups, so a
    /// row holding a negative distance, a 900 bpm heart rate, an unparseable
    /// `"kilometres"`, or a `hrZoneRaw` of `"z9"` yields nil for that field
    /// rather than reaching a formatter or a chart. Reading the columns
    /// directly bypasses all of that and should be limited to persistence
    /// tests.
    ///
    /// Returns an empty `CardioMetrics` (every field nil) for strength and
    /// timed-hold sets, which is what keeps their rendering unchanged.
    var cardioMetrics: CardioMetrics {
        CardioMetrics(
            distanceMeters: distanceMeters,
            distanceUnit: DistanceUnit.from(raw: distanceUnitRaw),
            avgHeartRate: avgHeartRate,
            calories: calories,
            inclinePercent: inclinePercent,
            resistanceLevel: resistanceLevel,
            hrZone: HRZone.from(raw: hrZoneRaw)
        )
    }

    /// Write site for the cardio columns.
    ///
    /// Writing through a normalized `CardioMetrics` rather than assigning the
    /// columns one by one means an invalid value is rejected *before* it is
    /// persisted, not merely hidden at read time — the store never accumulates
    /// rows that only look clean through `cardioMetrics`. The Slice 4 entry UI
    /// is expected to be the first real caller.
    ///
    /// Assigning an empty `CardioMetrics` clears every column, so this is also
    /// how a set is reverted to a plain timed hold.
    func applyCardioMetrics(_ metrics: CardioMetrics) {
        distanceMeters = metrics.distanceMeters
        // `CardioMetrics` already drops a unit that has no distance, so the two
        // columns can never disagree about whether a distance was recorded.
        distanceUnitRaw = metrics.distanceUnit?.rawValue
        avgHeartRate = metrics.avgHeartRate
        calories = metrics.calories
        inclinePercent = metrics.inclinePercent
        resistanceLevel = metrics.resistanceLevel
        hrZoneRaw = metrics.hrZone?.rawValue
    }

    /// True when this set carries at least one cardio metric. Distinct from
    /// "is a cardio exercise" (that is `Exercise.trackingMode`) — a cardio bout
    /// logged with only a duration has no metrics and reports false here, which
    /// is exactly what keeps it rendering as a plain duration row.
    var hasCardioMetrics: Bool { !cardioMetrics.isEmpty }
}

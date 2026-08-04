import Foundation

// ======================================================
// MARK: - Cardio target distance
// ======================================================

/// A cardio slot's **target** distance, validated.
///
/// The counterpart of `CardioMetrics` on the programming side: where
/// `CardioMetrics` describes what was *performed*, this describes what was
/// *planned*. The two are deliberately separate types on separate models — a
/// 5 km target logged as 4.2 km must stay visibly different from a 4.2 km
/// target, and nothing about logging a set should be able to rewrite the
/// routine that prescribed it.
///
/// Like `CardioMetrics` it is the **only** intended read path for the stored
/// columns: every value passes back through `CardioMetrics`' distance
/// normalizer and the tolerant `DistanceUnit.from(raw:)` lookup, so a row
/// holding a negative distance, an absurd one, or a `targetDistanceUnitRaw` of
/// `"kilometres"` degrades to nil-or-fallback rather than reaching a formatter.
/// Reading the columns directly should be limited to persistence tests.
///
/// Pace and speed are absent for the same reason they are absent from
/// `CardioMetrics`: both are distance ÷ duration and are derived at render
/// time. A *target* pace would additionally be a third value that could
/// disagree with the other two.
struct CardioTargetDistance: Equatable {

    /// Canonical storage. Always finite, positive, and within
    /// `CardioLimits.maxDistanceMeters` — the initializer refuses anything else.
    let meters: Double

    /// The unit the target was authored in, so it reads back the way it was
    /// written even if the user later changes the global preference.
    let unit: DistanceUnit

    /// The stored columns as a validated value, or nil when there is no usable
    /// target.
    ///
    /// - Parameter fallbackUnit: used when `unitRaw` is missing or unparseable.
    ///   The distance is still shown rather than dropped: it is stored
    ///   canonically in meters, so the number is correct in whichever unit it
    ///   renders. Passed in rather than read from `AppSettings` so the type
    ///   stays pure and its tests do not depend on the tester's preferences.
    init?(meters: Double?, unitRaw: String?, fallbackUnit: DistanceUnit) {
        guard let meters = CardioMetrics.normalizedDistanceMeters(meters)
        else { return nil }
        self.meters = meters
        self.unit = DistanceUnit.from(raw: unitRaw) ?? fallbackUnit
    }

    /// Build from user-entered text, for the routine editor's field.
    ///
    /// Empty, non-numeric, negative, zero and out-of-range input all yield nil
    /// — "no target", which is the correct reading of a field the user cleared
    /// or fumbled. Nothing here can throw or produce a sentinel.
    init?(text: String, unit: DistanceUnit) {
        guard let meters = CardioMetrics.parseDistance(text, unit: unit)
        else { return nil }
        self.meters = meters
        self.unit = unit
    }

    /// The target expressed in its own unit — the number to show in an entry
    /// field or a summary.
    var value: Double? { unit.value(fromMeters: meters) }

    /// The number alone, formatted as the app formats every distance
    /// ("5", "6.2", "6.25"). Nil only if the conversion somehow fails.
    var valueText: String? {
        value.flatMap { CardioDerived.formatDistance(value: $0) }
    }

    /// The full display string, "5 km" / "3.1 mi". Unit symbols are untranslated,
    /// matching how `kg` / `lb` / `s` are already rendered in every language.
    var displayText: String? {
        valueText.map { "\($0) \(unit.symbol)" }
    }

    /// The two columns to persist. Written as a pair so they can never disagree
    /// about whether a target was set — the mirror of
    /// `SetLog.applyCardioMetrics`.
    var storage: (meters: Double?, unitRaw: String?) {
        (meters, unit.rawValue)
    }

    /// The storage pair for "no target". Assigning this is how a target is
    /// cleared, and it clears *both* columns rather than orphaning a unit.
    static let cleared: (meters: Double?, unitRaw: String?) = (nil, nil)
}

// MARK: - Model accessors

extension SlotPrescription {

    /// The slot's validated target distance, or nil when none is set.
    ///
    /// - Parameter fallbackUnit: the unit used when the stored raw unit is
    ///   missing or unparseable. Callers pass `AppSettings.distanceUnit`.
    func targetDistance(fallbackUnit: DistanceUnit) -> CardioTargetDistance? {
        CardioTargetDistance(
            meters: targetDistanceMeters,
            unitRaw: targetDistanceUnitRaw,
            fallbackUnit: fallbackUnit)
    }

    /// Write site for the target-distance columns. Passing nil clears both.
    ///
    /// Writing through the validated type rather than assigning the columns one
    /// by one means an invalid value is rejected *before* it is persisted, so
    /// the store never accumulates rows that only look clean at read time.
    func applyTargetDistance(_ target: CardioTargetDistance?) {
        let storage = target?.storage ?? CardioTargetDistance.cleared
        targetDistanceMeters = storage.meters
        targetDistanceUnitRaw = storage.unitRaw
    }
}

extension PlannedPrescriptionSnapshot {

    /// The frozen target distance this workout was started with.
    func targetDistance(fallbackUnit: DistanceUnit) -> CardioTargetDistance? {
        CardioTargetDistance(
            meters: targetDistanceMeters,
            unitRaw: targetDistanceUnitRaw,
            fallbackUnit: fallbackUnit)
    }
}

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
/// distance: every value passes back through `CardioMetrics`' distance
/// normalizer, so a row holding a negative distance or an absurd one degrades
/// to nil rather than reaching a formatter. Reading the columns directly should
/// be limited to persistence tests.
///
/// **Unit policy (Slice 8 patch): a target has no unit of its own.** Distance
/// is stored canonically in meters and rendered in whatever
/// `AppSettings.distanceUnit` says today, so a target authored in miles reads
/// in km the moment the user prefers km — the number converts, the meters do
/// not move. `targetDistanceUnitRaw` is still written (and still read by
/// transfer/import) for backward compatibility, but it is no longer a
/// user-facing override: nothing on the display path consults it. This is the
/// deliberate difference from `CardioMetrics`, where a *performed* bout keeps
/// the unit it was run in because it is a record of something that happened.
///
/// Pace and speed are absent for the same reason they are absent from
/// `CardioMetrics`: both are distance ÷ duration and are derived at render
/// time. A *target* pace would additionally be a third value that could
/// disagree with the other two.
struct CardioTargetDistance: Equatable {

    /// Canonical storage. Always finite, positive, and within
    /// `CardioLimits.maxDistanceMeters` — the initializer refuses anything else.
    let meters: Double

    /// The unit this target is displayed and edited in — always the caller's
    /// current preference, never a per-target choice.
    let unit: DistanceUnit

    /// The stored distance as a validated value, or nil when there is no usable
    /// target.
    ///
    /// - Parameter displayUnit: the unit to render in. Callers pass
    ///   `AppSettings.distanceUnit`; it is a parameter rather than a direct
    ///   read so the type stays pure and its tests do not depend on the
    ///   tester's preferences. The stored `targetDistanceUnitRaw` is
    ///   deliberately not consulted.
    init?(meters: Double?, displayUnit: DistanceUnit) {
        guard let meters = CardioMetrics.normalizedDistanceMeters(meters)
        else { return nil }
        self.meters = meters
        self.unit = displayUnit
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
    ///
    /// `unitRaw` still carries a value so existing rows, routine transfer and
    /// import keep a well-formed pair, but it records the unit the target was
    /// *entered* in rather than a preference the reader must honour — the read
    /// path ignores it entirely.
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
    /// - Parameter displayUnit: the unit to render in. Callers pass
    ///   `AppSettings.distanceUnit`; `targetDistanceUnitRaw` is not consulted.
    func targetDistance(displayUnit: DistanceUnit) -> CardioTargetDistance? {
        CardioTargetDistance(
            meters: targetDistanceMeters, displayUnit: displayUnit)
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

    /// The frozen target distance this workout was started with. The *meters*
    /// are frozen; the unit it renders in still follows the preference.
    func targetDistance(displayUnit: DistanceUnit) -> CardioTargetDistance? {
        CardioTargetDistance(
            meters: targetDistanceMeters, displayUnit: displayUnit)
    }
}

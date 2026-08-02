import Foundation

// ======================================================
// MARK: - Distance unit
// ======================================================

/// Entry / display unit for a cardio distance.
///
/// Storage is always canonical **meters** (`CardioMetrics.distanceMeters`); this
/// type only converts at the entry and display boundaries. That is deliberately
/// different from how weight works (`AppSettings.weightIsKg` is a global display
/// flag, so history logged in lb and read in kg is silently reinterpreted).
/// Distance has no bodyweight-style anchor to sanity-check it, and a weekly
/// distance total aggregated over mixed km/mi rows would be quietly wrong, so
/// the ambiguity is removed at the storage layer instead.
///
/// The raw values are the display symbols, so a persisted `distanceUnitRaw`
/// column is human-readable in a CSV export.
enum DistanceUnit: String, CaseIterable, Codable, Equatable {
    case kilometers = "km"
    case miles = "mi"

    /// Untranslated unit symbol, matching the app's existing convention of
    /// rendering bare unit letters (`kg` / `lb` / `s`) in every language.
    var symbol: String { rawValue }

    /// Exact conversion factor. The mile is defined as exactly 1609.344 m.
    var metersPerUnit: Double {
        switch self {
        case .kilometers: return 1_000
        case .miles: return 1_609.344
        }
    }

    /// Convert a user-entered value in this unit to canonical meters.
    /// Non-finite or negative input returns nil rather than propagating garbage.
    func meters(from value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        let meters = value * metersPerUnit
        guard meters.isFinite else { return nil }
        return meters
    }

    /// Convert canonical meters to a display value in this unit.
    /// Non-finite or negative input returns nil.
    func value(fromMeters meters: Double) -> Double? {
        guard meters.isFinite, meters >= 0 else { return nil }
        let value = meters / metersPerUnit
        guard value.isFinite else { return nil }
        return value
    }

    /// Tolerant lookup for a persisted / imported raw string. Trimmed and
    /// case-insensitive so `" KM "` still resolves; unknown input returns nil
    /// rather than silently defaulting to a unit the user did not choose.
    static func from(raw: String?) -> DistanceUnit? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return DistanceUnit.allCases.first { $0.rawValue == key }
    }
}

// ======================================================
// MARK: - Heart-rate zone
// ======================================================

/// Coarse heart-rate zone, as printed on gym equipment and in training plans.
///
/// A closed enum rather than free text so zones can be grouped and charted
/// later. Independent of `CardioMetrics.avgHeartRate`: some equipment shows a
/// zone, some shows a number, some shows both.
///
/// Labels here are intentionally **not localized**. Nothing renders them yet —
/// this slice is model-only — and `Z1`…`Z5` reads the same in every language the
/// app ships. The UI slice that first displays a zone adds a localized display
/// name at that point, alongside its own string-catalog entries.
enum HRZone: String, CaseIterable, Codable, Equatable, Comparable {
    case z1, z2, z3, z4, z5

    /// 1-based zone number, for ordering and for building a display string.
    var number: Int {
        switch self {
        case .z1: return 1
        case .z2: return 2
        case .z3: return 3
        case .z4: return 4
        case .z5: return 5
        }
    }

    /// Compact, language-neutral label ("Z3").
    var shortLabel: String { "Z\(number)" }

    /// Tolerant lookup for a persisted / imported raw string.
    static func from(raw: String?) -> HRZone? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return HRZone.allCases.first { $0.rawValue == key }
    }

    static func < (lhs: HRZone, rhs: HRZone) -> Bool {
        lhs.number < rhs.number
    }
}

// ======================================================
// MARK: - Cardio metric bounds
// ======================================================

/// Plausibility bounds for the manually entered cardio metrics.
///
/// **Out-of-range input resolves to `nil` (rejected), it is not clamped.** This
/// is a deliberate difference from `DurationLimits`, which clamps: a duration
/// arrives from a *bounded picker* or from imported/legacy data, so clamping
/// repairs a value that is known to be well-intentioned. Cardio metrics are
/// typed free-hand into numeric fields and have no legacy rows at all, so an
/// out-of-range entry is a typo. Clamping "1500 bpm" to "300 bpm" would store a
/// fabricated vital sign that looks entirely legitimate in a chart; rejecting it
/// leaves the field visibly empty so the user retypes it.
enum CardioLimits {

    /// 1000 km. Comfortably past any single logged bout while still catching a
    /// misplaced decimal or a value typed in the wrong unit.
    static let maxDistanceMeters: Double = 1_000_000

    /// Physiologically plausible average heart rate, in bpm.
    static let minHeartRate: Int = 20
    static let maxHeartRate: Int = 300

    static let maxCalories: Int = 100_000

    /// Treadmill / stepper grade, in percent.
    static let maxInclinePercent: Double = 100

    /// Machine resistance setting. Unitless — equipment numbers its own levels.
    static let maxResistanceLevel: Double = 100
}

// ======================================================
// MARK: - Cardio metrics
// ======================================================

/// The optional, manually entered metrics describing one cardio bout.
///
/// Duration is **not** part of this type: it already lives on the performed log
/// (`SetLog.durationSeconds`) and is the one required cardio value. Everything
/// here is optional, and a bout carrying nothing but a duration is a complete,
/// valid cardio set — that is what keeps existing beta cardio logs rendering
/// exactly as they do today.
///
/// Pace and speed are **derived**, never stored: both are distance ÷ duration,
/// and a stored pace that disagreed with the stored distance and duration would
/// be unresolvable.
///
/// Every value is normalized on the way in, so an instance can never hold a
/// negative, non-finite, or out-of-range metric.
struct CardioMetrics: Equatable, Codable {

    /// Canonical distance in meters. Always > 0 when non-nil.
    private(set) var distanceMeters: Double?

    /// The unit the distance was entered in, preserved so History reads back the
    /// way the user typed it rather than shifting when the preference changes.
    private(set) var distanceUnit: DistanceUnit?

    private(set) var avgHeartRate: Int?
    private(set) var calories: Int?

    /// Grade in percent. Unlike the other metrics, **0 is kept**: a treadmill
    /// set explicitly recorded as flat is meaningful, and distinct from "not
    /// recorded".
    private(set) var inclinePercent: Double?

    private(set) var resistanceLevel: Double?
    private(set) var hrZone: HRZone?

    /// Normalizing initializer — the only way to populate the type. Each value
    /// passes through its field's rule, so invalid input lands as nil.
    init(
        distanceMeters: Double? = nil,
        distanceUnit: DistanceUnit? = nil,
        avgHeartRate: Int? = nil,
        calories: Int? = nil,
        inclinePercent: Double? = nil,
        resistanceLevel: Double? = nil,
        hrZone: HRZone? = nil
    ) {
        self.distanceMeters = Self.normalizedDistanceMeters(distanceMeters)
        // A unit without a distance carries no information; drop it so the two
        // fields can never disagree about whether a distance was recorded.
        self.distanceUnit = self.distanceMeters == nil ? nil : distanceUnit
        self.avgHeartRate = Self.normalizedHeartRate(avgHeartRate)
        self.calories = Self.normalizedCalories(calories)
        self.inclinePercent = Self.normalizedInclinePercent(inclinePercent)
        self.resistanceLevel = Self.normalizedResistanceLevel(resistanceLevel)
        self.hrZone = hrZone
    }

    /// True when nothing was recorded. The History path uses this to keep
    /// rendering a duration-only cardio set exactly as it does today.
    var isEmpty: Bool {
        distanceMeters == nil && avgHeartRate == nil && calories == nil
            && inclinePercent == nil && resistanceLevel == nil && hrZone == nil
    }

    // MARK: Field normalization

    /// Distance: finite, strictly positive, at or under the bound. A zero
    /// distance is "not recorded", matching the app's existing convention that
    /// 0 means unset for optional numeric fields.
    static func normalizedDistanceMeters(_ meters: Double?) -> Double? {
        guard let meters, meters.isFinite, meters > 0,
            meters <= CardioLimits.maxDistanceMeters
        else { return nil }
        return meters
    }

    /// Heart rate: inside the plausible bpm window, or nothing.
    static func normalizedHeartRate(_ bpm: Int?) -> Int? {
        guard let bpm, bpm >= CardioLimits.minHeartRate,
            bpm <= CardioLimits.maxHeartRate
        else { return nil }
        return bpm
    }

    static func normalizedCalories(_ kcal: Int?) -> Int? {
        guard let kcal, kcal > 0, kcal <= CardioLimits.maxCalories else {
            return nil
        }
        return kcal
    }

    /// Incline: finite, in `0...max`. Zero is preserved (see `inclinePercent`).
    ///
    /// Decline (a negative grade) is not accepted in this phase; treadmills that
    /// support it are rare enough that recording it in notes is acceptable for
    /// now. Tracked as an open question in `docs/CARDIO_SYSTEM_DESIGN.md`.
    static func normalizedInclinePercent(_ percent: Double?) -> Double? {
        guard let percent, percent.isFinite, percent >= 0,
            percent <= CardioLimits.maxInclinePercent
        else { return nil }
        return percent
    }

    static func normalizedResistanceLevel(_ level: Double?) -> Double? {
        guard let level, level.isFinite, level > 0,
            level <= CardioLimits.maxResistanceLevel
        else { return nil }
        return level
    }

    // MARK: Free-text entry

    /// Parse a distance typed in `unit` into canonical meters.
    /// Empty / whitespace-only / non-numeric / out-of-range input yields nil.
    static func parseDistance(_ text: String, unit: DistanceUnit) -> Double? {
        guard let value = parseDouble(text) else { return nil }
        return normalizedDistanceMeters(unit.meters(from: value))
    }

    static func parseHeartRate(_ text: String) -> Int? {
        normalizedHeartRate(parseInt(text))
    }

    static func parseCalories(_ text: String) -> Int? {
        normalizedCalories(parseInt(text))
    }

    static func parseInclinePercent(_ text: String) -> Double? {
        normalizedInclinePercent(parseDouble(text))
    }

    static func parseResistanceLevel(_ text: String) -> Double? {
        normalizedResistanceLevel(parseDouble(text))
    }

    /// Shared numeric parsing for the free-text helpers above. `Double(_:)`
    /// accepts "inf" / "nan", so the finiteness check is not redundant.
    private static func parseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite
        else { return nil }
        return value
    }

    private static func parseInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    // MARK: Display

    /// The stored distance expressed in `unit`, for display or for seeding an
    /// entry field.
    func distanceValue(in unit: DistanceUnit) -> Double? {
        guard let distanceMeters else { return nil }
        return unit.value(fromMeters: distanceMeters)
    }
}

// ======================================================
// MARK: - Derived pace & speed
// ======================================================

/// Pace and speed, computed from a distance and a duration.
///
/// Every entry point returns `nil` rather than a sentinel when the inputs cannot
/// produce a meaningful answer — missing distance, missing or non-positive
/// duration, non-finite input, or a result that would not be finite. No
/// division is performed until both operands are known positive and finite, so
/// NaN and infinity are never produced, let alone exposed.
enum CardioDerived {

    /// Pace in **seconds per unit** (seconds per km, or seconds per mile).
    static func paceSecondsPerUnit(
        distanceMeters: Double?, durationSeconds: Int?, unit: DistanceUnit
    ) -> Double? {
        guard let distance = CardioMetrics.normalizedDistanceMeters(distanceMeters),
            let seconds = positiveDuration(durationSeconds),
            let units = unit.value(fromMeters: distance), units > 0
        else { return nil }
        let pace = seconds / units
        guard pace.isFinite else { return nil }
        return pace
    }

    /// Speed in **units per hour** (km/h, or mph).
    static func speedUnitsPerHour(
        distanceMeters: Double?, durationSeconds: Int?, unit: DistanceUnit
    ) -> Double? {
        guard let distance = CardioMetrics.normalizedDistanceMeters(distanceMeters),
            let seconds = positiveDuration(durationSeconds),
            let units = unit.value(fromMeters: distance)
        else { return nil }
        let speed = units / (seconds / 3_600)
        guard speed.isFinite else { return nil }
        return speed
    }

    /// A duration is only usable for a rate when it is present and positive.
    private static func positiveDuration(_ seconds: Int?) -> Double? {
        guard let seconds, seconds > 0 else { return nil }
        return Double(seconds)
    }

    // MARK: Formatting

    /// Pace as `M:SS` ("4:50"). Minutes are not rolled into hours — a pace
    /// slower than an hour per unit is already an outlier, and "75:00" stays
    /// unambiguous where "1:15:00" would read as a duration.
    static func formatPace(secondsPerUnit: Double) -> String? {
        guard secondsPerUnit.isFinite, secondsPerUnit > 0 else { return nil }
        let total = Int(secondsPerUnit.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Speed to one decimal ("12.4"). Uses `String(format:)` without a locale,
    /// so the separator is always "." — matching `AppSettings.formatWeight`.
    static func formatSpeed(unitsPerHour: Double) -> String? {
        guard unitsPerHour.isFinite, unitsPerHour >= 0 else { return nil }
        return String(format: "%.1f", unitsPerHour)
    }

    /// Distance value with up to two decimals, trailing zeros trimmed
    /// ("5", "6.2", "6.25"). Mirrors `AppSettings.formatWeight` so distance and
    /// weight read consistently.
    static func formatDistance(value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        var s = String(format: "%.2f", value)  // C-locale "." separator
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

extension CardioMetrics {
    /// Pace for this bout, in seconds per `unit`.
    func paceSecondsPerUnit(durationSeconds: Int?, in unit: DistanceUnit)
        -> Double?
    {
        CardioDerived.paceSecondsPerUnit(
            distanceMeters: distanceMeters, durationSeconds: durationSeconds,
            unit: unit)
    }

    /// Speed for this bout, in `unit` per hour.
    func speedUnitsPerHour(durationSeconds: Int?, in unit: DistanceUnit)
        -> Double?
    {
        CardioDerived.speedUnitsPerHour(
            distanceMeters: distanceMeters, durationSeconds: durationSeconds,
            unit: unit)
    }
}

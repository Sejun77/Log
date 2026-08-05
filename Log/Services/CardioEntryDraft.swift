import Foundation

// ======================================================
// MARK: - Cardio entry draft
// ======================================================

/// The raw, in-progress text of the active-workout cardio Details fields.
///
/// Deliberately a plain value type holding **strings**, not a `CardioMetrics`:
/// a user mid-typing has "6." in the distance field and "-" in the incline
/// field, neither of which is a valid metric, and neither of which should be
/// destroyed by round-tripping through a normalizing type on every keystroke.
/// Normalization happens once, at `metrics`, when the set is logged.
///
/// Pure and view-free so the entire entry contract — what a field accepts, what
/// it rejects, what reaches the store — is testable without a SwiftUI host.
struct CardioEntryDraft: Equatable {

    /// The unit `distance` is entered and displayed in — always
    /// `AppSettings.distanceUnit`, supplied by the caller.
    ///
    /// It is stored on the draft rather than read from `AppSettings` here so
    /// the type stays pure and its tests do not depend on the tester's
    /// preferences, but it is **not a per-set choice**: the Details row shows
    /// the symbol as a label, there is no picker, and every construction site
    /// passes the preference. Distance is stored canonically in meters, so this
    /// decides how a number is read and written, never what it means.
    var unit: DistanceUnit

    var distance: String = ""
    var avgHeartRate: String = ""
    var calories: String = ""
    var incline: String = ""
    var resistance: String = ""
    var hrZone: HRZone?

    init(
        unit: DistanceUnit,
        distance: String = "",
        avgHeartRate: String = "",
        calories: String = "",
        incline: String = "",
        resistance: String = "",
        hrZone: HRZone? = nil
    ) {
        self.unit = unit
        self.distance = distance
        self.avgHeartRate = avgHeartRate
        self.calories = calories
        self.incline = incline
        self.resistance = resistance
        self.hrZone = hrZone
    }

    /// True when the user has typed nothing. Note this is about the *text*, not
    /// about validity — "abc" is not empty even though it normalizes to nil.
    /// The distinction matters for the row's collapsed state, which should stay
    /// open-looking once someone has started entering something.
    var isEmpty: Bool {
        distance.isEmpty && avgHeartRate.isEmpty && calories.isEmpty
            && incline.isEmpty && resistance.isEmpty && hrZone == nil
    }

    // MARK: - Normalization

    /// The draft resolved to storable metrics.
    ///
    /// Every field goes through its `CardioMetrics.parse*` rule, so empty,
    /// partial, non-numeric, and out-of-range input all land as nil — the
    /// field is simply not recorded. Nothing here can throw or produce a
    /// sentinel, so logging a set never fails because of a typo in an optional
    /// field.
    ///
    /// `CardioMetrics` drops `unit` when the distance is nil, so a set logged
    /// with no distance never persists a stray `distanceUnitRaw`.
    var metrics: CardioMetrics {
        CardioMetrics(
            distanceMeters: CardioMetrics.parseDistance(distance, unit: unit),
            distanceUnit: unit,
            avgHeartRate: CardioMetrics.parseHeartRate(avgHeartRate),
            calories: CardioMetrics.parseCalories(calories),
            inclinePercent: CardioMetrics.parseInclinePercent(incline),
            resistanceLevel: CardioMetrics.parseResistanceLevel(resistance),
            hrZone: hrZone
        )
    }

    /// Compact one-line summary of what has been entered, for the collapsed
    /// disclosure label — "5.2 km · 142 bpm · 410 kcal". Nil when nothing valid
    /// has been entered, so the label shows just "Details".
    ///
    /// Capped at three segments by `CardioHistorySummary.collapsedSummary`.
    /// Showing every recorded metric here overflowed the label and ellipsized
    /// it, which is strictly worse than showing fewer things legibly: the
    /// expanded section is one tap away and shows everything.
    var summaryText: String? {
        CardioHistorySummary.collapsedSummary(metrics, fallbackUnit: unit)
    }

    // MARK: - Derived preview

    /// Live pace for the entered distance and the row's current duration, as
    /// "7:15 /km". Nil whenever it cannot be derived — no distance, no
    /// duration, a zero duration, or unparseable input — so the preview row
    /// disappears rather than showing a placeholder.
    func paceText(durationSeconds: Int?) -> String? {
        guard
            let pace = metrics.paceSecondsPerUnit(
                durationSeconds: durationSeconds, in: unit),
            let formatted = CardioDerived.formatPace(secondsPerUnit: pace)
        else { return nil }
        return "\(formatted) /\(unit.symbol)"
    }

    /// Live speed, as "8.3 km/h". Same nil-rather-than-placeholder contract as
    /// `paceText`.
    func speedText(durationSeconds: Int?) -> String? {
        guard
            let speed = metrics.speedUnitsPerHour(
                durationSeconds: durationSeconds, in: unit),
            let formatted = CardioDerived.formatSpeed(unitsPerHour: speed)
        else { return nil }
        return "\(formatted) \(unit.symbol)/h"
    }

    // MARK: - Field sanitizers

    /// Keystroke filters, mirroring how the duration field already restricts
    /// itself to digits. These stop nonsense from being *typed* — they are not
    /// the validation boundary. `metrics` is, and it re-checks everything.

    /// Digits and a single decimal separator. Used by Distance and Resistance,
    /// neither of which can be negative.
    static func sanitizeDecimal(_ text: String) -> String {
        var seenDot = false
        return String(
            text.filter { ch in
                if ch.isNumber { return true }
                if ch == ".", !seenDot {
                    seenDot = true
                    return true
                }
                return false
            })
    }

    /// Digits only. Used by Average Heart Rate and Calories, both integers.
    static func sanitizeInteger(_ text: String) -> String {
        String(text.filter(\.isNumber))
    }

    /// Digits, one decimal separator, and a **leading** minus — treadmills that
    /// support decline are the reason `CardioLimits.minInclinePercent` is −30,
    /// and a field that could not accept "-3" would make that unreachable. A
    /// minus anywhere but the front is dropped, so "3-" cannot be typed.
    static func sanitizeSignedDecimal(_ text: String) -> String {
        let isNegative = text.hasPrefix("-")
        let magnitude = sanitizeDecimal(text)
        return isNegative ? "-" + magnitude : magnitude
    }
}

// ======================================================
// MARK: - Draft persistence bridge
// ======================================================

extension CardioEntryDraft {

    /// Rebuild a draft from a persisted `ParentDraftStore` snapshot, for cold
    /// resume after Save & Exit or a force-quit. Returns nil when the snapshot
    /// holds no cardio fields at all — which is every strength draft, every
    /// timed-hold draft, and every draft written before Slice 4.
    ///
    /// The snapshot's own `distanceUnit` is **not** read back: the field it
    /// restores is labelled with the current preference, so restoring a
    /// different unit would put a number on screen that meant something other
    /// than its label. The persisted value is still written (see
    /// `ParentDraftStore.persist`) so an older build resuming a newer draft
    /// finds what it expects.
    init?(snapshot: ParentDraftStore.Snapshot, displayUnit: DistanceUnit) {
        guard snapshot.hasCardio else { return nil }
        self.init(
            unit: displayUnit,
            distance: snapshot.distance ?? "",
            avgHeartRate: snapshot.avgHeartRate ?? "",
            calories: snapshot.calories ?? "",
            incline: snapshot.incline ?? "",
            resistance: snapshot.resistance ?? "",
            hrZone: HRZone.from(raw: snapshot.hrZone)
        )
    }

    /// Seed a draft from an already-logged `SetLog`, so a logged cardio set
    /// still shows what was recorded when the session is resumed. Values are
    /// rendered back through the same formatters the entry fields use, so the
    /// text round-trips.
    ///
    /// Rendered in `displayUnit`, not the log's own `distanceUnitRaw`: the row
    /// is a live entry surface whose label follows the preference, and the
    /// stored value is canonical meters, so converting is exact. (History rows
    /// are a different surface and keep the logged unit — see
    /// `CardioHistorySummary`.)
    init(logged: SetLog, displayUnit: DistanceUnit) {
        let metrics = logged.cardioMetrics
        let unit = displayUnit
        let distance =
            metrics.distanceValue(in: unit)
            .flatMap { CardioDerived.formatDistance(value: $0) } ?? ""
        self.init(
            unit: unit,
            distance: distance,
            avgHeartRate: metrics.avgHeartRate.map(String.init) ?? "",
            calories: metrics.calories.map(String.init) ?? "",
            incline: metrics.inclinePercent
                .flatMap { CardioEntryDraft.formatSigned($0) } ?? "",
            resistance: metrics.resistanceLevel
                .flatMap { CardioDerived.formatDistance(value: $0) } ?? "",
            hrZone: metrics.hrZone
        )
    }

    /// `CardioDerived.formatDistance` rejects negatives; incline can be one.
    private static func formatSigned(_ value: Double) -> String? {
        guard let magnitude = CardioDerived.formatDistance(value: abs(value))
        else { return nil }
        return value < 0 ? "-\(magnitude)" : magnitude
    }
}

extension ParentDraftStore {

    /// Persists every cardio field of a draft in one pass. Empty fields are
    /// written as empty strings rather than skipped, so clearing a field
    /// survives a resume instead of being backfilled from an older value.
    func persist(slotID: UUID, setIndex: Int, cardio draft: CardioEntryDraft) {
        persist(
            slotID: slotID, setIndex: setIndex,
            values: [
                .distance: draft.distance,
                .distanceUnit: draft.unit.rawValue,
                .avgHeartRate: draft.avgHeartRate,
                .calories: draft.calories,
                .incline: draft.incline,
                .resistance: draft.resistance,
                .hrZone: draft.hrZone?.rawValue ?? "",
            ])
    }
}

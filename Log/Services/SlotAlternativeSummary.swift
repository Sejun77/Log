import Foundation

// ======================================================
// MARK: - Alternative row summary (Phase D)
// ======================================================

/// One-line summaries for the routine editor's alternative rows.
///
/// Pure value type — no SwiftData, no `ModelContext`, no SwiftUI — so the
/// wording is unit-testable without a store, matching
/// `BlockPrescriptionSummary` / `RoutineSummary` / `WorkoutSummary`.
///
/// The prescription half is **delegated** to `BlockPrescriptionSummary`'s
/// value-in initializer rather than re-derived, so an alternative's
/// "3 × 8–12 · 90s rest · RIR 2" is composed by exactly the code that writes a
/// block row's subtitle. Inventing a fourth summary format here is the thing
/// §6.2 explicitly warns against.
///
/// On top of that, presence flags for the three things an alternative carries
/// that a reset source cannot — warm-ups, techniques, a structured cardio plan.
/// Flags only: no counts, no detail. Their labels are the **existing** editor
/// row titles (`Warmup` / `Techniques` / `Structured Cardio`) rather than the
/// design sketch's "warm-ups / techniques / Cardio Plan", so the summary names
/// these three tools exactly as the rows one screen up name them.
enum SlotAlternativeSummary {

    /// The subtitle under an alternative's name in the editor list.
    ///
    /// - Parameters:
    ///   - effortMetric: the app-wide autoreg metric; `nil` (autoreg off) omits
    ///     the effort segment, matching every other summary in the app.
    ///   - displayUnit: the unit a target distance renders in. Defaults to
    ///     kilometers so this stays pure and its tests do not depend on the
    ///     tester's preferences; the editor passes `AppSettings.distanceUnit`.
    static func subtitle(
        for alternative: SlotAlternative,
        effortMetric: EffortMetric? = nil,
        displayUnit: DistanceUnit = .kilometers
    ) -> String {
        subtitle(
            for: alternative.prescription, effortMetric: effortMetric,
            displayUnit: displayUnit)
    }

    static func subtitle(
        for p: AlternativePrescriptionPayload,
        effortMetric: EffortMetric? = nil,
        displayUnit: DistanceUnit = .kilometers
    ) -> String {
        let core = BlockPrescriptionSummary(
            sets: p.sets,
            repMin: p.repMin,
            repMax: p.repMax,
            durationSeconds: p.durationMaxSeconds ?? p.durationMinSeconds,
            usesDuration: p.usesDuration,
            targetDistance: CardioTargetDistance(
                meters: p.targetDistanceMeters, displayUnit: displayUnit)?
                .displayText,
            restSeconds: p.restSecondsBetweenSets,
            effort: effortSummary(for: p, metric: effortMetric)
        ).subtitle

        return ([core] + presenceFlags(for: p)).joined(separator: " · ")
    }

    /// Which of the three carried-plan tools this alternative has, in the order
    /// the prescription editor lists them.
    static func presenceFlags(
        for p: AlternativePrescriptionPayload
    ) -> [String] {
        var flags: [String] = []
        if !p.warmupSteps.isEmpty { flags.append(String(localized: "Warmup")) }
        if !p.techniques.isEmpty {
            flags.append(String(localized: "Techniques"))
        }
        if let plan = p.cardioSegments, !plan.isEmpty {
            flags.append(String(localized: "Structured Cardio"))
        }
        return flags
    }

    /// Detail value for the `Alternative Exercises` navigation row: the count,
    /// or `None` — the wording every sibling row (Warmup, Techniques,
    /// Structured Cardio) already uses for "nothing here yet".
    static func countLabel(_ count: Int) -> String {
        count > 0 ? "\(count)" : String(localized: "None")
    }

    // MARK: - Effort

    /// The one-line effort suffix, in the caller's autoreg metric.
    ///
    /// Mirrors `BlockPrescriptionSummary.effortSummary(for:metric:)`, including
    /// its `10 - x` fallback to the opposite metric, so an alternative seeded
    /// under one metric still shows a target when the app is set to the other.
    /// Re-implemented over the payload rather than shared, because that helper
    /// is private to a `SlotPrescription` and this type has no model.
    private static func effortSummary(
        for p: AlternativePrescriptionPayload, metric: EffortMetric?
    ) -> String? {
        guard let metric else { return nil }
        let convert: (Double) -> Double = { 10 - $0 }
        let single, start, end: Double?
        switch metric {
        case .rir:
            single = p.rir ?? p.rpe.map(convert)
            start = p.rirStart ?? p.rpeStart.map(convert)
            end = p.rirEnd ?? p.rpeEnd.map(convert)
        case .rpe:
            single = p.rpe ?? p.rir.map(convert)
            start = p.rpeStart ?? p.rirStart.map(convert)
            end = p.rpeEnd ?? p.rirEnd.map(convert)
        }
        return EffortTargetResolver.summary(
            metric: metric, mode: effortMode(for: p),
            single: single, start: start, end: end)
    }

    /// Derived effort mode, by the same rule `SlotPrescription.effortMode`
    /// uses: an explicit, valid raw wins; otherwise a stored single value means
    /// `.single` and nothing means `.none`. Keeps a payload authored before an
    /// explicit mode was set rendering exactly like the slot it came from.
    static func effortMode(for p: AlternativePrescriptionPayload) -> EffortMode {
        if let raw = p.effortModeRaw, let mode = EffortMode(rawValue: raw) {
            return mode
        }
        return (p.rir != nil || p.rpe != nil) ? .single : .none
    }
}

import Foundation

/// Pure, value-based resolver that turns an immutable session snapshot's effort
/// fields into per-working-set display labels for active-workout rows
/// (Slice E2).
///
/// **Snapshot-only:** it operates on plain value inputs (`Fields`, or a
/// `PrescriptionSnapshotPayload`) — it never reads or mutates a live `Routine`
/// / `SlotPrescription` / `ModelContext`, so a routine edit during a workout
/// can't change what a running session shows. Interpolation, rounding, and
/// `2`-not-`2.0` formatting are delegated to `EffortTargetResolver`; the
/// paired-metric `10 - x` fallback mirrors `BlockPrescriptionSummary` and the
/// editor so a value stored under the opposite metric still displays.
enum WorkoutEffortTargetResolver {

    /// The effort fields copied out of a `PrescriptionSnapshotPayload` /
    /// `PlannedPrescriptionSnapshot`. A standalone value type so the resolver is
    /// unit-testable without SwiftData.
    struct Fields: Equatable {
        var effortModeRaw: String?
        var rir: Double?
        var rpe: Double?
        var rirStart: Double?
        var rirEnd: Double?
        var rpeStart: Double?
        var rpeEnd: Double?

        init(
            effortModeRaw: String? = nil,
            rir: Double? = nil,
            rpe: Double? = nil,
            rirStart: Double? = nil,
            rirEnd: Double? = nil,
            rpeStart: Double? = nil,
            rpeEnd: Double? = nil
        ) {
            self.effortModeRaw = effortModeRaw
            self.rir = rir
            self.rpe = rpe
            self.rirStart = rirStart
            self.rirEnd = rirEnd
            self.rpeStart = rpeStart
            self.rpeEnd = rpeEnd
        }
    }

    /// Per-working-set labels (`["RIR 2", "RIR 1", "RIR 0"]`) in the app's
    /// autoreg metric. Returns `[]` when autoreg is `.none`, the effort mode is
    /// `.none`, there's no usable value, or `workingSetCount <= 0`. The result
    /// length is `workingSetCount` when targets exist; callers index it by
    /// working-set ordinal (warmup/dropset rows get no label).
    static func perSetLabels(
        fields: Fields,
        autoregMode: AutoregMode,
        workingSetCount: Int
    ) -> [String] {
        guard let metric = metric(for: autoregMode) else { return [] }

        // Fall back to the opposite metric via `10 - x` when the active
        // metric's field is nil — matching the editor / block-summary display.
        let convert: (Double) -> Double = { 10 - $0 }
        let single, start, end: Double?
        switch metric {
        case .rir:
            single = fields.rir ?? fields.rpe.map(convert)
            start = fields.rirStart ?? fields.rpeStart.map(convert)
            end = fields.rirEnd ?? fields.rpeEnd.map(convert)
        case .rpe:
            single = fields.rpe ?? fields.rir.map(convert)
            start = fields.rpeStart ?? fields.rirStart.map(convert)
            end = fields.rpeEnd ?? fields.rirEnd.map(convert)
        }

        return EffortTargetResolver.perSetStrings(
            metric: metric,
            mode: derivedMode(fields),
            single: single,
            start: start,
            end: end,
            setCount: workingSetCount
        )
    }

    /// Convenience over a session snapshot payload.
    static func perSetLabels(
        payload: PrescriptionSnapshotPayload,
        autoregMode: AutoregMode,
        workingSetCount: Int
    ) -> [String] {
        perSetLabels(
            fields: Fields(payload: payload),
            autoregMode: autoregMode,
            workingSetCount: workingSetCount
        )
    }

    // MARK: - Private

    /// Derive the effort mode purely from value fields — mirrors
    /// `SlotPrescription.effortMode`: an explicit, valid `effortModeRaw` wins;
    /// otherwise any single value present (`rir`/`rpe`) ⇒ `.single`, else
    /// `.none`. (The live accessor can't be used here — we only have values.)
    private static func derivedMode(_ f: Fields) -> EffortMode {
        if let raw = f.effortModeRaw, let mode = EffortMode(rawValue: raw) {
            return mode
        }
        return (f.rir != nil || f.rpe != nil) ? .single : .none
    }

    private static func metric(for mode: AutoregMode) -> EffortMetric? {
        switch mode {
        case .rir: return .rir
        case .rpe: return .rpe
        case .none: return nil
        }
    }
}

extension WorkoutEffortTargetResolver.Fields {
    /// Extract the effort fields from a session snapshot payload (snapshot-only;
    /// no live template read).
    init(payload: PrescriptionSnapshotPayload) {
        self.init(
            effortModeRaw: payload.effortModeRaw,
            rir: payload.rir,
            rpe: payload.rpe,
            rirStart: payload.rirStart,
            rirEnd: payload.rirEnd,
            rpeStart: payload.rpeStart,
            rpeEnd: payload.rpeEnd
        )
    }
}

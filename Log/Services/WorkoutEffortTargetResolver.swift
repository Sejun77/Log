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
        let label = metric == .rir ? "RIR" : "RPE"
        return perSetValues(
            fields: fields,
            autoregMode: autoregMode,
            workingSetCount: workingSetCount
        ).map { "\(label) \(EffortTargetResolver.format($0))" }
    }

    /// Per-working-set numeric targets (e.g. `[2, 1, 0]`) in the app's autoreg
    /// metric — the unlabeled basis for `perSetLabels` and the routine editor's
    /// "Set targets:" progression preview. Returns `[]` when autoreg is `.none`,
    /// the mode is `.none`, there's no usable value, or `workingSetCount <= 0`.
    /// Applies the same opposite-metric `10 - x` fallback as the labels.
    static func perSetValues(
        fields: Fields,
        autoregMode: AutoregMode,
        workingSetCount: Int
    ) -> [Double] {
        guard let metric = metric(for: autoregMode) else { return [] }
        let t = resolvedTriple(fields, metric: metric)
        return EffortTargetResolver.resolve(
            mode: derivedMode(fields),
            single: t.single,
            start: t.start,
            end: t.end,
            setCount: workingSetCount
        )
    }

    /// One-line effort summary in the app's autoreg metric:
    /// `"RIR 2"` (single) / `"RIR 2 → 0"` (progression) / `nil`. Returns `nil`
    /// when autoreg is `.none`, the mode is `.none`, or there's no usable value.
    /// Applies the same opposite-metric `10 - x` fallback as the per-set values,
    /// so a snapshot stored under one metric summarizes correctly in the other.
    /// Used by the active-workout Plan card so its summary matches the per-set
    /// rows and the block summary.
    static func summary(fields: Fields, autoregMode: AutoregMode) -> String? {
        guard let metric = metric(for: autoregMode) else { return nil }
        let t = resolvedTriple(fields, metric: metric)
        return EffortTargetResolver.summary(
            metric: metric,
            mode: derivedMode(fields),
            single: t.single,
            start: t.start,
            end: t.end
        )
    }

    /// The derived effort mode for these value fields (mirrors
    /// `SlotPrescription.effortMode`). Lets UI decide single-vs-progression
    /// behavior without reading a live model.
    static func effortMode(for fields: Fields) -> EffortMode {
        derivedMode(fields)
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

    /// Map effort labels onto a row list described by `setKinds` (the kind of
    /// each rendered set row, in order). Only `.working` rows receive a label —
    /// their sequential working-set ordinal indexes the resolved targets;
    /// `.warmup` and `.dropset` rows get `nil`. The returned array is aligned
    /// 1:1 with `setKinds`, so a row view can look up `result[rowIndex]`.
    /// Returns all-nil when there's nothing to show (no metric / mode `.none` /
    /// no usable value).
    static func perRowLabels(
        setKinds: [SetKind],
        fields: Fields,
        autoregMode: AutoregMode
    ) -> [String?] {
        let workingCount = setKinds.filter { $0 == .working }.count
        let labels = perSetLabels(
            fields: fields,
            autoregMode: autoregMode,
            workingSetCount: workingCount
        )
        guard !labels.isEmpty else {
            return Array(repeating: nil, count: setKinds.count)
        }
        var ordinal = 0
        return setKinds.map { kind -> String? in
            guard kind == .working else { return nil }
            let label = ordinal < labels.count ? labels[ordinal] : nil
            ordinal += 1
            return label
        }
    }

    /// Convenience over a session snapshot payload.
    static func perRowLabels(
        setKinds: [SetKind],
        payload: PrescriptionSnapshotPayload,
        autoregMode: AutoregMode
    ) -> [String?] {
        perRowLabels(
            setKinds: setKinds,
            fields: Fields(payload: payload),
            autoregMode: autoregMode
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

    /// Active-metric (single, start, end) values, falling back to the opposite
    /// metric via `10 - x` when the active field is nil — the single source of
    /// the paired-fallback rule shared by `perSetValues` and `summary`.
    private static func resolvedTriple(
        _ f: Fields, metric: EffortMetric
    ) -> (single: Double?, start: Double?, end: Double?) {
        let convert: (Double) -> Double = { 10 - $0 }
        switch metric {
        case .rir:
            return (
                f.rir ?? f.rpe.map(convert),
                f.rirStart ?? f.rpeStart.map(convert),
                f.rirEnd ?? f.rpeEnd.map(convert)
            )
        case .rpe:
            return (
                f.rpe ?? f.rir.map(convert),
                f.rpeStart ?? f.rirStart.map(convert),
                f.rpeEnd ?? f.rirEnd.map(convert)
            )
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

    /// Extract the effort fields from a live `SlotPrescription`. Used by the
    /// routine editor's progression preview so it shares the same paired-metric
    /// fallback as the block summary and active-workout rows.
    init(prescription: SlotPrescription) {
        self.init(
            effortModeRaw: prescription.effortModeRaw,
            rir: prescription.rir,
            rpe: prescription.rpe,
            rirStart: prescription.rirStart,
            rirEnd: prescription.rirEnd,
            rpeStart: prescription.rpeStart,
            rpeEnd: prescription.rpeEnd
        )
    }
}

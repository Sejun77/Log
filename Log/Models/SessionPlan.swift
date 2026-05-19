import Foundation

/// Phase 11.1 — moved out of `ActiveWorkoutView.swift` for behavior-preserving
/// file decomposition. Codable conformance, field shape, and computed
/// summaries are unchanged.
///
/// Session-scoped editable copy of a routine slot's prescription (in-memory
/// only). The active workout maintains one `SessionPlan` per
/// `routineSlotID` so the user can override the slot's planned values
/// for this session without mutating the underlying `RoutineExercise` /
/// `SlotPrescription` (the silent-mutation invariant from Phase 2).
///
/// Persisted via `AppState` to survive force-quit + cold-resume; the
/// Codable conformance is intentionally synthesized so field renames /
/// reorderings would be visible diffs.
struct SessionPlan: Codable {
    var sets: Int?
    var repMin: Int?
    var repMax: Int?
    var restSecondsBetweenSets: Int?
    var restSecondsAfterExercise: Int?
    var tempo: String?
    var rir: Double?
    var rpe: Double?
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool = false
    var slotNotes: String?

    /// Line 1: sets + rep range (or duration range)
    var primarySummary: String {
        var parts: [String] = []
        if let s = sets { parts.append("\(s) sets") }
        if usesDuration {
            if let lo = durationMinSeconds, let hi = durationMaxSeconds,
                lo != hi
            {
                parts.append("\(lo)–\(hi)s")
            } else if let d = durationMaxSeconds ?? durationMinSeconds {
                parts.append("\(d)s")
            }
        } else {
            if let lo = repMin, let hi = repMax, lo != hi {
                parts.append("\(lo)–\(hi) reps")
            } else if let r = repMax ?? repMin {
                parts.append("\(r) reps")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Line 2: rest + intensity (mode-filtered) + tempo.
    /// Shows only the active autoregulation field; falls back to a converted value
    /// from the other field if the active one is nil.
    func secondarySummary(autoregMode: AutoregMode) -> String {
        var parts: [String] = []
        if let r = restSecondsBetweenSets, r > 0 { parts.append("\(r)s rest") }
        let fmt: (Double) -> String = { v in
            v.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(v)) : String(format: "%.1f", v)
        }
        switch autoregMode {
        case .rir:
            let val = rir ?? rpe.map { 10 - $0 }
            if let v = val { parts.append("RIR \(fmt(v))") }
        case .rpe:
            let val = rpe ?? rir.map { 10 - $0 }
            if let v = val { parts.append("RPE \(fmt(v))") }
        case .none:
            break
        }
        if let t = tempo, !t.isEmpty { parts.append("Tempo \(t)") }
        return parts.joined(separator: " · ")
    }

    init() { self.usesDuration = false }

    init(from snapshot: PrescriptionSnapshotPayload, notes: String?) {
        self.sets = snapshot.sets
        self.repMin = snapshot.repMin
        self.repMax = snapshot.repMax
        self.restSecondsBetweenSets = snapshot.restSecondsBetweenSets
        self.restSecondsAfterExercise = snapshot.restSecondsAfterExercise
        self.tempo = snapshot.tempo
        self.rir = snapshot.rir
        self.rpe = snapshot.rpe
        self.durationMinSeconds = snapshot.durationMinSeconds
        self.durationMaxSeconds = snapshot.durationMaxSeconds
        self.usesDuration = snapshot.usesDuration
        self.slotNotes = notes
    }
}

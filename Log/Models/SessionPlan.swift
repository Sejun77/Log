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

    /// Line 2: rest + effort + tempo. The effort segment is **injected** by the
    /// caller (`effortSummary`) so it can be mode-aware (None / Single /
    /// Progression) and snapshot-derived — this value type no longer assumes a
    /// single rir/rpe. Pass `nil` (e.g. autoreg `.none`, or mode `.none`) to omit
    /// the effort segment. Centralized formatting lives in
    /// `WorkoutEffortTargetResolver` / `EffortTargetResolver`.
    func secondarySummary(effortSummary: String?) -> String {
        var parts: [String] = []
        if let r = restSecondsBetweenSets, r > 0 { parts.append("\(r)s rest") }
        if let effortSummary, !effortSummary.isEmpty { parts.append(effortSummary) }
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

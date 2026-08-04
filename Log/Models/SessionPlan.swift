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
struct SessionPlan: Codable, Equatable {
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
    // Cardio Slice 5 — the session's editable copy of the slot's target
    // distance. Optional, and `Codable` synthesis decodes an `Optional` with
    // `decodeIfPresent`, so a `SessionPlan` persisted by an earlier build
    // restores with nil rather than failing to decode.
    var targetDistanceMeters: Double? = nil
    var targetDistanceUnitRaw: String? = nil
    var slotNotes: String?

    /// The plan's target distance, validated, or nil when none is set.
    func targetDistance(fallbackUnit: DistanceUnit) -> CardioTargetDistance? {
        CardioTargetDistance(
            meters: targetDistanceMeters,
            unitRaw: targetDistanceUnitRaw,
            fallbackUnit: fallbackUnit)
    }

    /// Line 1: sets + rep range (or duration range), plus the cardio distance
    /// target when one is set.
    ///
    /// The distance is appended rather than substituted: duration and distance
    /// are independent targets, so "1 sets · 1800s · 5 km" says both, and a
    /// cardio slot with only a distance target reads "1 sets · 5 km". Absent
    /// values contribute no segment — never a placeholder.
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
        // Fall back to km for an unparseable stored unit: the value is
        // canonical meters, so the number is right whichever unit renders it.
        if let distance = targetDistance(fallbackUnit: .kilometers)?.displayText
        {
            parts.append(distance)
        }
        return parts.joined(separator: " · ")
    }

    /// The tempo value this plan may actually display/edit.
    ///
    /// Tempo describes eccentric/concentric rep phases, so it is meaningless
    /// for a duration-based exercise. Reading through this property (rather
    /// than `tempo` directly) makes every render site duration-safe in one
    /// place and, critically, suppresses **stale** tempo that older data — or
    /// a prescription that was later flipped to duration — may still carry.
    var effectiveTempo: String? {
        guard !usesDuration, let t = tempo, !t.isEmpty else { return nil }
        return t
    }

    /// Line 2: rest + effort + tempo. The effort segment is **injected** by the
    /// caller (`effortSummary`) so it can be mode-aware (None / Single /
    /// Progression) and snapshot-derived — this value type no longer assumes a
    /// single rir/rpe. Pass `nil` (e.g. autoreg `.none`, or mode `.none`) to omit
    /// the effort segment. Centralized formatting lives in
    /// `WorkoutEffortTargetResolver` / `EffortTargetResolver`.
    ///
    /// Tempo reads through `effectiveTempo`, so a duration-based slot never
    /// shows a tempo segment even if one is stored.
    func secondarySummary(effortSummary: String?) -> String {
        var parts: [String] = []
        if let r = restSecondsBetweenSets, r > 0 { parts.append(String(localized: "\(r)s rest")) }
        if let effortSummary, !effortSummary.isEmpty { parts.append(effortSummary) }
        if let t = effectiveTempo { parts.append(String(localized: "Tempo \(t)")) }
        return parts.joined(separator: " · ")
    }

    init() { self.usesDuration = false }

    init(from snapshot: PrescriptionSnapshotPayload, notes: String?) {
        self.sets = snapshot.sets
        self.repMin = snapshot.repMin
        self.repMax = snapshot.repMax
        self.restSecondsBetweenSets = snapshot.restSecondsBetweenSets
        self.restSecondsAfterExercise = snapshot.restSecondsAfterExercise
        // Drop tempo carried by a duration-based snapshot at the ingest point,
        // so stale saved tempo can never re-enter the live session plan (and so
        // `isSessionPlanDirty` doesn't report a phantom edit against it).
        self.tempo = snapshot.usesDuration ? nil : snapshot.tempo
        self.rir = snapshot.rir
        self.rpe = snapshot.rpe
        self.durationMinSeconds = snapshot.durationMinSeconds
        self.durationMaxSeconds = snapshot.durationMaxSeconds
        self.usesDuration = snapshot.usesDuration
        self.targetDistanceMeters = snapshot.targetDistanceMeters
        self.targetDistanceUnitRaw = snapshot.targetDistanceUnitRaw
        self.slotNotes = notes
    }
}

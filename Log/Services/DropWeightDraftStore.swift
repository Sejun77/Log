import Foundation

/// Phase 7.4-B — per-workout `UserDefaults`-backed store for un-logged
/// drop-weight drafts. Lifted out of `ActiveWorkoutView` so the persistence
/// shape can be unit-tested in isolation; storage layout is **byte-identical**
/// to the prior inline implementation so in-flight drafts survive the refactor.
///
/// The `slotKey` is already-stringly-typed by the caller, currently formatted
/// as `"<slotID>_<parentSetIndex>_<subIndex>"`. This format is shared with
/// other `dropWeight*` `@State` dictionaries in `ActiveWorkoutView` and must
/// stay aligned with them.
///
/// Storage layout (DO NOT CHANGE without a migration story):
///  - top-level key: `"dropWeightDrafts_<workoutUUID>"` → `[String: String]`
///  - per-slot key:  caller-formed string (today `"<slotID>_<setIndex>_<subIndex>"`)
///
/// All operations are no-ops if `UserDefaults` returns an incompatible value
/// for the top-level key — corrupted state reads as "no drafts", never crashes.
struct DropWeightDraftStore {

    let workoutID: UUID
    let defaults: UserDefaults

    init(workoutID: UUID, defaults: UserDefaults = .standard) {
        self.workoutID = workoutID
        self.defaults = defaults
    }

    // MARK: - Key derivation

    private var udKey: String {
        "dropWeightDrafts_\(workoutID.uuidString)"
    }

    /// Defensive read: a missing key or wrong value type returns an empty
    /// dict so callers can write fresh entries without losing data they
    /// could have read.
    private func readDict() -> [String: String] {
        (defaults.dictionary(forKey: udKey) as? [String: String]) ?? [:]
    }

    // MARK: - Mutations

    func persist(slotKey: String, value: String) {
        var dict = readDict()
        dict[slotKey] = value
        defaults.set(dict, forKey: udKey)
    }

    /// No-op (and no write) when the slot is not present — avoids spurious
    /// `UserDefaults` churn on cascade-clear paths that fire for keys that
    /// may or may not have a persisted draft.
    func clear(slotKey: String) {
        var dict = readDict()
        guard dict[slotKey] != nil else { return }
        dict.removeValue(forKey: slotKey)
        defaults.set(dict, forKey: udKey)
    }

    /// Drops the entire per-workout key — used on workout finish/dismiss.
    func clearAll() {
        defaults.removeObject(forKey: udKey)
    }

    // MARK: - Read

    /// Returns every persisted drop-weight draft for this workout. Returns
    /// an empty dictionary when nothing is persisted (or when the entry is
    /// the wrong type). Used by `ActiveWorkoutView`'s `restoreDropWeightDrafts`
    /// to bridge persisted state into the view's `@State` buffers.
    func loadAll() -> [String: String] {
        readDict()
    }

    /// Replaces the entire per-workout dict with `dict` in a single
    /// `UserDefaults` write. Used by the Phase 5.2-B legacy-key migration
    /// in `ActiveWorkoutView.restoreDropWeightDrafts` so the rewrite is
    /// atomic.
    func setAll(_ dict: [String: String]) {
        if dict.isEmpty {
            defaults.removeObject(forKey: udKey)
        } else {
            defaults.set(dict, forKey: udKey)
        }
    }
}

// MARK: - Phase 5.2-B legacy key migration (pure helper)

extension DropWeightDraftStore {

    /// Phase 5.2-B — rewrites legacy `"<Exercise.id>_<setIdx>_<sub>"` drop
    /// keys to the new `"<routineSlotID>_<setIdx>_<sub>"` format using a
    /// per-plan `legacyExerciseToSlots` map.
    ///
    /// Rules (matches the design in the Slice B audit):
    /// 1. **Already-migrated keys** (leading UUID is a known
    ///    `routineSlotID`) pass through untouched.
    /// 2. **Legacy keys** (leading UUID is a known `Exercise.id`) are
    ///    rewritten — when an `Exercise.id` maps to multiple slots (the
    ///    duplicate-Exercise case), the legacy value is **fanned out**
    ///    to every matching new key. The legacy entry is then removed.
    /// 3. **New-key-wins**: if a new-format key for the same slot already
    ///    exists in `dict`, the existing value is preserved (the legacy
    ///    value is dropped).
    /// 4. **Stale legacy** (leading UUID is neither a known Exercise.id
    ///    nor a known slot) is preserved unchanged — the workout may
    ///    have had a swap that retired that Exercise from the plan; the
    ///    entry will die at `clearAll` on workout finish.
    /// 5. **Malformed** keys (no leading 36-char UUID followed by `_`)
    ///    are preserved unchanged.
    ///
    /// Pure — no `UserDefaults` access — so it's covered by focused
    /// unit tests in `DropWeightDraftStoreTests`.
    static func migrateLegacyKeys(
        in dict: [String: String],
        legacyExerciseToSlots: [UUID: [UUID]],
        knownSlots: Set<UUID>
    ) -> [String: String] {
        // Two-pass: collect rewrites, then apply (so legacy → new
        // fan-outs don't see partial state).
        var result = dict
        for (oldKey, value) in dict {
            // Parse "<36-char UUID>_<suffix>" — the suffix is opaque.
            guard oldKey.count > 37 else { continue }
            let uuidEnd = oldKey.index(oldKey.startIndex, offsetBy: 36)
            guard oldKey[uuidEnd] == "_" else { continue }
            let uuidStr = String(oldKey[oldKey.startIndex..<uuidEnd])
            guard let leadingUUID = UUID(uuidString: uuidStr) else { continue }
            let suffix = String(oldKey[oldKey.index(after: uuidEnd)..<oldKey.endIndex])

            // Rule 1 — already a known slot.
            if knownSlots.contains(leadingUUID) { continue }

            // Rule 2 + 3 — legacy Exercise.id → fan out new keys, drop legacy.
            if let slotIDs = legacyExerciseToSlots[leadingUUID], !slotIDs.isEmpty {
                for sid in slotIDs {
                    let newKey = "\(sid)_\(suffix)"
                    if result[newKey] == nil {
                        result[newKey] = value
                    }
                }
                result.removeValue(forKey: oldKey)
            }
            // Rule 4 — stale legacy (not in plan): preserved.
        }
        return result
    }
}

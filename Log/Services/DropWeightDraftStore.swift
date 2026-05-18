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
}

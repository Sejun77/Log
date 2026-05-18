import Foundation

/// Phase 7.4 — per-workout `UserDefaults`-backed store for un-logged parent
/// working-set drafts (reps / weight / duration). Lifted out of
/// `ActiveWorkoutView` so the persistence shape can be unit-tested in
/// isolation; storage layout is **byte-identical** to the prior inline
/// implementation so in-flight drafts survive the refactor.
///
/// Storage layout (DO NOT CHANGE without a migration story):
///  - top-level key:  `"parentDrafts_<workoutUUID>"`  → `[String: String]`
///  - per-field key:  `"<slotID>_<setIndex>_<field>"`  where `field ∈ {reps, weight, duration}`
///
/// All operations are no-ops if `UserDefaults` returns an incompatible value
/// for the top-level key — corrupted state reads as "no draft", never crashes.
struct ParentDraftStore {

    enum Field: String { case reps, weight, duration }

    /// Three independently-nilable fields. The store returns `nil` (not a
    /// snapshot with all nil fields) when nothing is persisted for a slot;
    /// `isEmpty` is provided for callers that already hold a snapshot.
    struct Snapshot: Equatable {
        var reps: String?
        var weight: String?
        var duration: String?
        var isEmpty: Bool { reps == nil && weight == nil && duration == nil }
    }

    let workoutID: UUID
    let defaults: UserDefaults

    init(workoutID: UUID, defaults: UserDefaults = .standard) {
        self.workoutID = workoutID
        self.defaults = defaults
    }

    // MARK: - Key derivation

    private var udKey: String {
        "parentDrafts_\(workoutID.uuidString)"
    }

    private func slotKey(slotID: UUID, setIndex: Int, field: Field) -> String {
        "\(slotID)_\(setIndex)_\(field.rawValue)"
    }

    /// Reads the per-workout dictionary defensively. A missing key, a wrong
    /// value type, or anything else non-conformant returns an empty dict so
    /// callers can write freshly without losing data they could have read.
    private func readDict() -> [String: String] {
        (defaults.dictionary(forKey: udKey) as? [String: String]) ?? [:]
    }

    // MARK: - Mutations

    func persist(slotID: UUID, setIndex: Int, field: Field, value: String) {
        var dict = readDict()
        dict[slotKey(slotID: slotID, setIndex: setIndex, field: field)] = value
        defaults.set(dict, forKey: udKey)
    }

    /// Removes all three fields for `(slotID, setIndex)` in a single write.
    /// No-op (and no write) when nothing matches the prefix.
    func clear(slotID: UUID, setIndex: Int) {
        var dict = readDict()
        let prefix = "\(slotID)_\(setIndex)_"
        let toRemove = dict.keys.filter { $0.hasPrefix(prefix) }
        guard !toRemove.isEmpty else { return }
        for key in toRemove { dict.removeValue(forKey: key) }
        defaults.set(dict, forKey: udKey)
    }

    /// Drops the entire per-workout key — used on workout finish/dismiss.
    func clearAll() {
        defaults.removeObject(forKey: udKey)
    }

    // MARK: - Read

    /// Returns the persisted snapshot for a slot, or `nil` when every field
    /// is absent. Each field may independently be `nil`; callers backfill
    /// from prescription defaults.
    func load(slotID: UUID, setIndex: Int) -> Snapshot? {
        let dict = readDict()
        let reps = dict[slotKey(slotID: slotID, setIndex: setIndex, field: .reps)]
        let weight = dict[slotKey(slotID: slotID, setIndex: setIndex, field: .weight)]
        let duration = dict[slotKey(slotID: slotID, setIndex: setIndex, field: .duration)]
        if reps == nil && weight == nil && duration == nil { return nil }
        return Snapshot(reps: reps, weight: weight, duration: duration)
    }
}

import Foundation

/// Phase 7.4 — per-workout `UserDefaults`-backed store for un-logged parent
/// working-set drafts (reps / weight / duration). Lifted out of
/// `ActiveWorkoutView` so the persistence shape can be unit-tested in
/// isolation; storage layout is **byte-identical** to the prior inline
/// implementation so in-flight drafts survive the refactor.
///
/// Storage layout (DO NOT CHANGE without a migration story):
///  - top-level key:  `"parentDrafts_<workoutUUID>"`  → `[String: String]`
///  - per-field key:  `"<slotID>_<setIndex>_<field>"`  where `field` is a
///    `Field` raw value
///
/// Cardio Slice 4 **added** field cases (`distance` … `hrZone`) rather than
/// changing the layout: new cases mint new per-field keys, every pre-existing
/// `reps` / `weight` / `duration` key keeps its exact spelling, and the
/// prefix-matching `clear` sweeps old and new alike. An in-flight draft written
/// by a previous build reads back unchanged, with the cardio fields simply
/// absent.
///
/// All operations are no-ops if `UserDefaults` returns an incompatible value
/// for the top-level key — corrupted state reads as "no draft", never crashes.
struct ParentDraftStore {

    enum Field: String, CaseIterable {
        case reps, weight, duration
        // Cardio Slice 4 — raw text of the active-workout Details fields, kept
        // as typed so a partially entered "6." survives a force-quit exactly as
        // the duration field's text already does. Normalization to
        // `CardioMetrics` happens at log time, not here.
        case distance, distanceUnit, avgHeartRate, calories
        case incline, resistance, hrZone
    }

    /// Independently-nilable fields. The store returns `nil` (not a snapshot
    /// with all nil fields) when nothing is persisted for a slot; `isEmpty` is
    /// provided for callers that already hold a snapshot.
    struct Snapshot: Equatable {
        var reps: String?
        var weight: String?
        var duration: String?

        // Cardio Slice 4 — nil for every strength and timed-hold draft, and
        // for every draft written before this slice.
        var distance: String?
        var distanceUnit: String?
        var avgHeartRate: String?
        var calories: String?
        var incline: String?
        var resistance: String?
        var hrZone: String?

        var isEmpty: Bool {
            reps == nil && weight == nil && duration == nil && !hasCardio
        }

        /// True when the snapshot carries any cardio field. Lets the restore
        /// path skip rebuilding a cardio draft for the overwhelming majority of
        /// slots, which have none.
        var hasCardio: Bool {
            distance != nil || distanceUnit != nil || avgHeartRate != nil
                || calories != nil || incline != nil || resistance != nil
                || hrZone != nil
        }
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

    /// Writes several fields of one slot in a single read-modify-write.
    /// The cardio Details section persists on every keystroke and has seven
    /// fields; doing that as seven separate `persist` calls would mean seven
    /// full dictionary rewrites per character typed.
    func persist(slotID: UUID, setIndex: Int, values: [Field: String]) {
        guard !values.isEmpty else { return }
        var dict = readDict()
        for (field, value) in values {
            dict[slotKey(slotID: slotID, setIndex: setIndex, field: field)] = value
        }
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
        func value(_ field: Field) -> String? {
            dict[slotKey(slotID: slotID, setIndex: setIndex, field: field)]
        }
        let snapshot = Snapshot(
            reps: value(.reps),
            weight: value(.weight),
            duration: value(.duration),
            distance: value(.distance),
            distanceUnit: value(.distanceUnit),
            avgHeartRate: value(.avgHeartRate),
            calories: value(.calories),
            incline: value(.incline),
            resistance: value(.resistance),
            hrZone: value(.hrZone)
        )
        return snapshot.isEmpty ? nil : snapshot
    }
}

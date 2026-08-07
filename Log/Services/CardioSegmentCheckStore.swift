import Foundation

/// Structured Cardio Slice 12D — per-workout `UserDefaults`-backed store for
/// the **checklist ticks** on a cardio slot's structured segment plan.
///
/// A sibling of `ParentDraftStore` / `DropWeightDraftStore` rather than a new
/// field on either, for two reasons:
///
///  * `ParentDraftStore` is keyed `"<slotID>_<setIndex>_<field>"` and its
///    layout is documented as byte-frozen. A tick is **per slot**, not per set
///    — a structured plan describes one bout, and the app logs one aggregate
///    `SetLog` for it — so it has no set index to key on, and shoehorning one in
///    would mean inventing a fake index that the prefix-matching `clear` would
///    then sweep at the wrong moments.
///  * Keeping it separate makes the guarantee that matters structural: this
///    store is the *only* place a tick is written. Nothing here can reach
///    `SetLog`, `WorkoutItem`, or `Workout`, so History can never imply the app
///    observed a segment it did not.
///
/// Storage layout:
///  - top-level key: `"cardioSegmentChecks_<workoutUUID>"` → `[String: [String]]`
///  - per-slot key:  `slotID.uuidString`
///  - value:         the ticked `ResolvedCardioSegment.id`s
///    (`"<segment uuid>#<round>"`), so round 1 and round 2 of a repeat are
///    independent and a reorder of the plan moves ticks with their segments
///    rather than down a row.
///
/// A tick whose id is no longer in the plan is **ignored, never repaired**:
/// callers intersect what they load against the live expanded plan
/// (`checked(slotID:in:)`), so an orphan from an edited or reset plan simply
/// stops rendering. That is why every operation here is total and none of them
/// can fail.
///
/// All operations are no-ops if `UserDefaults` returns an incompatible value
/// for the top-level key — corrupted state reads as "nothing ticked", never
/// crashes.
struct CardioSegmentCheckStore {

    let workoutID: UUID
    let defaults: UserDefaults

    init(workoutID: UUID, defaults: UserDefaults = .standard) {
        self.workoutID = workoutID
        self.defaults = defaults
    }

    // MARK: - Key derivation

    private var udKey: String {
        "cardioSegmentChecks_\(workoutID.uuidString)"
    }

    /// Defensive read: a missing key, a wrong value type, or a dictionary whose
    /// values are not string arrays all read as empty, so a caller can write
    /// fresh entries without losing data it could have read.
    private func readDict() -> [String: [String]] {
        (defaults.dictionary(forKey: udKey) as? [String: [String]]) ?? [:]
    }

    // MARK: - Mutations

    /// Replace one slot's ticks. An empty set removes the slot's entry rather
    /// than storing `[]`, so "nothing ticked" and "never ticked" persist
    /// identically — the same one-representation rule
    /// `SlotPrescription.setStructuredCardioPlan` follows for the plan itself.
    func save(slotID: UUID, checked: Set<String>) {
        var dict = readDict()
        if checked.isEmpty {
            guard dict[slotID.uuidString] != nil else { return }
            dict.removeValue(forKey: slotID.uuidString)
        } else {
            // Sorted so the stored array is stable across writes — an
            // unordered `Set` would otherwise churn `UserDefaults` (and any
            // test asserting on the raw value) with every toggle.
            dict[slotID.uuidString] = checked.sorted()
        }
        defaults.set(dict, forKey: udKey)
    }

    /// Drop one slot's ticks. Used when a slot is switched onto an exercise
    /// whose plan cannot hold them. No-op (and no write) when the slot has
    /// none.
    func clear(slotID: UUID) {
        var dict = readDict()
        guard dict[slotID.uuidString] != nil else { return }
        dict.removeValue(forKey: slotID.uuidString)
        defaults.set(dict, forKey: udKey)
    }

    /// Drops the entire per-workout key — used on workout finish/dismiss,
    /// alongside the other two draft stores.
    func clearAll() {
        defaults.removeObject(forKey: udKey)
    }

    // MARK: - Read

    /// Every tick persisted for one slot, exactly as stored — orphans
    /// included. Prefer `checked(slotID:in:)`, which filters them.
    func load(slotID: UUID) -> Set<String> {
        Set(readDict()[slotID.uuidString] ?? [])
    }

    /// One slot's ticks, filtered to the segments the given plan actually has.
    ///
    /// This is the orphan gate: a plan that was edited, reset, or replaced by a
    /// switch leaves ids behind that name segments no longer in it, and those
    /// must never render or count. Passing `nil` (the slot has no structured
    /// plan) yields an empty set, so a cardio slot that lost its plan — or a
    /// slot switched onto a strength exercise — shows nothing regardless of
    /// what is still on disk.
    func checked(slotID: UUID, in plan: CardioSegmentPlan?) -> Set<String> {
        guard let plan else { return [] }
        let live = Set(plan.expandedSegments().map(\.id))
        return load(slotID: slotID).intersection(live)
    }

    /// Every slot with at least one tick. Used by the resume path to rebuild
    /// the view's in-memory state in one read.
    func loadAll() -> [UUID: Set<String>] {
        var result: [UUID: Set<String>] = [:]
        for (key, ids) in readDict() {
            // A key that is not a UUID cannot address a slot; skipping it is
            // the same tolerance the rest of this file applies to bad data.
            guard let slotID = UUID(uuidString: key), !ids.isEmpty else {
                continue
            }
            result[slotID] = Set(ids)
        }
        return result
    }
}

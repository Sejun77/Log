import XCTest

@testable import Log

/// Phase 7.4-B — `DropWeightDraftStore` was extracted out of
/// `ActiveWorkoutView` so the per-workout drop-weight draft persistence
/// shape can be unit-tested in isolation. Tests must lock down both the
/// public behavior AND the on-disk storage format because any user with an
/// in-flight workout when the app updates must find their drafts
/// byte-identical on relaunch.
final class DropWeightDraftStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore(workoutID: UUID = UUID()) -> DropWeightDraftStore {
        DropWeightDraftStore(workoutID: workoutID, defaults: defaults)
    }

    /// Production callers form keys like `"<slotID>_<parentSetIndex>_<subIndex>"`;
    /// the store itself is agnostic to the format, but tests use realistic
    /// keys so a future regression that depends on the format surfaces here.
    private func slotKey(
        slotID: UUID = UUID(), setIndex: Int = 0, subIndex: Int = 1
    ) -> String {
        "\(slotID)_\(setIndex)_\(subIndex)"
    }

    // MARK: - Round trip

    func testPersistThenLoadAllRoundTrip() {
        let store = makeStore()
        let k1 = slotKey(setIndex: 0, subIndex: 1)
        let k2 = slotKey(setIndex: 0, subIndex: 2)

        store.persist(slotKey: k1, value: "80")
        store.persist(slotKey: k2, value: "60")

        XCTAssertEqual(store.loadAll(), [k1: "80", k2: "60"])
    }

    // MARK: - Empty

    func testLoadAllReturnsEmptyWhenNothingPersisted() {
        let store = makeStore()
        XCTAssertEqual(store.loadAll(), [:])
    }

    // MARK: - Clear single slot

    func testClearOneSlotLeavesOtherSlotsIntact() {
        let store = makeStore()
        let kA = slotKey(setIndex: 0, subIndex: 1)
        let kB = slotKey(setIndex: 0, subIndex: 2)

        store.persist(slotKey: kA, value: "80")
        store.persist(slotKey: kB, value: "60")

        store.clear(slotKey: kA)

        let all = store.loadAll()
        XCTAssertNil(all[kA])
        XCTAssertEqual(all[kB], "60")
    }

    func testClearOnMissingSlotIsNoop() {
        // Defensive: production cascade-clear paths fire for keys that
        // may or may not have a persisted draft. The store must not panic
        // and must not churn `UserDefaults` for a missing key.
        let store = makeStore()
        store.persist(slotKey: slotKey(subIndex: 1), value: "80")

        store.clear(slotKey: "non-existent-key")

        XCTAssertEqual(store.loadAll().count, 1)
    }

    // MARK: - clearAll

    func testClearAllRemovesAllDraftsForWorkout() {
        let store = makeStore()
        store.persist(slotKey: slotKey(subIndex: 1), value: "80")
        store.persist(slotKey: slotKey(setIndex: 2, subIndex: 1), value: "60")

        store.clearAll()

        XCTAssertEqual(store.loadAll(), [:])
    }

    // MARK: - Cross-workout isolation

    func testTwoWorkoutsAreIsolatedInSameUserDefaults() {
        let storeA = makeStore(workoutID: UUID())
        let storeB = makeStore(workoutID: UUID())
        let key = slotKey()

        storeA.persist(slotKey: key, value: "80")

        XCTAssertEqual(storeA.loadAll()[key], "80")
        XCTAssertNil(storeB.loadAll()[key])

        storeA.clearAll()
        storeB.persist(slotKey: key, value: "60")

        XCTAssertEqual(storeA.loadAll(), [:])
        XCTAssertEqual(storeB.loadAll()[key], "60")
    }

    // MARK: - Overwrite

    func testOverwriteSameSlotKeepsLatestValue() {
        let store = makeStore()
        let key = slotKey()

        store.persist(slotKey: key, value: "80")
        store.persist(slotKey: key, value: "75")

        XCTAssertEqual(store.loadAll()[key], "75")
    }

    // MARK: - Empty-string sentinel

    func testEmptyStringPersistsAsEmptyStringNotMissing() {
        // The dropset UI binding writes whatever the user typed (after
        // `.filter(\.isNumber)`), which can be the empty string when the
        // user clears the field. Store must preserve "" distinctly from
        // "absent" so a force-quit doesn't silently restore the suggested
        // value on resume.
        let store = makeStore()
        let key = slotKey()

        store.persist(slotKey: key, value: "")

        let all = store.loadAll()
        XCTAssertNotNil(all[key])
        XCTAssertEqual(all[key], "")
    }

    // MARK: - Corrupted UserDefaults entry

    func testCorruptedUserDefaultsEntryReadsAsEmptyAndDoesNotCrash() {
        let workoutID = UUID()
        let store = makeStore(workoutID: workoutID)

        defaults.set(["mismatched": 42], forKey: "dropWeightDrafts_\(workoutID.uuidString)")

        XCTAssertEqual(store.loadAll(), [:])

        // Subsequent persist should still succeed (the garbage value is
        // overwritten with a fresh dict; we don't preserve it).
        let key = slotKey()
        store.persist(slotKey: key, value: "80")
        XCTAssertEqual(store.loadAll()[key], "80")
    }

    // MARK: - Storage format pin

    func testStorageKeyFormatIsStable() {
        // This format is depended on by any user with an in-flight workout
        // when the app updates. If this assertion fails, somebody changed
        // the on-disk format — add a migration before merging.
        let workoutID = UUID()
        let store = makeStore(workoutID: workoutID)
        let slotID = UUID()
        let key = "\(slotID)_2_3"

        store.persist(slotKey: key, value: "60")

        let topKey = "dropWeightDrafts_\(workoutID.uuidString)"
        let dict = defaults.dictionary(forKey: topKey) as? [String: String]
        XCTAssertEqual(dict?[key], "60")
    }

    // MARK: - Phase 5.2-B legacy key migration

    func testMigrateLegacyKeysRewritesLegacyExerciseIDToRoutineSlotID() {
        // Pre-Slice-B drafts were keyed by Exercise.id. The migration
        // walker rewrites them to routineSlotID-based keys using a
        // per-plan map. Single Exercise → single slot is the common case.
        let exerciseID = UUID()
        let slotID = UUID()
        let legacyKey = "\(exerciseID)_2_3"
        let input = [legacyKey: "60"]

        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: input,
            legacyExerciseToSlots: [exerciseID: [slotID]],
            knownSlots: [slotID]
        )

        XCTAssertEqual(migrated["\(slotID)_2_3"], "60")
        XCTAssertNil(migrated[legacyKey], "Legacy key must be removed after rewrite")
    }

    func testMigrateLegacyKeysFansOutToBothSlotsForDuplicateExercise() {
        // Duplicate-Exercise case: pre-Slice-B persisted a single entry
        // under Exercise.id, but post-Slice-B both slots need their own
        // entry. The migration fans the legacy value out to every slot
        // that resolves from the legacy Exercise.id.
        let exerciseID = UUID()
        let slotA = UUID()
        let slotB = UUID()
        let legacyKey = "\(exerciseID)_0_1"
        let input = [legacyKey: "100"]

        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: input,
            legacyExerciseToSlots: [exerciseID: [slotA, slotB]],
            knownSlots: [slotA, slotB]
        )

        XCTAssertEqual(migrated["\(slotA)_0_1"], "100")
        XCTAssertEqual(migrated["\(slotB)_0_1"], "100")
        XCTAssertNil(migrated[legacyKey])
    }

    func testMigrateLegacyKeysPrefersExistingNewKeyOverLegacyValue() {
        // If a new-format key for the same slot already exists in the
        // dict (e.g. user re-typed under post-Slice-B), the existing
        // value wins — the legacy value is dropped along with its key.
        let exerciseID = UUID()
        let slotID = UUID()
        let legacyKey = "\(exerciseID)_1_2"
        let newKey = "\(slotID)_1_2"
        let input = [
            legacyKey: "STALE",
            newKey: "FRESH",
        ]

        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: input,
            legacyExerciseToSlots: [exerciseID: [slotID]],
            knownSlots: [slotID]
        )

        XCTAssertEqual(migrated[newKey], "FRESH")
        XCTAssertNil(migrated[legacyKey])
    }

    func testMigrateLegacyKeysLeavesAlreadyMigratedKeysUnchanged() {
        // A dict that has already been migrated (every leading UUID is a
        // known routineSlotID) must round-trip unchanged on a second
        // walker pass — the migration must be idempotent.
        let slotID = UUID()
        let key = "\(slotID)_0_1"
        let input = [key: "55"]

        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: input,
            legacyExerciseToSlots: [:],
            knownSlots: [slotID]
        )

        XCTAssertEqual(migrated, input)
    }

    func testMigrateLegacyKeysPreservesStaleLegacyKey() {
        // A legacy key whose leading UUID is NOT in the plan's
        // Exercise→slot map (e.g. user swapped that Exercise in a prior
        // session) is preserved as-is. It will die at clearAll on
        // workout finish; never resurrected into the in-memory dicts
        // because the bridge iterates the migrated dict and the
        // unrecognized prefix won't match any plan slot.
        let unknownExerciseID = UUID()
        let key = "\(unknownExerciseID)_3_4"
        let input = [key: "90"]

        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: input,
            legacyExerciseToSlots: [:],
            knownSlots: [UUID()]
        )

        XCTAssertEqual(migrated, input)
    }

    func testMigrateLegacyKeysPreservesMalformedKey() {
        // Defensive: a key without a parseable leading UUID is preserved
        // unchanged. The walker should never crash on garbage input.
        let inputs: [String: String] = [
            "not-a-uuid_0_1": "x",
            "tooShort": "y",
            "_0_1": "z",
        ]

        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: inputs,
            legacyExerciseToSlots: [:],
            knownSlots: []
        )

        XCTAssertEqual(migrated, inputs)
    }

    func testMigrateLegacyKeysEmptyInputReturnsEmpty() {
        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: [:],
            legacyExerciseToSlots: [UUID(): [UUID()]],
            knownSlots: [UUID()]
        )
        XCTAssertTrue(migrated.isEmpty)
    }

    func testMigrateLegacyKeysDoesNotMutateInputDictionary() {
        // `migrateLegacyKeys` takes `dict` by value. This test pins that
        // contract — call sites should be safe to use the original dict
        // after the call, e.g. for diffing against the migrated result
        // to decide whether to write back.
        let exerciseID = UUID()
        let slotID = UUID()
        let legacyKey = "\(exerciseID)_0_1"
        let input = [legacyKey: "60"]

        _ = DropWeightDraftStore.migrateLegacyKeys(
            in: input,
            legacyExerciseToSlots: [exerciseID: [slotID]],
            knownSlots: [slotID]
        )

        XCTAssertEqual(input, [legacyKey: "60"])
    }

    func testMigrateLegacyKeysPreservesUnrelatedSuffixShapes() {
        // The walker treats the suffix as opaque — if a key has a
        // different shape (e.g. extra components), as long as the leading
        // UUID resolves, the rewrite preserves the suffix verbatim.
        let exerciseID = UUID()
        let slotID = UUID()
        let legacyKey = "\(exerciseID)_alpha_beta_gamma"
        let input = [legacyKey: "x"]

        let migrated = DropWeightDraftStore.migrateLegacyKeys(
            in: input,
            legacyExerciseToSlots: [exerciseID: [slotID]],
            knownSlots: [slotID]
        )

        XCTAssertEqual(migrated["\(slotID)_alpha_beta_gamma"], "x")
        XCTAssertNil(migrated[legacyKey])
    }

    // MARK: - setAll

    func testSetAllReplacesEntireDict() {
        let store = makeStore()
        store.persist(slotKey: "a_0_1", value: "1")
        store.persist(slotKey: "b_0_1", value: "2")

        let replacement = ["c_0_1": "3", "d_0_1": "4"]
        store.setAll(replacement)

        XCTAssertEqual(store.loadAll(), replacement)
    }

    func testSetAllWithEmptyDictRemovesTopLevelKey() {
        let workoutID = UUID()
        let store = makeStore(workoutID: workoutID)
        store.persist(slotKey: "a_0_1", value: "1")

        store.setAll([:])

        // Top-level UserDefaults key should be absent (not just empty).
        let topKey = "dropWeightDrafts_\(workoutID.uuidString)"
        XCTAssertNil(defaults.dictionary(forKey: topKey))
    }
}

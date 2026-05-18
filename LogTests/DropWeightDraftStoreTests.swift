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
}

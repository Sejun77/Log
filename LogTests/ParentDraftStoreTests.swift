import XCTest

@testable import Log

/// Phase 7.4 — `ParentDraftStore` was extracted out of `ActiveWorkoutView`
/// so the per-workout draft persistence shape can be unit-tested in
/// isolation. Tests must lock down both the public behavior AND the
/// on-disk storage format because any user with an in-flight workout
/// when the app updates must find their drafts byte-identical on relaunch.
final class ParentDraftStoreTests: XCTestCase {

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

    private func makeStore(workoutID: UUID = UUID()) -> ParentDraftStore {
        ParentDraftStore(workoutID: workoutID, defaults: defaults)
    }

    // MARK: - Round trip

    func testPersistThenLoadReturnsAllThreeFields() {
        let store = makeStore()
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .reps, value: "5")
        store.persist(slotID: slot, setIndex: 0, field: .weight, value: "100")
        store.persist(slotID: slot, setIndex: 0, field: .duration, value: "30")

        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertEqual(snap, ParentDraftStore.Snapshot(reps: "5", weight: "100", duration: "30"))
    }

    // MARK: - Empty / partial

    func testLoadReturnsNilWhenNothingPersisted() {
        let store = makeStore()
        XCTAssertNil(store.load(slotID: UUID(), setIndex: 0))
    }

    func testPartialSnapshotWhenOnlyOneFieldExists() {
        let store = makeStore()
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .weight, value: "100")

        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertEqual(snap?.reps, nil)
        XCTAssertEqual(snap?.weight, "100")
        XCTAssertEqual(snap?.duration, nil)
        XCTAssertEqual(snap?.isEmpty, false)
    }

    // MARK: - Clear semantics

    func testClearOneSlotLeavesOtherSlotsIntact() {
        let store = makeStore()
        let slotA = UUID()
        let slotB = UUID()

        store.persist(slotID: slotA, setIndex: 0, field: .reps, value: "5")
        store.persist(slotID: slotA, setIndex: 0, field: .weight, value: "100")
        store.persist(slotID: slotB, setIndex: 0, field: .reps, value: "8")

        store.clear(slotID: slotA, setIndex: 0)

        XCTAssertNil(store.load(slotID: slotA, setIndex: 0))
        XCTAssertEqual(store.load(slotID: slotB, setIndex: 0)?.reps, "8")
    }

    func testClearRemovesAllThreeFieldsForOneSlot() {
        let store = makeStore()
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .reps, value: "5")
        store.persist(slotID: slot, setIndex: 0, field: .weight, value: "100")
        store.persist(slotID: slot, setIndex: 0, field: .duration, value: "30")

        store.clear(slotID: slot, setIndex: 0)

        XCTAssertNil(store.load(slotID: slot, setIndex: 0))
    }

    func testClearOnEmptySlotIsNoop() {
        // Defensive: clearing a slot that has no entries should not write
        // an empty dict back (would still be a no-op semantically, but the
        // production implementation skips the write to avoid churn).
        let store = makeStore()
        store.clear(slotID: UUID(), setIndex: 0)
        XCTAssertNil(store.load(slotID: UUID(), setIndex: 0))
    }

    func testClearOneSetIndexLeavesOtherSetIndexIntactSameSlot() {
        // The clear() prefix is "<slotID>_<setIndex>_" so it must not
        // bleed into adjacent set indices for the same slot.
        let store = makeStore()
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .reps, value: "5")
        store.persist(slotID: slot, setIndex: 1, field: .reps, value: "6")

        store.clear(slotID: slot, setIndex: 0)

        XCTAssertNil(store.load(slotID: slot, setIndex: 0))
        XCTAssertEqual(store.load(slotID: slot, setIndex: 1)?.reps, "6")
    }

    func testClearAllRemovesAllDraftsForThisWorkout() {
        let store = makeStore()
        let slotA = UUID()
        let slotB = UUID()

        store.persist(slotID: slotA, setIndex: 0, field: .reps, value: "5")
        store.persist(slotID: slotB, setIndex: 2, field: .weight, value: "100")

        store.clearAll()

        XCTAssertNil(store.load(slotID: slotA, setIndex: 0))
        XCTAssertNil(store.load(slotID: slotB, setIndex: 2))
    }

    // MARK: - Cross-workout isolation

    func testTwoWorkoutsAreIsolatedInSameUserDefaults() {
        let workoutA = UUID()
        let workoutB = UUID()
        let storeA = makeStore(workoutID: workoutA)
        let storeB = makeStore(workoutID: workoutB)
        let slot = UUID()

        storeA.persist(slotID: slot, setIndex: 0, field: .reps, value: "5")

        XCTAssertEqual(storeA.load(slotID: slot, setIndex: 0)?.reps, "5")
        XCTAssertNil(storeB.load(slotID: slot, setIndex: 0))

        storeA.clearAll()
        storeB.persist(slotID: slot, setIndex: 0, field: .reps, value: "8")

        XCTAssertNil(storeA.load(slotID: slot, setIndex: 0))
        XCTAssertEqual(storeB.load(slotID: slot, setIndex: 0)?.reps, "8")
    }

    // MARK: - Empty-string sentinel

    func testEmptyStringPersistsAsEmptyStringNotNil() {
        // ActiveWorkoutView's "undo a logged parent set" path writes
        // log.weight.map { ... } ?? "" — i.e. an empty string sentinel for
        // body-weight exercises. The store must preserve "" distinctly
        // from "field absent" or that undo path silently loses the weight
        // value across a force-quit.
        let store = makeStore()
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .weight, value: "")

        let snap = store.load(slotID: slot, setIndex: 0)
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.weight, "")
    }

    // MARK: - Overwrite

    func testOverwriteSameFieldKeepsLatestValue() {
        let store = makeStore()
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 0, field: .reps, value: "5")
        store.persist(slotID: slot, setIndex: 0, field: .reps, value: "7")

        XCTAssertEqual(store.load(slotID: slot, setIndex: 0)?.reps, "7")
    }

    // MARK: - Corrupted UserDefaults entry

    func testCorruptedUserDefaultsEntryReadsAsNoDraftAndDoesNotCrash() {
        let workoutID = UUID()
        let store = makeStore(workoutID: workoutID)

        // Plant a wrong-typed value under the per-workout key.
        defaults.set(["mismatched": 42], forKey: "parentDrafts_\(workoutID.uuidString)")

        XCTAssertNil(store.load(slotID: UUID(), setIndex: 0))

        // A subsequent persist should still succeed (the bad value gets
        // overwritten with a fresh dict; we don't preserve the garbage).
        let slot = UUID()
        store.persist(slotID: slot, setIndex: 0, field: .reps, value: "5")
        XCTAssertEqual(store.load(slotID: slot, setIndex: 0)?.reps, "5")
    }

    // MARK: - Storage format pin

    func testStorageKeyFormatIsStable() {
        // This format is depended on by any user with an in-flight workout
        // when the app updates. If this assertion fails, somebody changed
        // the on-disk format — add a migration before merging.
        let workoutID = UUID()
        let store = makeStore(workoutID: workoutID)
        let slot = UUID()

        store.persist(slotID: slot, setIndex: 3, field: .weight, value: "100")

        let topKey = "parentDrafts_\(workoutID.uuidString)"
        let slotKey = "\(slot)_3_weight"
        let dict = defaults.dictionary(forKey: topKey) as? [String: String]
        XCTAssertEqual(dict?[slotKey], "100")
    }
}

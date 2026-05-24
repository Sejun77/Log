import XCTest

@testable import Log

/// Phase 10-polish-H (2026-05-24) — coverage for `CustomOptionStore`:
/// the trim / canonical-exclusion / case-insensitive-dedupe rules for
/// `add`, the swipe-to-delete index path through `remove(at:)`, the
/// value-based `remove(_:)`, persistence across instances, and the
/// invariant that the store never reaches into SwiftData (asserted by
/// running every test without a `ModelContext`).
///
/// Per-test isolation: each test gets a unique `UserDefaults(suiteName:)`
/// in setUp and tears it down in tearDown. The production singletons
/// (`CustomOptionStore.bodyParts`, `.equipment`) are never touched.
@MainActor
final class CustomOptionStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CustomOptionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let suite = suiteName, let d = defaults {
            d.removePersistentDomain(forName: suite)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore(key: String = "test-key") -> CustomOptionStore {
        CustomOptionStore(key: key, defaults: defaults)
    }

    // MARK: - add: trim + non-empty

    func testAddTrimsLeadingAndTrailingWhitespace() {
        let store = makeStore()
        XCTAssertTrue(store.add("   Forearms   ", excludingCanonical: []))
        XCTAssertEqual(store.options, ["Forearms"])
    }

    func testAddRejectsEmptyAndWhitespaceOnly() {
        let store = makeStore()
        XCTAssertFalse(store.add("", excludingCanonical: []))
        XCTAssertFalse(store.add("   ", excludingCanonical: []))
        XCTAssertFalse(store.add("\n\t", excludingCanonical: []))
        XCTAssertEqual(store.options, [])
    }

    // MARK: - add: case-insensitive dedupe

    func testAddRejectsCaseInsensitiveDuplicate() {
        let store = makeStore()
        XCTAssertTrue(store.add("Forearms", excludingCanonical: []))
        XCTAssertFalse(store.add("forearms", excludingCanonical: []))
        XCTAssertFalse(store.add("FOREARMS", excludingCanonical: []))
        XCTAssertFalse(store.add("  Forearms  ", excludingCanonical: []))
        XCTAssertEqual(store.options, ["Forearms"])
    }

    // MARK: - add: canonical exclusion

    func testAddRejectsCanonicalCaseInsensitive() {
        let store = makeStore()
        let canon = ["Chest", "Back", "Shoulders"]
        XCTAssertFalse(store.add("Chest", excludingCanonical: canon))
        XCTAssertFalse(store.add("chest", excludingCanonical: canon))
        XCTAssertFalse(store.add("  BACK  ", excludingCanonical: canon))
        XCTAssertEqual(store.options, [])
    }

    func testAddAcceptsNonCanonical() {
        let store = makeStore()
        let canon = ["Chest", "Back"]
        XCTAssertTrue(store.add("Forearms", excludingCanonical: canon))
        XCTAssertTrue(store.add("Grip", excludingCanonical: canon))
        XCTAssertEqual(store.options, ["Forearms", "Grip"])
    }

    // MARK: - persistence

    func testAddPersistsAcrossInstancesAtSameKey() {
        let s1 = makeStore(key: "shared-key")
        XCTAssertTrue(s1.add("Forearms", excludingCanonical: []))
        XCTAssertTrue(s1.add("Grip", excludingCanonical: []))

        // A second store at the same key reads the persisted value
        // — proves storage went through UserDefaults, not an in-memory
        // cache local to s1.
        let s2 = CustomOptionStore(key: "shared-key", defaults: defaults)
        XCTAssertEqual(s2.options, ["Forearms", "Grip"])
    }

    func testRemovePersists() {
        let s1 = makeStore(key: "shared-key")
        s1.add("A", excludingCanonical: [])
        s1.add("B", excludingCanonical: [])
        s1.remove("A")

        let s2 = CustomOptionStore(key: "shared-key", defaults: defaults)
        XCTAssertEqual(s2.options, ["B"])
    }

    // MARK: - remove(at:) — the .onDelete handler path

    func testRemoveAtSingleOffsetRemovesOnlyThatRow() {
        let store = makeStore()
        store.add("A", excludingCanonical: [])
        store.add("B", excludingCanonical: [])
        store.add("C", excludingCanonical: [])
        XCTAssertEqual(store.options, ["A", "B", "C"])

        store.remove(at: IndexSet(integer: 1))
        XCTAssertEqual(store.options, ["A", "C"])
    }

    func testRemoveAtMultipleOffsets() {
        let store = makeStore()
        for c in ["A", "B", "C", "D", "E"] {
            store.add(c, excludingCanonical: [])
        }
        // Indices 0 and 2 — "A" and "C". Result: ["B", "D", "E"].
        store.remove(at: IndexSet([0, 2]))
        XCTAssertEqual(store.options, ["B", "D", "E"])
    }

    func testRemoveAtOutOfBoundsIsTolerated() {
        let store = makeStore()
        store.add("Only", excludingCanonical: [])
        // Defensively passing an out-of-bounds index should not crash and
        // should leave the in-bounds entries intact.
        store.remove(at: IndexSet([5]))
        XCTAssertEqual(store.options, ["Only"])
    }

    // MARK: - remove(_:)

    func testRemoveByValueCaseInsensitive() {
        let store = makeStore()
        store.add("Forearms", excludingCanonical: [])
        store.add("Grip", excludingCanonical: [])

        store.remove("FOREARMS")
        XCTAssertEqual(store.options, ["Grip"])

        store.remove("  grip  ")
        XCTAssertEqual(store.options, [])
    }

    func testRemoveByValueMissingIsNoOp() {
        let store = makeStore()
        store.add("Forearms", excludingCanonical: [])
        store.remove("Nothing")
        XCTAssertEqual(store.options, ["Forearms"])
    }

    // MARK: - independence

    func testTwoStoresAtDifferentKeysDoNotShareData() {
        let bodyParts = makeStore(key: "k.body")
        let equipment = makeStore(key: "k.equip")

        bodyParts.add("Forearms", excludingCanonical: [])
        equipment.add("Landmine", excludingCanonical: [])

        XCTAssertEqual(bodyParts.options, ["Forearms"])
        XCTAssertEqual(equipment.options, ["Landmine"])
    }

    // MARK: - SwiftData isolation (encoded as a structural property)

    /// Removing an option from the store must not require, depend on, or
    /// touch any SwiftData state. The test runs with no `ModelContext`
    /// and no `ModelContainer`, so any silent SwiftData reach would
    /// surface here as a crash or thrown error. The fact that the test
    /// passes is the assertion: deletion is purely a UserDefaults-list
    /// mutation.
    func testRemoveDoesNotTouchSwiftDataState() {
        let store = makeStore()
        store.add("Forearms", excludingCanonical: [])
        store.remove("Forearms")
        XCTAssertEqual(store.options, [])
    }
}

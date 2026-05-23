import SwiftData
import XCTest

@testable import Log

/// Phase 6.C1 — `groupItemsBySourceBlock(_:)` is the pure partition
/// helper that the future Phase 6.C2 History display will consume.
/// These tests pin the contract on `SwiftDataTestHarness` because
/// `WorkoutItem` is an `@Model` and can't be value-typed.
@MainActor
final class WorkoutItemGroupingTests: SwiftDataTestHarness {

    // MARK: - Fixture

    /// Build a `WorkoutItem` with the four Phase 6.C1 snapshot fields
    /// optionally populated. The fixture deliberately does NOT attach
    /// the item to any `Workout` (the helper operates on a plain
    /// `[WorkoutItem]` array so the relationship is irrelevant).
    private func makeItem(
        name: String,
        sourceBlockSlotID: UUID? = nil,
        sourceBlockIsSuperset: Bool? = nil,
        sourceBlockOrder: Int? = nil,
        sourceExerciseOrderInBlock: Int? = nil
    ) -> WorkoutItem {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        let item = WorkoutItem(exercise: ex, setLogs: [])
        item.sourceBlockSlotID = sourceBlockSlotID
        item.sourceBlockIsSuperset = sourceBlockIsSuperset
        item.sourceBlockOrder = sourceBlockOrder
        item.sourceExerciseOrderInBlock = sourceExerciseOrderInBlock
        context.insert(item)
        return item
    }

    // MARK: - All flat (legacy nil + non-superset)

    func testAllFlatLegacyItemsBecomeSingletonGroups() {
        let a = makeItem(name: "A")
        let b = makeItem(name: "B")
        let c = makeItem(name: "C")

        let groups = groupItemsBySourceBlock([a, b, c])

        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.items.count == 1 })
        XCTAssertTrue(groups.allSatisfy { !$0.isSuperset })
        XCTAssertEqual(
            groups.map { $0.items.first?.exerciseNameSnapshot },
            ["A", "B", "C"],
            "legacy nil-order items preserve input order via stable tiebreaker"
        )
    }

    func testNonSupersetItemsWithSnapshotBecomeSingletonGroups() {
        // sourceBlockIsSuperset == false → each item is its own singleton
        // group regardless of whether they share a sourceBlockSlotID.
        let blockA = UUID()
        let blockB = UUID()
        let a = makeItem(
            name: "A",
            sourceBlockSlotID: blockA,
            sourceBlockIsSuperset: false,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )
        let b = makeItem(
            name: "B",
            sourceBlockSlotID: blockB,
            sourceBlockIsSuperset: false,
            sourceBlockOrder: 1,
            sourceExerciseOrderInBlock: 0
        )

        let groups = groupItemsBySourceBlock([a, b])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.isSuperset), [false, false])
        XCTAssertEqual(
            groups.map { $0.items.first?.exerciseNameSnapshot },
            ["A", "B"]
        )
    }

    // MARK: - One superset group

    func testSupersetMembersMergeIntoOneGroup() {
        let block = UUID()
        let a = makeItem(
            name: "Bench",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )
        let b = makeItem(
            name: "Fly",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 1
        )

        let groups = groupItemsBySourceBlock([a, b])

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isSuperset)
        XCTAssertEqual(groups[0].sourceBlockSlotID, block)
        XCTAssertEqual(groups[0].sourceBlockOrder, 0)
        XCTAssertEqual(
            groups[0].items.map(\.exerciseNameSnapshot),
            ["Bench", "Fly"]
        )
    }

    func testSupersetMembersSortByExerciseOrderInBlock() {
        // Insert in reversed order (B with order=1 first, then A with order=0)
        // and assert the group sorts to [A, B].
        let block = UUID()
        let b = makeItem(
            name: "Fly",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 1
        )
        let a = makeItem(
            name: "Bench",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )

        let groups = groupItemsBySourceBlock([b, a])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0].items.map(\.exerciseNameSnapshot),
            ["Bench", "Fly"],
            "intra-superset sort by sourceExerciseOrderInBlock (stable)"
        )
    }

    // MARK: - Mixed: one superset + standalones

    func testMixedSupersetAndStandalonesPartitionCorrectly() {
        let supersetBlock = UUID()
        let standaloneBlockA = UUID()
        let standaloneBlockB = UUID()

        let s1 = makeItem(
            name: "S1",
            sourceBlockSlotID: supersetBlock,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 1,
            sourceExerciseOrderInBlock: 0
        )
        let s2 = makeItem(
            name: "S2",
            sourceBlockSlotID: supersetBlock,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 1,
            sourceExerciseOrderInBlock: 1
        )
        let a = makeItem(
            name: "A",
            sourceBlockSlotID: standaloneBlockA,
            sourceBlockIsSuperset: false,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )
        let b = makeItem(
            name: "B",
            sourceBlockSlotID: standaloneBlockB,
            sourceBlockIsSuperset: false,
            sourceBlockOrder: 2,
            sourceExerciseOrderInBlock: 0
        )

        // Insert in mixed order (matches the user-jumps-around-the-plan case).
        let groups = groupItemsBySourceBlock([s1, a, s2, b])

        XCTAssertEqual(
            groups.count, 3,
            "two superset members merge; two standalones each remain a singleton"
        )
        // Sorted by sourceBlockOrder: A (0), superset (1), B (2)
        XCTAssertEqual(groups[0].items.map(\.exerciseNameSnapshot), ["A"])
        XCTAssertFalse(groups[0].isSuperset)
        XCTAssertEqual(
            groups[1].items.map(\.exerciseNameSnapshot),
            ["S1", "S2"]
        )
        XCTAssertTrue(groups[1].isSuperset)
        XCTAssertEqual(groups[2].items.map(\.exerciseNameSnapshot), ["B"])
        XCTAssertFalse(groups[2].isSuperset)
    }

    // MARK: - Legacy nil snapshot items

    func testLegacyNilItemsRemainStandaloneEvenAmongstSupersetItems() {
        let block = UUID()
        let legacy = makeItem(name: "Legacy")  // all snapshot fields nil
        let s1 = makeItem(
            name: "S1",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )
        let s2 = makeItem(
            name: "S2",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 1
        )

        let groups = groupItemsBySourceBlock([s1, legacy, s2])

        XCTAssertEqual(
            groups.count, 2,
            "the two superset members merge; the legacy item stays separate"
        )
        // Superset has sourceBlockOrder 0; legacy has nil → sorts last.
        XCTAssertTrue(groups[0].isSuperset)
        XCTAssertEqual(
            groups[0].items.map(\.exerciseNameSnapshot),
            ["S1", "S2"]
        )
        XCTAssertFalse(groups[1].isSuperset)
        XCTAssertEqual(groups[1].items.map(\.exerciseNameSnapshot), ["Legacy"])
        XCTAssertNil(groups[1].sourceBlockSlotID)
        XCTAssertNil(groups[1].sourceBlockOrder)
    }

    // MARK: - Interleaved insertion order with stable sort

    func testInterleavedInsertionOrderSortsByBlockOrder() {
        // Simulate a user who logged Block 2 before Block 0 before Block 1.
        let blockA = UUID()  // order 0
        let blockB = UUID()  // order 1 — superset
        let blockC = UUID()  // order 2

        let c = makeItem(
            name: "C",
            sourceBlockSlotID: blockC,
            sourceBlockIsSuperset: false,
            sourceBlockOrder: 2,
            sourceExerciseOrderInBlock: 0
        )
        let bExA = makeItem(
            name: "BExA",
            sourceBlockSlotID: blockB,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 1,
            sourceExerciseOrderInBlock: 0
        )
        let a = makeItem(
            name: "A",
            sourceBlockSlotID: blockA,
            sourceBlockIsSuperset: false,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )
        let bExB = makeItem(
            name: "BExB",
            sourceBlockSlotID: blockB,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 1,
            sourceExerciseOrderInBlock: 1
        )

        let groups = groupItemsBySourceBlock([c, bExA, a, bExB])

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.sourceBlockOrder), [0, 1, 2])
        XCTAssertEqual(groups[0].items.map(\.exerciseNameSnapshot), ["A"])
        XCTAssertEqual(
            groups[1].items.map(\.exerciseNameSnapshot),
            ["BExA", "BExB"],
            "superset members reunite + sort by sourceExerciseOrderInBlock"
        )
        XCTAssertEqual(groups[2].items.map(\.exerciseNameSnapshot), ["C"])
    }

    // MARK: - Empty input

    func testEmptyInputReturnsEmptyArray() {
        XCTAssertTrue(groupItemsBySourceBlock([]).isEmpty)
    }

    // MARK: - Single-member superset

    func testSingleMemberSupersetStillReportsIsSupersetTrue() {
        // A superset block that lost all but one member (unusual but
        // possible). Display layer decides how to render single-member
        // supersets; the helper just reports the snapshot honestly.
        let item = makeItem(
            name: "Solo",
            sourceBlockSlotID: UUID(),
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )

        let groups = groupItemsBySourceBlock([item])

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isSuperset)
        XCTAssertEqual(groups[0].items.count, 1)
    }

    // MARK: - Phase 6.C2 — `WorkoutItemGroup.id` (Identifiable)

    /// Superset groups must derive their `id` from `sourceBlockSlotID`
    /// so SwiftUI `ForEach` diffs the group as one stable identity
    /// across body re-renders. Two superset members of the same block
    /// share the same group id; superset groups in different blocks
    /// have distinct ids.
    func testGroupID_SupersetUsesSourceBlockSlotID() {
        let block = UUID()
        let a = makeItem(
            name: "A",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )
        let b = makeItem(
            name: "B",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 1
        )

        let groups = groupItemsBySourceBlock([a, b])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, AnyHashable(block))
    }

    /// Two superset groups with distinct source blocks must produce
    /// distinct group ids — protects against block-UUID collision
    /// at the ForEach diff layer.
    func testGroupID_DistinctSupersetsHaveDistinctBlockIDs() {
        let block1 = UUID()
        let block2 = UUID()
        let a1 = makeItem(
            name: "A1",
            sourceBlockSlotID: block1,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )
        let a2 = makeItem(
            name: "A2",
            sourceBlockSlotID: block1,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 1
        )
        let b1 = makeItem(
            name: "B1",
            sourceBlockSlotID: block2,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 1,
            sourceExerciseOrderInBlock: 0
        )
        let b2 = makeItem(
            name: "B2",
            sourceBlockSlotID: block2,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 1,
            sourceExerciseOrderInBlock: 1
        )

        let groups = groupItemsBySourceBlock([a1, a2, b1, b2])

        XCTAssertEqual(groups.count, 2)
        XCTAssertNotEqual(groups[0].id, groups[1].id)
    }

    /// Singleton (non-superset) groups derive their `id` from the
    /// first item's `ObjectIdentifier` so each row remains a stable,
    /// distinct ForEach identity. Two different items must produce
    /// different ids.
    func testGroupID_SingletonsUsePerItemIdentity() {
        let a = makeItem(
            name: "A",
            sourceBlockSlotID: UUID(),
            sourceBlockIsSuperset: false,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )
        let b = makeItem(
            name: "B",
            sourceBlockSlotID: UUID(),
            sourceBlockIsSuperset: false,
            sourceBlockOrder: 1,
            sourceExerciseOrderInBlock: 0
        )

        let groups = groupItemsBySourceBlock([a, b])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, AnyHashable(ObjectIdentifier(a)))
        XCTAssertEqual(groups[1].id, AnyHashable(ObjectIdentifier(b)))
        XCTAssertNotEqual(
            groups[0].id, groups[1].id,
            "two distinct singleton groups must have distinct ids"
        )
    }

    /// Legacy nil-snapshot items also fall through the singleton
    /// branch — `id` is the item's `ObjectIdentifier`, not block-based,
    /// even though `sourceBlockSlotID` is nil on the underlying
    /// `WorkoutItem`.
    func testGroupID_LegacyNilItemsUsePerItemIdentity() {
        let legacy = makeItem(name: "Legacy")  // all snapshot fields nil

        let groups = groupItemsBySourceBlock([legacy])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0].id, AnyHashable(ObjectIdentifier(legacy))
        )
    }

    /// Single-member superset groups still use block identity (the
    /// snapshot says it's a superset), even though the View layer
    /// chooses to render them flat. The helper's contract is
    /// "report the snapshot honestly"; ForEach identity follows.
    func testGroupID_SingleMemberSupersetUsesBlockIdentity() {
        let block = UUID()
        let solo = makeItem(
            name: "Solo",
            sourceBlockSlotID: block,
            sourceBlockIsSuperset: true,
            sourceBlockOrder: 0,
            sourceExerciseOrderInBlock: 0
        )

        let groups = groupItemsBySourceBlock([solo])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, AnyHashable(block))
    }
}

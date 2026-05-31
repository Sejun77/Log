import XCTest

@testable import Log

/// Pure tests for `ExerciseReorder`. No SwiftData harness — the helper is
/// value-in / value-out over `UUID` identities.
final class ExerciseReorderTests: XCTestCase {

    // Fixed ids so assertions read clearly. `a < ... < e` are arbitrary,
    // distinct UUIDs; the helper must never sort by them.
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()
    private let e = UUID()

    private var all: [UUID] { [a, b, c, d, e] }

    // MARK: - sendToTop

    func testMoveMiddleItemToTop() {
        XCTAssertEqual(ExerciseReorder.sendToTop(all, moving: c), [c, a, b, d, e])
    }

    func testAlreadyTopSendToTopIsStable() {
        XCTAssertEqual(ExerciseReorder.sendToTop(all, moving: a), all)
    }

    func testSendBottomItemToTop() {
        XCTAssertEqual(ExerciseReorder.sendToTop(all, moving: e), [e, a, b, c, d])
    }

    // MARK: - sendToBottom

    func testMoveMiddleItemToBottom() {
        XCTAssertEqual(ExerciseReorder.sendToBottom(all, moving: c), [a, b, d, e, c])
    }

    func testAlreadyBottomSendToBottomIsStable() {
        XCTAssertEqual(ExerciseReorder.sendToBottom(all, moving: e), all)
    }

    func testSendTopItemToBottom() {
        XCTAssertEqual(ExerciseReorder.sendToBottom(all, moving: a), [b, c, d, e, a])
    }

    // MARK: - Missing / empty / single

    func testMissingTargetReturnsUnchanged() {
        let missing = UUID()
        XCTAssertEqual(ExerciseReorder.sendToTop(all, moving: missing), all)
        XCTAssertEqual(ExerciseReorder.sendToBottom(all, moving: missing), all)
    }

    func testEmptyListReturnsEmpty() {
        XCTAssertEqual(ExerciseReorder.sendToTop([], moving: a), [])
        XCTAssertEqual(ExerciseReorder.sendToBottom([], moving: a), [])
    }

    func testSingleItemReturnsUnchanged() {
        XCTAssertEqual(ExerciseReorder.sendToTop([a], moving: a), [a])
        XCTAssertEqual(ExerciseReorder.sendToBottom([a], moving: a), [a])
    }

    // MARK: - Invariants

    func testRelativeOrderOfNonTargetItemsPreservedOnTop() {
        // Removing c from [a,b,c,d,e] must leave [a,b,d,e] in that order.
        let result = ExerciseReorder.sendToTop(all, moving: c)
        XCTAssertEqual(result.filter { $0 != c }, [a, b, d, e])
    }

    func testRelativeOrderOfNonTargetItemsPreservedOnBottom() {
        let result = ExerciseReorder.sendToBottom(all, moving: c)
        XCTAssertEqual(result.filter { $0 != c }, [a, b, d, e])
    }

    func testOutputIsPermutationNoLossOrDuplicate() {
        for target in all {
            let top = ExerciseReorder.sendToTop(all, moving: target)
            let bottom = ExerciseReorder.sendToBottom(all, moving: target)
            XCTAssertEqual(top.count, all.count)
            XCTAssertEqual(bottom.count, all.count)
            XCTAssertEqual(Set(top), Set(all))
            XCTAssertEqual(Set(bottom), Set(all))
        }
    }

    // MARK: - orderMap

    func testOrderMapIsContiguousZeroToN() {
        let map = ExerciseReorder.orderMap(for: all)
        XCTAssertEqual(map[a], 0)
        XCTAssertEqual(map[b], 1)
        XCTAssertEqual(map[c], 2)
        XCTAssertEqual(map[d], 3)
        XCTAssertEqual(map[e], 4)
        XCTAssertEqual(Set(map.values), Set(0..<all.count))
    }

    func testOrderMapEmptyIsEmpty() {
        XCTAssertTrue(ExerciseReorder.orderMap(for: []).isEmpty)
    }

    func testOrderMapReflectsReorderedSequence() {
        // After a reorder, the map gives the contiguous orders to persist.
        let reordered = ExerciseReorder.sendToTop(all, moving: d)  // [d,a,b,c,e]
        let map = ExerciseReorder.orderMap(for: reordered)
        XCTAssertEqual(map[d], 0)
        XCTAssertEqual(map[a], 1)
        XCTAssertEqual(map[e], 4)
    }
}

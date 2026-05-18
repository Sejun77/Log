import XCTest

@testable import Log

/// Phase 7 Slice 7.4 — pure unit tests for the rest-notification ID builder.
/// `RestTimer.stableNotificationID(workoutID:slotID:)` is the deterministic
/// key used by `AppState.activeRestSlotID`, `RestTimer.scheduleEndNotification`,
/// and `BootstrapRoot.validateActiveSession`'s cleanup path to identify a
/// single pending rest notification. Two consumers must agree on this string
/// or scheduled notifications won't be cancellable on workout end, so the
/// format is a public contract worth pinning in tests.
///
/// Note: the production signature takes a **non-optional `slotID: UUID`**.
/// "nil slotID" cases from the Phase 7.4 plan are not applicable to today's
/// API and would require an API change to introduce — out of scope for this
/// pure-test slice.
@MainActor
final class RestTimerTests: XCTestCase {

    func testSameWorkoutAndSlotProduceIdenticalID() {
        let workoutID = UUID()
        let slotID = UUID()

        let a = RestTimer.stableNotificationID(workoutID: workoutID, slotID: slotID)
        let b = RestTimer.stableNotificationID(workoutID: workoutID, slotID: slotID)

        XCTAssertEqual(a, b)
    }

    func testDifferentWorkoutIDProducesDifferentID() {
        let slotID = UUID()
        let workoutA = UUID()
        let workoutB = UUID()

        let a = RestTimer.stableNotificationID(workoutID: workoutA, slotID: slotID)
        let b = RestTimer.stableNotificationID(workoutID: workoutB, slotID: slotID)

        XCTAssertNotEqual(a, b)
    }

    func testDifferentSlotIDProducesDifferentID() {
        let workoutID = UUID()
        let slotA = UUID()
        let slotB = UUID()

        let a = RestTimer.stableNotificationID(workoutID: workoutID, slotID: slotA)
        let b = RestTimer.stableNotificationID(workoutID: workoutID, slotID: slotB)

        XCTAssertNotEqual(a, b)
    }

    func testIDIsNonEmpty() {
        let id = RestTimer.stableNotificationID(
            workoutID: UUID(),
            slotID: UUID()
        )

        XCTAssertFalse(id.isEmpty)
    }

    func testIDFormatStartsWithRestPrefix() {
        // Format is depended on implicitly by notification cancellation —
        // pinning it here makes any accidental format change a test failure.
        let id = RestTimer.stableNotificationID(
            workoutID: UUID(),
            slotID: UUID()
        )

        XCTAssertTrue(id.hasPrefix("rest."), "Got: \(id)")
    }

    func testIDContainsBothUUIDStrings() {
        let workoutID = UUID()
        let slotID = UUID()

        let id = RestTimer.stableNotificationID(
            workoutID: workoutID,
            slotID: slotID
        )

        XCTAssertTrue(
            id.contains(workoutID.uuidString),
            "Expected \(workoutID.uuidString) in \(id)"
        )
        XCTAssertTrue(
            id.contains(slotID.uuidString),
            "Expected \(slotID.uuidString) in \(id)"
        )
    }

    func testSwappedWorkoutAndSlotProducesDifferentID() {
        // Defensive: even when both UUIDs are present, swapping which one is
        // the "workout" vs "slot" must produce a different string. Guards
        // against a future refactor that accidentally drops the positional
        // structure of the format.
        let a = UUID()
        let b = UUID()

        let forward = RestTimer.stableNotificationID(workoutID: a, slotID: b)
        let swapped = RestTimer.stableNotificationID(workoutID: b, slotID: a)

        XCTAssertNotEqual(forward, swapped)
    }
}

import XCTest

@testable import Log

/// Regression cover for the background/foreground timer bug: `ActiveWorkoutView`
/// runs two `RestTimer` instances — `rest` (real between-sets rest) and
/// `setTimer` (duration-based sets) — which used to persist to one global set
/// of UserDefaults keys. A running duration set therefore rehydrated into the
/// *rest* timer on foreground, so reopening the app during a timed hold
/// presented the rest overlay ("Rest") driven by the duration countdown, while
/// the toolbar's own "Duration: Ns" text stayed frozen at its pre-background
/// value.
///
/// These tests pin the two halves of the fix:
///   • each instance persists to, and resumes from, its own namespace, and
///   • a resumed countdown is re-derived from the persisted wall-clock end
///     date rather than the suspended in-memory tick counter.
@MainActor
final class RestTimerNamespaceTests: XCTestCase {

    private func clearAllNamespaces() {
        RestTimer.clearPersistedStateAndNotifications()
    }

    override func setUp() {
        super.setUp()
        clearAllNamespaces()
    }

    override func tearDown() {
        clearAllNamespaces()
        super.tearDown()
    }

    // MARK: - Namespace isolation

    func testRestAndSetNamespacesAreDistinct() {
        XCTAssertNotEqual(RestTimer.Namespace.rest, RestTimer.Namespace.set)
    }

    func testRestNamespaceKeepsOriginalKeyPrefix() {
        // Changing this strands any rest countdown persisted by a previous
        // build mid-workout, so it is a compatibility contract.
        XCTAssertEqual(RestTimer.Namespace.rest, "restTimer")
    }

    func testDefaultNamespaceIsRest() {
        XCTAssertEqual(RestTimer().storeNamespace, RestTimer.Namespace.rest)
    }

    /// The exact reported bug: a running duration set must not reappear as a
    /// rest countdown after background → foreground.
    func testRunningSetTimerDoesNotRehydrateIntoRestTimer() {
        let setTimer = RestTimer(namespace: RestTimer.Namespace.set)
        setTimer.start(seconds: 90, mode: .set)

        // Fresh rest instance = the rest timer coming back on foreground.
        let rest = RestTimer(namespace: RestTimer.Namespace.rest)
        rest.resumeIfScheduled()

        XCTAssertFalse(
            rest.isRunning,
            "Rest timer rehydrated the duration set's countdown"
        )
        XCTAssertEqual(rest.remaining, 0)
        XCTAssertNil(rest.runningMode)

        setTimer.stop()
    }

    /// The mirror case: a real rest must not leak into the duration timer.
    func testRunningRestTimerDoesNotRehydrateIntoSetTimer() {
        let rest = RestTimer(namespace: RestTimer.Namespace.rest)
        rest.start(seconds: 60, mode: .rest)

        let setTimer = RestTimer(namespace: RestTimer.Namespace.set)
        setTimer.resumeIfScheduled()

        XCTAssertFalse(setTimer.isRunning)
        XCTAssertNil(setTimer.runningMode)

        rest.stop()
    }

    /// Both can run at once (rest started while a timed hold is counting);
    /// each must survive foreground as itself.
    func testConcurrentTimersEachResumeTheirOwnCountdown() {
        let rest = RestTimer(namespace: RestTimer.Namespace.rest)
        let setTimer = RestTimer(namespace: RestTimer.Namespace.set)

        rest.start(seconds: 45, mode: .rest)
        setTimer.start(seconds: 120, mode: .set)

        let restAfterForeground = RestTimer(
            namespace: RestTimer.Namespace.rest
        )
        let setAfterForeground = RestTimer(namespace: RestTimer.Namespace.set)
        restAfterForeground.resumeIfScheduled()
        setAfterForeground.resumeIfScheduled()

        XCTAssertTrue(restAfterForeground.isRunning)
        XCTAssertEqual(restAfterForeground.total, 45)
        XCTAssertTrue(setAfterForeground.isRunning)
        XCTAssertEqual(setAfterForeground.total, 120)

        rest.stop()
        setTimer.stop()
        restAfterForeground.stop()
        setAfterForeground.stop()
    }

    // MARK: - Wall-clock resume (the "catch up" half)

    /// A resumed countdown reads its remaining time from the persisted end
    /// date, not from a counter that stopped ticking in the background.
    func testResumeDerivesRemainingFromPersistedEndDate() {
        let setTimer = RestTimer(namespace: RestTimer.Namespace.set)
        setTimer.start(seconds: 300, mode: .set)

        let resumed = RestTimer(namespace: RestTimer.Namespace.set)
        resumed.resumeIfScheduled()

        XCTAssertTrue(resumed.isRunning)
        XCTAssertEqual(resumed.total, 300)
        // Wall-clock derived: within a second of the full duration, and never
        // the 0 an unstarted in-memory counter would report.
        XCTAssertGreaterThan(resumed.remaining, 297)
        XCTAssertLessThanOrEqual(resumed.remaining, 300)

        setTimer.stop()
        resumed.stop()
    }

    /// A countdown whose end date passed while the app was away resumes as
    /// finished rather than resuming a stale positive remainder.
    func testExpiredCountdownDoesNotResume() {
        let ud = UserDefaults.standard
        let past = Date().addingTimeInterval(-30).timeIntervalSince1970
        ud.set(past, forKey: "\(RestTimer.Namespace.set).endDate")
        ud.set(60, forKey: "\(RestTimer.Namespace.set).total")
        ud.set("set", forKey: "\(RestTimer.Namespace.set).mode")

        let resumed = RestTimer(namespace: RestTimer.Namespace.set)
        resumed.resumeIfScheduled()

        XCTAssertFalse(resumed.isRunning)
        XCTAssertEqual(resumed.remaining, 0)
    }

    func testStopClearsOnlyItsOwnNamespace() {
        let rest = RestTimer(namespace: RestTimer.Namespace.rest)
        let setTimer = RestTimer(namespace: RestTimer.Namespace.set)
        rest.start(seconds: 60, mode: .rest)
        setTimer.start(seconds: 60, mode: .set)

        rest.stop()

        let setAfter = RestTimer(namespace: RestTimer.Namespace.set)
        setAfter.resumeIfScheduled()
        XCTAssertTrue(
            setAfter.isRunning,
            "Stopping rest wiped the duration timer's persisted state"
        )

        setTimer.stop()
        setAfter.stop()
    }

    /// Workout end / discard clears every namespace, so the next session can
    /// never inherit a countdown.
    func testClearPersistedStateClearsEveryNamespace() {
        let rest = RestTimer(namespace: RestTimer.Namespace.rest)
        let setTimer = RestTimer(namespace: RestTimer.Namespace.set)
        rest.start(seconds: 60, mode: .rest)
        setTimer.start(seconds: 60, mode: .set)

        RestTimer.clearPersistedStateAndNotifications()

        let restAfter = RestTimer(namespace: RestTimer.Namespace.rest)
        let setAfter = RestTimer(namespace: RestTimer.Namespace.set)
        restAfter.resumeIfScheduled()
        setAfter.resumeIfScheduled()

        XCTAssertFalse(restAfter.isRunning)
        XCTAssertFalse(setAfter.isRunning)

        rest.stop()
        setTimer.stop()
    }

    // MARK: - Rest-only presentation

    /// `runningMode` is the seam rest-specific UI keys off. A duration
    /// countdown must never report `.rest`, or it would earn the rest overlay
    /// title, the rest notification, and the Live Activity.
    func testRunningModeReportsRestOnlyForActualRest() {
        let rest = RestTimer(namespace: RestTimer.Namespace.rest)
        rest.start(seconds: 30, mode: .rest)
        XCTAssertEqual(rest.runningMode, .rest)
        rest.stop()

        let setTimer = RestTimer(namespace: RestTimer.Namespace.set)
        setTimer.start(seconds: 30, mode: .set)
        XCTAssertEqual(setTimer.runningMode, .set)
        XCTAssertNotEqual(
            setTimer.runningMode,
            .rest,
            "Duration countdown claimed rest presentation"
        )
        setTimer.stop()
    }

    func testIdleTimerHasNoRunningMode() {
        let rest = RestTimer(namespace: RestTimer.Namespace.rest)
        XCTAssertNil(rest.runningMode)

        rest.start(seconds: 30, mode: .rest)
        rest.stop()
        XCTAssertNil(rest.runningMode, "Stopped rest still claims a mode")
    }

    /// Resuming preserves the role, so a rehydrated rest is still presented as
    /// rest and a rehydrated duration set still is not.
    func testResumePreservesMode() {
        let setTimer = RestTimer(namespace: RestTimer.Namespace.set)
        setTimer.start(seconds: 120, mode: .set)

        let resumed = RestTimer(namespace: RestTimer.Namespace.set)
        resumed.resumeIfScheduled()
        XCTAssertEqual(resumed.runningMode, .set)

        setTimer.stop()
        resumed.stop()
    }

    /// Unchanged-behavior guard for real rest: it still persists, still
    /// rehydrates on foreground, and still reports rest so the "Rest" wording
    /// and the rest notification continue to apply.
    func testActualRestStillResumesAsRest() {
        let rest = RestTimer(namespace: RestTimer.Namespace.rest)
        rest.start(seconds: 90, mode: .rest)

        let resumed = RestTimer(namespace: RestTimer.Namespace.rest)
        resumed.resumeIfScheduled()

        XCTAssertTrue(resumed.isRunning)
        XCTAssertEqual(resumed.runningMode, .rest)
        XCTAssertEqual(resumed.total, 90)
        XCTAssertGreaterThan(resumed.remaining, 87)

        rest.stop()
        resumed.stop()
    }
}

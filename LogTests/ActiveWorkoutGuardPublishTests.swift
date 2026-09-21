import Combine
import XCTest

@testable import Log

/// Pins the reason the reps / weight / duration fields were slow everywhere in
/// the app, not just on the workout screen.
///
/// `ActiveWorkoutView` rewrites `inputsCache` and `loggedCache` on **every**
/// character typed into a set-input field (`syncToGuardCaches`). Nine views
/// hold `ActiveWorkoutGuard.shared` as an `@ObservedObject` — RootTabView,
/// RoutinesView, ExercisesView and its detail host, HistoryView and its detail,
/// RoutineEditor, StartWorkoutFromRoutineView, and the active workout itself —
/// so while those two properties were `@Published`, one keystroke sent two
/// `objectWillChange` notifications through the whole tab hierarchy, several of
/// whose bodies re-read `@Query` results over the entire store.
///
/// Neither cache is rendered: both are read imperatively on appear
/// (`syncFromGuardCachesIfAny`, `ensureInputsInitializedFromPlan`). Dropping
/// the wrapper is therefore invisible to every observer, and this test fails if
/// someone puts it back.
@MainActor
final class ActiveWorkoutGuardPublishTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        ActiveWorkoutGuard.shared.endSession()
        super.tearDown()
    }

    /// Replays `syncToGuardCaches()` once per character of a two-digit reps
    /// entry and asserts the singleton stays quiet.
    func testWritingInputCachesDoesNotNotifyObservers() {
        let sut = ActiveWorkoutGuard.shared
        var publishes = 0
        sut.objectWillChange
            .sink { _ in publishes += 1 }
            .store(in: &cancellables)

        let slot = UUID()
        for keystroke in ["1", "12"] {
            var inputs = sut.inputsCache
            inputs[slot, default: [:]][0] = (
                reps: keystroke, weight: "60", duration: ""
            )
            sut.inputsCache = inputs
            // `syncToGuardCaches()` assigns both caches every time, whether or
            // not the logged set changed.
            let logged = sut.loggedCache
            sut.loggedCache = logged
        }

        XCTAssertEqual(
            publishes, 0,
            """
            Assigning the session input caches notified every observing view. \
            These caches are never rendered — if one of them needs to drive UI, \
            give that screen its own observable state instead of re-adding \
            @Published here, or typing a set will invalidate the whole tab \
            hierarchy again.
            """
        )
    }

    /// The caches still have to carry their values across navigation — that is
    /// the only thing they are for.
    func testInputCachesStillRoundTripValues() {
        let sut = ActiveWorkoutGuard.shared
        let slot = UUID()

        sut.inputsCache[slot] = [0: (reps: "8", weight: "60", duration: "")]
        sut.loggedCache[slot] = [0, 1]

        XCTAssertEqual(sut.inputsCache[slot]?[0]?.reps, "8")
        XCTAssertEqual(sut.inputsCache[slot]?[0]?.weight, "60")
        XCTAssertEqual(sut.loggedCache[slot], [0, 1])
    }

    /// Lock and session state stay observable — those *are* rendered (the
    /// "In use" affordances and the resume banner).
    func testLockChangesStillNotifyObservers() {
        let sut = ActiveWorkoutGuard.shared
        var publishes = 0
        sut.objectWillChange
            .sink { _ in publishes += 1 }
            .store(in: &cancellables)

        sut.lockRoutine(UUID())

        XCTAssertGreaterThan(
            publishes, 0,
            "Lock state drives visible UI and must stay published.")
    }

    /// The properties the other eight observers actually render.
    ///
    /// An audit of every `inputsCache` / `loggedCache` use found all of them
    /// inside `ActiveWorkoutView` and all of them either `.onAppear` reads or
    /// plain writes — nothing renders from them, which is why dropping
    /// `@Published` there is safe. What the other views *do* render is session
    /// state: RootTabView's resume banner and session clock read `activePlan` /
    /// `activeWorkoutID` / `sessionStart`, and RoutinesView, ExercisesView,
    /// RoutineEditor and StartWorkoutFromRoutineView read the lock sets. Those
    /// must keep publishing, so pin it here — this is the half of the object a
    /// future "make it all non-published" pass must not touch.
    func testSessionStateChangesStillNotifyObservers() {
        let sut = ActiveWorkoutGuard.shared
        var publishes = 0
        sut.objectWillChange
            .sink { _ in publishes += 1 }
            .store(in: &cancellables)

        sut.activeWorkoutID = UUID()
        XCTAssertGreaterThan(
            publishes, 0, "`activeWorkoutID` drives the resume banner.")

        let afterID = publishes
        sut.sessionStart = Date()
        XCTAssertGreaterThan(
            publishes, afterID, "`sessionStart` drives the session clock.")
    }

    /// Ending a session has to reach the observers that render the "In use"
    /// affordances and the resume banner, even though the two caches it also
    /// clears no longer publish on their own.
    func testEndSessionStillNotifiesObservers() {
        let sut = ActiveWorkoutGuard.shared
        sut.activeWorkoutID = UUID()
        sut.sessionStart = Date()
        sut.lockRoutine(UUID())

        var publishes = 0
        sut.objectWillChange
            .sink { _ in publishes += 1 }
            .store(in: &cancellables)

        sut.endSession()

        XCTAssertGreaterThan(
            publishes, 0,
            "endSession() stopped notifying observers. The locks and session "
                + "fields it clears are rendered by RootTabView, RoutinesView, "
                + "ExercisesView and RoutineEditor — they would keep showing a "
                + "workout that has ended."
        )
    }

    func testEndSessionStillClearsCaches() {
        let sut = ActiveWorkoutGuard.shared
        let slot = UUID()
        sut.inputsCache[slot] = [0: (reps: "8", weight: "60", duration: "")]
        sut.loggedCache[slot] = [0]

        sut.endSession()

        XCTAssertTrue(sut.inputsCache.isEmpty)
        XCTAssertTrue(sut.loggedCache.isEmpty)
    }
}

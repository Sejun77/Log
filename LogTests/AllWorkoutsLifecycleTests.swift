import Combine
import SwiftData
import SwiftUI
import XCTest

@testable import Log

/// Guards the cost of `AllWorkoutsView` against the size of the history.
///
/// A pushed All Workouts screen stays alive when the user switches tabs instead
/// of going Back, and it re-evaluates on every save made during a workout. When
/// it summarized every workout on each evaluation, logging one set blocked the
/// main thread for over a second with about 220 workouts.
///
/// These tests count workouts scanned rather than measure time, so they do not
/// depend on machine speed. They render the real view in a real window, because
/// `List`'s laziness is the behavior under test.
@MainActor
final class AllWorkoutsLifecycleTests: SwiftDataTestHarness {

    /// History size. Must stay well above `maxScansPerStep`, so that scanning the
    /// whole history cannot pass.
    private let workoutCount = 300

    /// Upper limit on scans in one step: a screenful of rows, built a few times
    /// over. Scales with the screen, never with the history.
    private let maxScansPerStep = 150

    private var window: UIWindow?

    /// Rendered `@Query`s outlive their test by an unpredictable time and trap if
    /// a later save reaches them after their container is gone.
    private static var retainedContainers: [ModelContainer] = []
    private static var didRenderFirstList = false

    override func tearDown() {
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        Self.retainedContainers.append(container)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Mirrors the app's shape: All Workouts pushed on a stack inside a tab.
    private final class HostState: ObservableObject {
        @Published var tab = 0
        @Published var isAllWorkoutsPushed = false
    }

    private struct Host: View {
        @ObservedObject var state: HostState

        var body: some View {
            TabView(selection: $state.tab) {
                NavigationStack {
                    Text("History")
                        .navigationDestination(isPresented: $state.isAllWorkoutsPushed) {
                            AllWorkoutsView()
                        }
                }
                .tabItem { Text("History") }
                .tag(0)

                Text("Routines")
                    .tabItem { Text("Routines") }
                    .tag(1)
            }
        }
    }

    private func seedHistory() throws -> Workout {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let exercise = Exercise(name: "Bench Press", isCustom: true)
        context.insert(exercise)
        var newest: Workout?
        for i in 0..<workoutCount {
            let log = SetLog(indexInExercise: 0, kind: .working, reps: 8, weight: 100)
            let item = WorkoutItem(exercise: exercise, setLogs: [log])
            let workout = Workout(
                date: base.addingTimeInterval(-Double(i) * 86_400),
                items: [item]
            )
            context.insert(workout)
            if i == 0 { newest = workout }
        }
        try context.save()
        return try XCTUnwrap(newest)
    }

    private func show(_ state: HostState) throws {
        try renderFirstListInProcess()
        window = try makeWindow(showing: Host(state: state).modelContainer(container))
        settle()
    }

    /// The first `List` rendered in a test process builds every row, 4,000+ scans
    /// over 300 workouts, against 22 for the same screen afterward. The real app
    /// does not do this: its first open of All Workouts builds 18 rows. Rendering
    /// an unrelated list first keeps that out of the counts.
    private func renderFirstListInProcess() throws {
        guard !Self.didRenderFirstList else { return }
        Self.didRenderFirstList = true
        let warmUp = try makeWindow(
            showing: NavigationStack { List(0..<3, id: \.self) { Text("\($0)") } }
        )
        settle()
        warmUp.rootViewController = nil
        warmUp.isHidden = true
    }

    private func makeWindow<Content: View>(showing content: Content) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first,
            "The test host has no window scene to render in."
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        return window
    }

    /// Lets SwiftUI process pending invalidations, navigation and tab changes.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }

    private func logSet(to workout: Workout) throws {
        let item = try XCTUnwrap(workout.items.first)
        item.setLogs.append(
            SetLog(indexInExercise: item.setLogs.count, kind: .working, reps: 8, weight: 100)
        )
        try context.save()
        settle()
    }

    /// Scans made by `work`.
    private func scans(during work: () throws -> Void) rethrows -> Int {
        let start = WorkoutSummary.workoutScanCountForTesting
        try work()
        return WorkoutSummary.workoutScanCountForTesting - start
    }

    // MARK: - Tests

    /// Uses the cheapest of three opens. Under the test host an open occasionally
    /// builds far more rows, for no established reason; 20 launches of the real app
    /// on a copy of a 218-workout store each built 18. Summarizing the whole history
    /// costs at least `workoutCount` on every open, so it still fails here.
    ///
    /// This guards the usual cost only. It does not establish worst-case performance:
    /// an expensive open is ignored as long as one of the three is cheap.
    func test_opening_scansOnlyBuiltRows() throws {
        _ = try seedHistory()
        let state = HostState()
        try show(state)

        var opens: [Int] = []
        for _ in 0..<3 {
            opens.append(
                scans {
                    state.isAllWorkoutsPushed = true
                    settle()
                })
            state.isAllWorkoutsPushed = false
            settle()
        }

        let cheapest = try XCTUnwrap(opens.min())
        XCTAssertGreaterThan(cheapest, 0, "All Workouts never rendered a row.")
        XCTAssertLessThanOrEqual(cheapest, maxScansPerStep, "Scans per open: \(opens)")
    }

    func test_savesAfterTabSwitch_scanOnlyBuiltRows() throws {
        let newest = try seedHistory()
        let state = HostState()
        try show(state)
        state.isAllWorkoutsPushed = true
        settle()

        state.tab = 1
        settle()

        for _ in 0..<3 {
            let scanned = try scans { try logSet(to: newest) }
            XCTAssertLessThanOrEqual(scanned, maxScansPerStep)
        }
    }

    func test_savesAfterBack_scanNothing() throws {
        let newest = try seedHistory()
        let state = HostState()
        try show(state)
        state.isAllWorkoutsPushed = true
        settle()

        state.isAllWorkoutsPushed = false
        settle()
        state.tab = 1
        settle()

        let scanned = try scans { try logSet(to: newest) }
        XCTAssertEqual(scanned, 0, "All Workouts stayed alive after Back.")
    }
}

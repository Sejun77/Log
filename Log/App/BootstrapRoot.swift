import SwiftData
import SwiftUI

struct BootstrapRoot: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var ctx

    // MARK: - Static (test-only)

    /// Ensures UI test data reset runs only once per test session.
    private static var didResetUITestData = false

    // MARK: - State

    @State private var isLoading = true
    @State private var launchStart = Date()

    // MARK: - Environment Flags

    /// Returns true when running under UI tests (Xcode launch argument).
    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    // MARK: - Body

    var body: some View {
        RootTabView()
            // Prevent the tab view itself from animating when loading finishes.
            .animation(.none, value: isLoading)
            .overlay {
                LoadingView()
                    .opacity(isLoading ? 1 : 0)
                    // Fade only the opacity of the overlay.
                    .animation(.easeOut(duration: 1.0), value: isLoading)
                    // Ensure the overlay covers the entire UI.
                    .modifier(IgnoreAllSafeAreas())
                    // Block taps while loading is visible.
                    .allowsHitTesting(isLoading)
            }
            .task {
                launchStart = Date()

                // For UI tests, reset the data store once per session.
                if isUITesting && !Self.didResetUITestData {
                    await resetDataForUITests()
                    Self.didResetUITestData = true
                }

                // Enforce a minimum splash duration only for real users.
                if !isUITesting {
                    let elapsed = Date().timeIntervalSince(launchStart)
                    let remaining = max(0, 1.5 - elapsed)
                    if remaining > 0 {
                        try? await Task.sleep(
                            nanoseconds: UInt64(remaining * 1_000_000_000)
                        )
                    }
                }

                isLoading = false
            }
    }

    // MARK: - Test Data Reset

    /// Clears all persistent data for UI tests so each run starts clean.
    @MainActor
    private func resetDataForUITests() async {
        deleteAll(SetLog.self)
        deleteAll(WorkoutItem.self)
        deleteAll(Workout.self)
        deleteAll(Routine.self)
        deleteAll(RoutineBlock.self)
        deleteAll(RoutineExercise.self)
        deleteAll(SetTemplate.self)
        deleteAll(Exercise.self)
        try? ctx.save()
    }

    /// Deletes all instances of a given SwiftData model type.
    private func deleteAll<T: PersistentModel>(_ type: T.Type) {
        if let all = try? ctx.fetch(FetchDescriptor<T>()) {
            all.forEach { ctx.delete($0) }
        }
    }
}

// MARK: - Safe-Area Ignoring Modifier

/// Ensures the overlay covers the whole screen, including the tab bar.
/// Uses the iOS 17 `.container` behavior when available.
private struct IgnoreAllSafeAreas: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.ignoresSafeArea(.container, edges: .all)
        } else {
            content.ignoresSafeArea(.all)
        }
    }
}

import SwiftData
import SwiftUI

@main
@MainActor
struct LogApp: App {

    // MARK: - Notification State

    /// Ensures we only request notification authorization once per app launch.
    private static var didRequestNotifications = false

    // MARK: - Environment Flags

    /// Returns true when running under UI tests (Xcode launch argument).
    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    // MARK: - Init

    init() {
        // Configure notification handling once at app startup.
        AppNotificationService.shared.configure()
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            BootstrapRoot()
                // Global app font (Manrope) for all views.
                .environment(\.font, .custom("Manrope-Regular", size: 16))
                // Request notifications once, outside of UI tests.
                .task {
                    if !isUITesting && !Self.didRequestNotifications {
                        await AppNotificationService
                            .requestAuthorizationIfNeeded()
                        Self.didRequestNotifications = true
                    }
                }
                // Global accent / tint color.
                .tint(DSColor.brand)
        }
        .modelContainer(for: [
            Exercise.self,
            SetTemplate.self,
            RoutineExercise.self,
            RoutineBlock.self,
            RoutineVariant.self,
            Routine.self,
            SetLog.self,
            WorkoutItem.self,
            Workout.self,
        ])
    }
}

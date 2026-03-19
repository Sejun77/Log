import SwiftData
import SwiftUI

struct RootTabView: View {
    // MARK: - Tab Model

    enum Tab: Hashable {
        case routines
        case exercises
        case history
        case settings
    }

    // MARK: - Environment

    @Environment(\.modelContext) private var ctx
    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    // MARK: - State

    @State private var selection: Tab = .routines
    @State private var didCheckResume = false
    @State private var triggerResumeNavigation = false
    @State private var showResumeFailedAlert = false

    // MARK: - Body

    var body: some View {
        TabView(selection: $selection) {
            routinesTab
            exercisesTab
            historyTab
            settingsTab
        }
        // Use your brand color for the selected tab icon/label
        .tint(DSColor.brand)
        // Unified background for the whole tab interface
        .background(
            DSColor.bg
                .ignoresSafeArea()
        )
        .task {
            guard !didCheckResume else { return }
            didCheckResume = true
            checkForActiveSession()
        }
        .alert(
            "Could not resume workout",
            isPresented: $showResumeFailedAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "The previous workout could not be restored. It may have been deleted."
            )
        }
    }

    // MARK: - Tabs

    private var routinesTab: some View {
        RoutinesView(resumeNavigationTrigger: $triggerResumeNavigation)
            .tag(Tab.routines)
            .tabItem {
                Label("Routines", systemImage: "list.bullet.rectangle")
            }
    }

    private var exercisesTab: some View {
        ExercisesView()
            .tag(Tab.exercises)
            .tabItem {
                Label("Exercises", systemImage: "dumbbell")
            }
    }

    private var historyTab: some View {
        HistoryView()
            .tag(Tab.history)
            .tabItem {
                Label("History", systemImage: "calendar")
            }
    }

    private var settingsTab: some View {
        SettingsView()
            .tag(Tab.settings)
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
    }

    // MARK: - Resume Check

    private func checkForActiveSession() {
        // Skip if there's already an active in-memory session
        guard activeGuard.activePlan == nil else { return }

        let appState = BootstrapRoot.fetchOrCreateAppState(in: ctx)
        guard appState.workoutState == .active,
              let workoutID = appState.activeWorkoutID
        else { return }

        // Fetch the workout
        let descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.id == workoutID }
        )
        guard let workout = try? ctx.fetch(descriptor).first else {
            // Workout is gone — reset state + clear orphaned rest
            clearOrphanedRestState(
                appState: appState, workoutID: workoutID
            )
            appState.workoutState = .idle
            appState.activeWorkoutID = nil
            appState.activeWorkoutStartedAt = nil
            appState.activeRestEndsAt = nil
            appState.activeRestSlotID = nil
            try? ctx.save()
            return
        }

        // Rebuild the plan
        guard let plan = WorkoutResumeService.rebuildPlan(
            for: workout, in: ctx
        ) else {
            clearOrphanedRestState(
                appState: appState, workoutID: workoutID
            )
            appState.workoutState = .idle
            appState.activeWorkoutID = nil
            appState.activeWorkoutStartedAt = nil
            appState.activeRestEndsAt = nil
            appState.activeRestSlotID = nil
            try? ctx.save()
            showResumeFailedAlert = true
            return
        }

        // Restore in-memory state and navigate inside the Routines tab
        activeGuard.activeWorkoutID = workoutID
        activeGuard.sessionStart = appState.activeWorkoutStartedAt
        activeGuard.beginSession(plan: plan)

        selection = .routines
        triggerResumeNavigation = true
    }

    /// Clears orphaned rest timer persistence (UserDefaults + notifications)
    /// when the session is being reset without going through ActiveWorkoutView.
    private func clearOrphanedRestState(
        appState: AppState,
        workoutID: UUID
    ) {
        var ids: [String] = []
        if let slotID = appState.activeRestSlotID {
            ids.append(
                RestTimer.stableNotificationID(
                    workoutID: workoutID, slotID: slotID
                )
            )
        }
        RestTimer.clearPersistedStateAndNotifications(
            cancelNotificationIDs: ids
        )
    }
}

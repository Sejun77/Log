import SwiftData
import SwiftUI

struct RootTabView: View {
    // MARK: - Tab Model

    enum Tab: Hashable {
        case routines
        case exercises
        case history
    }

    // MARK: - Environment

    @Environment(\.modelContext) private var ctx
    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    // MARK: - State

    @State private var selection: Tab = .routines
    @State private var resumePlan: WorkoutPlan?
    @State private var showResumedWorkout = false
    @State private var didCheckResume = false

    // MARK: - Body

    var body: some View {
        TabView(selection: $selection) {
            routinesTab
            exercisesTab
            historyTab
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
        .fullScreenCover(isPresented: $showResumedWorkout) {
            if let plan = resumePlan {
                NavigationStack {
                    ActiveWorkoutView(plan: plan)
                }
            }
        }
    }

    // MARK: - Tabs

    private var routinesTab: some View {
        RoutinesView()
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
            // Workout is gone — reset state
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
            appState.workoutState = .idle
            appState.activeWorkoutID = nil
            appState.activeWorkoutStartedAt = nil
            appState.activeRestEndsAt = nil
            appState.activeRestSlotID = nil
            try? ctx.save()
            return
        }

        // Restore in-memory state
        activeGuard.activeWorkoutID = workoutID
        activeGuard.sessionStart = appState.activeWorkoutStartedAt

        resumePlan = plan
        showResumedWorkout = true
    }
}

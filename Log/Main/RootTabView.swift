import SwiftUI

struct RootTabView: View {
    // MARK: - Tab Model

    enum Tab: Hashable {
        case routines
        case exercises
        case history
    }

    // MARK: - State

    @State private var selection: Tab = .routines

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
}

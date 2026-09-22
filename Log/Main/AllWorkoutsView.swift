import SwiftData
import SwiftUI

/// The complete reverse-chronological workout history.
///
/// The root History page lists only `HistoryDisplay.recentWorkoutLimit`
/// workouts so the page keeps a constant height as history grows; this screen
/// is where the rest live. It is deliberately a plain list and nothing else —
/// no calendar, no chart, no filtering — because its whole job is the one thing
/// the root page gave up.
///
/// Rows come from the shared `WorkoutRow`, so appearance, navigation into
/// `WorkoutDetailView`, and the delete / blocked-delete swipe behavior are
/// identical to the root page by construction. The two alerts are owned here,
/// matching `HistoryView`'s own pattern and wording.
///
/// Pushed onto the History tab's existing `NavigationStack`, so it inherits that
/// stack rather than creating one of its own.
struct AllWorkoutsView: View {
    @Environment(\.modelContext) private var ctx

    // Same ordering as the root page's query — reverse-chronological — so the
    // two lists can never disagree about what "most recent" means.
    @Query(sort: \Workout.date, order: .reverse) private var workouts: [Workout]
    @Query private var routines: [Routine]

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    @State private var toDelete: Workout?
    @State private var showConfirmDelete = false
    @State private var showActiveDeleteWarning = false

    var body: some View {
        // Same once-per-render precompute discipline as `HistoryView`: build the
        // resolver and the summary map once here, never inside a row's `body`.
        let resolver = RoutineLabelResolver(routines: routines)
        let summaries = WorkoutSummary.map(for: workouts)

        List {
            ForEach(workouts) { w in
                WorkoutRow(
                    workout: w,
                    isActive: activeGuard.activeWorkoutID == w.id,
                    routineLabel: resolver.label(for: w),
                    summarySubtitle: (summaries[w.id]
                        ?? WorkoutSummary(workout: w)).subtitle,
                    onRequestDelete: {
                        toDelete = w
                        showConfirmDelete = true
                    },
                    onBlockedDelete: { showActiveDeleteWarning = true }
                )
            }
        }
        .navigationTitle("All Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 56)
        .listRowSpacing(8)
        .scrollContentBackground(.hidden)
        .background(DSColor.bg.ignoresSafeArea())
        .accessibilityIdentifier("screen_all_workouts")
        .alert("Delete workout?", isPresented: $showConfirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let w = toDelete {
                    withAnimation {
                        ctx.delete(w)
                        try? ctx.save()
                    }
                    toDelete = nil
                }
            }
        } message: {
            Text("This will remove the workout and all its sets permanently.")
        }
        .alert(
            "Can't delete active workout",
            isPresented: $showActiveDeleteWarning
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("End the current workout first, then try again.")
        }
    }
}

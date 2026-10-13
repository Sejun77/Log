import Foundation
import SwiftData

/// Rules for the Saved Routines row's trailing **Start** button.
///
/// The button is only a shortcut to the existing start path: it pushes the
/// same `StartWorkoutFromRoutineView(routine:)` the routine editor's toolbar
/// Start pushes, which then builds the frozen plan and starts the workout.
/// Nothing here creates a session.
///
/// Visibility mirrors the editor's gate and deliberately goes no further:
/// - a routine the editor would refuse to start (`Routine.isStartable`) gets
///   no button — the row's own subtitle ("Empty routine") already says why for
///   the common case, and opening the row still leads to the editor as before;
/// - while **any** workout is active the button is hidden on every row. The
///   Resume row at the top of the page is the primary action then, and
///   replacing the active workout stays behind the editor's existing
///   "Start New" confirmation — the list never becomes a second override path.
enum RoutineQuickStart {

    /// IDs of the routines that pass `Routine.isStartable`, evaluated with a
    /// single live-slot fetch for the whole list rather than one per row.
    @MainActor
    static func startableRoutineIDs(
        for routines: [Routine],
        in ctx: ModelContext
    ) -> Set<UUID> {
        guard !routines.isEmpty else { return [] }
        let liveSlotIDs = Routine.liveSlotIDs(in: ctx)
        return Set(
            routines
                .filter { $0.isStartable(liveSlotIDs: liveSlotIDs, in: ctx) }
                .map(\.id)
        )
    }

    /// Whether a row shows the Start button.
    static func showsStartButton(
        routineID: UUID,
        startableIDs: Set<UUID>,
        hasActiveWorkout: Bool
    ) -> Bool {
        !hasActiveWorkout && startableIDs.contains(routineID)
    }
}

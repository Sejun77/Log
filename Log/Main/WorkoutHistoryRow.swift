import SwiftData
import SwiftUI

// ======================================================
// MARK: - History display rules
// ======================================================

/// Pure display rules for the History surfaces.
///
/// Kept as plain values (not buried in a `body`) so "how many workouts does the
/// root History page show" is a unit test rather than a screenshot.
enum HistoryDisplay {

    /// How many workouts the root History page lists before deferring the rest
    /// to the full-history screen.
    ///
    /// **Why a limit at all:** listing every workout made the page grow without
    /// bound, so Calendar and Progression sank further below the fold with
    /// every session logged. A fixed slice gives History a constant height —
    /// the same reach to Calendar on session 5 and on session 500.
    ///
    /// **Why four specifically:** a workout row is three lines (date + duration,
    /// routine, set summary) and measures ~90pt including the 8pt
    /// `listRowSpacing`. On the reference device (iPhone 17, 874pt tall) the
    /// space between the page intro and the floating tab bar fits about five
    /// such rows — so a five-row slice pushes the "View All Workouts" row
    /// underneath the tab bar, where it is invisible until the user scrolls.
    /// Four rows keep that affordance on screen at first paint, which matters
    /// because it is the only route to the rest of the history. Four also still
    /// covers a typical training week for the three-to-four-day lifter, and
    /// anyone training more often is exactly the user who benefits most from
    /// the full-history screen being visibly one tap away.
    static let recentWorkoutLimit = 4

    /// The slice the root History page renders.
    ///
    /// Takes an already-sorted array and never re-sorts it, so the caller's
    /// reverse-chronological `@Query` ordering is preserved exactly.
    static func recent(_ workouts: [Workout]) -> [Workout] {
        Array(workouts.prefix(recentWorkoutLimit))
    }

    /// Whether the "View All Workouts" row should be offered — i.e. whether the
    /// slice above actually hides anything.
    static func hasMore(_ workouts: [Workout]) -> Bool {
        workouts.count > recentWorkoutLimit
    }
}

// ======================================================
// MARK: - Workout duration formatting
// ======================================================

/// Formats a workout's elapsed duration for a history row.
///
/// Extracted from `HistoryView` unchanged so the root History section and the
/// full-history screen cannot drift apart on formatting. Pure and static —
/// no model context, no fetches.
enum WorkoutRowFormat {

    /// Duration from `date` → `completedAt`.
    /// Returns nil when the workout has no `completedAt` (in-progress or legacy).
    static func duration(for w: Workout) -> String? {
        guard let end = w.completedAt else { return nil }
        let total = max(0, Int(end.timeIntervalSince(w.date)))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return String(localized: "\(max(1, m))m")
    }
}

// ======================================================
// MARK: - Workout row
// ======================================================

/// One workout in a history list: navigation into `WorkoutDetailView`, the
/// date / status / routine / summary label, and the delete-or-blocked swipe
/// action.
///
/// Shared by the root History page's "Recent Workouts" section and the
/// full-history `AllWorkoutsView` so the row's appearance and behavior are
/// defined exactly once.
///
/// The precomputed `routineLabel` and `summarySubtitle` are passed **in** rather
/// than derived here on purpose: both screens build a `RoutineLabelResolver` and
/// a `WorkoutSummary.map` once per render and look up by id, and computing them
/// inside this row's `body` would reintroduce the per-row rescanning that
/// discipline exists to avoid.
///
/// The two alerts stay with the host screen (each already owns its own
/// presentation state); this view only reports which one to raise.
struct WorkoutRow: View {
    let workout: Workout
    let isActive: Bool
    let routineLabel: String?
    let summarySubtitle: String
    /// Raise the host's delete confirmation for this workout.
    let onRequestDelete: () -> Void
    /// Raise the host's "can't delete active workout" warning.
    let onBlockedDelete: () -> Void

    var body: some View {
        NavigationLink {
            WorkoutDetailView(workout: workout)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(
                        workout.date.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    .font(.dsBody)

                    Spacer()

                    if isActive {
                        StatusPill(text: "In Progress")
                    } else if let duration = WorkoutRowFormat.duration(
                        for: workout
                    ) {
                        Text(duration)
                            .font(.dsBodySecondary.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let routineLabel {
                    Text(routineLabel)
                        .font(.dsBodySecondary)
                        .foregroundStyle(.secondary)
                }

                // Read-only slot/set glance line. Shown for every workout
                // including in-progress ones (it reflects what's logged so far;
                // the "In Progress" pill above still conveys status).
                Text(summarySubtitle)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .swipeActions(allowsFullSwipe: false) {
            if isActive {
                // Deletion is blocked while this workout is the active session.
                // Gray + lock icon matches the app-wide "blocked / in use"
                // swipe convention (locked Exercise / Routine rows); red is
                // reserved for an available destructive action. Wording uses
                // this screen's existing "In Progress" terminology (row pill +
                // the blocked-delete alert).
                Button(action: onBlockedDelete) {
                    Label("In Progress", systemImage: "lock.fill")
                }
                .tint(.gray)
            } else {
                Button(action: onRequestDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }
}

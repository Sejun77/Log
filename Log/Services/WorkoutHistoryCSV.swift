import Foundation

/// One denormalized row of `workout_history.csv` — a single `SetLog` flattened
/// together with its parent `WorkoutItem` and `Workout` context (CSV Slice 3,
/// REMAINING_WORK_PLAN.md §3.10). Export-only: there is no history *import*
/// (skipped per the §3.10 data-safety rules — history is append-only and
/// snapshotted at session start). Carries no IDs / SwiftData identifiers.
struct WorkoutHistoryCSVRow: Equatable {
    var workoutDate: Date
    var completedAt: Date?
    var routineName: String?
    /// Snapshot-safe display name (see `WorkoutHistoryCSV.exerciseName`).
    var exerciseName: String
    var blockOrder: Int?
    var setIndex: Int
    var subIndex: Int?
    /// `SetKind` raw value: "warmup" / "working" / "dropset".
    var kind: String
    var reps: Int
    var weight: Double?
    var durationSeconds: Int?
    var restSeconds: Int?
    var timestamp: Date
    var workoutNotes: String?
}

/// Pure exporter for workout history. Maps `[Workout]` → denormalized CSV text
/// (one row per `SetLog`) via `CSVCodec`. No `ModelContext`, no UI, no file
/// I/O; reads model properties only. Mirrors the `ExerciseCSV` layering.
enum WorkoutHistoryCSV {
    /// Canonical column order. Export emits exactly this header.
    static let header = [
        "workoutDate", "completedAt", "routineName", "exerciseName",
        "blockOrder", "setIndex", "subIndex", "kind", "reps", "weight",
        "durationSeconds", "restSeconds", "timestamp", "workoutNotes",
    ]

    /// ISO-8601 (RFC 3339, UTC) formatter. `ISO8601DateFormatter` defaults to
    /// GMT + `.withInternetDateTime`, so output is timezone-stable and
    /// deterministic given a fixed `Date` (e.g. epoch 0 → "1970-01-01T00:00:00Z").
    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Mapping

    /// Snapshot-safe exercise name: prefer the durable
    /// `WorkoutItem.exerciseNameSnapshot` (written at session start, survives
    /// deletion of the live `Exercise`), then fall back to the live
    /// `exercise?.name`, then to empty. Never requires a live `Exercise`.
    static func exerciseName(for item: WorkoutItem) -> String {
        item.exerciseNameSnapshot ?? item.exercise?.name ?? ""
    }

    /// Flatten workouts → one row per `SetLog`, preserving order at every level:
    /// the caller's workout order, then `workout.items` array order, then each
    /// item's `setLogs` array order. Pure — never sorts or mutates.
    static func rows(from workouts: [Workout]) -> [WorkoutHistoryCSVRow] {
        var rows: [WorkoutHistoryCSVRow] = []
        for workout in workouts {
            for item in workout.items {
                let name = exerciseName(for: item)
                for log in item.setLogs {
                    rows.append(WorkoutHistoryCSVRow(
                        workoutDate: workout.date,
                        completedAt: workout.completedAt,
                        routineName: workout.routineName,
                        exerciseName: name,
                        blockOrder: item.sourceBlockOrder,
                        setIndex: log.indexInExercise,
                        subIndex: log.subIndex,
                        kind: log.kind.rawValue,
                        reps: log.reps,
                        weight: log.weight,
                        durationSeconds: log.durationSeconds,
                        restSeconds: log.restSeconds,
                        timestamp: log.timestamp,
                        workoutNotes: workout.notes
                    ))
                }
            }
        }
        return rows
    }

    // MARK: - Export

    /// Serialize rows to CSV text: the canonical header followed by one record
    /// per row. Dates use ISO-8601; `nil` optionals become empty cells.
    static func export(_ rows: [WorkoutHistoryCSVRow]) -> String {
        var grid: [[String]] = [header]
        for r in rows {
            grid.append([
                isoFormatter.string(from: r.workoutDate),
                r.completedAt.map(isoFormatter.string(from:)) ?? "",
                r.routineName ?? "",
                r.exerciseName,
                r.blockOrder.map(String.init) ?? "",
                String(r.setIndex),
                r.subIndex.map(String.init) ?? "",
                r.kind,
                String(r.reps),
                r.weight.map(formatWeight) ?? "",
                r.durationSeconds.map(String.init) ?? "",
                r.restSeconds.map(String.init) ?? "",
                isoFormatter.string(from: r.timestamp),
                r.workoutNotes ?? "",
            ])
        }
        return CSVCodec.encode(grid)
    }

    /// Convenience: flatten workouts and serialize in one step. Read-only.
    static func export(workouts: [Workout]) -> String {
        export(rows(from: workouts))
    }

    // MARK: - Helpers

    /// Locale-independent weight rendering: integral values print without a
    /// decimal point ("80"), fractional values keep their digits ("82.5").
    /// Uses the `.` radix unconditionally (no locale comma) for spreadsheet
    /// portability.
    private static func formatWeight(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

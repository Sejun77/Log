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

    // Cardio metrics (Cardio Phase 1, Slice 9). All optional and all appended
    // after `workoutNotes`, so a strength or timed-hold row simply leaves them
    // nil and exports as blank cells. Nil is exported as blank, never as 0 —
    // "not recorded" and "recorded as zero" have to stay distinguishable in a
    // spreadsheet, and for `inclinePercent` 0 is an ordinary interior value.
    var cardio: CardioMetrics = CardioMetrics()

    init(
        workoutDate: Date,
        completedAt: Date? = nil,
        routineName: String? = nil,
        exerciseName: String,
        blockOrder: Int? = nil,
        setIndex: Int,
        subIndex: Int? = nil,
        kind: String,
        reps: Int,
        weight: Double? = nil,
        durationSeconds: Int? = nil,
        restSeconds: Int? = nil,
        timestamp: Date,
        workoutNotes: String? = nil,
        cardio: CardioMetrics = CardioMetrics()
    ) {
        self.workoutDate = workoutDate
        self.completedAt = completedAt
        self.routineName = routineName
        self.exerciseName = exerciseName
        self.blockOrder = blockOrder
        self.setIndex = setIndex
        self.subIndex = subIndex
        self.kind = kind
        self.reps = reps
        self.weight = weight
        self.durationSeconds = durationSeconds
        self.restSeconds = restSeconds
        self.timestamp = timestamp
        self.workoutNotes = workoutNotes
        self.cardio = cardio
    }
}

/// Pure exporter for workout history. Maps `[Workout]` → denormalized CSV text
/// (one row per `SetLog`) via `CSVCodec`. No `ModelContext`, no UI, no file
/// I/O; reads model properties only. Mirrors the `ExerciseCSV` layering.
enum WorkoutHistoryCSV {
    /// Canonical column order. Export emits exactly this header.
    ///
    /// The seven cardio columns (Cardio Phase 1, Slice 9) are **appended** to
    /// the original fourteen, never interleaved, so a spreadsheet or script
    /// built against the pre-cardio export still finds every old column at its
    /// old index.
    ///
    /// `distanceMeters` is the canonical distance — it is the value that was
    /// stored and the only one safe to aggregate. `distanceUnitRaw` rides along
    /// purely as compatibility / original-input metadata recording which unit
    /// the user typed the bout in; it does **not** control how anything is
    /// displayed (display follows the Settings distance unit everywhere) and a
    /// consumer summing distance should ignore it entirely.
    static let header = [
        "workoutDate", "completedAt", "routineName", "exerciseName",
        "blockOrder", "setIndex", "subIndex", "kind", "reps", "weight",
        "durationSeconds", "restSeconds", "timestamp", "workoutNotes",
        "distanceMeters", "distanceUnitRaw", "avgHeartRate", "hrZone",
        "calories", "inclinePercent", "resistanceLevel",
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
                        workoutNotes: workout.notes,
                        // Read through `cardioMetrics`, the only intended read
                        // path: it normalizes every column, so a corrupt stored
                        // value exports blank rather than escaping into a file.
                        // Strength and timed-hold logs yield an empty
                        // `CardioMetrics`, i.e. seven blank cells.
                        cardio: log.cardioMetrics
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
                r.weight.map(formatDecimal) ?? "",
                r.durationSeconds.map(String.init) ?? "",
                r.restSeconds.map(String.init) ?? "",
                isoFormatter.string(from: r.timestamp),
                r.workoutNotes ?? "",
                r.cardio.distanceMeters.map(formatDecimal) ?? "",
                r.cardio.distanceUnit?.rawValue ?? "",
                r.cardio.avgHeartRate.map(String.init) ?? "",
                r.cardio.hrZone?.rawValue ?? "",
                r.cardio.calories.map(String.init) ?? "",
                r.cardio.inclinePercent.map(formatDecimal) ?? "",
                r.cardio.resistanceLevel.map(formatDecimal) ?? "",
            ])
        }
        return CSVCodec.encode(grid)
    }

    /// Convenience: flatten workouts and serialize in one step. Read-only.
    static func export(workouts: [Workout]) -> String {
        export(rows(from: workouts))
    }

    // MARK: - Helpers

    /// Locale-independent numeric rendering: integral values print without a
    /// decimal point ("80", "5000", "-3"), fractional values keep their digits
    /// ("82.5", "-1.5"). Uses the `.` radix unconditionally (no locale comma)
    /// for spreadsheet portability.
    ///
    /// Shared by weight and by the cardio distance / incline / resistance
    /// columns so every numeric cell in the file reads the same way. Signed
    /// input is handled by construction — a treadmill decline exports as
    /// "-3", not as a blank or an absolute value.
    private static func formatDecimal(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

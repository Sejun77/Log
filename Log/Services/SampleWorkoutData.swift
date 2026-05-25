import Foundation

// MARK: - SampleWorkoutData

/// In-memory sample workout history for the AP Calculus AB analytics showcase.
///
/// This exists purely so the analytics view has a rich, calculus-friendly
/// dataset to render on camera when the user's real history is thin. It is
/// **100% value-typed and in-memory**: it never constructs a `Workout`,
/// `WorkoutItem`, or `SetLog`, never touches a `ModelContext` or `@Query`, and
/// can never reach the user's persisted history. Because nothing here persists,
/// it is safe in release builds without `#if DEBUG` gating.
///
/// The generator produces plain `SampleSession`s; the adapters below convert
/// them into the same `StrengthAnalytics.SeriesPoint` / `.VolumePoint` series
/// the real-data extractor (Slice 2's sibling, future) will produce, so the
/// view consumes one shape regardless of source.
enum SampleWorkoutData {

    // MARK: - Value Types

    /// One logged set. No `kind` field — every sample set is treated as a
    /// working set by the analytics adapters (warmups/dropsets are a real-data
    /// concern, out of scope for the curated showcase series).
    struct SampleSet: Equatable {
        var weight: Double
        var reps: Int
    }

    /// One training session on a given date with one or more sets.
    struct SampleSession: Equatable {
        var date: Date
        var sets: [SampleSet]
    }

    /// A named exercise with its full sample session history.
    struct SampleExercise: Equatable {
        var name: String
        var sessions: [SampleSession]
    }

    // MARK: - Dates

    /// Deterministic anchor for the sample timeline. Fixed (not `.now`) so the
    /// dataset and its tests are reproducible. The analytics view (a later
    /// slice) may pass its own `start` to make the series end near today for
    /// the recording.
    static let defaultStartDate = Date(timeIntervalSinceReferenceDate: 0)

    /// Date of the `weekIndex`-th weekly session relative to `start`.
    private static func sessionDate(weekIndex: Int, from start: Date) -> Date {
        start.addingTimeInterval(Double(weekIndex) * StrengthAnalytics.daysPerWeek * StrengthAnalytics.secondsPerDay)
    }

    // MARK: - Curated Sample: Bench Press

    /// Ten weekly Bench Press sessions designed to exercise every analytics
    /// card. The top set per week (driving e1RM) follows:
    ///
    ///   W1 60×8 · W2 62.5×8 · W3 65×7 · W4 67.5×6 · W5 70×5
    ///   W6 70×6 · W7 72.5×4 · W8 72.5×5 · W9 72.5×5 · W10 72.5×5
    ///
    /// Shape on the e1RM curve: brisk early gains (W1→W6), a mid-block dip as
    /// the lifter pushes heavier-but-fewer reps (W7), then a flat plateau at
    /// the top weight (W8–W10). The accompanying volume (three sets per
    /// session) rises then tapers as reps drop — so volume visibly changes
    /// over time. Net effect: positive overall average rate of change, a
    /// near-zero *recent* slope (plateau), and a negative second derivative
    /// (gains slowing).
    static func benchPress(startingFrom start: Date = defaultStartDate) -> SampleExercise {
        // (top-set weight, reps) per week.
        let weeklyTopSets: [(weight: Double, reps: Int)] = [
            (60.0, 8), (62.5, 8), (65.0, 7), (67.5, 6), (70.0, 5),
            (70.0, 6), (72.5, 4), (72.5, 5), (72.5, 5), (72.5, 5),
        ]

        let sessions = weeklyTopSets.enumerated().map { index, top in
            // Three working sets at the week's prescription, so per-session
            // volume = 3 · weight · reps is meaningful and trends over time.
            SampleSession(
                date: sessionDate(weekIndex: index, from: start),
                sets: Array(
                    repeating: SampleSet(weight: top.weight, reps: top.reps),
                    count: 3
                )
            )
        }

        return SampleExercise(name: "Bench Press", sessions: sessions)
    }

    /// All curated sample exercises (currently Bench Press). Returned as an
    /// array so a future picker can iterate without code changes.
    static func allExercises(startingFrom start: Date = defaultStartDate) -> [SampleExercise] {
        [benchPress(startingFrom: start)]
    }

    // MARK: - Adapters → StrengthAnalytics

    /// Per-session best e1RM series. One point per session whose sets yield a
    /// valid e1RM (all sample sets here qualify). Pure; built from
    /// `StrengthAnalytics.bestE1RM`.
    static func strengthSeries(_ sessions: [SampleSession]) -> [StrengthAnalytics.SeriesPoint] {
        sessions.compactMap { session in
            guard let best = StrengthAnalytics.bestE1RM(sets: tuples(session.sets)) else {
                return nil
            }
            return StrengthAnalytics.SeriesPoint(date: session.date, value: best)
        }
    }

    /// Per-session volume series (`accumulatedVolume` left at 0 — fill via
    /// `StrengthAnalytics.accumulatedVolume`). Pure; built from
    /// `StrengthAnalytics.sessionVolume`.
    static func volumeSeries(_ sessions: [SampleSession]) -> [StrengthAnalytics.VolumePoint] {
        sessions.map { session in
            StrengthAnalytics.VolumePoint(
                date: session.date,
                volume: StrengthAnalytics.sessionVolume(tuples(session.sets))
            )
        }
    }

    /// Convenience roll-up for a sample exercise: strength + volume series fed
    /// straight into `StrengthAnalytics.analyze`. Pure.
    static func analysisSummary(for exercise: SampleExercise) -> StrengthAnalytics.AnalysisSummary {
        StrengthAnalytics.analyze(
            strength: strengthSeries(exercise.sessions),
            volume: volumeSeries(exercise.sessions)
        )
    }

    // MARK: - Helpers

    /// Map `SampleSet`s to the labeled tuples `StrengthAnalytics` expects.
    private static func tuples(_ sets: [SampleSet]) -> [(weight: Double, reps: Int)] {
        sets.map { (weight: $0.weight, reps: $0.reps) }
    }
}

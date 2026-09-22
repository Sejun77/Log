import Foundation
import SwiftUI

/// Phase 11.1 — moved out of `ActiveWorkoutView.swift` for behavior-preserving
/// file decomposition. Implementation, access levels, and runtime semantics
/// are unchanged.
///
/// Singleton shared across `ActiveWorkoutView`, `RoutinesView`, `ExercisesView`,
/// and the bootstrap flow. Holds:
///   • per-Exercise and per-Routine lock sets (so the routine / exercise list
///     UIs can surface "In use" affordances while a workout is active),
///   • the active workout's `WorkoutPlan` + persistent ID + session start
///     timestamp (so resume-after-cold-restart can rehydrate),
///   • two routineSlotID-keyed caches (`inputsCache`, `loggedCache`) that
///     survive navigation away/back inside an active session.
///
/// `@MainActor` so observers can update SwiftUI without dispatching;
/// `@Published` properties drive every consumer view.
@MainActor
final class ActiveWorkoutGuard: ObservableObject {
    static let shared = ActiveWorkoutGuard()

    // Locks
    @Published private(set) var lockedExerciseIDs: Set<UUID> = []
    @Published private(set) var lockedRoutineIDs: Set<UUID> = []

    // Active session (for resume)
    @Published var activePlan: WorkoutPlan?
    @Published var activeWorkoutID: UUID?

    // 🔵 Global session timer (in-memory only)
    @Published var sessionStart: Date?

    // UI/session caches that must survive navigation away/back.
    // Keyed by routineSlotID (per-slot identity) — NOT Exercise.id —
    // so duplicate Exercise usage across slots doesn't collide.
    //
    // Deliberately NOT `@Published`. `ActiveWorkoutView` rewrites both on every
    // character typed into a reps / weight / duration / cardio field
    // (`syncToGuardCaches`), and nine views hold this singleton as an
    // `@ObservedObject` — RootTabView, RoutinesView, ExercisesView (x2),
    // HistoryView (x2), RoutineEditor, StartWorkoutFromRoutineView and the
    // active workout itself. Publishing here therefore invalidated the entire
    // tab hierarchy twice per keystroke, which is what made typing lag app-wide
    // rather than only on the workout screen. Nothing renders these: they are
    // read imperatively by `syncFromGuardCachesIfAny()` and
    // `ensureInputsInitializedFromPlan()` on appear, never inside a `body`, so
    // no observer loses an update by dropping the wrapper.
    var inputsCache:
        [UUID: [Int: (reps: String, weight: String, duration: String)]] = [:]

    // routineSlotID -> set indexes that are logged (UI checkmarks)
    var loggedCache: [UUID: Set<Int>] = [:]

    // Exercises
    func lockExercises<S: Sequence>(_ ids: S) where S.Element == UUID {
        lockedExerciseIDs.formUnion(ids)
    }
    func unlockExercises<S: Sequence>(_ ids: S) where S.Element == UUID {
        lockedExerciseIDs.subtract(ids)
    }
    func isExerciseLocked(_ id: UUID) -> Bool { lockedExerciseIDs.contains(id) }
    func lock<S: Sequence>(_ ids: S) where S.Element == UUID {
        lockExercises(ids)
    }
    func unlock<S: Sequence>(_ ids: S) where S.Element == UUID {
        unlockExercises(ids)
    }
    func isLocked(_ id: UUID) -> Bool { isExerciseLocked(id) }

    // Routines
    func lockRoutine(_ id: UUID) { lockedRoutineIDs.insert(id) }
    func unlockRoutine(_ id: UUID) { lockedRoutineIDs.remove(id) }
    func isRoutineLocked(_ id: UUID) -> Bool { lockedRoutineIDs.contains(id) }

    // Routine blocks

    /// Whether one routine *block* is in use by the active workout.
    ///
    /// The two lock sets answer two different questions and must not be
    /// confused:
    ///
    /// • `lockedExerciseIDs` is **Exercise-definition** identity. It holds
    ///   every Exercise the active plan references, which is exactly what the
    ///   exercise library needs — deleting Bench Press mid-session is unsafe
    ///   no matter which screen you delete it from. It says nothing about
    ///   which *routine* is being trained.
    ///
    /// • `lockedRoutineIDs` is **routine ownership**, seeded from
    ///   `plan.routineID` in `beginSession`. Only that routine's blocks are
    ///   the slots the session is executing.
    ///
    /// Block identity follows routine ownership: a block in Routine B is a
    /// different slot in a different plan than a block in Routine A, even when
    /// both point at the same Exercise. Consulting the exercise set alone
    /// froze blocks in unrelated routines that merely reuse a shared exercise
    /// (Bench Press in Push A and Push B), so the routine check gates it.
    func isBlockInUse<S: Sequence>(
        routineID: UUID,
        exerciseIDs: S
    ) -> Bool where S.Element == UUID {
        guard isRoutineLocked(routineID) else { return false }
        return exerciseIDs.contains { isExerciseLocked($0) }
    }

    // Session lifecycle
    func beginSession(plan: WorkoutPlan) {
        activePlan = plan
        // set once; survives view disappear/reappear
        if sessionStart == nil { sessionStart = Date() }
        lockExercises(plan.blocks.flatMap { $0.exercises.map(\.id) })
        lockRoutine(plan.routineID)
    }

    func endSession() {
        if let plan = activePlan {
            // Only routine needs to be explicitly unlocked;
            // exercises are unlocked by clearing the lock set.
            unlockRoutine(plan.routineID)
        }

        // 🔐 Fully clear all exercise locks (including swapped-in ones)
        lockedExerciseIDs.removeAll()

        activePlan = nil
        activeWorkoutID = nil
        sessionStart = nil  // 🔵 reset global timer
        inputsCache.removeAll()
        loggedCache.removeAll()
    }
}

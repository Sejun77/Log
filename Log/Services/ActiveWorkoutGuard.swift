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
    @Published var inputsCache:
        [UUID: [Int: (reps: String, weight: String, duration: String)]] = [:]

    // routineSlotID -> set indexes that are logged (UI checkmarks)
    @Published var loggedCache: [UUID: Set<Int>] = [:]

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

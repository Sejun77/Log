import Foundation
import SwiftData

// MARK: - Workout Resume Service

/// Rebuilds a `WorkoutPlan` from persisted data so the app can resume
/// an active workout after a cold restart.
enum WorkoutResumeService {

    /// Attempt to rebuild a plan for the given workout.
    ///
    /// **Primary path** – `Workout.routineID` is set and the `Routine` still
    /// exists: rebuild from the routine template (same logic as
    /// `StartWorkoutFromRoutineView.makePlan()`).
    ///
    /// **Fallback path** – routine is missing or `routineID` is nil: build a
    /// flat single-exercise-per-block plan from `Workout.items`.
    @MainActor
    static func rebuildPlan(
        for workout: Workout,
        in context: ModelContext
    ) -> WorkoutPlan? {
        // Try the primary (routine-based) path first.
        if let routineID = workout.routineID {
            let descriptor = FetchDescriptor<Routine>(
                predicate: #Predicate { $0.id == routineID }
            )
            if let routine = try? context.fetch(descriptor).first {
                return planFromRoutine(routine, workoutName: workout.routineName)
            }
        }

        // Fallback: build from workout items.
        return planFromWorkoutItems(workout)
    }

    // MARK: - Primary Path

    /// Mirrors `StartWorkoutFromRoutineView.makePlan(from:)`.
    private static func planFromRoutine(
        _ routine: Routine,
        workoutName: String?
    ) -> WorkoutPlan {
        let blocks: [PlanBlock] = routine.blocks
            .sorted { $0.order < $1.order }
            .compactMap { b -> PlanBlock? in
                let exs: [PlanExercise] = b.exercises
                    .sorted { $0.order < $1.order }
                    .compactMap { re in
                        guard let ex = re.exercise else { return nil }
                        let templates = re.resolvedTemplates().enumerated()
                            .map { (i, tpl) in
                                PlanSetTemplate(
                                    id: "\(ex.id.uuidString)-set\(i)",
                                    kind: tpl.kind,
                                    targetReps: tpl.targetReps,
                                    targetWeight: tpl.targetWeight.map {
                                        Int($0.rounded())
                                    },
                                    restSecondsAfter: tpl.restSecondsAfter,
                                    durationSeconds: tpl.durationSeconds
                                )
                            }
                        return PlanExercise(
                            id: ex.id,
                            routineExerciseID: re.id,
                            originalExerciseID: ex.id,
                            currentExerciseID: ex.id,
                            name: ex.name,
                            notes: ex.notes,
                            templates: templates,
                            isTimeBased: ex.isTimeBased,
                            routineSlotID: re.slotID,
                            templateNotesSnapshot: re.templateNotes,
                            prescriptionSnapshot: re.prescription.map(
                                PrescriptionSnapshotPayload.init(from:)
                            )
                        )
                    }
                guard !exs.isEmpty else { return nil }
                return PlanBlock(
                    isSuperset: b.isSuperset,
                    restAfterSeconds: b.restAfterSeconds,
                    supersetRoundRestSeconds: b.supersetRoundRestSeconds,
                    exercises: exs
                )
            }

        return WorkoutPlan(
            routineID: routine.id,
            routineName: workoutName ?? routine.name,
            blocks: blocks
        )
    }

    // MARK: - Fallback Path

    /// Builds a flat plan from existing `WorkoutItem`s when the routine
    /// has been deleted. Each item becomes its own single-exercise block.
    private static func planFromWorkoutItems(
        _ workout: Workout
    ) -> WorkoutPlan? {
        let items = workout.items
        guard !items.isEmpty else { return nil }

        let blocks: [PlanBlock] = items.compactMap { item in
            guard let ex = item.exercise else { return nil }

            // Reconstruct templates from set logs already recorded
            let templates: [PlanSetTemplate] = item.setLogs
                .sorted { $0.indexInExercise < $1.indexInExercise }
                .enumerated()
                .map { (i, log) in
                    PlanSetTemplate(
                        id: "\(ex.id.uuidString)-set\(i)",
                        kind: log.kind,
                        targetReps: log.reps,
                        targetWeight: log.weight.map { Int($0.rounded()) },
                        restSecondsAfter: log.restSeconds,
                        durationSeconds: log.durationSeconds
                    )
                }

            // If no logs yet, build from the prescription snapshot
            let finalTemplates: [PlanSetTemplate]
            if templates.isEmpty, let snap = item.plannedPrescriptionSnapshot {
                let payload = PrescriptionSnapshotPayload(from: snap)
                let count = max(1, payload.sets ?? 3)
                finalTemplates = (0..<count).map { i in
                    PlanSetTemplate(
                        id: "\(ex.id.uuidString)-set\(i)",
                        kind: .working,
                        targetReps: payload.repMax ?? payload.repMin ?? 8,
                        targetWeight: nil,
                        restSecondsAfter: payload.restSecondsBetweenSets,
                        durationSeconds: payload.usesDuration
                            ? (payload.durationMaxSeconds ?? payload.durationMinSeconds)
                            : nil
                    )
                }
            } else if templates.isEmpty {
                // No logs and no snapshot — use exercise defaults
                finalTemplates = ex.defaultTemplates
                    .sorted { $0.order < $1.order }
                    .enumerated()
                    .map { (i, tpl) in
                        PlanSetTemplate(
                            id: "\(ex.id.uuidString)-set\(i)",
                            kind: tpl.kind,
                            targetReps: tpl.targetReps,
                            targetWeight: tpl.targetWeight.map { Int($0.rounded()) },
                            restSecondsAfter: tpl.restSecondsAfter,
                            durationSeconds: tpl.durationSeconds
                        )
                    }
            } else {
                finalTemplates = templates
            }

            let prescriptionPayload = item.plannedPrescriptionSnapshot
                .map(PrescriptionSnapshotPayload.init(from:))

            return PlanBlock(
                isSuperset: false,
                restAfterSeconds: nil,
                supersetRoundRestSeconds: nil,
                exercises: [
                    PlanExercise(
                        id: ex.id,
                        routineExerciseID: item.persistentModelID,
                        originalExerciseID: ex.id,
                        currentExerciseID: ex.id,
                        name: ex.name,
                        notes: ex.notes,
                        templates: finalTemplates,
                        isTimeBased: ex.isTimeBased,
                        routineSlotID: item.routineSlotID ?? UUID(),
                        templateNotesSnapshot: item.templateNotesSnapshot,
                        prescriptionSnapshot: prescriptionPayload
                    )
                ]
            )
        }

        guard !blocks.isEmpty else { return nil }

        return WorkoutPlan(
            routineID: workout.routineID ?? UUID(),
            routineName: workout.routineName ?? "Resumed Workout",
            blocks: blocks
        )
    }
}

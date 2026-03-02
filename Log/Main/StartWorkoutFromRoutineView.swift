import SwiftData
import SwiftUI

// MARK: - Value snapshot used by the workout UI (no live SwiftData references)

struct PlanSetTemplate: Identifiable {
    var id: String  // stable composite key
    var kind: SetKind
    var targetReps: Int
    var targetWeight: Int?
    var restSecondsAfter: Int?
    var durationSeconds: Int?
}

/// Value-type snapshot of one warmup step — no live SwiftData references.
struct WarmupStepSnapshot {
    var order: Int
    var kind: WarmupStepKind
    var reps: Int?
    var percentOfWorking: Double?
    var note: String?
    var restSecondsAfter: Int?
}

/// Lightweight value-type copy of SlotPrescription fields, carried in the plan
/// and converted to @Model PlannedPrescriptionSnapshot at WorkoutItem creation.
struct PrescriptionSnapshotPayload {
    var sets: Int?
    var repMin: Int?
    var repMax: Int?
    var restSecondsBetweenSets: Int?
    var restSecondsAfterExercise: Int?
    var rir: Double?
    var rpe: Double?
    var tempo: String?
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool
    var equipment: String?
    var setupNotes: String?

    init(from source: SlotPrescription) {
        self.sets = source.sets
        self.repMin = source.repMin
        self.repMax = source.repMax
        self.restSecondsBetweenSets = source.restSecondsBetweenSets
        self.restSecondsAfterExercise = source.restSecondsAfterExercise
        self.rir = source.rir
        self.rpe = source.rpe
        self.tempo = source.tempo
        self.durationMinSeconds = source.durationMinSeconds
        self.durationMaxSeconds = source.durationMaxSeconds
        self.usesDuration = source.usesDuration
        self.equipment = source.equipment
        self.setupNotes = source.setupNotes
    }

    func toModel() -> PlannedPrescriptionSnapshot {
        PlannedPrescriptionSnapshot(
            sets: sets,
            repMin: repMin,
            repMax: repMax,
            restSecondsBetweenSets: restSecondsBetweenSets,
            restSecondsAfterExercise: restSecondsAfterExercise,
            rir: rir,
            rpe: rpe,
            tempo: tempo,
            durationMinSeconds: durationMinSeconds,
            durationMaxSeconds: durationMaxSeconds,
            usesDuration: usesDuration,
            equipment: equipment,
            setupNotes: setupNotes
        )
    }
}

extension PrescriptionSnapshotPayload {
    /// Reconstruct a payload from a persisted snapshot (for resume path).
    init(from snapshot: PlannedPrescriptionSnapshot) {
        self.sets = snapshot.sets
        self.repMin = snapshot.repMin
        self.repMax = snapshot.repMax
        self.restSecondsBetweenSets = snapshot.restSecondsBetweenSets
        self.restSecondsAfterExercise = snapshot.restSecondsAfterExercise
        self.rir = snapshot.rir
        self.rpe = snapshot.rpe
        self.tempo = snapshot.tempo
        self.durationMinSeconds = snapshot.durationMinSeconds
        self.durationMaxSeconds = snapshot.durationMaxSeconds
        self.usesDuration = snapshot.usesDuration
        self.equipment = snapshot.equipment
        self.setupNotes = snapshot.setupNotes
    }
}

struct PlanExercise: Identifiable {
    // Stable identity tied to RoutineExercise
    var id: UUID

    // NEW — original & current
    var routineExerciseID: PersistentIdentifier
    var originalExerciseID: UUID
    var currentExerciseID: UUID

    // Display/state
    var name: String
    var notes: String?
    var templates: [PlanSetTemplate]
    var isTimeBased: Bool = false

    // Session snapshot payload (Phase 3.3)
    var routineSlotID: UUID
    var templateNotesSnapshot: String?
    var prescriptionSnapshot: PrescriptionSnapshotPayload?

    // Phase 3.6: technique labels snapshotted at plan-build time (read-only; never mutates prescription)
    var techniqueSummaries: [String] = []

    // Warmup steps snapshotted at plan-build time (read-only; no live SwiftData references)
    var warmupStepsSnapshot: [WarmupStepSnapshot] = []
}

struct PlanBlock: Identifiable {
    var id = UUID()
    var isSuperset: Bool
    var restAfterSeconds: Int?
    var supersetRoundRestSeconds: Int?
    var exercises: [PlanExercise]
}

struct WorkoutPlan: Identifiable {
    var id = UUID()
    var routineID: UUID
    var routineName: String
    var blocks: [PlanBlock]
}

// MARK: - View

struct StartWorkoutFromRoutineView: View {
    @Bindable var routine: Routine

    @State private var cachedPlan: WorkoutPlan?

    // MARK: - Plan Builder

    private func makePlan(from routine: Routine) -> WorkoutPlan {
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
                        // Phase 3.6: snapshot technique labels (read-only; never mutates prescription)
                        let techniqueSummaries: [String] = (re.prescription?.techniquePlans ?? [])
                            .sorted { $0.order < $1.order }
                            .map { tp in
                                switch tp.type {
                                case .dropset:
                                    if let pct = tp.dropPercent, let n = tp.dropCount {
                                        return "Dropset ×\(n) (−\(Int(pct))%)"
                                    } else if let n = tp.dropCount {
                                        return "Dropset ×\(n)"
                                    }
                                    return "Dropset"
                                case .partialReps:
                                    if let note = tp.partialRangeNote, !note.isEmpty {
                                        return "Partials (\(note))"
                                    }
                                    return "Partial Reps"
                                case .restPause:
                                    if let r = tp.rounds { return "Rest-Pause ×\(r)" }
                                    return "Rest-Pause"
                                case .amrap:
                                    return "AMRAP"
                                case .toFailure:
                                    return "To Failure"
                                case .cluster:
                                    if let r = tp.rounds, let rest = tp.restSeconds {
                                        return "Cluster ×\(r) (\(rest)s)"
                                    } else if let r = tp.rounds {
                                        return "Cluster ×\(r)"
                                    }
                                    return "Cluster"
                                case .tempoOverride:
                                    if let t = tp.note, !t.isEmpty { return "Tempo: \(t)" }
                                    return "Tempo Override"
                                }
                            }

                        let warmupStepsSnapshot: [WarmupStepSnapshot] =
                            (re.prescription?.warmupScheme?.steps ?? [])
                            .sorted { $0.order < $1.order }
                            .map { step in
                                WarmupStepSnapshot(
                                    order: step.order,
                                    kind: step.kind,
                                    reps: step.reps,
                                    percentOfWorking: step.percentOfWorking,
                                    note: step.note,
                                    restSecondsAfter: step.restSecondsAfter
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
                            ),
                            techniqueSummaries: techniqueSummaries,
                            warmupStepsSnapshot: warmupStepsSnapshot
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
            routineName: routine.name,
            blocks: blocks
        )
    }

    // MARK: - Body

    var body: some View {
        List {
            overviewSection
            blocksSection
        }
        .navigationTitle("Start Workout")
        // Design system integration (purely visual)
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 56)
        .listRowSpacing(8)
        .scrollContentBackground(.hidden)
        .background(DSColor.bg.ignoresSafeArea())
        .onAppear {
            cachedPlan = makePlan(from: routine)
        }
        .onChange(of: routine) {
            cachedPlan = makePlan(from: routine)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // Use the cached snapshot plan
                NavigationLink {
                    if let plan = cachedPlan {
                        ActiveWorkoutView(plan: plan)
                    } else {
                        // Fallback (shouldn't happen once onAppear ran)
                        ActiveWorkoutView(plan: makePlan(from: routine))
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.dsBody.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("beginWorkoutFromRoutine")
                .disabled(cachedPlan == nil)
            }
        }
    }

    // MARK: - Sections (UI-only changes)

    private var overviewSection: some View {
        Section {
            Text(routine.name)
                .font(.dsBody.weight(.semibold))

            if let notes = routine.notes, !notes.isEmpty {
                Text(notes)
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        } header: {
            DSSectionHeader(title: "Overview", systemImage: "info.circle")
        }
    }

    private var blocksSection: some View {
        Section {
            ForEach(routine.blocks.sorted { $0.order < $1.order }) { b in
                VStack(alignment: .leading, spacing: 6) {
                    Text(b.isSuperset ? "Superset" : "Exercise")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)

                    Text(
                        b.exercises
                            .sorted { $0.order < $1.order }
                            .compactMap { $0.exercise?.name }
                            .joined(separator: " + ")
                    )
                    .font(.dsBody)

                    if let r = b.restAfterSeconds, r > 0 {
                        Text("Rest after: \(r)s")
                            .font(.dsBodySecondary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            DSSectionHeader(
                title: "Blocks",
                systemImage: "square.grid.2x2"
            )
        }
    }
}

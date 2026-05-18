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
struct WarmupStepSnapshot: Codable {
    var order: Int
    var kind: WarmupStepKind
    var reps: Int?
    var percentOfWorking: Double?
    var note: String?
    var restSecondsAfter: Int?
    /// Target weight for fixed-weight steps; nil for other kinds.
    /// Nil default is Codable-safe for snapshots created before this field was added.
    var weight: Double? = nil
}

/// Value-type snapshot of one technique plan — no live SwiftData references.
struct TechniquePlanSnapshot: Codable {
    var order: Int
    var type: TechniqueType       // Codable via RawRepresentable
    var dropPercent: Double?      // stored as percentage, e.g. 20.0 = 20%
    var dropCount: Int?
    var rounds: Int?
    var restSeconds: Int?
    var partialRangeNote: String?
    var note: String?
    var reps: Int?

    // New fields — optional for backward-compatible JSON decoding of existing data.
    // nil decodes as the appropriate default (lastWorkingSet / amrap).
    var appliesToRaw: String?
    var appliesToSetNumber: Int?
    // Explicit 0-based indices CSV (nil = not set; fall back to appliesTo).
    var appliesToSetIndicesRaw: String? = nil
    var dropsetEffortRaw: String?
    var dropsetEffortReps: Int?

    var appliesTo: TechniqueAppliesTo {
        TechniqueAppliesTo.from(raw: appliesToRaw ?? "lastWorkingSet", setNumber: appliesToSetNumber)
    }

    /// Parsed 0-based set indices. Empty = not set; runtime resolves using setCount.
    var appliesToSetIndices: Set<Int> {
        if let raw = appliesToSetIndicesRaw, !raw.isEmpty {
            return Set(raw.split(separator: ",").compactMap { Int($0) })
        }
        // Migration from old appliesTo: only setNumber can be statically resolved here.
        switch appliesTo {
        case .setNumber(let n): return [n - 1]
        default: return []
        }
    }

    var dropsetEffort: DropsetEffort {
        DropsetEffort.from(raw: dropsetEffortRaw, reps: dropsetEffortReps)
    }

    /// Payload-only label — no applies-to suffix.
    /// Used when the chip is already attached to the relevant set row.
    var setAttachedLabel: String {
        switch type {
        case .dropset:
            var parts: [String] = []
            if let pct = dropPercent, pct > 0 { parts.append("−\(Int(pct))%") }
            if let n = dropCount { parts.append("×\(n)") }
            switch dropsetEffort {
            case .amrap:            parts.append("(AMRAP)")
            case .fixedReps(let n): parts.append("(\(n) reps)")
            }
            if let r = restSeconds, r > 0 { parts.append("\(r)s") }
            let tail = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
            return "Dropset\(tail)"
        case .restPause:
            var s = "Rest-Pause"
            if let r = restSeconds, r > 0 { s += " \(r)s" }
            if let n = rounds, n > 0 { s += " ×\(n)" }
            return s
        case .tempoOverride:
            return (note.flatMap { $0.isEmpty ? nil : $0 }).map { "Tempo \($0)" } ?? "Tempo"
        case .partialReps:
            var s = "Partials"
            if let region = partialRangeNote, !region.isEmpty { s += " \(region)" }
            if let n = reps, n > 0 { s += " (\(n))" }
            return s
        case .amrap:    return "AMRAP"
        case .toFailure: return "To Failure"
        case .cluster:
            var s = "Cluster"
            if let n = reps, n > 0 { s += " \(n)r" }
            if let c = rounds, c > 0 { s += " ×\(c)" }
            if let r = restSeconds, r > 0 { s += " (\(r)s)" }
            return s
        }
    }

    /// Full label with applies-to suffix — used in header overview and editors.
    var summaryLabel: String {
        var label = setAttachedLabel
        // Append set qualifier. Prefer explicit indices when available.
        let indices = appliesToSetIndices
        if !indices.isEmpty {
            let nums = indices.sorted().map { String($0 + 1) }.joined(separator: ",")
            label += indices.count == 1 ? " [set \(nums)]" : " [sets \(nums)]"
        } else {
            switch appliesTo {
            case .lastWorkingSet: break
            case .allWorkingSets:   label += " [all]"
            case .setNumber(let n): label += " [set \(n)]"
            }
        }
        return label
    }
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

    // Technique plans snapshotted at plan-build time (read-only; no live SwiftData references)
    var techniquePlansSnapshot: [TechniquePlanSnapshot] = []

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
    /// Phase 6.B: id of the `RoutineVariant` selected for this session, if any.
    /// Carried through to the persisted `Workout.routineVariantID`. Optional
    /// because legacy routines that pre-date variant backfill may not have one
    /// when the start path runs, and because the fallback resume path
    /// (planFromWorkoutItems) cannot recover this from items alone.
    var routineVariantID: UUID?
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
                        // Snapshot technique plans (read-only; no live SwiftData references)
                        let techniquePlansSnapshot: [TechniquePlanSnapshot] =
                            (re.prescription?.techniquePlans ?? [])
                            .sorted { $0.order < $1.order }
                            .map { tp in
                                TechniquePlanSnapshot(
                                    order: tp.order,
                                    type: tp.type,
                                    dropPercent: tp.dropPercent,
                                    dropCount: tp.dropCount,
                                    rounds: tp.rounds,
                                    restSeconds: tp.restSeconds,
                                    partialRangeNote: tp.partialRangeNote,
                                    note: tp.note,
                                    reps: tp.reps,
                                    appliesToRaw: tp.appliesToRaw,
                                    appliesToSetNumber: tp.appliesToSetNumber,
                                    appliesToSetIndicesRaw: tp.appliesToSetIndicesRaw.isEmpty ? nil : tp.appliesToSetIndicesRaw,
                                    dropsetEffortRaw: tp.dropsetEffortRaw,
                                    dropsetEffortReps: tp.dropsetEffortReps
                                )
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
                                    restSecondsAfter: step.restSecondsAfter,
                                    weight: step.weight
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
                            techniquePlansSnapshot: techniquePlansSnapshot,
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
            routineVariantID: routine.preferredVariantID,
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

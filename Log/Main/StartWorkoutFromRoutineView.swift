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

    // MARK: - Template Resolution (unchanged logic)

    private func normalizeTemplateOrder(_ templates: [SetTemplate]) {
        let n = templates.count
        guard n > 0 else { return }

        let orders = templates.map(\.order)
        let uniqueCount = Set(orders).count
        let minOrder = orders.min() ?? 0
        let maxOrder = orders.max() ?? 0

        // Invalid if:
        // - duplicate orders
        // - negative values
        // - not exactly 0...(n-1)
        let needsFix =
            uniqueCount != n || minOrder < 0 || maxOrder != (n - 1)

        guard needsFix else { return }

        // Deterministic repair:
        // 1. warmup → working → dropset
        // 2. then previous order
        let repaired = templates.sorted { a, b in
            if a.kindSortKey != b.kindSortKey {
                return a.kindSortKey < b.kindSortKey
            }
            return a.order < b.order
        }

        for (i, tpl) in repaired.enumerated() {
            tpl.order = i
        }
    }

    private func resolvedTemplates(for re: RoutineExercise) -> [SetTemplate] {
        guard let ex = re.exercise else { return [] }

        let base =
            re.setTemplates.isEmpty ? ex.defaultTemplates : re.setTemplates

        normalizeTemplateOrder(base)

        let sorted = base.sorted { $0.order < $1.order }

        return sorted.map { src in
            let copy = SetTemplate(
                kind: src.kind,
                targetReps: src.targetReps,
                targetWeight: src.targetWeight,
                restSecondsAfter: src.restSecondsAfter
            )
            copy.durationSeconds = src.durationSeconds
            return copy
        }
    }

    private func makePlan(from routine: Routine) -> WorkoutPlan {
        let blocks: [PlanBlock] = routine.blocks
            .sorted { $0.order < $1.order }
            .compactMap { b -> PlanBlock? in
                let exs: [PlanExercise] = b.exercises
                    .sorted { $0.order < $1.order }
                    .compactMap { re in
                        guard let ex = re.exercise else { return nil }
                        let templates = resolvedTemplates(for: re).enumerated()
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
                            isTimeBased: ex.isTimeBased
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

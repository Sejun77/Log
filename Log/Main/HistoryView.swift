import Charts
import SwiftData
import SwiftUI

// MARK: - Progress metric options
enum ProgressMetric: String, CaseIterable, Identifiable {
    case e1rm, volume, bestWeight, totalReps, totalDuration
    var id: String { rawValue }

    var title: String {
        switch self {
        case .e1rm: return "e1RM"
        case .volume: return "Volume"
        case .bestWeight: return "Best wt"
        case .totalReps: return "Reps"
        case .totalDuration: return "Duration"
        }
    }

    var yAxisLabel: String {
        switch self {
        case .e1rm:
            return "e1RM (\(Units.weightIsKg ? "kg" : "lb"))"
        case .volume:
            return "Volume (\(Units.weightIsKg ? "kg" : "lb")·reps)"
        case .bestWeight:
            return "Best wt (\(Units.weightIsKg ? "kg" : "lb"))"
        case .totalReps:
            return "Total reps"
        case .totalDuration:
            return "Total duration (s)"
        }
    }
}

struct HistoryView: View {
    @Query(sort: \Workout.date, order: .reverse) private var workouts: [Workout]

    @State private var selectedExerciseID: UUID?
    @State private var selectedDays: Set<DateComponents> = []
    @State private var metric: ProgressMetric = .e1rm  // default progression = e1RM
    @State private var chartStartDate: Date =
        Calendar.current.date(
            byAdding: .month,
            value: -3,
            to: Date()
        ) ?? Date()

    private enum StartDatePreset: Equatable {
        case months(Int)
        case all
    }

    @State private var activePreset: StartDatePreset? = nil
    @State private var presetIsUpdatingDate = false

    @Environment(\.modelContext) private var ctx
    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    @State private var toDelete: Workout?
    @State private var showConfirmDelete = false
    @State private var showActiveDeleteWarning = false

    @ViewBuilder
    private func presetButton(_ title: String, preset: StartDatePreset)
        -> some View
    {
        let isActive = (activePreset == preset)

        Button(title) {
            setChartStartPreset(preset)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? DSColor.brand : .secondary)
    }

    private var metricsForSelectedExercise: [ProgressMetric] {
        guard
            let id = selectedExerciseID,
            let ex = try? ctx.fetch(
                FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
            ).first
        else {
            return ProgressMetric.allCases
        }
        return ex.isTimeBased
            ? [.totalDuration]
            : [.e1rm, .volume, .bestWeight, .totalReps]
    }

    private func workoutDayComponents() -> Set<DateComponents> {
        Set(
            workouts.map {
                Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: $0.date
                )
            }
        )
    }

    private func earliestWorkoutDate(for exerciseID: UUID) -> Date? {
        workouts
            .filter { w in
                w.items.contains { $0.exercise?.id == exerciseID }
            }
            .map(\.date)
            .min()
    }

    private func setChartStartPreset(_ preset: StartDatePreset) {
        guard let id = selectedExerciseID else { return }
        let earliest = earliestWorkoutDate(for: id)

        presetIsUpdatingDate = true
        activePreset = preset

        let applyDate: (Date) -> Void = { date in
            chartStartDate = date
            DispatchQueue.main.async {
                presetIsUpdatingDate = false
            }
        }

        switch preset {
        case .months(let monthsBack):
            let candidate =
                Calendar.current.date(
                    byAdding: .month,
                    value: -monthsBack,
                    to: Date()
                )
                ?? chartStartDate
            applyDate(earliest.map { max(candidate, $0) } ?? candidate)

        case .all:
            if let earliest {
                applyDate(earliest)
            } else {
                // No data: still clear flag
                DispatchQueue.main.async { presetIsUpdatingDate = false }
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                calendarSection
                progressionSection
                recentWorkoutsSection
            }
            .navigationTitle("History")
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 56)
            .listRowSpacing(8)
            .scrollContentBackground(.hidden)
            .background(DSColor.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .alert("Delete workout?", isPresented: $showConfirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let w = toDelete {
                        withAnimation {
                            ctx.delete(w)
                            try? ctx.save()
                        }
                        toDelete = nil
                    }
                }
            } message: {
                Text(
                    "This will remove the workout and all its sets permanently."
                )
            }
            .alert(
                "Can't delete active workout",
                isPresented: $showActiveDeleteWarning
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("End the current workout first, then try again.")
            }
        }
    }

    // MARK: - Sections

    private var calendarSection: some View {
        Section {
            if workouts.isEmpty {
                Text("No workouts yet. Your calendar will light up here.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            } else {
                MultiDatePicker(
                    "Workout Days",
                    selection: $selectedDays
                )
                .onChange(of: workouts, initial: true) { _, _ in
                    selectedDays = workoutDayComponents()
                }
            }
        } header: {
            DSSectionHeader(title: "Calendar", systemImage: "calendar")
        }
    }

    private var progressionSection: some View {
        Section {
            // Metric picker (segmented)
            Picker("Metric", selection: $metric) {
                ForEach(metricsForSelectedExercise) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)

            NavigationLink {
                ExercisePicker(selectedID: $selectedExerciseID)
            } label: {
                HStack {
                    Text("Choose Exercise")
                        .font(.dsBody.weight(.semibold))
                    Spacer()
                    if let id = selectedExerciseID,
                        let ex = try? ctx.fetch(
                            FetchDescriptor<Exercise>(
                                predicate: #Predicate { $0.id == id }
                            )
                        ).first
                    {
                        Text(ex.name)
                            .font(.dsBodySecondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Start date")
                        .font(.dsBody.weight(.semibold))

                    Spacer()

                    DatePicker(
                        "",
                        selection: $chartStartDate,
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    presetButton("1M", preset: .months(1))
                    presetButton("3M", preset: .months(3))
                    presetButton("6M", preset: .months(6))
                    presetButton("All", preset: .all)
                }
                .font(.dsCaption.weight(.semibold))
                .disabled(selectedExerciseID == nil)
            }

            if let id = selectedExerciseID {
                ProgressChart(
                    exerciseID: id,
                    metric: metric,
                    startDate: chartStartDate
                )
                .frame(height: 240)
            } else {
                Text("Select an exercise to view progression.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        } header: {
            DSSectionHeader(
                title: "Progression",
                systemImage: "chart.line.uptrend.xyaxis"
            )
        }
        .onChange(of: selectedExerciseID) { _, newID in
            if let id = newID,
                let ex = try? ctx.fetch(
                    FetchDescriptor<Exercise>(
                        predicate: #Predicate { $0.id == id }
                    )
                ).first,
                ex.isTimeBased
            {
                metric = .totalDuration
            } else if metric == .totalDuration {
                metric = .e1rm
            }

            if let id = newID, let earliest = earliestWorkoutDate(for: id) {
                chartStartDate = earliest
                activePreset = nil
            }
        }
        .onChange(of: chartStartDate) { _, newDate in
            if !presetIsUpdatingDate {
                activePreset = nil
            }

            guard let id = selectedExerciseID,
                  let earliest = earliestWorkoutDate(for: id)
            else { return }

            if newDate < earliest {
                chartStartDate = earliest
            }
        }
    }

    private var recentWorkoutsSection: some View {
        Section {
            if workouts.isEmpty {
                Text("You don't have any workouts yet.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(workouts) { w in
                    let isActive = activeGuard.activeWorkoutID == w.id
                    NavigationLink {
                        WorkoutDetailView(workout: w)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(
                                    w.date.formatted(
                                        date: .abbreviated,
                                        time: .omitted
                                    )
                                )
                                .font(.dsBody)

                                Spacer()

                                if isActive {
                                    Text("In Progress")
                                        .font(.dsCaption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.thinMaterial)
                                        .clipShape(Capsule())
                                        .foregroundStyle(.secondary)
                                } else if let duration = workoutDuration(w) {
                                    Text(duration)
                                        .font(.dsBodySecondary.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let name = w.routineName {
                                Text(name)
                                    .font(.dsBodySecondary)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button {
                            if isActive {
                                showActiveDeleteWarning = true
                            } else {
                                toDelete = w
                                showConfirmDelete = true
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        } header: {
            DSSectionHeader(
                title: "Recent Workouts",
                systemImage: "clock.arrow.circlepath"
            )
        }
    }

    /// Formats workout duration from `date` → `completedAt`.
    /// Returns nil when the workout has no `completedAt` (in-progress or legacy).
    private func workoutDuration(_ w: Workout) -> String? {
        guard let end = w.completedAt else { return nil }
        let total = max(0, Int(end.timeIntervalSince(w.date)))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return "\(max(1, m))m"
    }
}

// MARK: - Workout Detail

private struct WorkoutDetailView: View {
    let workout: Workout
    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    private var isActive: Bool { activeGuard.activeWorkoutID == workout.id }

    private func exerciseName(for item: WorkoutItem) -> String {
        item.exercise?.name
            ?? item.exerciseNameSnapshot
            ?? "Deleted exercise"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Date") {
                    Text(
                        workout.date.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }

                if let name = workout.routineName {
                    LabeledContent("Routine") {
                        Text(name)
                    }
                }

                if isActive {
                    LabeledContent("Status") {
                        Text("In Progress")
                            .foregroundStyle(.secondary)
                    }
                } else if let end = workout.completedAt {
                    let total = max(0, Int(end.timeIntervalSince(workout.date)))
                    let h = total / 3600
                    let m = (total % 3600) / 60
                    LabeledContent("Duration") {
                        Text(
                            h > 0
                                ? String(format: "%dh %02dm", h, m)
                                : "\(max(1, m))m"
                        )
                        .monospacedDigit()
                    }
                }

                if let notes = workout.notes, !notes.isEmpty {
                    LabeledContent("Notes") {
                        Text(notes)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Overview")
            }

            ForEach(workout.items, id: \.id) { item in
                Section {
                    let logs = item.setLogs.sorted {
                        if $0.indexInExercise != $1.indexInExercise {
                            return $0.indexInExercise < $1.indexInExercise
                        }
                        return ($0.subIndex ?? -1) < ($1.subIndex ?? -1)
                    }
                    if logs.isEmpty {
                        Text("No sets logged")
                            .font(.dsBodySecondary)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(logs, id: \.id) { log in
                            HStack {
                                Text(
                                    "\(log.indexInExercise + 1). \(log.kindRaw.capitalized)"
                                )
                                .font(.dsBody)
                                Spacer()

                                if let dur = log.durationSeconds, dur > 0 {
                                    Text("\(dur)s")
                                        .font(.dsBodySecondary.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                } else {
                                    if let w = log.weight, w > 0 {
                                        let unit =
                                            Units.weightIsKg ? "kg" : "lb"
                                        Text(
                                            "\(Int(w.rounded())) \(unit)"
                                        )
                                        .font(
                                            .dsBodySecondary.monospacedDigit()
                                        )
                                        .foregroundStyle(.secondary)
                                    }
                                    Text(
                                        "\(log.reps) rep\(log.reps == 1 ? "" : "s")"
                                    )
                                    .font(.dsBodySecondary.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(exerciseName(for: item))
                }
            }
        }
        .navigationTitle("Workout")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColor.bg.ignoresSafeArea())
    }
}

// MARK: - Exercise picker

private struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Binding var selectedID: UUID?

    var body: some View {
        List(exercises) { ex in
            Button {
                selectedID = ex.id
                dismiss()
            } label: {
                HStack {
                    Text(ex.name)
                        .font(.dsBody)
                    Spacer()
                    if selectedID == ex.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .navigationTitle("Pick Exercise")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColor.bg.ignoresSafeArea())
    }
}

// MARK: - Chart

private struct ProgressChart: View {
    @Query(sort: \Workout.date) private var workouts: [Workout]
    let exerciseID: UUID
    let metric: ProgressMetric
    let startDate: Date

    private let PR_ICON_SIZE: CGFloat = 11
    private let PR_BADGE_PADDING: CGFloat = 3

    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let isPR: Bool
    }

    @State private var points: [Point] = []

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Date", p.date),
                    y: .value(metric.yAxisLabel, p.value)
                )
                PointMark(
                    x: .value("Date", p.date),
                    y: .value(metric.yAxisLabel, p.value)
                )
            }

            // PR markers
            ForEach(points.filter { $0.isPR }) { p in
                PointMark(
                    x: .value("Date", p.date),
                    y: .value(metric.yAxisLabel, p.value)
                )
                .annotation(position: .top) {
                    Image(systemName: "rosette")
                        .font(.system(size: PR_ICON_SIZE, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.yellow)
                        .padding(PR_BADGE_PADDING)
                        .background(Circle().fill(Color.yellow.opacity(0.22)))
                        .overlay(
                            Circle().stroke(
                                Color.yellow.opacity(0.55),
                                lineWidth: 0.5
                            )
                        )
                        .accessibilityLabel("Personal Record")
                }
            }
        }
        .overlay {
            if points.isEmpty {
                Text("No sets logged for this exercise yet.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: workouts) { computePoints() }
        .onChange(of: metric) { computePoints() }
        .onChange(of: startDate) { computePoints() }
        .onAppear { computePoints() }
    }

    @MainActor
    private func computePoints() {
        var perDay: [(Date, Double)] = []

        for w in workouts {
            guard w.date >= startDate else { continue }

            let items = w.items.filter { $0.exercise?.id == exerciseID }
            guard !items.isEmpty else { continue }

            let value: Double? = {
                switch metric {
                case .e1rm:
                    return items.compactMap { item in
                        item.setLogs.filter { $0.kind == .working }
                            .compactMap { log -> Double? in
                                guard let wt = log.weight, wt > 0, log.reps > 0
                                else { return nil }
                                return wt * (1.0 + Double(log.reps) / 30.0)
                            }
                            .max()
                    }.max()

                case .volume:
                    let sum = items.reduce(0.0) { total, item in
                        total
                            + item.setLogs.filter { $0.kind == .working }
                            .reduce(0.0) {
                                $0
                                    + (($1.weight ?? 0)
                                        * Double(max(0, $1.reps)))
                            }
                    }
                    return sum > 0 ? sum : nil

                case .bestWeight:
                    return items.compactMap { item in
                        item.setLogs.filter { $0.kind == .working }
                            .compactMap { $0.weight }
                            .max()
                    }.max()

                case .totalReps:
                    let reps = items.reduce(0) { total, item in
                        total
                            + item.setLogs.filter { $0.kind == .working }
                            .reduce(0) { $0 + max(0, $1.reps) }
                    }
                    return reps > 0 ? Double(reps) : nil

                case .totalDuration:
                    // Sum durations for all logs (time-based)
                    let total = items.reduce(0) { sum, item in
                        sum
                            + item.setLogs.compactMap(\.durationSeconds).reduce(
                                0,
                                +
                            )
                    }
                    return total > 0 ? Double(total) : nil
                }
            }()

            if let v = value, v.isFinite {
                perDay.append((w.date, v))
            }
        }

        // Sort + PR detection
        let sorted = perDay.sorted { $0.0 < $1.0 }
        guard
            let maxVal = sorted.map({ $0.1 }).max(),
            let firstMaxIdx = sorted.firstIndex(where: { $0.1 == maxVal })
        else {
            points = []
            return
        }

        points = sorted.enumerated().map { idx, pair in
            let (date, v) = pair
            return Point(date: date, value: v, isPR: idx == firstMaxIdx)
        }
    }
}

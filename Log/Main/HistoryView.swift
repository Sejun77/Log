import Charts
import SwiftData
import SwiftUI

// MARK: - Progress metric options
enum ProgressMetric: String, CaseIterable, Identifiable {
    case e1rm, volume, bestWeight, totalReps, bestReps, totalDuration
    var id: String { rawValue }

    var title: String {
        switch self {
        case .e1rm: return "e1RM"
        case .volume: return "Volume"
        case .bestWeight: return "Best wt"
        case .totalReps: return "Reps"
        case .bestReps: return "Best reps"
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
        case .bestReps:
            return "Best reps (single set)"
        case .totalDuration:
            return "Total duration (s)"
        }
    }
}

/// Progress metrics offered for an exercise in History.
/// - Time-based: duration only (unchanged; takes precedence).
/// - Bodyweight-inclusive **with** a user bodyweight: load-based metrics
///   (computed on effective load) plus rep-based metrics.
/// - Bodyweight-inclusive **without** a user bodyweight: rep-based metrics only
///   (e1RM / volume / best-weight need a load, which can't be determined).
/// - Pure bodyweight equipment with the flag **off**: rep-based metrics only —
///   the active-workout weight field is hidden so logged weight is nil and no
///   effective load exists.
/// - Otherwise (normal weighted): the full weight-based set (unchanged).
func availableProgressMetrics(
    isTimeBased: Bool,
    isBodyweightEquipment: Bool,
    includesBodyweight: Bool,
    hasUserBodyweight: Bool
) -> [ProgressMetric] {
    if isTimeBased {
        return [.totalDuration]
    }
    if includesBodyweight {
        // Bodyweight counts toward load — load metrics need the user's bodyweight.
        return hasUserBodyweight
            ? [.e1rm, .volume, .bestWeight, .totalReps, .bestReps]
            : [.totalReps, .bestReps]
    }
    if isBodyweightEquipment {
        // Pure bodyweight equipment, flag off: no logged weight, no added
        // bodyweight → no load. Rep-based metrics only.
        return [.totalReps, .bestReps]
    }
    return [.e1rm, .volume, .bestWeight, .totalReps]
}

/// Effective load for a working set used by History strength metrics. When the
/// exercise counts bodyweight toward load, the user's bodyweight is added to the
/// logged (added) weight; otherwise only the logged weight is used. Returns nil
/// when no load can be determined (e.g. bodyweight-inclusive with no logged
/// weight and no user bodyweight). Pure.
func effectiveLoad(
    loggedWeight: Double?, includesBodyweight: Bool, userBodyweight: Double?
) -> Double? {
    let base = includesBodyweight ? (userBodyweight ?? 0) : 0
    let total = base + (loggedWeight ?? 0)
    return total > 0 ? total : nil
}

struct HistoryView: View {
    @Query(sort: \Workout.date, order: .reverse) private var workouts: [Workout]
    @Query private var routines: [Routine]

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

    private var selectedExercise: Exercise? {
        guard let id = selectedExerciseID else { return nil }
        return try? ctx.fetch(
            FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private var metricsForSelectedExercise: [ProgressMetric] {
        guard let ex = selectedExercise else {
            return ProgressMetric.allCases
        }
        return availableProgressMetrics(
            isTimeBased: ex.isTimeBased,
            isBodyweightEquipment: isBodyweightEquipment(ex.equipmentType),
            includesBodyweight: ex.includesBodyweightInLoad,
            hasUserBodyweight: AppSettings.userBodyweight != nil
        )
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
                    startDate: chartStartDate,
                    includesBodyweight: selectedExercise?.includesBodyweightInLoad ?? false,
                    userBodyweight: AppSettings.userBodyweight
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
            // Reset the selected metric if it is no longer valid for the newly
            // selected exercise (e.g. e1RM/volume/best-weight don't apply to
            // bodyweight; only duration applies to time-based). Falls back to
            // the first available metric (Total Reps for bodyweight).
            let ex = newID.flatMap { id in
                try? ctx.fetch(
                    FetchDescriptor<Exercise>(
                        predicate: #Predicate { $0.id == id }
                    )
                ).first
            }
            let available = availableProgressMetrics(
                isTimeBased: ex?.isTimeBased ?? false,
                isBodyweightEquipment: isBodyweightEquipment(ex?.equipmentType),
                includesBodyweight: ex?.includesBodyweightInLoad ?? false,
                hasUserBodyweight: AppSettings.userBodyweight != nil
            )
            if !available.contains(metric) {
                metric = available.first ?? .totalReps
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
        // Build the label resolver once per body evaluation so per-row lookups
        // are O(1). Routines/variants accessed during init make this section
        // re-render when a rename happens — exactly what live labels need.
        let resolver = RoutineLabelResolver(routines: routines)
        // Precompute the slot/set summaries once per render (keyed by id) so each
        // row reads its subtitle from the map instead of re-scanning
        // `workout.items` / `item.setLogs` in its own `body` — same once-per-render
        // discipline as the `resolver` above and the Routines list `RoutineSummary`.
        let summaries = WorkoutSummary.map(for: workouts)
        return Section {
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
                                    StatusPill(text: "In Progress")
                                } else if let duration = workoutDuration(w) {
                                    Text(duration)
                                        .font(.dsBodySecondary.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let name = resolver.label(for: w) {
                                Text(name)
                                    .font(.dsBodySecondary)
                                    .foregroundStyle(.secondary)
                            }

                            // Read-only slot/set glance line. Shown for every
                            // workout including in-progress ones (it reflects
                            // what's logged so far; the "In Progress" pill above
                            // still conveys status). Falls back to a fresh
                            // summary if the once-per-render map ever misses.
                            Text(
                                (summaries[w.id]
                                    ?? WorkoutSummary(workout: w)).subtitle
                            )
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        if isActive {
                            // Deletion is blocked while this workout is the
                            // active session. Gray + lock icon matches the
                            // app-wide "blocked / in use" swipe convention
                            // (locked Exercise / Routine rows); red is reserved
                            // for an available destructive action. Wording uses
                            // this screen's existing "In Progress" terminology
                            // (row pill + the blocked-delete alert). Tapping
                            // still surfaces the existing "Can't delete active
                            // workout" alert — behavior unchanged.
                            Button {
                                showActiveDeleteWarning = true
                            } label: {
                                Label("In Progress", systemImage: "lock.fill")
                            }
                            .tint(.gray)
                        } else {
                            Button {
                                toDelete = w
                                showConfirmDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
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
    @Query private var routines: [Routine]
    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    private var isActive: Bool { activeGuard.activeWorkoutID == workout.id }

    private func exerciseName(for item: WorkoutItem) -> String {
        item.exercise?.name
            ?? item.exerciseNameSnapshot
            ?? "Deleted exercise"
    }

    var body: some View {
        let resolver = RoutineLabelResolver(routines: routines)
        return List {
            Section {
                LabeledContent("Date") {
                    Text(
                        workout.date.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }

                if let name = resolver.label(for: workout) {
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

            // Phase 6.C2 — group items by source block snapshot.
            // Superset blocks with ≥2 surviving members render as one
            // "Superset" section with each member labeled inline.
            // Singletons, single-member supersets, and legacy nil-
            // snapshot items render exactly as before (one Section per
            // item, header = exercise name).
            let groups = groupItemsBySourceBlock(workout.items)
            ForEach(groups) { group in
                if group.isSuperset && group.items.count >= 2 {
                    Section {
                        ForEach(group.items, id: \.id) { item in
                            supersetMemberHeader(
                                name: exerciseName(for: item)
                            )
                            equipmentAndSetupRows(for: item)
                            setLogList(for: item)
                        }
                    } header: {
                        Text("Superset")
                    }
                } else if let item = group.items.first {
                    Section {
                        equipmentAndSetupRows(for: item)
                        setLogList(for: item)
                    } header: {
                        Text(exerciseName(for: item))
                    }
                }
            }
        }
        .navigationTitle("Workout")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColor.bg.ignoresSafeArea())
    }

    /// Renders the inline label for one exercise inside a "Superset"
    /// section. Visually subordinate to the section header but more
    /// prominent than the set-log rows below it, so the member's
    /// identity is immediately legible without nesting another Section.
    @ViewBuilder
    private func supersetMemberHeader(name: String) -> some View {
        Text(name)
            .font(.dsSection)
            .foregroundStyle(DSColor.textPrimary)
    }

    /// Trim and treat empty/whitespace-only as nil so a blank snapshot
    /// value never renders an empty row. Mirrors the `ActiveWorkoutView`
    /// helper used at workout time.
    private func trimmedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Equipment / Setup rows for one history item, sourced exclusively
    /// from the immutable `plannedPrescriptionSnapshot` captured at
    /// session start. Never reads live `Exercise.equipmentType` /
    /// `setupDefaults` — that would violate the snapshot-immutability
    /// invariant pinned by `testEditingExerciseEquipment_DoesNotMutateExistingSnapshot`.
    /// Empty/whitespace-only values are hidden; legacy items with a nil
    /// snapshot or both fields nil add zero rows.
    @ViewBuilder
    private func equipmentAndSetupRows(for item: WorkoutItem) -> some View {
        let equipment = trimmedOrNil(item.plannedPrescriptionSnapshot?.equipment)
        let setup = trimmedOrNil(item.plannedPrescriptionSnapshot?.setupNotes)

        if let equipment {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Equipment")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(equipment)
                    .font(.dsBody)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let setup {
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(setup)
                    .font(.dsBody)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Renders the set-log rows for one `WorkoutItem`. Extracted from
    /// the pre-6.C2 inline body so the same row layout drives both the
    /// singleton-section path and the superset-section path — keeps the
    /// per-row visual identical to flat rendering.
    @ViewBuilder
    private func setLogList(for item: WorkoutItem) -> some View {
        // Warmup SetLogs carry a negative `indexInExercise` (`-(order+1)`) to
        // avoid colliding with 0-based working-set indices. Sorting raw by that
        // index put warmups last-to-first with negative/zero labels (e.g. the
        // 4th warmup showed as "-3"). Sort key: warmups first (group 0) by
        // warmup number ascending (= -index), then working/dropset (group 1) by
        // index then subIndex. Keys are computed inline in the comparator —
        // a nested func isn't allowed in this @ViewBuilder body.
        let logs = item.setLogs.sorted { a, b in
            let ka = a.kind == .warmup
                ? (0, -a.indexInExercise, 0)
                : (1, a.indexInExercise, a.subIndex ?? -1)
            let kb = b.kind == .warmup
                ? (0, -b.indexInExercise, 0)
                : (1, b.indexInExercise, b.subIndex ?? -1)
            return ka < kb
        }
        if logs.isEmpty {
            Text("No sets logged")
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
        } else {
            ForEach(logs, id: \.id) { log in
                HStack {
                    Text(
                        log.kind == .warmup
                            ? "Warmup \(-log.indexInExercise)"
                            : "\(log.indexInExercise + 1). \(log.kindRaw.capitalized)"
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
                                "\(Units.formatWeight(w)) \(unit)"
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
    }
}

// MARK: - Exercise picker

private struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Binding var selectedID: UUID?
    @State private var search = ""

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name-filtered library. An empty search returns the full `@Query` order
    /// (alphabetical by name); a search term narrows it without reordering —
    /// mirrors `ExercisePickerSingle` / `ExerciseMultiPicker`.
    private var filtered: [Exercise] {
        guard !trimmedSearch.isEmpty else { return exercises }
        return exercises.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                Text(
                    trimmedSearch.isEmpty
                        ? "No exercises yet."
                        : "No exercises match “\(trimmedSearch)”."
                )
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(filtered) { ex in
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
            }
        }
        .navigationTitle("Pick Exercise")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColor.bg.ignoresSafeArea())
        // `.always` pins the search bar visible the moment the picker opens, so
        // it's discoverable without a manual upward scroll (default `.automatic`
        // placement hides it until the list is pulled down).
        .searchable(
            text: $search,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search"
        )
        // Dismissal paths for the search keyboard: scrolling the list dismisses
        // it, pressing Search resigns focus for a non-empty query, and the
        // `.keyboard` Done button below covers the empty submit (`.onSubmit(of:
        // .search)` doesn't fire when the field is empty after type-delete).
        // Search is the only text input here, so the accessory only shows for it.
        .scrollDismissesKeyboard(.immediately)
        .onSubmit(of: .search) { dismissKeyboard() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                KeyboardDismissButton()
            }
        }
    }
}

// MARK: - Chart

private struct ProgressChart: View {
    @Query(sort: \Workout.date) private var workouts: [Workout]
    let exerciseID: UUID
    let metric: ProgressMetric
    let startDate: Date
    /// Whether the selected exercise counts bodyweight toward effective load.
    var includesBodyweight: Bool = false
    /// User's bodyweight (Settings) in the displayed unit; nil = not set.
    var userBodyweight: Double? = nil

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
                                // Effective load for bodyweight-inclusive
                                // exercises; raw logged weight otherwise
                                // (identical to prior behavior).
                                let load = includesBodyweight
                                    ? effectiveLoad(
                                        loggedWeight: log.weight,
                                        includesBodyweight: true,
                                        userBodyweight: userBodyweight)
                                    : log.weight
                                guard let load, load > 0, log.reps > 0
                                else { return nil }
                                return load * (1.0 + Double(log.reps) / 30.0)
                            }
                            .max()
                    }.max()

                case .volume:
                    let sum = items.reduce(0.0) { total, item in
                        total
                            + item.setLogs.filter { $0.kind == .working }
                            .reduce(0.0) { acc, log in
                                let load = includesBodyweight
                                    ? (effectiveLoad(
                                        loggedWeight: log.weight,
                                        includesBodyweight: true,
                                        userBodyweight: userBodyweight) ?? 0)
                                    : (log.weight ?? 0)
                                return acc + load * Double(max(0, log.reps))
                            }
                    }
                    return sum > 0 ? sum : nil

                case .bestWeight:
                    return items.compactMap { item in
                        item.setLogs.filter { $0.kind == .working }
                            .compactMap { log -> Double? in
                                includesBodyweight
                                    ? effectiveLoad(
                                        loggedWeight: log.weight,
                                        includesBodyweight: true,
                                        userBodyweight: userBodyweight)
                                    : log.weight
                            }
                            .max()
                    }.max()

                case .bestReps:
                    let best = items.flatMap { item in
                        item.setLogs.filter { $0.kind == .working }
                            .map { max(0, $0.reps) }
                    }.max() ?? 0
                    return best > 0 ? Double(best) : nil

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

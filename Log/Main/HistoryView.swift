import Charts
import SwiftData
import SwiftUI

// MARK: - Progress metric options
enum ProgressMetric: String, CaseIterable, Identifiable {
    case e1rm, volume, bestWeight, totalReps, bestReps, totalDuration
    // Cardio metrics (Slice 11). `totalDuration` is deliberately shared with
    // timed holds rather than duplicated — it is the same sum of the same
    // column, and a cardio bout's duration chart should read identically to a
    // plank's.
    case cardioDistance, cardioPace, cardioCalories, cardioHeartRate
    var id: String { rawValue }

    /// Metrics that only make sense for a cardio exercise. Used both to build
    /// the cardio option list and to keep these out of the "no exercise
    /// selected" list, which otherwise offers pace for a bench press.
    var isCardioOnly: Bool {
        switch self {
        case .cardioDistance, .cardioPace, .cardioCalories, .cardioHeartRate:
            return true
        default:
            return false
        }
    }

    /// Picker label. Rendered through `LocalizedStringKey`, so a title with a
    /// string-catalog entry is translated and one without falls back to this
    /// literal — the behavior every `Text("…")` in the app already has.
    var title: String {
        switch self {
        case .e1rm: return "e1RM"
        case .volume: return "Volume"
        case .bestWeight: return "Best wt"
        case .totalReps: return "Reps"
        case .bestReps: return "Best reps"
        case .totalDuration: return "Duration"
        case .cardioDistance: return "Distance"
        case .cardioPace: return "Pace"
        case .cardioCalories: return "Calories"
        case .cardioHeartRate: return "Avg HR"
        }
    }

    /// Series label for the chart marks. Cardio units come from Settings —
    /// distance is stored in meters and only ever converted at display time, so
    /// this takes the unit rather than reading it, which is what lets the chart
    /// re-render when the preference changes (`AppSettings.distanceUnit` is a
    /// plain `UserDefaults` read that SwiftUI cannot observe).
    func yAxisLabel(distanceUnit: DistanceUnit) -> String {
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
        case .cardioDistance:
            return "Distance (\(distanceUnit.symbol))"
        case .cardioPace:
            return "Pace (\(distanceUnit.paceUnitSymbol))"
        case .cardioCalories:
            return "Calories (kcal)"
        case .cardioHeartRate:
            return "Avg heart rate (bpm)"
        }
    }

    /// For pace, lower is better: the rosette must mark the *fastest* session,
    /// not the slowest. Every other metric peaks upward.
    var lowerIsBetter: Bool { self == .cardioPace }

    /// Empty-state copy. Generic for the strength metrics (unchanged), specific
    /// for cardio, where "no data" usually means one particular field was left
    /// blank rather than that the exercise was never trained.
    var emptyStateText: LocalizedStringKey {
        switch self {
        case .cardioDistance:
            return "No distance logged for this exercise yet."
        case .cardioPace:
            return "No pace yet — a session needs both a distance and a duration."
        case .cardioCalories:
            return "No calories logged for this exercise yet."
        case .cardioHeartRate:
            return "No heart rate logged for this exercise yet."
        default:
            return "No sets logged for this exercise yet."
        }
    }
}

/// Progress metrics offered for an exercise in History.
/// - Cardio: distance, duration, pace, calories, heart rate (Slice 11). Checked
///   first, because cardio implies time-based and would otherwise be swallowed
///   by the duration-only rule below. Deliberately excludes e1RM / volume /
///   reps: a treadmill run has no load to estimate a one-rep max from.
/// - Time-based (non-cardio timed hold): duration only (unchanged).
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
    hasUserBodyweight: Bool,
    isCardio: Bool = false
) -> [ProgressMetric] {
    // Cardio implies time-based (the `Exercise` invariant), so this must come
    // first or every cardio exercise would resolve to duration-only. The extra
    // `isTimeBased` check keeps a hand-corrupted row from reaching cardio
    // metrics it has no duration for — the same defensive read `trackingMode`
    // performs.
    if isCardio && isTimeBased {
        return [
            .cardioDistance, .totalDuration, .cardioPace, .cardioCalories,
            .cardioHeartRate,
        ]
    }
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
            // Nothing selected: the same list this has always offered. The
            // cardio metrics are filtered out rather than added to it — there
            // is no exercise to say they apply to, and "Pace" in a list that
            // might be about a bench press is worse than not offering it.
            return ProgressMetric.allCases.filter { !$0.isCardioOnly }
        }
        return availableProgressMetrics(
            isTimeBased: ex.isTimeBased,
            isBodyweightEquipment: isBodyweightEquipment(ex.equipmentType),
            includesBodyweight: ex.includesBodyweightInLoad,
            hasUserBodyweight: AppSettings.userBodyweight != nil,
            isCardio: ex.isCardio
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
            // Metric picker (native Menu style). Replaces the prior segmented
            // row, which cramped/truncated with up to 6 options; the Menu shows
            // the selected metric inline and lists the available metrics on tap.
            // Binding, option source, availability rules, and labels unchanged.
            Picker("Metric", selection: $metric) {
                ForEach(metricsForSelectedExercise) { m in
                    Text(LocalizedStringKey(m.title)).tag(m)
                }
            }
            .pickerStyle(.menu)

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
                hasUserBodyweight: AppSettings.userBodyweight != nil,
                isCardio: ex?.isCardio ?? false
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
        return String(localized: "\(max(1, m))m")
    }
}

// MARK: - Workout Detail

private struct WorkoutDetailView: View {
    let workout: Workout
    @Query private var routines: [Routine]
    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    /// Cardio Slice 8 patch. Reading `AppSettings.distanceUnit` in `body`
    /// rendered the *correct* unit but never re-rendered: it is a plain
    /// `UserDefaults` lookup, so SwiftUI recorded no dependency and an open
    /// History page kept showing km after Settings changed to mi. Reopening the
    /// page appeared to fix it only because that built a fresh body.
    ///
    /// `@AppStorage` is the dependency SwiftUI can see. The default matches
    /// `AppSettings.distanceIsMetric`'s own locale-resolved fallback, so an
    /// unset key renders the same unit here as everywhere else rather than
    /// hardcoding km.
    @AppStorage(AppSettings.Keys.distanceIsMetric)
    private var distanceIsMetric: Bool = AppSettings.defaultDistanceIsMetric()

    /// The unit cardio rows render in, derived from observable state so the
    /// whole list re-renders the moment the preference changes.
    private var distanceUnit: DistanceUnit {
        AppSettings.distanceUnit(isMetric: distanceIsMetric)
    }

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
                                : String(localized: "\(max(1, m))m")
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

                // Future-prefill exclusion, editable after the fact for
                // completed workouts. Positive wording: ON means this workout
                // may seed last-performance prefill; OFF (recovery/deload)
                // keeps it in History but ignored by prefill. Maps to
                // Workout.excludedFromPrefill (inverted). Hidden while active —
                // that case is handled live in ActiveWorkoutView.
                if !isActive {
                    Toggle(
                        isOn: Binding(
                            get: { !workout.excludedFromPrefill },
                            set: { workout.excludedFromPrefill = !$0 }
                        )
                    ) {
                        // Explanation moved off the footer into an on-demand info
                        // button next to the toggle label to reduce clutter.
                        HStack(spacing: DSSpacing.xs) {
                            Text("Use for future prefill")
                            InfoButton(
                                "Use for future prefill",
                                message: "Turn off for recovery or deload workouts so they don't become the source for your next workout's prefill."
                            )
                        }
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
                            plannedCardioRows(for: item)
                            setLogList(for: item)
                        }
                    } header: {
                        Text("Superset")
                    }
                } else if let item = group.items.first {
                    Section {
                        equipmentAndSetupRows(for: item)
                        plannedCardioRows(for: item)
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
                Text(LocalizedStringKey(equipment))
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

    /// Structured Cardio Slice 12E — the **Planned** block for one history
    /// item: the segment plan this workout was started with.
    ///
    /// Read exclusively from the immutable `plannedPrescriptionSnapshot`, never
    /// from the live routine, so editing the routine afterwards cannot rewrite
    /// what an old workout says it planned — the same rule Equipment & Setup
    /// above already follows.
    ///
    /// Rendered only when that frozen snapshot decodes to a non-empty plan.
    /// That single condition is also the cardio gate: only a cardio slot can
    /// author segments, so a strength item and a timed hold decode nil and add
    /// zero rows, exactly as before this slice. A corrupt payload decodes nil
    /// too — the section disappears, the History row does not.
    ///
    /// **Plan only.** No ticks, no checkmarks, no completion state: the active
    /// checklist's ticks are session-scoped draft state that never reached this
    /// workout, and presenting anything here as "done" would claim the app
    /// observed something it did not. The logged result stays the aggregate
    /// cardio `SetLog` rendered by `setLogList` below, untouched.
    @ViewBuilder
    private func plannedCardioRows(for item: WorkoutItem) -> some View {
        if let plan = item.plannedPrescriptionSnapshot?.structuredCardioPlan {
            let rows = CardioPlannedHistory.rows(
                for: plan, distanceUnit: distanceUnit)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                    // "Cardio Plan", not "Planned": the same words the active
                    // workout checklist uses for the same list, and unambiguous
                    // that these are programmed cardio segments rather than
                    // per-segment results. Reuses the 12D key.
                    Text("Cardio Plan")
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: DSSpacing.sm)
                    // Verbatim — assembled from numbers and units, like every
                    // other composed plan summary in the app.
                    Text(
                        CardioPlannedHistory.summary(
                            for: plan, distanceUnit: distanceUnit)
                    )
                    .font(.dsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                ForEach(rows) { row in
                    plannedCardioRow(row)
                }
            }
        }
    }

    /// One planned segment, laid out exactly like a logged set row above it:
    ///
    ///     Warm-up                                                    10m
    ///     2 km · 0% incline · level 5 · Z1 · Easy
    ///
    /// Same three type styles as `setLogList`'s rows — `.dsBody` primary label,
    /// `.dsBodySecondary.monospacedDigit()` trailing value, `.dsCaption`
    /// metadata line, `spacing: 2` between them — so the eye lands in the same
    /// places whether it is reading the plan or the result. The only difference
    /// is what the values *mean*, and the section header says which.
    ///
    /// The note is part of the metadata line rather than a line of its own: a
    /// short note reads as one more piece of detail instead of a detached
    /// fragment, and a long one wraps in the same typography rather than
    /// switching style mid-row.
    @ViewBuilder
    private func plannedCardioRow(_ row: CardioPlannedSegmentRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(LocalizedStringKey(row.kindLabelKey))
                    .font(.dsBody)

                // Only ever present on a repeated group — no plan the current
                // editor writes has one, so a flat plan shows no round label.
                // Reuses the key the active checklist introduced in 12D.
                if let round = row.round, let roundCount = row.roundCount {
                    Text("Round \(round)/\(roundCount)")
                        .font(.dsCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // The leading target holds the position a logged row gives its
                // duration, so planned and performed values line up in one
                // column down the section.
                if !row.primaryTargetText.isEmpty {
                    Text(row.primaryTargetText)
                        .font(.dsBodySecondary.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !row.secondaryText.isEmpty {
                Text(row.secondaryText)
                    .font(.dsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
        // Whether these rows read as cardio ("1. Cardio Set") or as ordinary
        // sets ("1. Working Set"). Resolved once per item, not per row: every
        // row under one item belongs to the same exercise.
        let itemIsCardio = HistorySetRowLabel.isCardio(item)
        if logs.isEmpty {
            Text("No sets logged")
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
        } else {
            ForEach(logs, id: \.id) { log in
                // Cardio Slice 4 patch: the row is a VStack so recorded cardio
                // metrics can sit on their own grouped lines beneath it. A set
                // with no metrics produces no extra lines and no extra spacing,
                // so strength rows, timed holds, and duration-only cardio logs
                // occupy exactly the layout they always have.
                // Formatted here, per render, from the observable preference —
                // never stored in `@State`, so there is no cached string that
                // could survive a unit change.
                let cardioLines = CardioHistorySummary.secondaryLines(
                    for: log, displayUnit: distanceUnit)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        // Passed as a `String` (not an interpolated literal) so
                        // it renders verbatim — the helper has already resolved
                        // the localized kind name it contains.
                        Text(
                            HistorySetRowLabel.text(
                                for: log, isCardio: itemIsCardio)
                        )
                        .font(.dsBody)
                        Spacer()

                        // The duration stays the row's primary trailing value
                        // whatever else was recorded, so the eye lands in the
                        // same place on every row. `primaryText` returns the
                        // literal "\(dur)s" History has always produced, and
                        // nil for a strength set — which falls through to the
                        // untouched weight/reps rendering. Passed as a `String`
                        // (not an interpolated literal) so it renders verbatim.
                        if let duration = CardioHistorySummary.primaryText(for: log) {
                            Text(duration)
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

                    // One line per coherent group: what was covered, how the
                    // machine was set, how the body responded. The formatter
                    // localizes its own words; `id: \.self` is safe because the
                    // three lines are distinct by construction.
                    ForEach(cardioLines, id: \.self) { line in
                        Text(line)
                            .font(.dsCaption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

    /// Cardio distance/pace display unit. Declared as `@AppStorage` rather than
    /// read from `AppSettings` so SwiftUI records the dependency: flipping
    /// km ↔ mi in Settings has to re-plot an already-open chart, which is the
    /// bug the Slice 8 policy exists to prevent.
    @AppStorage(AppSettings.Keys.distanceIsMetric)
    private var distanceIsMetric: Bool = AppSettings.defaultDistanceIsMetric()

    private var distanceUnit: DistanceUnit {
        AppSettings.distanceUnit(isMetric: distanceIsMetric)
    }

    private let PR_ICON_SIZE: CGFloat = 11

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
                    y: .value(metric.yAxisLabel(distanceUnit: distanceUnit), p.value)
                )
                PointMark(
                    x: .value("Date", p.date),
                    y: .value(metric.yAxisLabel(distanceUnit: distanceUnit), p.value)
                )
            }

            // PR markers
            ForEach(points.filter { $0.isPR }) { p in
                PointMark(
                    x: .value("Date", p.date),
                    y: .value(metric.yAxisLabel(distanceUnit: distanceUnit), p.value)
                )
                .annotation(position: .top) {
                    // Subtle PR marker: the rosette alone (no filled badge/ring)
                    // so it reads as a quiet accent above the point rather than a
                    // competing floating badge.
                    Image(systemName: "rosette")
                        .font(.system(size: PR_ICON_SIZE, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.yellow.opacity(0.8))
                        .accessibilityLabel("Personal Record")
                }
            }
        }
        // Quiet the chart chrome so the trend line stays the focus: soft
        // gridlines (the app's subtle border token) and quieter caption-weight
        // axis labels. Default automatic tick positions and label formatting are
        // preserved — only styling changes, never the data, scales, or marks.
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(DSColor.border.opacity(0.6))
                AxisTick().foregroundStyle(DSColor.border)
                AxisValueLabel()
                    .font(.dsCaption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(DSColor.border.opacity(0.6))
                // Pace is plotted in seconds per unit, because that is the only
                // form that scales linearly. Ticks read as `m:ss` — "5:30", not
                // "330" and not the decimal "5.5", which nobody runs to.
                if metric == .cardioPace, let seconds = value.as(Double.self),
                    let label = CardioDerived.formatPace(secondsPerUnit: seconds)
                {
                    AxisValueLabel {
                        Text(label)
                    }
                    .font(.dsCaption)
                    .foregroundStyle(DSColor.textSecondary)
                } else {
                    AxisValueLabel()
                        .font(.dsCaption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .overlay {
            if points.isEmpty {
                Text(metric.emptyStateText)
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onChange(of: workouts) { computePoints() }
        .onChange(of: metric) { computePoints() }
        .onChange(of: startDate) { computePoints() }
        // Settings km ↔ mi re-plots the cardio series in the new unit. The
        // stored meters never move — only the projection does.
        .onChange(of: distanceIsMetric) { computePoints() }
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

                // Cardio (Slice 11). Every one of these delegates to
                // `CardioProgressAnalytics`, so the aggregation rules —
                // weighted pace, nil-means-absent, warm-up sets included —
                // live in one tested place rather than in this view.
                case .cardioDistance:
                    return CardioProgressAnalytics.totals(forItems: items)
                        .distanceValue(in: distanceUnit)

                case .cardioPace:
                    return CardioProgressAnalytics.totals(forItems: items)
                        .paceSecondsPerUnit(in: distanceUnit)

                case .cardioCalories:
                    return CardioProgressAnalytics.totals(forItems: items)
                        .caloriesValue

                case .cardioHeartRate:
                    return CardioProgressAnalytics.totals(forItems: items)
                        .avgHeartRateValue
                }
            }()

            if let v = value, v.isFinite {
                perDay.append((w.date, v))
            }
        }

        // Sort + PR detection. The best session is the highest value for every
        // metric except pace, where the fastest session is the *lowest* — a
        // rosette on the slowest run would be a lie the chart tells at a glance.
        let sorted = perDay.sorted { $0.0 < $1.0 }
        let values = sorted.map(\.1)
        guard
            let bestVal = metric.lowerIsBetter ? values.min() : values.max(),
            let firstBestIdx = sorted.firstIndex(where: { $0.1 == bestVal })
        else {
            points = []
            return
        }

        points = sorted.enumerated().map { idx, pair in
            let (date, v) = pair
            return Point(date: date, value: v, isPR: idx == firstBestIdx)
        }
    }
}

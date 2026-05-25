import Charts
import SwiftData
import SwiftUI

// MARK: - AnalyticsView

/// AP Calculus AB showcase screen. Renders a strength/volume analysis through
/// the pure `StrengthAnalytics` layer, from either the in-memory
/// `SampleWorkoutData` Bench Press dataset (default, for the video) or the
/// user's real completed workout history.
///
/// Read-only end to end: it reads `Workout` rows via `@Query` but writes no
/// `ModelContext`, mutates no history, and constructs no
/// `Workout`/`WorkoutItem`/`SetLog`. Real-history extraction is delegated to
/// the pure `WorkoutHistoryAnalytics`. Derived series live in `@State` and are
/// refreshed by `recompute()` on appear / mode / selection / data changes, so
/// the SwiftUI `body` does no heavy work. Pushed from Settings, so it adds no
/// `NavigationStack` of its own.
struct AnalyticsView: View {

    // MARK: - Data source

    enum DataSource: String, CaseIterable, Identifiable {
        case sample, real
        var id: String { rawValue }
        var label: String { self == .sample ? "Sample" : "Real History" }
    }

    @Query(sort: \Workout.date) private var workouts: [Workout]

    /// Anchors the (deterministic) sample timeline; the default ends the
    /// 10-week block near today so the charts read as recent history.
    private let sampleStart: Date

    init(
        start: Date = Calendar.current.date(byAdding: .day, value: -63, to: .now)
            ?? SampleWorkoutData.defaultStartDate
    ) {
        self.sampleStart = start
    }

    // MARK: - State

    @State private var dataSource: DataSource = .sample
    @State private var realSelection: WorkoutHistoryAnalytics.ExerciseRef?
    @State private var availableRefs: [WorkoutHistoryAnalytics.ExerciseRef] = []

    @State private var exerciseTitle: String = ""
    @State private var strengthPoints: [StrengthAnalytics.SeriesPoint] = []
    @State private var volumePoints: [StrengthAnalytics.VolumePoint] = []
    @State private var summary = StrengthAnalytics.analyze(strength: [], volume: [])

    private var unit: String { Units.weightIsKg ? "kg" : "lb" }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                header
                sourcePicker

                if dataSource == .real && availableRefs.isEmpty {
                    realEmptyState
                } else {
                    if dataSource == .real {
                        exercisePicker
                    }
                    analysisContent
                }

                explanationCard
            }
            .padding(DSSpacing.lg)
        }
        .background(DSColor.bg.ignoresSafeArea())
        .navigationTitle("Calculus Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recompute() }
        .onChange(of: dataSource) { recompute() }
        .onChange(of: realSelection) { recompute() }
        .onChange(of: workouts) { recompute() }
    }

    // MARK: - Recompute

    /// Rebuild the derived series + summary for the current mode/selection.
    /// Pure data plumbing; no persistence, no mutation of model objects.
    private func recompute() {
        switch dataSource {
        case .sample:
            let ex = SampleWorkoutData.benchPress(startingFrom: sampleStart)
            let strength = SampleWorkoutData.strengthSeries(ex.sessions)
            let volume = SampleWorkoutData.volumeSeries(ex.sessions)
            apply(strength: strength, volume: volume, title: ex.name)
            availableRefs = []

        case .real:
            let refs = WorkoutHistoryAnalytics.availableExercises(in: workouts)
            availableRefs = refs

            // Keep the current selection if it still exists; else first; else none.
            let resolved = realSelection
                .flatMap { sel in refs.first { $0.key == sel.key } }
                ?? refs.first
            if realSelection?.key != resolved?.key {
                realSelection = resolved
            }

            guard let ref = resolved else {
                apply(strength: [], volume: [], title: "")
                return
            }
            let strength = WorkoutHistoryAnalytics.strengthSeries(for: ref, in: workouts)
            let volume = WorkoutHistoryAnalytics.volumeSeries(for: ref, in: workouts)
            apply(strength: strength, volume: volume, title: ref.displayName)
        }
    }

    private func apply(
        strength: [StrengthAnalytics.SeriesPoint],
        volume: [StrengthAnalytics.VolumePoint],
        title: String
    ) {
        strengthPoints = strength
        volumePoints = StrengthAnalytics.accumulatedVolume(volume)
        summary = StrengthAnalytics.analyze(strength: strength, volume: volume)
        exerciseTitle = title
    }

    // MARK: - Header / controls

    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("Calculus Workout Analytics")
                .font(.dsTitle)
                .foregroundStyle(DSColor.textPrimary)
            HStack(spacing: DSSpacing.sm) {
                if !exerciseTitle.isEmpty {
                    Text(exerciseTitle)
                        .font(.dsBodySecondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DSTag(
                    text: dataSource == .sample ? "Sample data" : "Real history",
                    style: .accent
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcePicker: some View {
        Picker("Data source", selection: $dataSource) {
            ForEach(DataSource.allCases) { source in
                Text(source.label).tag(source)
            }
        }
        .pickerStyle(.segmented)
    }

    private var exercisePicker: some View {
        DSCard {
            HStack {
                Text("Exercise")
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                Spacer()
                Picker("Exercise", selection: $realSelection) {
                    ForEach(availableRefs) { ref in
                        Text(ref.displayName).tag(Optional(ref))
                    }
                }
                .pickerStyle(.menu)
                .tint(DSColor.brand)
            }
        }
    }

    // MARK: - Analysis content

    @ViewBuilder
    private var analysisContent: some View {
        if strengthPoints.isEmpty && volumePoints.isEmpty {
            analysisEmptyState
        } else {
            if !strengthPoints.isEmpty {
                strengthChartCard
            }
            if !volumePoints.isEmpty {
                volumeChartCard
                accumulatedChartCard
            }
            statsGrid
        }
    }

    // MARK: - Charts

    private var strengthChartCard: some View {
        chartCard(
            title: "Strength — S(t)",
            subtitle: "Estimated 1-rep max (e1RM) per session, in \(unit)"
        ) {
            Chart {
                ForEach(strengthPoints, id: \.date) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("e1RM", p.value)
                    )
                    .foregroundStyle(DSColor.brand)
                    PointMark(
                        x: .value("Date", p.date),
                        y: .value("e1RM", p.value)
                    )
                    .foregroundStyle(DSColor.brand)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 220)
        }
    }

    private var volumeChartCard: some View {
        chartCard(
            title: "Per-session volume",
            subtitle: "Σ(weight × reps) each workout"
        ) {
            Chart {
                ForEach(volumePoints, id: \.date) { p in
                    BarMark(
                        x: .value("Date", p.date),
                        y: .value("Volume", p.volume)
                    )
                    .foregroundStyle(DSColor.brand.opacity(0.55))
                }
            }
            .frame(height: 170)
        }
    }

    private var accumulatedChartCard: some View {
        chartCard(
            title: "Accumulated volume — Riemann sum",
            subtitle: "Running total of volume across discrete sessions"
        ) {
            Chart {
                ForEach(volumePoints, id: \.date) { p in
                    AreaMark(
                        x: .value("Date", p.date),
                        y: .value("Accumulated", p.accumulatedVolume)
                    )
                    .foregroundStyle(DSColor.brand.opacity(0.15))
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Accumulated", p.accumulatedVolume)
                    )
                    .foregroundStyle(DSColor.brand)
                    PointMark(
                        x: .value("Date", p.date),
                        y: .value("Accumulated", p.accumulatedVolume)
                    )
                    .foregroundStyle(DSColor.brand)
                }
            }
            .frame(height: 170)
        }
    }

    // MARK: - Stats grid

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: DSSpacing.md),
                      GridItem(.flexible(), spacing: DSSpacing.md)],
            spacing: DSSpacing.md
        ) {
            StatCard(
                title: "Latest e1RM",
                value: "\(num(summary.latestValue)) \(unit)"
            )
            StatCard(
                title: "Total change",
                value: "\(signed(summary.totalChange)) \(unit)",
                caption: "first → latest",
                valueTint: changeTint(summary.totalChange)
            )
            StatCard(
                title: "Avg rate of change",
                value: "\(signed(summary.averageRatePerWeek)) \(unit)/wk",
                caption: "secant slope",
                valueTint: changeTint(summary.averageRatePerWeek)
            )
            StatCard(
                title: "Recent S′(t)",
                value: "\(signed(summary.recentDerivativePerWeek)) \(unit)/wk",
                caption: "≈ instantaneous rate",
                valueTint: changeTint(summary.recentDerivativePerWeek)
            )
            StatCard(
                title: "Status",
                value: summary.isPlateau ? "Plateau" : "Progressing",
                caption: "S′(t) ≈ 0 ?",
                valueTint: summary.isPlateau ? DSColor.warning : DSColor.success
            )
            StatCard(
                title: "Concavity",
                value: summary.concavity.label,
                caption: "S″ \(signed(summary.secondDerivativePerWeekSquared, 2))/wk²",
                valueTint: concavityTint(summary.concavity)
            )
            StatCard(
                title: "Total volume",
                value: "\(num(summary.totalAccumulatedVolume, 0))",
                caption: "\(unit)·reps accumulated"
            )
        }
    }

    // MARK: - Explanation

    private var explanationCard: some View {
        DSCard {
            Text("The Calculus")
                .font(.dsSection)
                .foregroundStyle(DSColor.textPrimary)

            conceptRow("S(t)", "Strength over time. Each session's estimated 1-rep max e1RM = w·(1 + r/30) is one data point.")
            conceptRow("ΔS/Δt", "Average rate of change — the secant slope between the first and latest session.")
            conceptRow("S′(t)", derivativeExplanation)
            conceptRow("S′≈0", "A plateau: the slope flattens, so strength barely changes week to week.")
            conceptRow("S″(t)", "The second derivative's sign says whether gains are accelerating (+) or slowing (−).")
            conceptRow("ΣV·Δt", "Training volume accumulates as a Riemann-sum running total because workouts happen at discrete times.")
        }
    }

    // MARK: - Empty states

    /// Real mode with no completed history yet — points the user at sample mode
    /// so the showcase still works on a fresh device.
    private var realEmptyState: some View {
        DSCard {
            Text("No completed workout history yet")
                .font(.dsSection)
                .foregroundStyle(DSColor.textPrimary)
            Text("Finish a workout with logged working sets to analyze your real progress, or switch to Sample Data to see the showcase.")
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DSSecondaryButton(title: "Use Sample Data", systemImage: "sparkles") {
                dataSource = .sample
            }
        }
    }

    /// Selected exercise resolved but produced no analyzable working sets.
    private var analysisEmptyState: some View {
        DSCard {
            Text("No analyzable working sets for this exercise.")
                .font(.dsBody)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func chartCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        DSCard {
            Text(title)
                .font(.dsSection)
                .foregroundStyle(DSColor.textPrimary)
            Text(subtitle)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func conceptRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Text(symbol)
                .font(.dsBodySecondary.weight(.semibold))
                .foregroundStyle(DSColor.brand)
                .frame(width: 52, alignment: .leading)
            Text(text)
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// S′(t) explainer that ties the finite-difference method to the actual
    /// value the cards show, with a graceful "not enough data" fallback.
    private var derivativeExplanation: String {
        let method = "Instantaneous rate of progress, estimated with finite differences "
            + "(central for interior points, one-sided at the ends). "
        guard let recent = summary.recentDerivativePerWeek else {
            return method + "Not enough data to estimate S′(t) yet."
        }
        let lead = dataSource == .sample ? "For this sample" : "For your history"
        let trend: String
        if summary.isPlateau {
            trend = "so progress is plateauing"
        } else if recent > 0 {
            trend = "so strength is still rising"
        } else if recent < 0 {
            trend = "so strength is dipping"
        } else {
            trend = "so it's essentially flat"
        }
        return method
            + "\(lead), S′(t) ≈ \(signed(recent)) \(unit)/week near the end, \(trend)."
    }

    // MARK: - Formatting (view-local; no shared pure helper to test)

    private func num(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f", v)
    }

    private func signed(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v else { return "—" }
        let body = String(format: "%.\(digits)f", v)
        return v > 0 ? "+\(body)" : body
    }

    private func changeTint(_ v: Double?) -> Color {
        guard let v else { return DSColor.textPrimary }
        if v > 0 { return DSColor.success }
        if v < 0 { return DSColor.error }
        return DSColor.textPrimary
    }

    private func concavityTint(_ c: StrengthAnalytics.Concavity) -> Color {
        switch c {
        case .accelerating:    return DSColor.success
        case .slowing:         return DSColor.warning
        case .roughlyConstant: return DSColor.textPrimary
        }
    }
}

// MARK: - StatCard

private struct StatCard: View {
    let title: String
    let value: String
    var caption: String? = nil
    var valueTint: Color = DSColor.textPrimary

    var body: some View {
        DSCard {
            Text(title.uppercased())
                .font(.dsCaption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.dsNumeric)
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftData
import SwiftUI

// ======================================================
// MARK: - Alternative Exercises — routine editor (Phase D)
// ======================================================
//
// Authoring only. Nothing here is read by the active workout yet: the session
// freeze (Phase E) and the switch sheet (Phase F) come later, so an alternative
// authored today is prepared work that the app stores, shows, and does not yet
// offer mid-workout.
//
// Shape follows the three sibling tools this row sits beside — `WarmupScheme`,
// `TechniquePlan`, `CardioSegmentPlan` — each one navigation row on the slot's
// prescription section, pushing a dedicated screen (§6.1). That keeps the cost
// of the feature at exactly one row for the slots that never use it.

// ======================================================
// MARK: - The prescription-section row
// ======================================================

/// `Alternative Exercises        2 ›` — the only thing this feature adds to the
/// slot prescription editor.
///
/// Its own view, holding its own `@Bindable`, so reading
/// `prescription.alternativesData` registers observation on the *grandchild*
/// model and the count refreshes when the editor writes. Reading it from
/// `SlotPrescriptionSection` directly would hit the nested-`@Model` observation
/// gap that `blockSummaryRefresh` and `SupersetSetCountLabel` already work
/// around.
struct AlternativeExercisesRow: View {
    @Bindable var prescription: SlotPrescription
    /// The slot's own exercise, for the authoring-time "this is already the
    /// slot's exercise" note (§8.5). Nil for an orphan slot.
    let slotExerciseID: UUID?

    var body: some View {
        NavigationLink {
            SlotAlternativesEditor(
                prescription: prescription, slotExerciseID: slotExerciseID)
        } label: {
            HStack {
                Text("Alternative Exercises")
                Spacer()
                Text(
                    SlotAlternativeSummary.countLabel(
                        prescription.slotAlternatives.count)
                )
                .foregroundStyle(.secondary)
            }
        }
    }
}

// ======================================================
// MARK: - The list screen
// ======================================================

/// The slot's prepared alternatives: add, reorder, delete, and push into one.
struct SlotAlternativesEditor: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var prescription: SlotPrescription
    let slotExerciseID: UUID?

    /// Cardio Slice 8 rule: observable, so a Settings change re-renders the
    /// summaries with the new unit.
    @AppStorage(AppSettings.Keys.distanceIsMetric)
    private var distanceIsMetric: Bool = AppSettings.defaultDistanceIsMetric()

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    @State private var showPicker = false
    /// Set after adding, to push straight into the new alternative's editor —
    /// the user asked for an alternative, so land them where the work is.
    @State private var pushedAlternativeID: UUID?

    private var alternatives: [SlotAlternative] { prescription.slotAlternatives }

    private var distanceUnit: DistanceUnit {
        AppSettings.distanceUnit(isMetric: distanceIsMetric)
    }

    private var effortMetric: EffortMetric? {
        switch AutoregMode(rawValue: autoregModeRaw) ?? .rir {
        case .rir: return .rir
        case .rpe: return .rpe
        case .none: return nil
        }
    }

    var body: some View {
        List {
            Section {
                if alternatives.isEmpty {
                    Text("No alternatives added")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(alternatives) { alternative in
                        NavigationLink {
                            detailEditor(for: alternative.id)
                        } label: {
                            AlternativeRowLabel(
                                alternative: alternative,
                                effortMetric: effortMetric,
                                displayUnit: distanceUnit)
                        }
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                }

                Button {
                    showPicker = true
                } label: {
                    Label("Add Alternative", systemImage: "plus")
                }
            } footer: {
                Text(
                    "Alternatives appear when you switch this exercise during a workout."
                )
            }
        }
        .navigationTitle("Alternative Exercises")
        .toolbar {
            if !alternatives.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .sheet(isPresented: $showPicker) {
            // The library is fetched **imperatively**, as the sheet is built,
            // rather than held in a `@Query`.
            //
            // This screen is a navigation push source (every row pushes a
            // detail), and `RoutineEditor`'s `@Query` comment records what that
            // combination cost once already: a query invalidation re-rendering
            // a link's source mid-push deadlocked the main thread. Nothing here
            // creates or edits an `Exercise`, so a live query would buy nothing
            // and carry that risk — and reading the list here, rather than into
            // `@State` from the button action, means the sheet can never be
            // built from a list that was staged one render too late.
            ExercisePickerSingle(exercises: libraryExercises()) { picked in
                if let picked { add(picked) }
            }
        }
        .navigationDestination(item: $pushedAlternativeID) { id in
            detailEditor(for: id)
        }
    }

    @ViewBuilder
    private func detailEditor(for id: UUID) -> some View {
        SlotAlternativeDetailEditor(
            prescription: prescription,
            alternativeID: id,
            slotExerciseID: slotExerciseID)
    }

    // MARK: - Mutations

    /// The exercise library, sorted by name — the order every other exercise
    /// picker in the app presents.
    private func libraryExercises() -> [Exercise] {
        (try? ctx.fetch(
            FetchDescriptor<Exercise>(
                sortBy: [SortDescriptor(\Exercise.name)]))) ?? []
    }

    /// Seeded from the app's defaults for the **picked** exercise's tracking
    /// mode, never from the slot's own plan (§6.3): the premise of the feature
    /// is that the primary's plan may be wrong for this exercise.
    private func add(_ exercise: Exercise) {
        let added = SlotAlternativeAuthoring.append(
            exerciseID: exercise.id,
            exerciseName: exercise.name,
            prescription: AlternativeDraftStore.defaultPayload(
                for: exercise.trackingMode),
            to: prescription)
        try? ctx.save()
        pushedAlternativeID = added.id
    }

    private func delete(at offsets: IndexSet) {
        SlotAlternativeAuthoring.delete(atOffsets: offsets, in: prescription)
        try? ctx.save()
    }

    private func move(from source: IndexSet, to destination: Int) {
        SlotAlternativeAuthoring.move(
            fromOffsets: source, toOffset: destination, in: prescription)
        try? ctx.save()
    }
}

// ======================================================
// MARK: - Row
// ======================================================

/// Name, one-line summary, and the disabled marker.
///
/// A disabled alternative is dimmed and tagged `Off` rather than hidden: the
/// editor is where prepared work lives, and hiding it there would leave the
/// user no way to switch it back on (§8.7).
private struct AlternativeRowLabel: View {
    let alternative: SlotAlternative
    let effortMetric: EffortMetric?
    let displayUnit: DistanceUnit

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                Text(alternative.exerciseName)
                    .lineLimit(1)
                if !alternative.isEnabled {
                    Text("Off")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                SlotAlternativeSummary.subtitle(
                    for: alternative, effortMetric: effortMetric,
                    displayUnit: displayUnit)
            )
            .font(.dsCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .opacity(alternative.isEnabled ? 1 : 0.6)
    }
}

// ======================================================
// MARK: - The detail editor
// ======================================================

/// One alternative: its exercise, whether it is offered, its usage note, and
/// its full prescription.
///
/// The prescription half is the **existing** `SlotPrescriptionSection` — the
/// same editor the routine slot itself uses, with all of its rules — bound to a
/// scratch slot in a throwaway in-memory store (`AlternativeDraftStore`).
/// Edits are committed to the real `SlotPrescription` whenever the draft's
/// payload changes, which matches the routine editor's commit-immediately
/// pattern and means there is no unsaved state to lose on a back-swipe.
///
/// There is deliberately **no Cancel**: no other routine-editor screen has one,
/// and adding one here would make this the only place where backing out of an
/// edit discards it.
struct SlotAlternativeDetailEditor: View {
    /// The **real** slot prescription. Read before the draft context is
    /// injected below, so this stays the app's context, not the draft's.
    @Environment(\.modelContext) private var ctx
    @Bindable var prescription: SlotPrescription
    let alternativeID: UUID
    let slotExerciseID: UUID?

    /// The scratch world. Built once, on appear — never in `init`, which
    /// SwiftUI may run for a `NavigationLink` destination that is never pushed.
    @State private var store: AlternativeDraftStore?
    @State private var exerciseName = ""
    @State private var exerciseID: UUID?
    @State private var isEnabled = true
    @State private var note = ""
    @State private var didLoad = false

    @FocusState private var noteFocused: Bool

    /// The edited prescription, as a value. Reading it in `body` registers
    /// observation on every scratch field the editors can change, which is what
    /// drives the commit below.
    private var draftPayload: AlternativePrescriptionPayload? {
        store?.payload()
    }

    private var isSlotsOwnExercise: Bool {
        guard let exerciseID, let slotExerciseID else { return false }
        return exerciseID == slotExerciseID
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Exercise")
                    Spacer()
                    Text(exerciseName)
                        .foregroundStyle(.secondary)
                }
                Toggle("Enabled", isOn: $isEnabled)
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($noteFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            if noteFocused {
                                Spacer()
                                KeyboardDismissButton()
                            }
                        }
                    }
            } footer: {
                if isSlotsOwnExercise {
                    // Warned, not blocked (§8.5). The switch sheet will hide a
                    // same-exercise alternative rather than refuse to store it,
                    // so authoring one is pointless but never destructive.
                    Text("This is already the slot's exercise.")
                }
            }

            if let store {
                SlotPrescriptionSection(
                    re: store.slot,
                    isTimeBased: store.exercise.isTimeBased,
                    // No alternatives-of-alternatives: one level is the
                    // feature, two is a graph.
                    showsAlternatives: false,
                    // The warm-up and technique editors are pushed **on top of
                    // this screen**, so a step added in one mutates the scratch
                    // graph while this view is off-screen. The `.onChange`
                    // below cannot see that — it only fires when this body is
                    // re-evaluated, which never happens if the user leaves by
                    // switching tabs or popping straight back to the routine.
                    // The edit then died with the draft container. This hook
                    // makes the commit a call rather than an inference.
                    onNestedGraphChange: { commit() }
                )
                // Every editor below this line writes into the throwaway
                // store — `WarmupSchemeEditor`, `TechniquePlanEditor` and
                // `CardioSegmentPlanEditor` all insert through
                // `@Environment(\.modelContext)`, so this one line is what
                // keeps their rows out of the user's database.
                .environment(\.modelContext, store.context)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(exerciseName.isEmpty ? Text("Alternative Exercises") : Text(exerciseName))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        // Still the commit for everything edited *on this screen* —
        // `PrescriptionFields`' sets / reps / rest / effort / distance rows all
        // re-render this body, so the value change is seen. It is no longer the
        // only commit: the nested editors call `commit()` directly.
        .onChange(of: draftPayload) { _, payload in
            guard let payload else { return }
            commit(payload: payload)
        }
        .onChange(of: isEnabled) { _, _ in commit() }
        .onChange(of: note) { _, _ in commit() }
        // Belt to the hook's braces. Idempotent — committing the same payload
        // twice rewrites identical bytes — and it catches any edit path that
        // leaves without a value change this view happened to observe.
        .onDisappear { commit() }
    }

    // MARK: - Load

    /// Hydrate the scratch slot from the stored alternative, once.
    ///
    /// The tracking mode comes from the **live** exercise when it still
    /// resolves, so an alternative whose exercise was later flipped to cardio
    /// is edited under the mode it will actually be applied with (§8.4). When
    /// the exercise is gone, the payload's own shape is the best available
    /// reading — and the stored `exerciseName` still names the row.
    private func load() {
        guard !didLoad else { return }
        didLoad = true

        guard
            let alternative = prescription.slotAlternatives.first(where: {
                $0.id == alternativeID
            })
        else { return }

        exerciseID = alternative.exerciseID
        isEnabled = alternative.isEnabled
        note = alternative.note ?? ""

        let resolved = resolveExercise(alternative.exerciseID)
        exerciseName =
            resolved?.name ?? alternative.exerciseName

        store = try? AlternativeDraftStore(
            exerciseName: exerciseName,
            trackingMode: resolved?.trackingMode
                ?? fallbackMode(for: alternative.prescription),
            equipmentType: resolved?.equipmentType,
            includesBodyweightInLoad: resolved?.includesBodyweightInLoad ?? false,
            payload: alternative.prescription)
    }

    private func resolveExercise(_ id: UUID) -> Exercise? {
        var descriptor = FetchDescriptor<Exercise>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? ctx.fetch(descriptor))?.first
    }

    /// Mode for an alternative whose exercise no longer exists: what the stored
    /// plan itself implies. Never invents cardio for a rep-based payload.
    private func fallbackMode(
        for payload: AlternativePrescriptionPayload
    ) -> TrackingMode {
        guard payload.usesDuration else { return .strength }
        let hasCardioTargets =
            payload.targetDistanceMeters != nil || payload.cardioSegments != nil
        return hasCardioTargets ? .cardio : .timedHold
    }

    // MARK: - Commit

    /// Write the edited alternative back, addressed by id.
    ///
    /// Delegates to `AlternativeDraftCommit`, which reads the stored list,
    /// replaces exactly this alternative's fields, and writes the whole list
    /// back through `setSlotAlternatives` — so the slot's own prescription and
    /// every other alternative are untouched, and `id` and `order` survive an
    /// edit. Extracted so the write-back rule is testable without a view, and
    /// so the nested editors can trigger it directly.
    private func commit(payload: AlternativePrescriptionPayload? = nil) {
        guard didLoad else { return }
        // Falls back to the draft's *current* payload when the caller has none
        // — which is every call from a nested editor, and from `onDisappear`.
        AlternativeDraftCommit.commit(
            draft: store,
            alternativeID: alternativeID,
            isEnabled: isEnabled,
            note: note,
            payload: payload,
            into: prescription,
            context: ctx)
    }
}

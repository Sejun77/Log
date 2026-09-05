import SwiftData
import SwiftUI

// ======================================================
// MARK: - Structured cardio plan editor (Slice 12C)
// ======================================================

/// Authoring screen for a cardio slot's segment plan.
///
/// Pushed from the slot's prescription section, mirroring `WarmupSchemeEditor`
/// and `TechniquePlanEditor` — one list, edit in place, no modal stack.
///
/// **Repeats are not exposed here.** `CardioSegmentGroup.repeatCount` exists in
/// the model, is enforced, and round-trips, but this editor authors exactly one
/// group with `repeatCount == 1`. Interval UI is Slice 12F; writing the field
/// now means it needs no schema, decoder, or export change when it ships.
struct CardioSegmentPlanEditor: View {

    @Bindable var prescription: SlotPrescription

    /// Display/entry unit for segment distances. Observable so a Settings
    /// change re-renders an open editor — the Slice 8 rule.
    @AppStorage(AppSettings.Keys.distanceIsMetric)
    private var distanceIsMetric: Bool = AppSettings.defaultDistanceIsMetric()

    /// The working copy. Held as `@State` rather than read from the model each
    /// render because `CardioSegment` is immutable: an edit replaces an element,
    /// and the list needs somewhere to hold the result before it is re-encoded.
    /// Committed after every mutation, so there is no unsaved state to lose.
    @State private var segments: [CardioSegment] = []
    @State private var editingSegmentID: CardioSegment.ID?
    @State private var didLoad = false

    private var distanceUnit: DistanceUnit {
        AppSettings.distanceUnit(isMetric: distanceIsMetric)
    }

    /// Segment total, plus a mismatch cue when it differs from the slot's
    /// target distance. Renders nothing when the plan carries no distances —
    /// a duration-only plan has no total to state.
    @ViewBuilder
    private var targetComparison: some View {
        switch CardioPlanTargetCheck.evaluate(
            targetMeters: prescription.targetDistanceMeters,
            segmentTotalMeters: plan?.totalDistanceMeters,
            displayUnit: distanceUnit)
        {
        case .nothingToShow:
            EmptyView()
        case .total(let total):
            Text(CardioPlanTargetCheck.totalCaption(total))
                .foregroundStyle(.secondary)
        case .mismatch(let total, _):
            VStack(alignment: .leading, spacing: 2) {
                Text(CardioPlanTargetCheck.totalCaption(total))
                    .foregroundStyle(.secondary)
                Text(CardioPlanTargetCheck.mismatchCaption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Body

    var body: some View {
        List {
            if segments.isEmpty {
                Section {
                    Text(
                        "Add warm-up, work, recovery, or cool-down segments."
                    )
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(segments) { segment in
                        Button {
                            editingSegmentID = segment.id
                        } label: {
                            row(for: segment)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                } header: {
                    DSSectionHeader(
                        title: "Segments", systemImage: "list.number")
                } footer: {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        // Verbatim, like every other composed plan summary in
                        // the app (`SessionPlan.primarySummary`, block
                        // summaries): the string is assembled from numbers and
                        // units, so there is no whole phrase to translate.
                        Text(plan?.summary(distanceUnit: distanceUnit) ?? "")
                        // Audit L5 — the segment distances and the slot's
                        // target distance are independent fields that could
                        // silently describe different sessions. This states the
                        // total and, when it disagrees with the target beside
                        // it, says so. It never adjusts either value and never
                        // blocks saving: a plan that deliberately covers part
                        // of a longer target is a real thing to author.
                        targetComparison
                    }
                    .font(.dsCaption)
                }
            }

            Section {
                Menu {
                    ForEach(CardioSegmentKind.allCases, id: \.self) { kind in
                        Button {
                            add(kind: kind)
                        } label: {
                            Text(LocalizedStringKey(kind.label))
                        }
                    }
                } label: {
                    Label("Add Segment", systemImage: "plus.circle")
                }
                .disabled(isFull)
            } footer: {
                if isFull {
                    Text("This plan is full.")
                        .font(.dsCaption)
                }
            }
        }
        .navigationTitle("Cardio Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !segments.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .sheet(item: editingSegmentBinding) { segment in
            NavigationStack {
                CardioSegmentEditorSheet(
                    segment: segment,
                    distanceUnit: distanceUnit,
                    onSave: { updated in replace(updated) },
                    onDelete: { remove(id: segment.id) }
                )
            }
        }
        .onAppear(perform: loadOnce)
    }

    // MARK: Rows

    private func row(for segment: CardioSegment) -> some View {
        HStack(spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(segment.kind.label))
                    .font(.dsBody)
                // Targets only — the kind is already the line above. Verbatim
                // for the same reason as the plan summary.
                Text(segment.shortTargetSummary(distanceUnit: distanceUnit))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                if let note = segment.note {
                    Text(note)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DSSpacing.sm)
            Image(systemName: "chevron.right")
                .font(.dsCaption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: Plan state

    private var plan: CardioSegmentPlan? {
        Self.plan(from: segments)
    }

    /// One group, `repeatCount == 1` — see the type's note on repeats.
    /// Returns nil (not an error) for an empty list: no segments is a valid
    /// state, and it is what clears the column.
    private static func plan(from segments: [CardioSegment])
        -> CardioSegmentPlan?
    {
        guard !segments.isEmpty else { return nil }
        guard
            let group = try? CardioSegmentGroup(segments: segments),
            let plan = try? CardioSegmentPlan(groups: [group])
        else { return nil }
        return plan
    }

    private var isFull: Bool {
        segments.count >= min(
            CardioPlanLimits.maxSegmentsPerGroup,
            CardioPlanLimits.maxExpandedSegments)
    }

    private var editingSegmentBinding: Binding<CardioSegment?> {
        Binding(
            get: { segments.first { $0.id == editingSegmentID } },
            set: { if $0 == nil { editingSegmentID = nil } }
        )
    }

    /// Read the stored plan once. The guard stops a re-render or a navigation
    /// return from discarding in-progress list state — the same shape
    /// `TargetDistanceRow.seedFromModel` uses.
    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        segments = prescription.structuredCardioPlan?
            .groups.flatMap(\.segments) ?? []
    }

    // MARK: Mutations

    private func add(kind: CardioSegmentKind) {
        guard !isFull else { return }
        // Seeded with a plausible duration so a freshly added row is already a
        // valid segment (one with no target could not be constructed at all).
        guard
            let segment = try? CardioSegment(
                kind: kind, durationSeconds: kind.defaultDurationSeconds)
        else { return }
        segments.append(segment)
        commit()
        editingSegmentID = segment.id
    }

    private func replace(_ updated: CardioSegment) {
        guard let index = segments.firstIndex(where: { $0.id == updated.id })
        else { return }
        segments[index] = updated
        commit()
    }

    private func remove(id: CardioSegment.ID) {
        segments.removeAll { $0.id == id }
        commit()
    }

    private func delete(at offsets: IndexSet) {
        segments.remove(atOffsets: offsets)
        commit()
    }

    private func move(from source: IndexSet, to destination: Int) {
        segments.move(fromOffsets: source, toOffset: destination)
        commit()
    }

    /// Write the list back to the slot. Order is the list's order — a plan is a
    /// sequence, and a cool-down that sorted itself before the work would be a
    /// different session.
    private func commit() {
        prescription.setStructuredCardioPlan(Self.plan(from: segments))
    }
}

// ======================================================
// MARK: - Segment editor sheet
// ======================================================

/// Compact editor for one segment. Every field is optional; the sheet refuses
/// to save only when *all* of them are empty, which is the one state
/// `CardioSegment` cannot represent.
struct CardioSegmentEditorSheet: View {

    let segment: CardioSegment
    let distanceUnit: DistanceUnit
    let onSave: (CardioSegment) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: CardioSegmentKind
    @State private var durationSeconds: Int?
    @State private var distanceText: String
    @State private var inclineText: String
    @State private var resistanceText: String
    @State private var hrZone: HRZone?
    @State private var note: String

    init(
        segment: CardioSegment,
        distanceUnit: DistanceUnit,
        onSave: @escaping (CardioSegment) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.segment = segment
        self.distanceUnit = distanceUnit
        self.onSave = onSave
        self.onDelete = onDelete
        _kind = State(initialValue: segment.kind)
        _durationSeconds = State(initialValue: segment.durationSeconds)
        _distanceText = State(
            initialValue: CardioTargetDistance(
                meters: segment.distanceMeters, displayUnit: distanceUnit)?
                .valueText ?? "")
        _inclineText = State(
            initialValue: segment.inclinePercent.flatMap {
                CardioDerived.formatDistance(value: abs($0)).map {
                    text in (segment.inclinePercent ?? 0) < 0 ? "-\(text)" : text
                }
            } ?? "")
        _resistanceText = State(
            initialValue: segment.resistanceLevel.flatMap {
                CardioDerived.formatDistance(value: $0)
            } ?? "")
        _hrZone = State(initialValue: segment.hrZone)
        _note = State(initialValue: segment.note ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(CardioSegmentKind.allCases, id: \.self) { kind in
                        Text(LocalizedStringKey(kind.label)).tag(kind)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                DurationFieldRow(
                    title: "Duration",
                    seconds: $durationSeconds,
                    maxSeconds: DurationLimits.maxExerciseSeconds,
                    presets: [60, 120, 300, 600, 1_200]
                )
                decimalRow(
                    "Distance", text: $distanceText,
                    unit: distanceUnit.symbol)
                decimalRow("Incline / Decline", text: $inclineText, unit: "%")
                decimalRow("Resistance", text: $resistanceText, unit: "")
                Picker("Heart-Rate Zone", selection: $hrZone) {
                    Text("None").tag(HRZone?.none)
                    ForEach(HRZone.allCases, id: \.self) { zone in
                        Text(zone.shortLabel).tag(HRZone?.some(zone))
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Every field is optional. Fill in at least one.")
                    .font(.dsCaption)
            }

            Section {
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(1...3)
            }

            Section {
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Text("Remove Segment")
                }
            }
        }
        .navigationTitle(LocalizedStringKey(kind.label))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
                    .disabled(built == nil)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                KeyboardDismissButton()
            }
        }
    }

    private func decimalRow(
        _ title: LocalizedStringKey, text: Binding<String>, unit: String
    ) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Text(title)
            Spacer(minLength: DSSpacing.sm)
            TextField("—", text: text)
                .font(.dsBody.monospacedDigit())
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .multilineTextAlignment(.trailing)
            if !unit.isEmpty {
                Text(unit)
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The segment this sheet's fields describe, or nil when nothing usable was
    /// entered. Drives the Done button, so "at least one target" is enforced by
    /// the control being unavailable rather than by an alert after the fact.
    private var built: CardioSegment? {
        try? CardioSegment(
            id: segment.id,
            kind: kind,
            durationSeconds: durationSeconds,
            distanceMeters: CardioMetrics.parseDistance(
                distanceText, unit: distanceUnit),
            inclinePercent: CardioMetrics.parseInclinePercent(inclineText),
            resistanceLevel: CardioMetrics.parseResistanceLevel(resistanceText),
            hrZone: hrZone,
            note: note
        )
    }

    private func save() {
        guard let built else { return }
        onSave(built)
        dismiss()
    }
}

// ======================================================
// MARK: - Editor-facing helpers
// ======================================================

extension CardioSegmentKind {
    /// Starting duration for a freshly added segment, so the row is immediately
    /// valid and roughly right. Editable at once — the sheet opens on add.
    var defaultDurationSeconds: Int {
        switch self {
        case .warmUp, .coolDown: return 300
        case .work: return 600
        case .recovery: return 120
        }
    }
}

// `CardioSegment.shortTargetSummary` moved to `StructuredCardioPlan.swift` in
// Slice 12D: the active-workout checklist renders the same kind-less target
// line, and a summary shared by two features belongs beside the other
// summaries rather than in one feature's editor.

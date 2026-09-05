import SwiftData
import SwiftUI

// MARK: - Technique Plan Editor

// Editor for the list of TechniquePlan entries on a SlotPrescription.
// Access is default-internal so `SlotPrescriptionSection` (in
// `Log/Main/Routines/PrescriptionFields.swift`) can navigate to this
// editor across files.
struct TechniquePlanEditor: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var prescription: SlotPrescription
    /// True when the parent exercise is bodyweight: the weight-based Drop Set
    /// technique is blocked in the picker. Defaults false so non-bodyweight
    /// behavior is unchanged.
    var isBodyweight: Bool = false
    /// Called after **every** mutation this editor (or the parameter screen it
    /// pushes) makes to the prescription's technique graph — add, edit, delete,
    /// reorder. Nil for a routine slot; non-nil only for the prepared-alternative
    /// editor, which cannot see the change for itself while it is off-screen.
    /// See `AlternativeDraftCommit`.
    var onGraphChange: (() -> Void)? = nil
    @State private var showAdd = false
    @State private var addType: TechniqueType = .dropset
    /// Non-nil drives the "Delete Technique?" confirmation alert. Set by
    /// the per-row swipe Delete button (a roleless `.swipeActions`
    /// `Button`, tinted red) without mutating; the actual
    /// `deletePlans(at:)` call lives inside the alert's destructive
    /// button (wrapped in `withAnimation`). See the rationale on
    /// `BodyPartPicker.pendingSharedRemoval`: a `.onDelete` handler or a
    /// `role: .destructive` swipe button produces a
    /// collapse-then-spring-back glitch, so edit-mode delete is dropped
    /// here — `EditButton` still drives reordering via `.onMove`.
    @State private var pendingDeleteOffsets: IndexSet? = nil

    /// The plans this editor lists: only those still legal for the slot.
    ///
    /// `SlotPrescriptionSection.ensurePrescription` deletes incompatible plans
    /// when it appears, but that runs *after* the first render — and this
    /// editor can also be reached with a prescription that has not been through
    /// that heal yet. Filtering here keeps the list honest at all times, so a
    /// duration slot never lists a Tempo Override.
    private var sorted: [TechniquePlan] {
        compatibleTechniquePlans(
            prescription.techniquePlans,
            isBodyweight: isBodyweight,
            usesDuration: prescription.usesDuration
        )
        .sorted { $0.order < $1.order }
    }

    var body: some View {
        List {
            Section {
                if sorted.isEmpty {
                    Text("No techniques. Tap + to add.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sorted) { plan in
                    NavigationLink {
                        TechniqueParamEditView(
                            plan: plan,
                            siblingTechniques: sorted,
                            setCount: prescription.sets ?? 3,
                            onGraphChange: onGraphChange
                        )
                    } label: {
                        TechniquePlanRow(plan: plan)
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button {
                            if let idx = sorted.firstIndex(where: {
                                $0.id == plan.id
                            }) {
                                pendingDeleteOffsets = IndexSet(integer: idx)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                .onMove(perform: movePlans)
            } header: {
                Text("Techniques")
            }
        }
        .navigationTitle("Techniques")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            TechniqueTypePickerSheet(
                existingTechniques: sorted,
                setCount: prescription.sets ?? 3,
                usesDuration: prescription.usesDuration,
                isBodyweight: isBodyweight,
                onPick: { t in addPlan(type: t) }
            )
        }
        .alert(
            "Delete Technique?",
            isPresented: Binding(
                get: { pendingDeleteOffsets != nil },
                set: { if !$0 { pendingDeleteOffsets = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDeleteOffsets = nil
            }
            Button("Delete", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    withAnimation {
                        deletePlans(at: offsets)
                    }
                }
                pendingDeleteOffsets = nil
            }
        } message: {
            Text(
                "This technique will be removed from this slot. Its configuration will be lost."
            )
        }
    }

    /// The store this editor writes into: **the one the edited prescription
    /// already lives in**, not whatever `@Environment(\.modelContext)` resolves
    /// to.
    ///
    /// For every routine slot the two are the same object, so ordinary
    /// technique editing is unchanged. They differ for the scratch slot the
    /// Alternative Exercises detail editor binds this editor to, which lives in
    /// `AlternativeDraftStore`'s own in-memory container: writing there through
    /// the environment saved the plan into the *user's* store and related it
    /// across containers, and deleting through it was a silent no-op. See
    /// `TechniquePlanAuthoring` for the full note.
    private var writeContext: ModelContext {
        TechniquePlanAuthoring.writeContext(for: prescription, fallback: ctx)
    }

    private func addPlan(type: TechniqueType) {
        TechniquePlanAuthoring.addPlan(
            type: type, to: prescription, fallbackContext: ctx)
        onGraphChange?()
    }

    private func deletePlans(at offsets: IndexSet) {
        let s = sorted
        TechniquePlanAuthoring.delete(
            offsets.map { s[$0] },
            from: prescription,
            fallbackContext: ctx)
        for (i, p) in sorted.enumerated() { p.order = i }
        try? writeContext.save()
        onGraphChange?()
    }

    private func movePlans(from source: IndexSet, to destination: Int) {
        var s = sorted
        s.move(fromOffsets: source, toOffset: destination)
        for (i, p) in s.enumerated() { p.order = i }
        try? writeContext.save()
        onGraphChange?()
    }
}

// A single row summarising one TechniquePlan.
private struct TechniquePlanRow: View {
    @Bindable var plan: TechniquePlan

    private var title: String {
        switch plan.type {
        case .dropset:       return "Drop Set"
        case .partialReps:   return "Partial Reps"
        case .restPause:     return "Rest-Pause"
        case .amrap:         return "AMRAP"
        case .toFailure:     return "To Failure"
        case .cluster:       return "Cluster"
        case .tempoOverride: return "Tempo Override"
        }
    }

    private var detail: String {
        var parts: [String] = []
        let indices = plan.appliesToSetIndices
        if !indices.isEmpty {
            let nums = indices.sorted().map { String($0 + 1) }.joined(separator: ",")
            parts.append(indices.count == 1 ? "set \(nums)" : "sets \(nums)")
        } else if plan.appliesToRaw != "lastWorkingSet" {
            parts.append(plan.appliesTo.displayLabel)
        }
        if let r = plan.rounds,   r > 0  { parts.append("\(r) rounds") }
        if let r = plan.reps,     r > 0  { parts.append("\(r) reps") }
        if let d = plan.dropPercent, d > 0 { parts.append("\(Int(d))% drop") }
        if plan.type == .dropset {
            switch plan.dropsetEffort {
            case .amrap:            parts.append("AMRAP")
            case .fixedReps(let n): parts.append("\(n) reps/drop")
            }
        }
        if let s = plan.restSeconds, s > 0 { parts.append(String(localized: "\(s)s rest")) }
        if let n = plan.note, !n.isEmpty  { parts.append(n) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.dsBody)
            if !detail.isEmpty {
                Text(detail)
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// Sheet for picking a technique type when adding a new TechniquePlan.
private struct TechniqueTypePickerSheet: View {
    var existingTechniques: [TechniquePlan]
    /// Working set count from prescription — used for per-index conflict checking.
    var setCount: Int = 3
    /// When true, rep-count-dependent techniques are disabled (not applicable to duration sets).
    var usesDuration: Bool = false
    /// When true, the weight-based Drop Set technique is blocked.
    var isBodyweight: Bool = false
    var onPick: (TechniqueType) -> Void
    @Environment(\.dismiss) private var dismiss

    private let types: [(TechniqueType, String, String)] = [
        (.dropset,       "Drop Set",       "Reduce weight immediately after reaching failure."),
        (.partialReps,   "Partial Reps",   "Continue with partial range of motion after failure."),
        (.restPause,     "Rest-Pause",      "Short intra-set rest, then continue."),
        (.amrap,         "AMRAP",           "As many reps as possible on last set."),
        (.toFailure,     "To Failure",      "Push until technical failure."),
        (.cluster,       "Cluster",         "Intra-set pause clusters."),
        (.tempoOverride, "Tempo Override",  "Override tempo for this exercise."),
    ]

    /// Effective 0-based indices for an existing technique (uses new field or migrates old).
    private func effectiveIndices(for plan: TechniquePlan) -> Set<Int> {
        let idx = plan.appliesToSetIndices   // computed on TechniquePlan
        if !idx.isEmpty { return idx }
        let n = max(1, setCount)
        switch plan.appliesTo {
        case .lastWorkingSet: return [n - 1]
        case .allWorkingSets: return Set(0..<n)
        case .setNumber(let s): return [s - 1]
        }
    }

    /// Returns a block message if adding `newType` (defaults to last set index)
    /// would create a duplicate or violate conflict rules. Returns nil if allowed.
    private func conflictMessage(for newType: TechniqueType) -> String? {
        // Type-level availability (bodyweight + duration) — pure, independent
        // of existing techniques.
        if let msg = techniqueConflictMessage(
            for: newType, isBodyweight: isBodyweight, usesDuration: usesDuration
        ) {
            return msg
        }

        let defaultIdx = max(0, setCount - 1)
        let onDefault = existingTechniques.filter { effectiveIndices(for: $0).contains(defaultIdx) }

        // 1. Duplicate: same type already exists on the last set (set-number message).
        if onDefault.contains(where: { $0.type == newType }) {
            return "\(newType.displayName) already exists on set \(defaultIdx + 1)."
        }

        // 2. Cross-technique structural conflicts (shared pairwise rules).
        for existing in onDefault {
            if let msg = techniquePairConflict(newType, existing.type) {
                return msg
            }
        }

        return nil
    }

    var body: some View {
        NavigationStack {
            List(types, id: \.0) { type, name, desc in
                let conflict = conflictMessage(for: type)
                Button {
                    guard conflict == nil else { return }
                    onPick(type)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(name))
                            .font(.dsBody)
                            .foregroundStyle(conflict != nil ? Color.secondary : Color.primary)
                        Text(LocalizedStringKey(conflict ?? desc))
                            .font(.dsBodySecondary)
                            .foregroundStyle(conflict != nil ? Color.red.opacity(0.75) : Color.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .disabled(conflict != nil)
            }
            .navigationTitle("Add Technique")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Technique availability (pure helper)

/// Techniques that are not applicable to duration-based prescriptions.
///
/// Most of these require a rep count (`.dropset`, `.partialReps`, `.restPause`,
/// `.cluster`, `.amrap`). `.tempoOverride` is here for the same underlying
/// reason expressed differently: a tempo describes eccentric/concentric rep
/// phases, and a duration-based exercise has no reps to phase. This mirrors the
/// prescription-level rule that hides and clears `SlotPrescription.tempo` for
/// duration slots — Entry #12 P1 made the two consistent so tempo cannot reach
/// a duration exercise by either route.
let techniquesIncompatibleWithDuration: Set<TechniqueType> =
    [.dropset, .partialReps, .restPause, .cluster, .amrap, .tempoOverride]

/// Type-level availability gate for adding a technique, independent of any
/// existing techniques on the prescription. Returns a block message, or nil
/// when the type passes these checks.
///
/// - Bodyweight exercises block `.dropset` (a weight-reduction technique).
/// - Duration-based prescriptions block rep-count-dependent techniques.
///
/// Per-set duplicate / intensity-finisher conflict rules are evaluated
/// separately in `TechniqueTypePickerSheet.conflictMessage(for:)`.
func techniqueConflictMessage(
    for type: TechniqueType, isBodyweight: Bool, usesDuration: Bool
) -> String? {
    if isBodyweight && type == .dropset {
        return "Not available for bodyweight exercises."
    }
    if usesDuration && techniquesIncompatibleWithDuration.contains(type) {
        return "Not available for duration-based exercises."
    }
    return nil
}

/// Convenience boolean wrapper around `techniqueConflictMessage`.
func isTechniqueAllowed(
    _ type: TechniqueType, isBodyweight: Bool, usesDuration: Bool
) -> Bool {
    techniqueConflictMessage(
        for: type, isBodyweight: isBodyweight, usesDuration: usesDuration
    ) == nil
}

/// Filter technique snapshots down to the ones that are legal for a slot with
/// the given equipment / tracking type.
///
/// The authoring path blocks incompatible techniques at add time, but a
/// prescription can still *hold* one that later became illegal — the slot was
/// flipped to duration, the exercise was switched, or the routine was imported
/// from JSON. Render paths run everything through this so a stale technique is
/// suppressed rather than displayed, following the same
/// "resolve-don't-mutate" precedent as
/// `ActiveWorkoutView.dropsetSupportedActive` for stale bodyweight Drop Sets.
/// Pure.
func compatibleTechniques(
    _ snapshots: [TechniquePlanSnapshot],
    isBodyweight: Bool,
    usesDuration: Bool
) -> [TechniquePlanSnapshot] {
    snapshots.filter {
        isTechniqueAllowed(
            $0.type, isBodyweight: isBodyweight, usesDuration: usesDuration)
    }
}

/// `compatibleTechniques` over live `TechniquePlan` models (routine-editor
/// side). Same rule, different element type — returns the plans that are still
/// legal for the slot.
func compatibleTechniquePlans(
    _ plans: [TechniquePlan],
    isBodyweight: Bool,
    usesDuration: Bool
) -> [TechniquePlan] {
    plans.filter {
        isTechniqueAllowed(
            $0.type, isBodyweight: isBodyweight, usesDuration: usesDuration)
    }
}

/// Pairwise structural conflict between two techniques applied to the SAME set.
/// Order-independent. Returns a block message, or nil when the pair may coexist.
///
/// This encodes only cross-technique structural rules plus same-type
/// duplication. Type-level availability (bodyweight / duration) is handled
/// separately by `techniqueConflictMessage(for:isBodyweight:usesDuration:)`, and
/// Dropset effort × AMRAP validation by `TechniqueParamEditView.conflictForEffort`.
///
/// Allowed (notable): Drop Set + Rest-Pause and Rest-Pause + AMRAP — Rest-Pause
/// is display-only at runtime, so these do not affect logging/rest. AMRAP + To
/// Failure is a rep-target + effort-target combo, redundant but not structural.
func techniquePairConflict(_ a: TechniqueType, _ b: TechniqueType) -> String? {
    // Same technique twice on one set.
    if a == b {
        return "\(a.displayName) is already on this set."
    }

    let pair: Set<TechniqueType> = [a, b]

    // Drop Set already carries its own AMRAP / fixed-reps effort mode, so a
    // separate AMRAP technique on the same set is redundant.
    if pair == [.dropset, .amrap] {
        return "Dropset already defines AMRAP/fixed reps; remove it to use AMRAP."
    }
    // Drop Set and Cluster describe different set structures; the dropset card
    // cannot represent a cluster.
    if pair == [.dropset, .cluster] {
        return "Cluster can't combine with Drop Set on the same set."
    }
    // Rest-Pause and Cluster are both intra-set rest structures.
    if pair == [.restPause, .cluster] {
        return "Rest-Pause and Cluster can't share a set."
    }
    // Cluster prescribes fixed reps per mini-set; AMRAP changes the rep target.
    if pair == [.cluster, .amrap] {
        return "Cluster and AMRAP can't share a set."
    }
    return nil
}

// Edit parameters of an existing TechniquePlan (pushed via NavigationLink).
private struct TechniqueParamEditView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var plan: TechniquePlan
    /// All techniques on the same prescription (including self), for conflict detection.
    var siblingTechniques: [TechniquePlan] = []
    /// Working set count from the prescription (used for per-set-index UI and conflict checks).
    var setCount: Int = 3
    /// Forwarded from `TechniquePlanEditor`. This screen is pushed a further
    /// level deep, so for a prepared alternative it is the furthest point from
    /// the view that owns the commit — and the one most likely to be left by a
    /// route that never re-renders it.
    var onGraphChange: (() -> Void)? = nil

    /// Same rule as `TechniquePlanEditor.writeContext`, resolved from the plan
    /// itself: this screen is pushed one level deeper still, so in a prepared
    /// alternative the environment's context belongs to the app while the plan
    /// belongs to the draft container — and saving the wrong store silently
    /// flushed nothing. Identical to `ctx` for every routine slot.
    private var writeContext: ModelContext { plan.modelContext ?? ctx }

    /// Transient error shown when a set-index toggle is blocked by a conflict.
    @State private var appliesToErrorMsg: String? = nil
    /// Transient error shown when a Dropset effort change is immediately reverted.
    @State private var effortErrorMsg: String? = nil
    /// Focus for the Custom Partial Note field so its Done key can dismiss the
    /// keyboard (single-line, app-consistent — mirrors `RoutineEditor`).
    @FocusState private var customNoteFocused: Bool

    // MARK: - Conflict helpers (per-index)

    /// Effective 0-based indices for a sibling technique (new field or migrated from old).
    private func effectiveIndices(for p: TechniquePlan) -> Set<Int> {
        let idx = p.appliesToSetIndices
        if !idx.isEmpty { return idx }
        let n = max(1, setCount)
        switch p.appliesTo {
        case .lastWorkingSet: return [n - 1]
        case .allWorkingSets: return Set(0..<n)
        case .setNumber(let s): return [s - 1]
        }
    }

    /// Current resolved indices for the plan being edited.
    private var currentIndices: Set<Int> {
        let idx = plan.appliesToSetIndices
        if !idx.isEmpty { return idx }
        let n = max(1, setCount)
        switch plan.appliesTo {
        case .lastWorkingSet: return [n - 1]
        case .allWorkingSets: return Set(0..<n)
        case .setNumber(let s): return [s - 1]
        }
    }

    /// Returns a conflict message if toggling `idx` on (adding it) would break rules.
    private func conflictForAdding(idx: Int) -> String? {
        let sibs = siblingTechniques.filter { $0.persistentModelID != plan.persistentModelID }
        let sibsOnIdx = sibs.filter { effectiveIndices(for: $0).contains(idx) }

        // Duplicate type on same index (set-number message).
        if sibsOnIdx.contains(where: { $0.type == plan.type }) {
            return "\(plan.type.displayName) already on set \(idx + 1)."
        }
        // Cross-technique structural conflicts (shared pairwise rules).
        for sib in sibsOnIdx {
            if let msg = techniquePairConflict(plan.type, sib.type) {
                return msg
            }
        }
        return nil
    }

    /// Returns a message if switching Dropset effort to `effortRaw` is blocked.
    private func conflictForEffort(_ effortRaw: String) -> String? {
        guard plan.type == .dropset, effortRaw == "fixedReps" else { return nil }
        let planIndices = currentIndices
        let amrapOverlap = siblingTechniques.contains {
            $0.persistentModelID != plan.persistentModelID
                && $0.type == .amrap
                && !effectiveIndices(for: $0).isDisjoint(with: planIndices)
        }
        return amrapOverlap ? "AMRAP exists on an overlapping set; can't use fixed reps." : nil
    }

    var body: some View {
        Form {
            appliesToSection
            techniqueParamSection
        }
        .navigationTitle(typeName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: plan.dropPercent)              { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.dropCount)                { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.rounds)                   { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.restSeconds)              { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.reps)                     { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.partialRangeNote)         { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.partialRangeRaw)          { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.note)                     { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.appliesToRaw)             { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.appliesToSetNumber)       { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.appliesToSetIndicesRaw)   { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.dropsetEffortRaw)         { try? writeContext.save(); onGraphChange?() }
        .onChange(of: plan.dropsetEffortReps)        { try? writeContext.save(); onGraphChange?() }
    }

    // MARK: - Applies-To multi-select section

    @ViewBuilder
    private var appliesToSection: some View {
        let n = max(1, setCount)
        let indices = currentIndices
        Section {
            // Quick-action row
            HStack(spacing: 0) {
                Button("All") {
                    applyIndices(Set(0..<n))
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 20)
                Button("Last") {
                    applyIndices([n - 1])
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 20)
                Button("Clear") {
                    applyIndices([])
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 2)

            // Per-set checkboxes
            ForEach(0..<n, id: \.self) { idx in
                let selected = indices.contains(idx)
                let conflict = selected ? nil : conflictForAdding(idx: idx)
                Button {
                    if let msg = conflict {
                        appliesToErrorMsg = msg
                        return
                    }
                    var next = indices
                    if selected { next.remove(idx) } else { next.insert(idx) }
                    applyIndices(next)
                } label: {
                    HStack {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color(UIColor.secondaryLabel))
                        Text("Set \(idx + 1)")
                            .foregroundStyle(conflict != nil ? .secondary : .primary)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(conflict != nil && !selected)
            }

            if let msg = appliesToErrorMsg {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.85))
            }
        } header: {
            Text("Applies to Sets")
        }
    }

    private func applyIndices(_ indices: Set<Int>) {
        plan.appliesToSetIndices = indices   // writes appliesToSetIndicesRaw via setter
        appliesToErrorMsg = nil
    }

    private var typeName: String {
        switch plan.type {
        case .dropset:       return "Drop Set"
        case .partialReps:   return "Partial Reps"
        case .restPause:     return "Rest-Pause"
        case .amrap:         return "AMRAP"
        case .toFailure:     return "To Failure"
        case .cluster:       return "Cluster"
        case .tempoOverride: return "Tempo Override"
        }
    }

    /// Effective Partial Range picker selection (`""` = Not set). Maps a legacy
    /// row (nil raw + non-empty note) to `.custom` so its note stays visible and
    /// editable; once the user picks anything the model's `partialRangeRaw` is
    /// authoritative.
    private var partialRangeSelection: String {
        if let raw = plan.partialRangeRaw { return raw }
        return (plan.partialRangeNote?.isEmpty == false)
            ? PartialRange.custom.rawValue
            : ""
    }

    @ViewBuilder
    private var techniqueParamSection: some View {
        switch plan.type {
        case .dropset:
            Section("Drop Set") {
                Stepper(
                    "Drops: \(plan.dropCount ?? 1)",
                    value: Binding(
                        get: { plan.dropCount ?? 1 },
                        set: { plan.dropCount = $0 }
                    ),
                    in: 1...10
                )
                Stepper(
                    "Weight reduction: \(Int(plan.dropPercent ?? 20))%",
                    value: Binding(
                        get: { Int(plan.dropPercent ?? 20) },
                        set: { plan.dropPercent = Double($0) }
                    ),
                    in: 5...50,
                    step: 5
                )
                Stepper(
                    "Rest between drops: \(plan.restSeconds ?? 0)s",
                    value: Binding(
                        get: { plan.restSeconds ?? 0 },
                        set: { plan.restSeconds = $0 > 0 ? $0 : nil }
                    ),
                    in: 0...120,
                    step: 5
                )
            }
            Section("Effort Mode") {
                Picker("Effort", selection: Binding(
                    get: { plan.dropsetEffortRaw ?? "amrap" },
                    set: { v in
                        let prev = plan.dropsetEffortRaw
                        plan.dropsetEffortRaw = v
                        if v != "fixedReps" { plan.dropsetEffortReps = nil }
                        if let msg = conflictForEffort(v) {
                            plan.dropsetEffortRaw = prev
                            effortErrorMsg = msg
                        } else {
                            effortErrorMsg = nil
                        }
                    }
                )) {
                    Text("AMRAP").tag("amrap")
                    Text("Fixed reps").tag("fixedReps")
                }
                .pickerStyle(.segmented)
                if (plan.dropsetEffortRaw ?? "amrap") == "fixedReps" {
                    Stepper(
                        "Reps per drop: \(plan.dropsetEffortReps ?? 8)",
                        value: Binding(
                            get: { plan.dropsetEffortReps ?? 8 },
                            set: { plan.dropsetEffortReps = $0 }
                        ),
                        in: 1...30
                    )
                }
                if let msg = effortErrorMsg {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }
            }

        case .restPause:
            Section("Rest-Pause") {
                Stepper(
                    "Rounds: \(plan.rounds ?? 2)",
                    value: Binding(
                        get: { plan.rounds ?? 2 },
                        set: { plan.rounds = $0 }
                    ),
                    in: 1...10
                )
                Stepper(
                    "Rest: \(plan.restSeconds ?? 15)s",
                    value: Binding(
                        get: { plan.restSeconds ?? 15 },
                        set: { plan.restSeconds = $0 }
                    ),
                    in: 5...120,
                    step: 5
                )
            }

        case .cluster:
            Section("Cluster") {
                Stepper(
                    "Reps per cluster: \(plan.reps ?? 3)",
                    value: Binding(
                        get: { plan.reps ?? 3 },
                        set: { plan.reps = $0 }
                    ),
                    in: 1...20
                )
                Stepper(
                    "Clusters: \(plan.rounds ?? 3)",
                    value: Binding(
                        get: { plan.rounds ?? 3 },
                        set: { plan.rounds = $0 }
                    ),
                    in: 1...10
                )
                Stepper(
                    "Rest between clusters: \(plan.restSeconds ?? 10)s",
                    value: Binding(
                        get: { plan.restSeconds ?? 10 },
                        set: { plan.restSeconds = $0 }
                    ),
                    in: 5...120,
                    step: 5
                )
            }

        case .partialReps:
            Section("Partial Reps") {
                Picker("Partial Range", selection: Binding(
                    get: { partialRangeSelection },
                    set: { v in
                        plan.partialRangeRaw = v.isEmpty ? nil : v
                        // Clear stale custom/legacy text unless Custom is chosen,
                        // so old free text can't leak back via the resolver.
                        if v != PartialRange.custom.rawValue {
                            plan.partialRangeNote = nil
                        }
                    }
                )) {
                    Text("Not set").tag("")
                    Text(PartialRange.lengthenedHalf.displayName)
                        .tag(PartialRange.lengthenedHalf.rawValue)
                    Text(PartialRange.shortenedHalf.displayName)
                        .tag(PartialRange.shortenedHalf.rawValue)
                    Text(PartialRange.middleRange.displayName)
                        .tag(PartialRange.middleRange.rawValue)
                    Text(PartialRange.stickingPoint.displayName)
                        .tag(PartialRange.stickingPoint.rawValue)
                    Text(PartialRange.custom.displayName)
                        .tag(PartialRange.custom.rawValue)
                }
                if partialRangeSelection == PartialRange.custom.rawValue {
                    TextField("Custom partial note", text: Binding(
                        get: { plan.partialRangeNote ?? "" },
                        set: { plan.partialRangeNote = $0.isEmpty ? nil : $0 }
                    ))
                    .focused($customNoteFocused)
                    .submitLabel(.done)
                    .onSubmit { customNoteFocused = false }
                }
                Stepper(
                    "Partial reps: \(plan.reps ?? 5)",
                    value: Binding(
                        get: { plan.reps ?? 5 },
                        set: { plan.reps = $0 }
                    ),
                    in: 1...30
                )
            }

        case .tempoOverride:
            Section("Tempo Override") {
                TextField("Tempo (e.g. 3-1-3-0)", text: Binding(
                    get: { plan.note ?? "" },
                    set: { plan.note = $0.isEmpty ? nil : $0 }
                ))
                .keyboardType(.numbersAndPunctuation)
                Text("Format: eccentric-pause-concentric-pause")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .amrap:
            Section("AMRAP") {
                Text("As many reps as possible on the last set. No additional parameters.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }

        case .toFailure:
            Section("To Failure") {
                Text("Push until technical failure. No additional parameters.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

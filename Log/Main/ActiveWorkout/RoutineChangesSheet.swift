import SwiftData
import SwiftUI

// MARK: - Rows

/// One selectable row of the Save Routine Changes sheet: a pending change
/// from `RoutineTemplateUpdate.pendingChanges`, named with the exercises it
/// affects.
struct RoutineChangeRow: Identifiable, Equatable {
    enum Label: Equatable {
        /// "Bench Press → Incline DB Press"
        case replacement(from: String, to: String)
        /// "Incline DB Press plan changes" — the exercise now in the slot.
        case planChanges(exercise: String)
    }

    var change: RoutineTemplateUpdate.PendingChange
    var label: Label

    var id: RoutineTemplateUpdate.PendingChange { change }

    /// The localized row text.
    var title: String {
        switch label {
        case .replacement(let from, let to):
            return String(
                localized: "\(from) → \(to)",
                comment: "Save Routine Changes row: the routine's exercise (first) is replaced by the exercise used in this workout (second).")
        case .planChanges(let exercise):
            return String(
                localized: "\(exercise) plan changes",
                comment: "Save Routine Changes row: the plan edits made to this exercise during the workout. The placeholder is the exercise name.")
        }
    }
}

/// The sheet's rows for these slots, in workout order — per exercise, its
/// replacement row, then its plan-changes row (the order
/// `RoutineTemplateUpdate.pendingChanges` produces). Empty when nothing is
/// pending: then there is no sheet, only the plain finish confirmation. Pure.
///
/// - Parameter originalName: the name of the exercise a switched slot started
///   with — `PlanExercise.name` already holds the switched-in one.
func routineChangeRows(
    requests: [RoutineTemplateUpdate.SlotRequest],
    exercises: [PlanExercise],
    originalName: (UUID) -> String?
) -> [RoutineChangeRow] {
    var currentNames: [PersistentIdentifier: String] = [:]
    for exercise in exercises {
        currentNames[exercise.routineExerciseID] = exercise.name
    }
    let byID = Dictionary(
        requests.map { ($0.routineExerciseID, $0) },
        uniquingKeysWith: { first, _ in first })

    return RoutineTemplateUpdate.pendingChanges(for: requests).compactMap {
        change in
        guard let request = byID[change.routineExerciseID] else { return nil }
        let current = currentNames[change.routineExerciseID] ?? ""
        switch change.kind {
        case .replacement:
            let from =
                originalName(request.originalExerciseID)
                ?? String(localized: "Exercise")
            return RoutineChangeRow(
                change: change, label: .replacement(from: from, to: current))
        case .planChanges:
            return RoutineChangeRow(
                change: change, label: .planChanges(exercise: current))
        }
    }
}

/// One presentation of the sheet: its rows, frozen when Finish was reached.
/// A fresh value per presentation, so `.sheet(item:)` builds a fresh sheet —
/// and a fresh, all-selected `RoutineChangeSelection` — every time.
struct RoutineChangesPresentation: Identifiable {
    let id = UUID()
    let rows: [RoutineChangeRow]
}

// MARK: - Selection

/// Which rows are checked, for one presentation of the sheet. Every row starts
/// selected — the user made these changes on purpose and opts out — and every
/// row toggles on its own: no row selects or deselects another. Never
/// persisted. Pure.
struct RoutineChangeSelection: Equatable {
    let rows: [RoutineChangeRow]
    private(set) var selected: Set<RoutineTemplateUpdate.PendingChange>

    init(rows: [RoutineChangeRow]) {
        self.rows = rows
        self.selected = Set(rows.map(\.id))
    }

    func isSelected(_ id: RoutineTemplateUpdate.PendingChange) -> Bool {
        selected.contains(id)
    }

    mutating func toggle(_ id: RoutineTemplateUpdate.PendingChange) {
        guard rows.contains(where: { $0.id == id }) else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    /// Save Selected Changes is enabled only with something to save; zero
    /// selected is not quietly another action.
    var canSave: Bool { !selected.isEmpty }

    /// What Save Selected Changes records, or nil when it is disabled.
    var saveRequest: FinishRequest? {
        canSave ? .saveSelected(selected) : nil
    }
}

// MARK: - Sheet

/// Save Routine Changes — shown at finish only when routine changes are
/// pending. It decides nothing itself: it returns the selected pending changes
/// (or none) and the caller hands them to `RoutineTemplateUpdate`.
struct RoutineChangesSheet: View {
    let routineName: String
    let onCancel: () -> Void
    let onFinish: (FinishRequest) -> Void

    @State private var selection: RoutineChangeSelection

    init(
        routineName: String,
        rows: [RoutineChangeRow],
        onCancel: @escaping () -> Void,
        onFinish: @escaping (FinishRequest) -> Void
    ) {
        self.routineName = routineName
        self.onCancel = onCancel
        self.onFinish = onFinish
        _selection = State(initialValue: RoutineChangeSelection(rows: rows))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(selection.rows) { row in
                        rowView(row)
                    }
                } header: {
                    Text(
                        "Choose which changes to save to \u{201C}\(routineName)\u{201D}. Your workout will be recorded either way.",
                        comment: "Save Routine Changes sheet: explains the checklist. The placeholder is the routine's name."
                    )
                    .textCase(nil)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                }
            }
            .navigationTitle("Save Routine Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
    }

    private func rowView(_ row: RoutineChangeRow) -> some View {
        let isSelected = selection.isSelected(row.id)
        return Button {
            selection.toggle(row.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(verbatim: row.title)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver reads the row's name and its state in words, not only the
        // glyph. The value is the single source of selection state: the
        // `.isSelected` trait would repeat "Selected" on a checked row and
        // says nothing on an unchecked one. The button trait comes from
        // `Button`.
        .accessibilityLabel(Text(verbatim: row.title))
        .accessibilityValue(isSelected ? Text("Selected") : Text("Not selected"))
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                onFinish(.finishOnly)
            } label: {
                Text("Finish This Workout Only")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                if let request = selection.saveRequest { onFinish(request) }
            } label: {
                Text("Save Selected Changes")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!selection.canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Finish confirmation flow

/// The active workout's finish confirmation: the plain Finish / Cancel dialog
/// when nothing is pending, the Save Routine Changes sheet when something is,
/// and the single-fire hand-off to `finish` for both. The caller decides which
/// to present (`showFinishConfirm` or `routineChangesSheet`).
///
/// Buttons only **record** a `FinishRequest`; `finish` runs on a later
/// main-actor turn, after the dialog or sheet has gone, so the navigation pop
/// it ends with cannot race their dismissal.
struct FinishConfirmationFlow: ViewModifier {
    let routineName: String
    @Binding var showFinishConfirm: Bool
    @Binding var routineChangesSheet: RoutineChangesPresentation?
    @Binding var pendingFinish: FinishRequest?
    let finish: (FinishRequest) -> Void

    /// What the sheet's bottom action chose. Held until the sheet has fully
    /// dismissed (its `onDismiss`), then moved to `pendingFinish`. Cancel and
    /// swipe-to-dismiss leave it nil, so they finish nothing and write
    /// nothing.
    @State private var sheetFinishRequest: FinishRequest? = nil

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Finish this workout?",
                isPresented: $showFinishConfirm,
                titleVisibility: .visible
            ) {
                Button("Finish") { pendingFinish = .finishOnly }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(
                item: $routineChangesSheet,
                onDismiss: {
                    pendingFinish = sheetFinishRequest
                    sheetFinishRequest = nil
                }
            ) { presentation in
                RoutineChangesSheet(
                    routineName: routineName,
                    rows: presentation.rows,
                    onCancel: { routineChangesSheet = nil },
                    onFinish: { request in
                        sheetFinishRequest = request
                        routineChangesSheet = nil
                    })
            }
            .onChange(of: pendingFinish) { _, request in
                guard request != nil else { return }
                // Next main-actor turn: the presenter's teardown has committed
                // by the time this runs. Consuming via `consumePendingFinish`
                // nils the slot first — the finish pipeline can only ever run
                // once per confirmation.
                Task { @MainActor in
                    guard let chosen = consumePendingFinish(&pendingFinish)
                    else { return }
                    finish(chosen)
                }
            }
    }
}

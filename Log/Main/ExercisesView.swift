import SwiftData
import SwiftUI

// MARK: - Top-level list of exercises

struct ExercisesView: View {
    @AppStorage("universalDefaultRestSeconds") private
        var universalDefaultRestSeconds: Int = 0
    @State private var editingDefaultRest = false
    @State private var restDraft = ""
    @FocusState private var restFieldFocused: Bool

    /// Persisted via `@AppStorage`. Stored as the enum's raw `String` so
    /// the cases can be reordered without invalidating saved preferences.
    /// Default `.manual` preserves the pre-Phase-10-polish behavior for
    /// users who never open the toolbar Sort menu.
    @AppStorage("exercisesSortMode") private var sortModeRaw: String =
        ExerciseSortMode.manual.rawValue

    private var sortMode: ExerciseSortMode {
        ExerciseSortMode(rawValue: sortModeRaw) ?? .manual
    }

    @Environment(\.modelContext) private var ctx
    @Query(sort: [SortDescriptor(\Exercise.order), SortDescriptor(\Exercise.name)])
    private var exercises: [Exercise]
    @State private var newName = ""
    @State private var search = ""
    @State private var dupAlert = false
    @State private var dupName = ""
    @FocusState private var focusNewExercise: Bool

    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared
    @State private var showLockedAlert = false
    @State private var lockedName = ""

    @State private var showDeleteExerciseAlert = false
    @State private var pendingDeleteExercise: Exercise? = nil
    @State private var deleteImpactMessage = "This will delete the exercise."

    private func buildImpactMessage(for ex: Exercise) -> String {
        guard let routines = try? ctx.fetch(FetchDescriptor<Routine>()) else {
            return "This will delete “\(ex.name)”. This cannot be undone."
        }
        var supersetBlocks = 0
        var normalRefs = 0
        var affectedRoutines = Set<UUID>()

        for r in routines {
            for b in r.blocks {
                let hasRef = b.exercises.contains { re in
                    re.safeExercise(in: ctx)?.id == ex.id
                }
                if hasRef {
                    affectedRoutines.insert(r.id)
                    if b.isSuperset {
                        supersetBlocks += 1
                    } else {
                        normalRefs += 1
                    }
                }
            }
        }

        if supersetBlocks == 0 && normalRefs == 0 {
            return "Delete “\(ex.name)”? This cannot be undone."
        } else {
            let rs = affectedRoutines.count
            return """
                Delete “\(ex.name)”? This will remove it from \(rs) routine\(rs == 1 ? "" : "s"), delete \(supersetBlocks) superset block\(supersetBlocks == 1 ? "" : "s"), and unlink \(normalRefs) exercise reference\(normalRefs == 1 ? "" : "s"). This cannot be undone.
                """
        }
    }

    /// Display list = sort mode applied to the `@Query` result, then
    /// name-filtered by the search term. Sort is applied before filter so
    /// the search affordance never reorders rows on its own — typing into
    /// the search field only narrows the visible set. Drag-to-reorder is
    /// gated separately on `.manual` mode AND empty search via
    /// `.moveDisabled(...)` so the offsets `moveExercises` receives still
    /// refer to the full `exercises` array.
    private var filtered: [Exercise] {
        let sorted = ExerciseSorter.sort(exercises, mode: sortMode)
        guard !search.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            ListContent
                .probe("Exercises.List")
        }
    }

    // MARK: - List content

    private var ListContent: some View {
        List {
            defaultsSection
            addExerciseSection
            allExercisesSection
        }
        .navigationTitle("Exercises")
        .environment(\.defaultMinListRowHeight, 56)
        .listRowSpacing(8)
        .listStyle(.insetGrouped)
        .searchable(text: $search)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(DSColor.bg.ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortModeRaw) {
                        ForEach(ExerciseSortMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage)
                                .tag(mode.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .accessibilityLabel("Sort exercises")
                }
                EditButton()
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusNewExercise = false }
            }
        }
        .onAppear { backfillExerciseOrderIfNeeded() }
        .alert("Delete Exercise", isPresented: $showDeleteExerciseAlert) {
            Button("Cancel", role: .cancel) {
                pendingDeleteExercise = nil
            }
            Button("Delete", role: .destructive) {
                guard let ex = pendingDeleteExercise else { return }
                withAnimation {
                    let deletedID = ex.id
                    ctx.delete(ex)

                    if let routines = try? ctx.fetch(FetchDescriptor<Routine>())
                    {
                        for r in routines {
                            for b in Array(r.blocks) {
                                let refsThisExercise = b.exercises.contains {
                                    re in
                                    re.exercise?.id == deletedID
                                }
                                guard refsThisExercise else { continue }

                                if b.isSuperset {
                                    ctx.delete(b)
                                } else {
                                    for re in Array(b.exercises) {
                                        if re.exercise?.id == deletedID {
                                            ctx.delete(re)
                                        }
                                    }
                                    let remaining = b.exercises.sorted {
                                        $0.order < $1.order
                                    }
                                    for (i, re) in remaining.enumerated() {
                                        re.order = i
                                    }
                                }
                            }
                            let renum = r.blocks.sorted { $0.order < $1.order }
                            for (i, blk) in renum.enumerated() { blk.order = i }
                        }
                    }

                    try? ctx.save()
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                pendingDeleteExercise = nil
            }
        } message: {
            Text(deleteImpactMessage)
        }
        .alert(
            "Can't delete during active workout",
            isPresented: $showLockedAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(lockedName)” is currently used in an active workout.")
        }
        .sheet(isPresented: $editingDefaultRest) {
            DefaultRestEditorSheet(
                restDraft: $restDraft,
                isPresented: $editingDefaultRest,
                universalDefaultRestSeconds: $universalDefaultRestSeconds
            )
        }
    }

    // MARK: - Sections

    private var defaultsSection: some View {
        Section {
            HStack {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)

                Text("Default rest between sets")
                    .font(.dsBody)

                Spacer()

                Button {
                    restDraft =
                        universalDefaultRestSeconds > 0
                        ? String(universalDefaultRestSeconds)
                        : ""
                    editingDefaultRest = true
                } label: {
                    Text(
                        universalDefaultRestSeconds > 0
                            ? "\(universalDefaultRestSeconds)s"
                            : "Set"
                    )
                    .font(.dsCaption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        } header: {
            DSSectionHeader(title: "Defaults", systemImage: "timer")
        }
    }

    private var addExerciseSection: some View {
        Section {
            HStack {
                TextField("e.g. Barbell Bench Press", text: $newName)
                    .font(.dsBody)
                    .focused($focusNewExercise)
                    .submitLabel(.done)
                    .onSubmit { addExercise() }
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                Button("Add") { addExercise() }
                    .font(.dsBodySecondary.weight(.semibold))
                    .alert(
                        "Exercise already exists",
                        isPresented: $dupAlert
                    ) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("“\(dupName)” is already in your list.")
                    }
            }
            #if DEBUG
                .probe("Exercises.AddRow")
            #endif
        } header: {
            DSSectionHeader(title: "Add Exercise", systemImage: "plus.circle")
        }
    }

    private var allExercisesSection: some View {
        Section {
            ForEach(filtered) { ex in
                NavigationLink {
                    ExerciseDetailHost(exerciseID: ex.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ex.name)
                                .font(.dsBody)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.85)

                            if let bp = ex.bodyPart, !bp.isEmpty {
                                Text(bp)
                                    .font(.dsBodySecondary)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        Spacer(minLength: 12)

                        if activeGuard.isLocked(ex.id) {
                            LockBadge()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .swipeActions(allowsFullSwipe: false) {
                    if activeGuard.isLocked(ex.id) {
                        Button {
                            lockedName = ex.name
                            showLockedAlert = true
                        } label: {
                            Label("In use", systemImage: "lock.fill")
                        }
                    } else {
                        Button {
                            pendingDeleteExercise = ex
                            deleteImpactMessage = buildImpactMessage(for: ex)
                            showDeleteExerciseAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove(perform: moveExercises)
            .onDelete(perform: deleteExercisesFromEdit)
            // Drag-to-reorder writes back to `Exercise.order`, which only
            // the `.manual` sort mode reads. Under any other sort mode the
            // visual order is computed (alphabetical / by bodyPart / by
            // equipment) and a drag would silently change `order` without
            // visibly moving the row — gate the affordance off entirely.
            // The search gate (already in place pre-polish) stays: even
            // under `.manual`, filtered offsets do not match the full
            // `exercises` array that `moveExercises` rewrites.
            .moveDisabled(sortMode != .manual || !search.isEmpty)
        } header: {
            DSSectionHeader(title: "All Exercises", systemImage: "list.bullet")
        }
    }

    /// Edit-mode delete path for the Exercises list. Routes through the same
    /// safety as swipe-to-delete: locked exercises surface the "in use" alert,
    /// non-locked exercises queue the existing impact-summary confirmation.
    private func deleteExercisesFromEdit(at offsets: IndexSet) {
        guard let first = offsets.first, first < filtered.count else { return }
        let ex = filtered[first]
        if activeGuard.isLocked(ex.id) {
            lockedName = ex.name
            showLockedAlert = true
            return
        }
        pendingDeleteExercise = ex
        deleteImpactMessage = buildImpactMessage(for: ex)
        showDeleteExerciseAlert = true
    }

    // MARK: - Default Rest Sheet

    private struct DefaultRestEditorSheet: View {
        @Binding var restDraft: String
        @Binding var isPresented: Bool
        @Binding var universalDefaultRestSeconds: Int
        @FocusState private var fieldFocused: Bool

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                                .foregroundStyle(.secondary)
                            TextField(
                                "Seconds",
                                text: Binding(
                                    get: { restDraft },
                                    set: { restDraft = $0.filter(\.isNumber) }
                                )
                            )
                            .keyboardType(.numberPad)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .onSubmit { fieldFocused = false }

                            Text("s")
                                .foregroundStyle(.secondary)
                        }

                        Text(
                            "Applied automatically to newly added sets in all exercises (dropsets still have no rest)."
                        )
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Default Rest")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            fieldFocused = false
                            let v = Int(restDraft) ?? 0
                            universalDefaultRestSeconds = v > 0 ? v : 0
                            isPresented = false
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { fieldFocused = false }
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.async { fieldFocused = true }
            }
        }
    }

    // MARK: - Add Exercise

    private func addExercise() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let exists = exercises.contains {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }

        if exists {
            dupName = trimmed
            dupAlert = true
            return
        }

        let ex = Exercise(name: trimmed)
        ex.order = (exercises.map(\.order).max() ?? -1) + 1
        ctx.insert(ex)
        try? ctx.save()
        newName = ""
    }

    /// Reorder handler for the top-level All Exercises list. Persists the new
    /// display order by rewriting `Exercise.order` on every exercise to match
    /// the post-move sequence. Only enabled when search is inactive — see
    /// `.moveDisabled(!search.isEmpty)` on the ForEach — so the offsets always
    /// refer to indices in the full `exercises` array.
    private func moveExercises(from offsets: IndexSet, to newOffset: Int) {
        guard sortMode == .manual, search.isEmpty else { return }
        var sorted = exercises
        sorted.move(fromOffsets: offsets, toOffset: newOffset)
        for (i, ex) in sorted.enumerated() {
            ex.order = i
        }
        try? ctx.save()
    }

    /// One-shot normalization for legacy data: if every exercise has order 0
    /// (or order values collide), rewrite them based on the current `exercises`
    /// query order (`[order, name]` ascending — effectively alphabetical when
    /// all orders are 0). Idempotent; no-op once orders are unique.
    private func backfillExerciseOrderIfNeeded() {
        guard exercises.count > 1 else { return }
        let allZero = exercises.allSatisfy { $0.order == 0 }
        let hasDuplicates = Set(exercises.map(\.order)).count != exercises.count
        guard allZero || hasDuplicates else { return }
        for (i, ex) in exercises.enumerated() {
            ex.order = i
        }
        try? ctx.save()
    }
}

// MARK: - Exercise detail editor

struct ExerciseDetailView: View {
    @Bindable var exercise: Exercise
    @Environment(\.modelContext) private var ctx
    let isLocked: Bool

    @FocusState private var focusedField: String?

    fileprivate static let canonicalBodyParts: [String] = [
        "Chest", "Back", "Shoulders", "Arms", "Biceps", "Triceps",
        "Legs", "Quads", "Hamstrings", "Glutes", "Calves",
        "Core", "Full Body", "Cardio"
    ]

    fileprivate static let canonicalEquipment: [String] = [
        "Barbell", "Dumbbell", "Cable", "Machine", "Smith Machine",
        "Kettlebell", "Resistance Band", "Bodyweight",
        "EZ Bar", "Trap Bar", "Plate", "Sled"
    ]

    var body: some View {
        DetailForm
            .probe("ExerciseDetail.Form")
            .onDisappear { try? ctx.save() }
            .navigationTitle("Edit Exercise")
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
    }

    private var DetailForm: some View {
        Form {
            if isLocked {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    Text(
                        "This exercise is part of an active workout and can’t be edited."
                    )
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Info") {
                TextField("Name", text: $exercise.name)
                    .font(.dsBody)
                    .focused($focusedField, equals: "name")
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .disabled(isLocked)

                NavigationLink {
                    BodyPartPicker(
                        current: exercise.bodyPart,
                        canonicalOptions: ExerciseDetailView
                            .canonicalBodyParts,
                        onSelect: { newValue in
                            let trimmed = newValue?.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            exercise.bodyPart =
                                (trimmed?.isEmpty ?? true) ? nil : trimmed
                        }
                    )
                } label: {
                    HStack {
                        Text("Body Part")
                            .font(.dsBody)
                        Spacer()
                        Text(exercise.bodyPart ?? "Not set")
                            .font(.dsBodySecondary)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isLocked)

                NavigationLink {
                    EquipmentPicker(
                        current: exercise.equipmentType,
                        canonicalOptions: ExerciseDetailView
                            .canonicalEquipment,
                        onSelect: { newValue in
                            let trimmed = newValue?.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            exercise.equipmentType =
                                (trimmed?.isEmpty ?? true) ? nil : trimmed
                        }
                    )
                } label: {
                    HStack {
                        Text("Equipment")
                            .font(.dsBody)
                        Spacer()
                        Text(exercise.equipmentType ?? "Not set")
                            .font(.dsBodySecondary)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isLocked)

                TextField(
                    "Setup defaults",
                    text: Binding(
                        $exercise.setupDefaults,
                        replacingNilWith: ""
                    ),
                    axis: .vertical
                )
                .font(.dsBodySecondary)
                .lineLimit(2...5)
                .textInputAutocapitalization(.sentences)
                .focused($focusedField, equals: "setupDefaults")
                .disabled(isLocked)

                TextField(
                    "Notes",
                    text: Binding($exercise.notes, replacingNilWith: "")
                )
                .font(.dsBodySecondary)
                .submitLabel(.done)
                .lineLimit(3)
                .textInputAutocapitalization(.sentences)
                .focused($focusedField, equals: "notes")
                .disabled(isLocked)

                // Phase 9-D: direct binding to Exercise.isTimeBased. The
                // prior staging + "Switch set mode?" alert warned about
                // discarding rows in Exercise.defaultTemplates; with the
                // Sets editor removed, the mode flip is a pure metadata
                // edit. Downstream readers (BackfillService.hydrate,
                // makeSwapDefaultTemplates, SlotPrescriptionSection,
                // ActiveWorkoutView row rendering) continue to read
                // exercise.isTimeBased as the single source of truth.
                Toggle("Time-based", isOn: $exercise.isTimeBased)
                    .disabled(isLocked)
            }
        }
    }
}

// MARK: - Small helper for optional String bindings

extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith defaultValue: String) {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { newValue in
                source.wrappedValue = newValue.isEmpty ? nil : newValue
            }
        )
    }
}

private struct ExerciseDetailHost: View {
    let exerciseID: UUID

    @Query private var result: [Exercise]
    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    init(exerciseID: UUID) {
        self.exerciseID = exerciseID
        _result = Query(
            filter: #Predicate<Exercise> { $0.id == exerciseID },
            sort: []
        )
    }

    var body: some View {
        if let ex = result.first {
            ExerciseDetailView(
                exercise: ex,
                isLocked: activeGuard.isLocked(ex.id)
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text("Exercise not found")
                    .font(.dsBody.weight(.semibold))
                Text("It may have been deleted or moved.")
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

private struct LockBadge: View {
    var body: some View {
        Label("In use", systemImage: "lock.fill")
            .font(.dsCaption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Exercise currently in use")
    }
}

// MARK: - Body Part Picker

/// Push-style picker for `Exercise.bodyPart`. Lists the canonical 14 options
/// plus "Not set" and an "Other…" entry that opens a free-text alert.
/// Legacy `bodyPart` values that don't match any canonical option are
/// surfaced as a dedicated row so they remain visible and selectable —
/// the picker never silently rewrites or hides them.
private struct BodyPartPicker: View {
    let current: String?
    let canonicalOptions: [String]
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showOtherEntry = false
    @State private var otherDraft = ""

    private var legacyCustom: String? {
        guard
            let bp = current?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !bp.isEmpty,
            !canonicalOptions.contains(bp)
        else { return nil }
        return bp
    }

    var body: some View {
        List {
            Section {
                selectionRow(label: "Not set", value: nil)
                if let legacy = legacyCustom {
                    selectionRow(label: legacy, value: legacy)
                }
                ForEach(canonicalOptions, id: \.self) { name in
                    selectionRow(label: name, value: name)
                }
            }

            Section {
                Button {
                    otherDraft = ""
                    showOtherEntry = true
                } label: {
                    HStack {
                        Text("Other…")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .navigationTitle("Body Part")
        .alert("Custom Body Part", isPresented: $showOtherEntry) {
            TextField("e.g. Forearms", text: $otherDraft)
                .textInputAutocapitalization(.words)
            Button("Save") {
                let trimmed = otherDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty else { return }
                onSelect(trimmed)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a body part not in the list.")
        }
    }

    @ViewBuilder
    private func selectionRow(label: String, value: String?) -> some View {
        Button {
            onSelect(value)
            dismiss()
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected(value) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func isSelected(_ value: String?) -> Bool {
        if value == nil { return current == nil }
        return value == current
    }
}

// MARK: - Equipment Picker

/// Push-style picker for `Exercise.equipmentType`. Mirrors `BodyPartPicker`'s
/// shape: canonical options + a leading "Not set" + a legacy/custom row when
/// the current value isn't canonical + an "Other…" alert for free-text entry.
/// Kept as a sibling concrete type (rather than generalizing into a shared
/// "canonical-string picker") because the codebase pattern favors concrete
/// named views and the two pickers are conceptually distinct domains —
/// generalization is appropriate if a third canonical-list picker lands.
private struct EquipmentPicker: View {
    let current: String?
    let canonicalOptions: [String]
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showOtherEntry = false
    @State private var otherDraft = ""

    private var legacyCustom: String? {
        guard
            let v = current?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !v.isEmpty,
            !canonicalOptions.contains(v)
        else { return nil }
        return v
    }

    var body: some View {
        List {
            Section {
                selectionRow(label: "Not set", value: nil)
                if let legacy = legacyCustom {
                    selectionRow(label: legacy, value: legacy)
                }
                ForEach(canonicalOptions, id: \.self) { name in
                    selectionRow(label: name, value: name)
                }
            }

            Section {
                Button {
                    otherDraft = ""
                    showOtherEntry = true
                } label: {
                    HStack {
                        Text("Other…")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .navigationTitle("Equipment")
        .alert("Custom Equipment", isPresented: $showOtherEntry) {
            TextField("e.g. Landmine", text: $otherDraft)
                .textInputAutocapitalization(.words)
            Button("Save") {
                let trimmed = otherDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty else { return }
                onSelect(trimmed)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter equipment not in the list.")
        }
    }

    @ViewBuilder
    private func selectionRow(label: String, value: String?) -> some View {
        Button {
            onSelect(value)
            dismiss()
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected(value) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func isSelected(_ value: String?) -> Bool {
        if value == nil { return current == nil }
        return value == current
    }
}

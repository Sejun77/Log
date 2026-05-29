import SwiftData
import SwiftUI

// MARK: - Top-level list of exercises

struct ExercisesView: View {
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
    /// Drives `.searchable` presentation explicitly so navigation can dismiss
    /// search mode (not just the keyboard) before pushing a detail.
    @State private var isSearchPresented = false
    /// Value-based navigation target. A row taps sets this *after* clearing
    /// focus/search, so cleanup commits before the push — see `exerciseRow`.
    @State private var selectedExerciseID: UUID? = nil

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
            addExerciseSection
            exerciseListSections
        }
        .navigationTitle("Exercises")
        .environment(\.defaultMinListRowHeight, 56)
        .listRowSpacing(8)
        .listStyle(.insetGrouped)
        // `.always` pins the search bar visible below the nav title so it can
        // never be "scrolled off." This removes the post-navigation state where
        // a return from Exercise Detail left the auto-hiding bar buried and made
        // the screen feel stuck in search even after `isSearchPresented` was
        // cleared. Edit/Reorder controls still toggle correctly off of
        // `isSearchPresented` (see §2.4 — clearing it on row tap restores them
        // on return).
        .searchable(
            text: $search,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always)
        )
        // Pressing Search with non-empty text resigns focus. `.onSubmit(of:
        // .search)` does NOT fire on an empty submit — after type-then-delete
        // back to empty the system Search key may still look blue/enabled, but
        // it's inert and can't be greyed via standard APIs (see
        // `dismissKeyboard()`), so the gated `.keyboard` Done button below is
        // the reliable dismissal for that case. Matches every `.searchable`
        // surface in the app.
        .onSubmit(of: .search) { dismissKeyboard() }
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
            // `.keyboard` Done button for the SEARCH field only, gated on
            // `isSearchPresented`. Unlike every other `.searchable` surface this
            // screen also hosts the single-line "new exercise" add field, which
            // dismisses via its own return key (.submitLabel(.done) + .onSubmit)
            // and intentionally has no external Done button — so the accessory
            // must not show for it. The gate scopes the button to search, where
            // it's the reliable dismissal for an empty submit (`.onSubmit(of:
            // .search)` doesn't fire when the field is empty after type-delete).
            if isSearchPresented {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    KeyboardDismissButton()
                }
            }
        }
        .onAppear { backfillExerciseOrderIfNeeded() }
        // Push the detail via value-based navigation so the row's Button can
        // clear focus + search *before* the push commits (see `exerciseRow`).
        // `.onDisappear` proved insufficient: it doesn't reliably fire on a
        // NavigationStack push, so the `@FocusState` / `.searchable` state was
        // never cleared and SwiftUI restored it on pop — keyboard up, search
        // mode still active (hiding the Edit/reorder controls).
        .navigationDestination(item: $selectedExerciseID) { id in
            ExerciseDetailHost(exerciseID: id)
        }
        // Belt-and-suspenders for the tab-switch path (which *does* fire
        // onDisappear): drop focus + search mode so a focused add field or
        // active search doesn't linger when the tab is revisited. The typed
        // `newName` draft is intentionally preserved.
        .onDisappear {
            focusNewExercise = false
            isSearchPresented = false
            search = ""
        }
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
    }

    // MARK: - Sections

    private var addExerciseSection: some View {
        Section {
            HStack {
                TextField("e.g. Barbell Bench Press", text: $newName)
                    .font(.dsBody)
                    .focused($focusNewExercise)
                    .submitLabel(.done)
                    .onSubmit {
                        addExercise()
                        focusNewExercise = false
                    }
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

    /// Top-level exercise listing. Branches on `ExerciseSorter.sections`:
    /// a `nil` result (`.manual` / `.alphabetical`) renders the flat,
    /// optionally-reorderable "All Exercises" section; a non-nil result
    /// (`.bodyPart` / `.equipment`) renders one `Section` per group with the
    /// group title as the header and no drag-reorder. Search filters `filtered`
    /// by name *before* grouping, so empty groups never appear; an active
    /// search with zero matches shows a single "no matches" row instead of an
    /// empty list.
    @ViewBuilder
    private var exerciseListSections: some View {
        if !search.isEmpty && filtered.isEmpty {
            noMatchesSection
        } else if let sections = ExerciseSorter.sections(
            filtered, mode: sortMode
        ) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { ex in
                        exerciseRow(ex)
                    }
                    // Section-relative offsets — resolve against this
                    // section's own `items`, never the global `filtered`
                    // array. No `.onMove`: grouped modes are not reorderable
                    // (the order is computed from bodyPart / equipment, so a
                    // drag would silently rewrite `Exercise.order` with no
                    // visible effect).
                    .onDelete { offsets in
                        deleteFromEdit(in: section.items, at: offsets)
                    }
                } header: {
                    DSSectionHeader(title: section.title)
                }
            }
        } else {
            flatExercisesSection
        }
    }

    private var flatExercisesSection: some View {
        Section {
            ForEach(filtered) { ex in
                exerciseRow(ex)
            }
            .onMove(perform: moveExercises)
            .onDelete { offsets in deleteFromEdit(in: filtered, at: offsets) }
            // Drag-to-reorder writes back to `Exercise.order`, which only
            // the `.manual` sort mode reads. Under `.alphabetical` (the only
            // other flat mode) the visual order is computed and a drag would
            // silently change `order` without visibly moving the row — gate
            // the affordance off entirely. The search gate (already in place
            // pre-polish) stays: even under `.manual`, filtered offsets do
            // not match the full `exercises` array that `moveExercises`
            // rewrites.
            .moveDisabled(sortMode != .manual || !search.isEmpty)
        } header: {
            DSSectionHeader(title: "All Exercises", systemImage: "list.bullet")
        }
    }

    private var noMatchesSection: some View {
        Section {
            Text("No exercises match “\(search)”")
                .font(.dsBodySecondary)
                .foregroundStyle(.secondary)
        } header: {
            DSSectionHeader(title: "All Exercises", systemImage: "list.bullet")
        }
    }

    /// Shared row used by both the flat and grouped paths so navigation,
    /// focus/search clearing, lock badge, and swipe behavior stay identical.
    @ViewBuilder
    private func exerciseRow(_ ex: Exercise) -> some View {
        // A `Button` (not a `NavigationLink`) so the tap handler can
        // clear add-field focus and dismiss search *before* setting the
        // navigation target — the push then commits in normal list mode
        // with no keyboard and no active search. The chevron is added
        // manually to keep the NavigationLink disclosure look.
        Button {
            focusNewExercise = false
            isSearchPresented = false
            search = ""
            selectedExerciseID = ex.id
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

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(allowsFullSwipe: false) {
            if activeGuard.isLocked(ex.id) {
                Button {
                    lockedName = ex.name
                    showLockedAlert = true
                } label: {
                    Label("In use", systemImage: "lock.fill")
                }
                .tint(.gray)
            } else {
                // Roleless Button + .tint(.red): keeps the destructive
                // red appearance while avoiding the `.destructive`-role
                // row-collapse glitch. Matches every other Delete swipe
                // (Routines / History / Routine blocks / Warmup /
                // Technique / superset / custom-option pickers).
                Button {
                    requestDeleteExercise(ex)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    /// Edit-mode delete path. Resolves the tapped offset against the supplied
    /// row collection (`filtered` for the flat list, a `section.items` slice
    /// for a grouped section) so section-relative offsets never index the
    /// wrong exercise. Routes the resolved exercise through the same safety as
    /// swipe-to-delete.
    private func deleteFromEdit(in rows: [Exercise], at offsets: IndexSet) {
        guard let first = offsets.first, first < rows.count else { return }
        requestDeleteExercise(rows[first])
    }

    /// Shared delete request: locked exercises surface the "in use" alert,
    /// non-locked exercises queue the existing impact-summary confirmation.
    private func requestDeleteExercise(_ ex: Exercise) {
        if activeGuard.isLocked(ex.id) {
            lockedName = ex.name
            showLockedAlert = true
            return
        }
        pendingDeleteExercise = ex
        deleteImpactMessage = buildImpactMessage(for: ex)
        showDeleteExerciseAlert = true
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

    /// Read-only routine-usage snapshot, computed by the owning
    /// `ExerciseDetailHost` from its `@Query` and passed in as a plain value
    /// type — deliberately NOT recomputed here. Keeping the routines `@Query`
    /// (and its live relationship scan) off this view fixes a navigation
    /// freeze: when a `@Query` lived here, pushing the Body Part / Equipment
    /// `NavigationLink` refreshed this view — the link's source — mid-push,
    /// re-faulting `Routine.blocks` during the transition and deadlocking the
    /// main thread. This view now renders only value types in its `body`.
    let usage: ExerciseRoutineUsage

    @FocusState private var focusedField: String?

    /// Max routine rows shown before collapsing the remainder into a
    /// "+N more" row. Realistic routine counts are tiny; this only guards
    /// against an unbounded list in the Form section.
    private static let maxRoutineRows = 5

    // Phase 10-polish-G (2026-05-24): "Legs" removed from the canonical list.
    // The seed catalogue uses the specific lower-body buckets (Quads /
    // Hamstrings / Glutes / Calves), so a broad "Legs" canonical option was
    // redundant and confused the picker. Any pre-existing exercise whose
    // `bodyPart` is still "Legs" surfaces as the `legacyCustom` row in
    // `BodyPartPicker` (it's non-nil, non-empty, and not in this list), so
    // the value is preserved and remains selectable — no migration of
    // existing data, no silent rewrite. Users who want to move off "Legs"
    // can pick a specific bucket or use the new "Remove custom value" action.
    fileprivate static let canonicalBodyParts: [String] = [
        "Chest", "Back", "Shoulders", "Arms", "Biceps", "Triceps",
        "Quads", "Hamstrings", "Glutes", "Calves",
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
                    // Only the multiline `setupDefaults` field (`axis: .vertical`)
                    // needs an accessory: its Return key inserts a newline and
                    // can't dismiss the keyboard. Name and Notes are single-line
                    // and dismiss via their own Return key (.submitLabel(.done) +
                    // .onSubmit), so showing a checkmark for them would be a
                    // redundant external Done control — hence the focus gate.
                    if focusedField == "setupDefaults" {
                        Spacer()
                        Button { focusedField = nil } label: {
                            Image(systemName: "checkmark").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Done")
                    }
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

                // `axis: .vertical` makes Return insert a newline on the
                // soft keyboard; `lineLimit(3...8)` gives the cell room to
                // grow for typical 4–5-line setup cues before the content
                // starts scrolling within the cell. The inline binding
                // collapses nil / empty / whitespace-only input to nil on
                // save (vs the shared `replacingNilWith` helper which only
                // catches `isEmpty`) — the 10-polish-A/B display readers
                // already trim before deciding to render, so any stored
                // whitespace-only value would silently show nothing and
                // never round-trip back to "set" once cleared.
                TextField(
                    "Setup defaults — e.g. seat height 4, cable at shoulder",
                    text: Binding(
                        get: { exercise.setupDefaults ?? "" },
                        set: { newValue in
                            let trimmed = newValue.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            exercise.setupDefaults =
                                trimmed.isEmpty ? nil : newValue
                        }
                    ),
                    axis: .vertical
                )
                .font(.dsBody)
                .lineLimit(3...8)
                .lineSpacing(2)
                .textInputAutocapitalization(.sentences)
                .focused($focusedField, equals: "setupDefaults")
                .disabled(isLocked)

                TextField(
                    "Notes",
                    text: Binding($exercise.notes, replacingNilWith: "")
                )
                .font(.dsBodySecondary)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
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

            usedInRoutinesSection
        }
    }

    // MARK: - Used in Routines (read-only)

    /// Read-only summary of which routines reference this exercise. Shown
    /// regardless of `isLocked` (it never mutates anything). Counts unique
    /// routines; a routine that uses the exercise in more than one slot gets
    /// a "· N slots" suffix. Caps the visible rows at `maxRoutineRows` with a
    /// trailing "+N more" row.
    @ViewBuilder
    private var usedInRoutinesSection: some View {
        Section {
            Text(usage.summary)
                .font(.dsBody)

            if usage.routineCount > 0 {
                ForEach(
                    Array(usage.entries.prefix(Self.maxRoutineRows)),
                    id: \.routineID
                ) { entry in
                    HStack(spacing: 8) {
                        Text(entry.routineName)
                            .font(.dsBodySecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let suffix = entry.slotSuffix {
                            Spacer(minLength: 8)
                            Text(suffix)
                                .font(.dsBodySecondary)
                                .foregroundStyle(.secondary)
                                .layoutPriority(1)
                        }
                    }
                }

                if usage.routineCount > Self.maxRoutineRows {
                    Text("+\(usage.routineCount - Self.maxRoutineRows) more")
                        .font(.dsBodySecondary)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Used in Routines")
        } footer: {
            if usage.routineCount == 0 {
                Text("Add this exercise to a routine to see it here.")
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
    /// Gathered here — not on `ExerciseDetailView` — so the routine-usage scan
    /// and its `@Query` observation stay off the detail view that owns the
    /// Body Part / Equipment `NavigationLink`s (see `ExerciseDetailView.usage`
    /// for the freeze rationale). Sorted to match the Routines tab order.
    @Query(sort: [SortDescriptor(\Routine.order), SortDescriptor(\Routine.name)])
    private var routines: [Routine]
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
                isLocked: activeGuard.isLocked(ex.id),
                usage: ExerciseRoutineUsage(
                    routines: routines, exerciseID: ex.id
                )
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

/// Push-style picker for `Exercise.bodyPart`. Lists the canonical 13 options
/// plus "Not set" and an "Other…" entry that opens a free-text alert.
/// Legacy `bodyPart` values that don't match any canonical option AND are
/// not present in the shared custom-options store are surfaced as a
/// dedicated row so they remain visible and selectable — the picker never
/// silently rewrites or hides them.
///
/// Phase 10-polish-H (2026-05-24): custom Body Part options are now
/// shared across exercises via `CustomOptionStore.bodyParts` (backed by
/// UserDefaults). Entering a value through "Other…" both writes the
/// current exercise's field and appends to the shared store. The shared
/// store renders as its own "Custom" section between canonical options
/// and "Other…", with swipe-to-delete on each row. Deleting a shared
/// custom option never touches any `Exercise.bodyPart` — an exercise
/// already using that value continues to show it as a legacy/custom row.
///
/// Phase 10-polish-G (2026-05-24): when the current exercise's value is
/// non-canonical AND not in the shared store, a destructive "Remove
/// custom value" footer section is shown. This is the per-exercise
/// clearing affordance — distinct from removing the value from the
/// shared store, which is one-by-one swipe in the Custom section.
private struct BodyPartPicker: View {
    let current: String?
    let canonicalOptions: [String]
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var customStore = CustomOptionStore.bodyParts
    @State private var showOtherEntry = false
    @State private var otherDraft = ""
    /// Set by the per-row `.swipeActions` Delete button on the shared
    /// Custom section. Non-nil drives the "Remove Custom Body Part?"
    /// confirmation alert. Stores the option's value (not its `IndexSet`)
    /// so the confirm path can route through `customStore.remove(_:)` —
    /// the value-based remover is case-insensitive and resilient to the
    /// list shifting between swipe and confirm. **Neither `.onDelete` nor
    /// a `role: .destructive` swipe button is used here**: both make
    /// SwiftUI assume the data source mutates and play the row-collapse
    /// (assumed-delete) transition on tap. When the action only stashes
    /// state for the confirmation alert, the row collapses then springs
    /// back once the data is found unchanged, and the Section footer text
    /// overlaps mid-animation. A **roleless** `.swipeActions` `Button`
    /// (tinted red purely for the destructive look) has no such animation
    /// — the row stays put until the confirmed `customStore.remove(...)`
    /// runs inside `withAnimation`, giving one clean deletion pass.
    @State private var pendingSharedRemoval: String? = nil
    /// Set by the legacy-row "Remove custom value" button. Non-nil drives
    /// the "Clear Body Part?" confirmation alert. The current exercise's
    /// `bodyPart` is cleared (and the picker dismissed) only after the
    /// Clear button is tapped.
    @State private var pendingLegacyClear: String? = nil

    /// Surface the current exercise's value as a dedicated legacy row only
    /// when it is non-empty, not in the canonical list, AND not already in
    /// the shared custom store (otherwise the Custom section would render
    /// the same value, producing a duplicate row). The shared-store check
    /// is case-insensitive because the store dedupes on case.
    private var legacyCustom: String? {
        guard
            let bp = current?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !bp.isEmpty,
            !canonicalOptions.contains(bp),
            !customStore.options.contains(where: {
                $0.caseInsensitiveCompare(bp) == .orderedSame
            })
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

            if !customStore.options.isEmpty {
                Section {
                    ForEach(customStore.options, id: \.self) { custom in
                        Button {
                            onSelect(custom)
                            dismiss()
                        } label: {
                            HStack {
                                Text(custom)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isCustomSelected(custom) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            // Roleless Button + .tint(.red): a `.destructive`
                            // *role* here makes SwiftUI play its assumed-delete
                            // row-collapse transition on tap, even though the
                            // action only stashes pending state for the
                            // confirmation alert — producing the
                            // collapse-then-spring-back + footer-overlap glitch.
                            // Red tint keeps the destructive look without it.
                            Button {
                                pendingSharedRemoval = custom
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    Text("Custom")
                } footer: {
                    Text(
                        "Swipe a row to remove it from the list. Exercises that already use the value keep it."
                    )
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

            if let legacy = legacyCustom {
                Section {
                    Button(role: .destructive) {
                        pendingLegacyClear = legacy
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Remove custom value")
                        }
                    }
                } footer: {
                    Text(
                        "Clears “\(legacy)” from this exercise. Other exercises are not affected."
                    )
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
                customStore.add(
                    trimmed, excludingCanonical: canonicalOptions
                )
                onSelect(trimmed)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a body part not in the list.")
        }
        .alert(
            "Remove Custom Body Part?",
            isPresented: Binding(
                get: { pendingSharedRemoval != nil },
                set: { if !$0 { pendingSharedRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingSharedRemoval = nil
            }
            Button("Remove", role: .destructive) {
                if let opt = pendingSharedRemoval {
                    withAnimation {
                        customStore.remove(opt)
                    }
                }
                pendingSharedRemoval = nil
            }
        } message: {
            Text(
                "This removes the option from the picker list. Exercises already using this value will keep it until you change them."
            )
        }
        .alert(
            "Clear Body Part?",
            isPresented: Binding(
                get: { pendingLegacyClear != nil },
                set: { if !$0 { pendingLegacyClear = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingLegacyClear = nil
            }
            Button("Clear", role: .destructive) {
                pendingLegacyClear = nil
                onSelect(nil)
                dismiss()
            }
        } message: {
            Text("This clears the custom value from this exercise only.")
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

    /// Case-insensitive selection check used for shared custom rows. The
    /// store normalizes to a single canonical case on insert (via the
    /// dedupe rule), so an exercise whose `bodyPart` differs only in case
    /// from a stored custom option should still render the checkmark on
    /// the stored row.
    private func isCustomSelected(_ custom: String) -> Bool {
        guard let curr = current else { return false }
        return curr.caseInsensitiveCompare(custom) == .orderedSame
    }
}

// MARK: - Equipment Picker

/// Push-style picker for `Exercise.equipmentType`. Mirrors `BodyPartPicker`'s
/// shape: canonical options + a leading "Not set" + a legacy/custom row when
/// the current value isn't canonical AND not in the shared custom store +
/// a "Custom" section for the shared user-added options + an "Other…" alert
/// for free-text entry. Kept as a sibling concrete type (rather than
/// generalizing into a shared "canonical-string picker") because the
/// codebase pattern favors concrete named views and the two pickers are
/// conceptually distinct domains.
///
/// Phase 10-polish-H (2026-05-24): custom Equipment options are now
/// shared across exercises via `CustomOptionStore.equipment`. Same
/// semantics as the Body Part picker — adding through "Other…" appends
/// to the shared list, swipe-to-delete removes one entry at a time, and
/// removing a shared option never silently mutates any
/// `Exercise.equipmentType`.
///
/// Phase 10-polish-G (2026-05-24): the per-exercise "Remove custom value"
/// destructive footer is retained for the case where an exercise's value
/// is non-canonical AND not in the shared store (typically pre-existing
/// data that predates the shared store).
private struct EquipmentPicker: View {
    let current: String?
    let canonicalOptions: [String]
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var customStore = CustomOptionStore.equipment
    @State private var showOtherEntry = false
    @State private var otherDraft = ""
    /// Mirrors `BodyPartPicker.pendingSharedRemoval` — non-nil drives the
    /// "Remove Custom Equipment?" confirmation alert. Stores the option's
    /// value so the confirm path can route through the case-insensitive
    /// value-based `customStore.remove(_:)`. **Neither `.onDelete` nor a
    /// `role: .destructive` swipe button is used here** — see the matching
    /// comment on `BodyPartPicker.pendingSharedRemoval` for the
    /// row-collapse / footer-overlap rationale.
    @State private var pendingSharedRemoval: String? = nil
    /// Mirrors `BodyPartPicker.pendingLegacyClear` — non-nil drives the
    /// "Clear Equipment?" confirmation alert for the legacy-row clear
    /// button. The current exercise's `equipmentType` is cleared only
    /// after the user confirms.
    @State private var pendingLegacyClear: String? = nil

    private var legacyCustom: String? {
        guard
            let v = current?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !v.isEmpty,
            !canonicalOptions.contains(v),
            !customStore.options.contains(where: {
                $0.caseInsensitiveCompare(v) == .orderedSame
            })
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

            if !customStore.options.isEmpty {
                Section {
                    ForEach(customStore.options, id: \.self) { custom in
                        Button {
                            onSelect(custom)
                            dismiss()
                        } label: {
                            HStack {
                                Text(custom)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isCustomSelected(custom) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            // Roleless Button + .tint(.red): a `.destructive`
                            // *role* here makes SwiftUI play its assumed-delete
                            // row-collapse transition on tap, even though the
                            // action only stashes pending state for the
                            // confirmation alert — producing the
                            // collapse-then-spring-back + footer-overlap glitch.
                            // Red tint keeps the destructive look without it.
                            Button {
                                pendingSharedRemoval = custom
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    Text("Custom")
                } footer: {
                    Text(
                        "Swipe a row to remove it from the list. Exercises that already use the value keep it."
                    )
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

            if let legacy = legacyCustom {
                Section {
                    Button(role: .destructive) {
                        pendingLegacyClear = legacy
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Remove custom value")
                        }
                    }
                } footer: {
                    Text(
                        "Clears “\(legacy)” from this exercise. Other exercises are not affected."
                    )
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
                customStore.add(
                    trimmed, excludingCanonical: canonicalOptions
                )
                onSelect(trimmed)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter equipment not in the list.")
        }
        .alert(
            "Remove Custom Equipment?",
            isPresented: Binding(
                get: { pendingSharedRemoval != nil },
                set: { if !$0 { pendingSharedRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingSharedRemoval = nil
            }
            Button("Remove", role: .destructive) {
                if let opt = pendingSharedRemoval {
                    withAnimation {
                        customStore.remove(opt)
                    }
                }
                pendingSharedRemoval = nil
            }
        } message: {
            Text(
                "This removes the option from the picker list. Exercises already using this value will keep it until you change them."
            )
        }
        .alert(
            "Clear Equipment?",
            isPresented: Binding(
                get: { pendingLegacyClear != nil },
                set: { if !$0 { pendingLegacyClear = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingLegacyClear = nil
            }
            Button("Clear", role: .destructive) {
                pendingLegacyClear = nil
                onSelect(nil)
                dismiss()
            }
        } message: {
            Text("This clears the custom value from this exercise only.")
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

    /// See `BodyPartPicker.isCustomSelected` — same case-insensitive
    /// matching rationale.
    private func isCustomSelected(_ custom: String) -> Bool {
        guard let curr = current else { return false }
        return curr.caseInsensitiveCompare(custom) == .orderedSame
    }
}

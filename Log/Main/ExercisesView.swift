import SwiftData
import SwiftUI

// MARK: - Top-level list of exercises

struct ExercisesView: View {
    @AppStorage("universalDefaultRestSeconds") private
        var universalDefaultRestSeconds: Int = 0
    @State private var editingDefaultRest = false
    @State private var restDraft = ""
    @FocusState private var restFieldFocused: Bool

    @Environment(\.modelContext) private var ctx
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
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

    private var filtered: [Exercise] {
        guard !search.isEmpty else { return exercises }
        return exercises.filter {
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
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusNewExercise = false }
            }
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
        } header: {
            DSSectionHeader(title: "All Exercises", systemImage: "list.bullet")
        }
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

        ctx.insert(Exercise(name: trimmed))
        try? ctx.save()
        newName = ""
    }
}

// MARK: - Exercise detail editor

struct ExerciseDetailView: View {
    @State private var renderTemplates = false
    @State private var stagedTimeBased = false
    @State private var showSwitchModeAlert = false
    @State private var showResetConfirm = false

    @Bindable var exercise: Exercise
    @Environment(\.modelContext) private var ctx
    let isLocked: Bool

    @FocusState private var focusedField: String?

    private func sanitizeTemplates() {
        for i in exercise.defaultTemplates.indices {
            if let w = exercise.defaultTemplates[i].targetWeight,
                !w.isFinite || w <= 0
            {
                exercise.defaultTemplates[i].targetWeight = nil
            }
            if let r = exercise.defaultTemplates[i].restSecondsAfter,
                r <= 0
            {
                exercise.defaultTemplates[i].restSecondsAfter = nil
            }
            if exercise.defaultTemplates[i].kind == .dropset {
                exercise.defaultTemplates[i].restSecondsAfter = nil
            }
        }
    }

    private func normalizeTemplateOrderIfNeeded() {
        let n = exercise.defaultTemplates.count
        guard n > 0 else { return }

        let orders = exercise.defaultTemplates.map(\.order)
        let uniqueCount = Set(orders).count
        let minOrder = orders.min() ?? 0
        let maxOrder = orders.max() ?? 0

        let needsFix =
            uniqueCount != n || minOrder < 0 || maxOrder != (n - 1)

        guard needsFix else { return }

        let repaired = exercise.defaultTemplates.sorted { a, b in
            if a.kindSortKey != b.kindSortKey {
                return a.kindSortKey < b.kindSortKey
            }
            if a.order != b.order { return a.order < b.order }

            if a.targetReps != b.targetReps {
                return a.targetReps < b.targetReps
            }
            let aw = a.targetWeight ?? -1
            let bw = b.targetWeight ?? -1
            if aw != bw { return aw < bw }
            let ar = a.restSecondsAfter ?? -1
            let br = b.restSecondsAfter ?? -1
            if ar != br { return ar < br }
            let ad = a.durationSeconds ?? -1
            let bd = b.durationSeconds ?? -1
            return ad < bd
        }

        for (i, tpl) in repaired.enumerated() {
            tpl.order = i
        }

        try? ctx.save()
    }

    private func applyModeSwitch(to newValue: Bool) {
        if newValue == exercise.isTimeBased { return }
        exercise.isTimeBased = newValue
        normalizeTemplatesForMode()
        try? ctx.save()
    }

    private func normalizeTemplatesForMode() {
        for i in exercise.defaultTemplates.indices {
            if exercise.isTimeBased {
                exercise.defaultTemplates[i].durationSeconds =
                    exercise.defaultTemplates[i].durationSeconds ?? 60
                exercise.defaultTemplates[i].targetWeight = nil
                exercise.defaultTemplates[i].targetReps = max(
                    1,
                    exercise.defaultTemplates[i].targetReps
                )
            } else {
                exercise.defaultTemplates[i].durationSeconds = nil
            }
            if exercise.defaultTemplates[i].kind == .dropset {
                exercise.defaultTemplates[i].restSecondsAfter = nil
            }
        }
    }

    var sortedTemplates: [SetTemplate] {
        exercise.defaultTemplates.sorted { $0.order < $1.order }
    }

    private func moveTemplates(from offsets: IndexSet, to newOffset: Int) {
        var items = sortedTemplates
        items.move(fromOffsets: offsets, toOffset: newOffset)

        for (index, item) in items.enumerated() {
            item.order = index
        }

        try? ctx.save()
    }

    private func resetSetOrder() {
        let sorted = exercise.defaultTemplates.sorted { lhs, rhs in
            lhs.kindSortKey < rhs.kindSortKey
        }

        for (i, tpl) in sorted.enumerated() {
            tpl.order = i
        }

        try? ctx.save()
    }

    var body: some View {
        DetailForm
            .probe("ExerciseDetail.Form")
            .onAppear {
                sanitizeTemplates()
                normalizeTemplateOrderIfNeeded()
                stagedTimeBased = exercise.isTimeBased
                DispatchQueue.main.async { renderTemplates = true }
            }
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

                Toggle(
                    "Time-based",
                    isOn: Binding(
                        get: { stagedTimeBased },
                        set: { newVal in
                            stagedTimeBased = newVal
                            showSwitchModeAlert = true
                        }
                    )
                )
                .disabled(isLocked)
                .alert("Switch set mode?", isPresented: $showSwitchModeAlert) {
                    Button("Cancel", role: .cancel) {
                        stagedTimeBased = exercise.isTimeBased
                    }
                    Button("Switch", role: .destructive) {
                        applyModeSwitch(to: stagedTimeBased)
                    }
                } message: {
                    Text(
                        exercise.isTimeBased
                            ? "Switching to reps/weight will discard any durations for existing sets."
                            : "Switching to time-based will discard reps and target weights for existing sets."
                    )
                }
            }

            Section("Sets") {
                if renderTemplates {
                    if exercise.defaultTemplates.isEmpty {
                        Text("No sets. Add some below.")
                            .font(.dsBodySecondary)
                            .foregroundStyle(.secondary)
                    } else {
                        if isLocked {
                            ForEach(
                                sortedTemplates,
                                id: \.persistentModelID
                            ) { t in
                                let key = "t-\(t.persistentModelID.hashValue)"
                                SetTemplateRow(
                                    template: t,
                                    focusKey: key,
                                    focused: $focusedField,
                                    isTimeBased: exercise.isTimeBased
                                )
                                .listRowInsets(
                                    EdgeInsets(
                                        top: 6,
                                        leading: 16,
                                        bottom: 6,
                                        trailing: 16
                                    )
                                )
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                #if DEBUG
                                    .probe("Templates.Row.\(key)")
                                #endif
                            }
                        } else {
                            ForEach(
                                sortedTemplates,
                                id: \.persistentModelID
                            ) { t in
                                let key = "t-\(t.persistentModelID.hashValue)"
                                SetTemplateRow(
                                    template: t,
                                    focusKey: key,
                                    focused: $focusedField,
                                    isTimeBased: exercise.isTimeBased
                                )
                                .listRowInsets(
                                    EdgeInsets(
                                        top: 6,
                                        leading: 16,
                                        bottom: 6,
                                        trailing: 16
                                    )
                                )
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                #if DEBUG
                                    .probe("Templates.Row.\(key)")
                                #endif
                            }
                            .onMove(perform: moveTemplates)
                            .onDelete { offsets in
                                let currentSorted = sortedTemplates

                                let toDelete: [SetTemplate] = offsets.compactMap
                                { index in
                                    guard
                                        index >= 0
                                            && index < currentSorted.count
                                    else { return nil }
                                    return currentSorted[index]
                                }

                                for tpl in toDelete {
                                    if let idx = exercise.defaultTemplates
                                        .firstIndex(where: { $0.id == tpl.id })
                                    {
                                        exercise.defaultTemplates.remove(
                                            at: idx
                                        )
                                    }
                                }

                                let remaining = exercise.defaultTemplates.sorted
                                { $0.order < $1.order }
                                for (i, tpl) in remaining.enumerated() {
                                    tpl.order = i
                                }

                                focusedField = nil
                                try? ctx.save()
                            }

                            Button {
                                showResetConfirm = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Reset Set Order")
                                        .font(
                                            .dsBodySecondary.weight(.semibold)
                                        )
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 6,
                                    leading: 16,
                                    bottom: 6,
                                    trailing: 16
                                )
                            )
                            .disabled(isLocked)
                            .alert(
                                "Reset set order?",
                                isPresented: $showResetConfirm
                            ) {
                                Button("Cancel", role: .cancel) {}

                                Button("Reset", role: .destructive) {
                                    withAnimation(.easeInOut) {
                                        resetSetOrder()
                                    }
                                }
                            } message: {
                                Text(
                                    "This will reorder the sets as Warm-up → Working → Dropset."
                                )
                            }
                        }
                    }

                    Button {
                        withAnimation(.easeInOut) {
                            let newSet = SetTemplate(
                                kind: .working,
                                targetReps: 8,
                                targetWeight: nil,
                                restSecondsAfter: nil
                            )

                            let nextOrder =
                                (exercise.defaultTemplates.map(\.order).max()
                                    ?? -1) + 1
                            newSet.order = nextOrder

                            let def = UserDefaults.standard.integer(
                                forKey: "universalDefaultRestSeconds"
                            )
                            if def > 0 {
                                newSet.restSecondsAfter = def
                            }
                            if newSet.kind == .dropset {
                                newSet.restSecondsAfter = nil
                            }
                            exercise.defaultTemplates.append(newSet)
                            try? ctx.save()
                        }
                        UIImpactFeedbackGenerator(style: .light)
                            .impactOccurred()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Set")
                                .font(.dsBodySecondary.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(
                        EdgeInsets(
                            top: 6,
                            leading: 16,
                            bottom: 12,
                            trailing: 16
                        )
                    )
                    .disabled(isLocked)
                }
            }
            .disabled(isLocked)
        }
    }
}

// MARK: - Row for a single set template

private struct SetTemplateRow: View {
    @Bindable var template: SetTemplate
    let focusKey: String
    let focused: FocusState<String?>.Binding
    let isTimeBased: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(SetKind.allCases, id: \.self) { k in
                        Button(k.rawValue.capitalized) {
                            template.kind = k
                            if k == .dropset { template.restSecondsAfter = nil }
                        }
                    }
                } label: {
                    Label(
                        template.kind.rawValue.capitalized,
                        systemImage: "square.grid.2x2"
                    )
                }
                .font(.dsBody)

                if !isTimeBased {
                    HStack(spacing: 4) {
                        Text("Reps:")
                            .font(.dsBodySecondary)
                        let repsShown = max(1, min(50, template.targetReps))
                        Text("\(repsShown)")
                            .font(.dsBody.monospacedDigit())
                            .frame(width: 32, alignment: .trailing)
                            .layoutPriority(1)
                    }

                    Stepper("", value: $template.targetReps, in: 1...50)
                        .labelsHidden()
                }
            }

            HStack(spacing: 16) {
                if template.kind != .dropset {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .foregroundStyle(.secondary)
                        TextField(
                            "Rest",
                            text: Binding(
                                get: {
                                    template.restSecondsAfter.map(String.init)
                                        ?? ""
                                },
                                set: { input in
                                    let v = Int(input.filter(\.isNumber)) ?? 0
                                    template.restSecondsAfter = v > 0 ? v : nil
                                }
                            )
                        )
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.dsBody)
                        .frame(width: 84, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .focused(focused, equals: .some("rest:\(focusKey)"))
                        .submitLabel(.done)

                        Text("s")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(width: 115, alignment: .trailing)
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    if isTimeBased {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        TextField(
                            "Duration",
                            text: Binding(
                                get: {
                                    template.durationSeconds.map(String.init)
                                        ?? ""
                                },
                                set: { input in
                                    let v = Int(input.filter(\.isNumber)) ?? 0
                                    template.durationSeconds = v > 0 ? v : nil
                                }
                            )
                        )
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .font(.dsBody)
                        .frame(width: 96, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .focused(focused, equals: .some("dur:\(focusKey)"))
                        .submitLabel(.done)

                        Text("s")
                            .font(.dsBodySecondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Image(systemName: "scalemass")
                            .foregroundStyle(.secondary)
                        TextField(
                            "Target wt",
                            text: Binding(
                                get: {
                                    guard let w = template.targetWeight, w > 0
                                    else { return "" }
                                    return String(Int(w.rounded()))
                                },
                                set: { newVal in
                                    let digits = newVal.filter(\.isNumber)
                                    if let v = Int(digits), v > 0 {
                                        template.targetWeight = Double(v)
                                    } else {
                                        template.targetWeight = nil
                                    }
                                }
                            )
                        )
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .font(.dsBody)
                        .frame(width: 96, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .focused(focused, equals: .some("wt:\(focusKey)"))
                        .submitLabel(.done)

                        Text(Units.weightIsKg ? "kg" : "lb")
                            .font(.dsBodySecondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DSColor.surface)
        )
        .dsCardShadow()
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

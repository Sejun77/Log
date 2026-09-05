import SwiftData
import SwiftUI

// MARK: - Default Prescription Factory

/// Defaults for a newly created routine slot.
///
/// `isCardio` defaults to false, so every pre-Slice-5 call site keeps producing
/// exactly the prescription it produced before. When it is true the slot takes
/// the cardio defaults from `CardioRoutineRules`: one set, no rest, no seeded
/// effort target. Nothing here ever touches an existing prescription — this is
/// the *creation* path only.
@discardableResult
func makeDefaultPrescription(
    isTimeBased: Bool,
    isCardio: Bool = false,
    in ctx: ModelContext
) -> SlotPrescription {
    // Cardio implies time-based (`Exercise.trackingMode` guarantees it), but
    // resolve defensively so a caller passing the pair inconsistently gets the
    // safe reading rather than a distance target on a reps slot.
    let mode: TrackingMode =
        isTimeBased ? (isCardio ? .cardio : .timedHold) : .strength

    let p = SlotPrescription()
    p.usesDuration = isTimeBased
    p.sets = CardioRoutineRules.defaultSets(mode)
    if !isTimeBased {
        p.repMin = AppSettings.defaultRepMin
        p.repMax = AppSettings.defaultRepMax
    }
    p.restSecondsBetweenSets = CardioRoutineRules.defaultRestBetweenSets(mode)
    p.restSecondsAfterExercise =
        CardioRoutineRules.defaultRestAfterExercise(mode)
    if CardioRoutineRules.seedsEffortTarget(mode) {
        switch AppSettings.autoregMode {
        case .rir: p.rir = AppSettings.defaultRIR
        case .rpe: p.rpe = AppSettings.defaultRPE
        case .none: break
        }
    }
    ctx.insert(p)
    return p
}

// MARK: - Prescription Editor (Phase 3.5)

struct SlotPrescriptionSection: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var re: RoutineExercise
    let isTimeBased: Bool
    var hideRestFields: Bool = false
    var hideSetsField: Bool = false
    /// Alternative Exercises Phase D — false suppresses the `Alternative
    /// Exercises` row. Set only by `SlotAlternativeDetailEditor`, which renders
    /// this same section for a scratch slot: an alternative does not get
    /// alternatives of its own.
    var showsAlternatives: Bool = true
    /// Forwarded to the warm-up and technique editors this section pushes, so
    /// they can report a change to whoever owns the prescription they are
    /// editing. Nil for a routine slot — its prescription *is* the stored model
    /// and there is nothing to write back. Set only by
    /// `SlotAlternativeDetailEditor`, whose scratch prescription reaches the
    /// stored `SlotAlternative` payload only through a commit, and which is
    /// off-screen while either editor is pushed. See `AlternativeDraftCommit`.
    var onNestedGraphChange: (() -> Void)? = nil
    /// Phase 5.2 — when true (routine is in use by an active workout),
    /// the Section's content is non-interactive but still visible /
    /// scrollable. Applied to the Section itself so the parent List's
    /// scroll gesture stays intact.
    var isLocked: Bool = false

    /// Drives the gated keyboard checkmark for the multiline slot-notes field.
    /// Each rendered section has its own focus state, so when several sections
    /// share one detail screen only the focused one shows the accessory.
    @FocusState private var slotNotesFocused: Bool

    /// The slot's tracking mode, which decides which controls this section
    /// offers (see `CardioRoutineRules`).
    ///
    /// Falls back to the caller's `isTimeBased` when the exercise reference is
    /// nil — an orphan slot mid-normalization — so the section degrades to its
    /// pre-cardio behavior rather than guessing.
    private var trackingMode: TrackingMode {
        re.exercise?.trackingMode ?? (isTimeBased ? .timedHold : .strength)
    }

    private var isCardio: Bool { trackingMode == .cardio }

    var body: some View {
        Section {
            if !re.setTemplates.isEmpty {
                Label(
                    "Custom set templates override prescription.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let prescription = re.prescription {
                PrescriptionFields(
                    prescription: prescription,
                    trackingMode: trackingMode,
                    hideRestFields: hideRestFields,
                    hideSetsField: hideSetsField
                )

                // Phase 3.5: Warmup scheme navigation. Hidden for cardio: the
                // remaining kinds after the Slice 4 polish are "Reps" and
                // "Note Only", and programming reps for a treadmill is not a
                // warm-up. Any stored scheme is left untouched — hidden, not
                // deleted — so a slot switched back to strength still has it.
                if CardioRoutineRules.showsWarmupScheme(trackingMode) {
                    NavigationLink {
                        WarmupSchemeEditor(
                            prescription: prescription,
                            isBodyweight: isBodyweightEquipment(re.exercise?.equipmentType),
                            onGraphChange: onNestedGraphChange
                        )
                    } label: {
                        HStack {
                            Text("Warmup")
                            Spacer()
                            let count = prescription.warmupScheme?.steps.count ?? 0
                            if count > 0 {
                                Text("\(count) step\(count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("None")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Phase 3.5: Technique plans navigation. Hidden for cardio —
                // every technique the app models is defined in reps or load.
                // Stored plans are likewise left intact.
                if CardioRoutineRules.showsTechniques(trackingMode) {
                    NavigationLink {
                        TechniquePlanEditor(
                            prescription: prescription,
                            isBodyweight: isBodyweightEquipment(re.exercise?.equipmentType),
                            onGraphChange: onNestedGraphChange
                        )
                    } label: {
                        HStack {
                            Text("Techniques")
                            Spacer()
                            // Count only the techniques the slot can actually use,
                            // matching what `TechniquePlanEditor` will list — the
                            // on-appear heal deletes the rest, but this renders
                            // before it runs.
                            let count = compatibleTechniquePlans(
                                prescription.techniquePlans,
                                isBodyweight: isBodyweightEquipment(
                                    re.exercise?.equipmentType),
                                usesDuration: prescription.usesDuration
                            ).count
                            if count > 0 {
                                Text("\(count) technique\(count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("None")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Alternative Exercises Phase D — the bottom of the tools
                // group, below warm-ups / techniques / Structured Cardio, and
                // shown for every tracking mode: an alternative can replace a
                // treadmill as readily as a bench press. Always visible, even
                // at zero, because it is the only way to author the first one.
                if showsAlternatives {
                    AlternativeExercisesRow(
                        prescription: prescription,
                        slotExerciseID: re.exercise?.id)
                }
            }

            TextField("Slot notes", text: slotNotesBinding, axis: .vertical)
                .lineLimit(1...4)
                .focused($slotNotesFocused)
                .toolbar {
                    // Slot notes is multiline (axis: .vertical) — Return inserts
                    // a newline, so it needs a keyboard-integrated dismiss. Gated
                    // on this field's own focus so it never shows a redundant
                    // accessory for the rest of the prescription editor (all
                    // Steppers) or for sibling slot sections on the same screen.
                    ToolbarItemGroup(placement: .keyboard) {
                        if slotNotesFocused {
                            Spacer()
                            KeyboardDismissButton()
                        }
                    }
                }
        } header: {
            Text("Prescription")
        }
        // Section-level disable: cascades to PrescriptionFields,
        // Warmup / Techniques navigation links, and the slot-notes
        // TextField, leaving the parent List's scroll behavior alone.
        .disabled(isLocked)
        .onAppear(perform: ensurePrescription)
    }

    private var slotNotesBinding: Binding<String> {
        Binding(
            get: { re.templateNotes ?? "" },
            set: { re.templateNotes = $0.isEmpty ? nil : $0 }
        )
    }

    private func ensurePrescription() {
        if re.prescription == nil {
            re.prescription = makeDefaultPrescription(
                isTimeBased: isTimeBased, isCardio: isCardio, in: ctx)
            try? ctx.save()
            return
        }
        guard let p = re.prescription else { return }

        if p.usesDuration != isTimeBased {
            p.usesDuration = isTimeBased
        }

        // Reconcile a duration slot to the duration rules. Runs on every
        // appear (not only on the reps ↔ duration transition) so a slot that
        // was ALREADY duration-based still heals: imported routines and rows
        // written before these rules existed can both carry tempo state that
        // the editor now refuses to create.
        //
        // Tempo is cleared rather than merely hidden — an invisible-but-stored
        // value would still reach the session snapshot and any summary that
        // renders tempo. Tempo Override is the same rule expressed as a
        // technique, so incompatible technique plans go with it.
        guard isTimeBased else { return }
        var didChange = false

        if p.tempo != nil {
            p.tempo = nil
            didChange = true
        }

        let allowed = compatibleTechniquePlans(
            p.techniquePlans,
            isBodyweight: isBodyweightEquipment(re.exercise?.equipmentType),
            usesDuration: true
        )
        if allowed.count != p.techniquePlans.count {
            let allowedIDs = Set(allowed.map(\.id))
            let dropped = p.techniquePlans.filter { !allowedIDs.contains($0.id) }
            p.techniquePlans = allowed
            for plan in dropped { ctx.delete(plan) }
            for (i, plan) in p.techniquePlans.sorted(by: { $0.order < $1.order })
                .enumerated()
            {
                plan.order = i
            }
            didChange = true
        }

        if didChange { try? ctx.save() }
    }
}

private struct PrescriptionFields: View {
    @Bindable var prescription: SlotPrescription
    /// Drives every visibility decision in this section via
    /// `CardioRoutineRules`. Replaced the previous `isTimeBased` flag, which
    /// could not distinguish a treadmill from a plank.
    let trackingMode: TrackingMode
    var hideRestFields: Bool = false
    var hideSetsField: Bool = false

    /// Cardio Slice 8 patch: observable, so a Settings change re-renders this
    /// view. `AppSettings.distanceUnit` is a plain `UserDefaults` read and
    /// SwiftUI cannot see it — reading it in a `body` renders the right unit
    /// once and then never updates. See `AppSettings.distanceUnit`.
    @AppStorage(AppSettings.Keys.distanceIsMetric)
    private var distanceIsMetric: Bool = AppSettings.defaultDistanceIsMetric()

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    private var isTimeBased: Bool { trackingMode != .strength }

    var body: some View {
        if !hideSetsField {
            optionalIntStepper("Sets", keyPath: \.sets, range: 0...20)
        }

        // Duration and rest use `DurationFieldRow` (preset strip + h/m/s
        // wheels) rather than a stepper: the bounds are now 6h / 60m, which no
        // fixed-step stepper can cover in a usable number of taps. Reps still
        // step — their range is small and the ± affordance suits it.
        if isTimeBased {
            durationRow("Duration min", keyPath: \.durationMinSeconds)
            durationRow("Duration max", keyPath: \.durationMaxSeconds)
        } else {
            optionalIntStepper("Rep min", keyPath: \.repMin, range: 0...50)
            optionalIntStepper("Rep max", keyPath: \.repMax, range: 0...50)
        }

        // Cardio only. A duration target and a distance target are independent:
        // either, both, or neither is a valid cardio prescription, and the row
        // simply does not exist for the modes that cannot use it.
        if CardioRoutineRules.showsTargetDistance(trackingMode) {
            TargetDistanceRow(
                prescription: prescription, displayUnit: entryUnit)
        }

        // Structured Cardio Slice 12C — the shape of the bout, next to the
        // targets that describe its size. The cardio counterpart of the warm-up
        // scheme (hidden for cardio), so a slot never offers both.
        if CardioRoutineRules.showsCardioSegments(trackingMode) {
            NavigationLink {
                CardioSegmentPlanEditor(prescription: prescription)
            } label: {
                HStack {
                    Text("Cardio Plan")
                    Spacer()
                    // Verbatim: the summary is composed from counts and units,
                    // like every other plan summary in the app. Reading it here
                    // (rather than caching) is what makes the row refresh when
                    // the editor pushes an edit back.
                    if let summary = prescription.structuredCardioPlan?
                        .summary(distanceUnit: entryUnit)
                    {
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if !hideRestFields {
            restRow("Rest between sets", keyPath: \.restSecondsBetweenSets)
            restRow("Rest after exercise", keyPath: \.restSecondsAfterExercise)
        }

        // Hidden for cardio: RIR is "reps in reserve", and the app exposes RIR
        // and RPE through one control governed by a single preference, so the
        // two cannot be separated without splitting that preference. Stored
        // values are untouched — this is display-only.
        if CardioRoutineRules.showsEffortControl(trackingMode) {
            effortSection
        }

        // Tempo describes rep phases — hidden and uneditable for a
        // duration-based slot. `ensurePrescription` clears any stored value
        // when a slot becomes duration-based, so nothing stale hides here.
        if CardioRoutineRules.showsTempo(trackingMode) {
            TempoEditorView(tempo: $prescription.tempo)
        }
    }

    /// The unit the distance field displays and edits in: the user's Settings
    /// preference, and the only place it can be changed. Distance is stored
    /// canonically in meters, so switching the preference re-expresses an
    /// existing target rather than reinterpreting it.
    private var entryUnit: DistanceUnit {
        AppSettings.distanceUnit(isMetric: distanceIsMetric)
    }

    // MARK: - Effort target mode (Slice D)

    /// Effort controls, gated on the app-wide autoreg metric. `.none` shows
    /// nothing; `.rir`/`.rpe` show a mode picker (None / Single / Progression)
    /// plus the matching value steppers. Single stores into `rir`/`rpe`;
    /// Progression stores into `rir(Start|End)` / `rpe(Start|End)`. Both keep
    /// the opposite metric mirrored via `10 - x`, matching the prior behavior.
    @ViewBuilder
    private var effortSection: some View {
        switch autoregMode {
        case .rir:
            effortControls(
                label: "RIR", paths: Self.rirPaths,
                range: 0...5, defaultValue: AppSettings.defaultRIR)
        case .rpe:
            effortControls(
                label: "RPE", paths: Self.rpePaths,
                range: 5...10, defaultValue: AppSettings.defaultRPE)
        case .none:
            // M4 — autoreg off hides the controls, and always has; it has never
            // deleted anything. Without this row a slot's authored targets
            // simply vanished from the editor, which reads as data loss. Shown
            // only when there is actually something saved, so a slot that never
            // had targets stays as quiet as before. Read-only by construction:
            // there is no metric selected to edit them in.
            if EffortTargetPresence.hasSavedTargets(
                in: WorkoutEffortTargetResolver.Fields(
                    prescription: prescription))
            {
                Text(LocalizedStringKey(EffortTargetHelp.savedWhileAutoregOff))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Active/paired key paths for one metric. The "paired" set is the opposite
    /// metric, kept mirrored (`10 - x`) so switching the app autoreg mode later
    /// surfaces a sensible converted value — exactly as the single stepper did.
    private struct EffortKeyPaths {
        let metric: EffortMetric
        let single, start, end: ReferenceWritableKeyPath<SlotPrescription, Double?>
        let pairedSingle, pairedStart, pairedEnd:
            ReferenceWritableKeyPath<SlotPrescription, Double?>
    }

    private static let rirPaths = EffortKeyPaths(
        metric: .rir,
        single: \.rir, start: \.rirStart, end: \.rirEnd,
        pairedSingle: \.rpe, pairedStart: \.rpeStart, pairedEnd: \.rpeEnd)
    private static let rpePaths = EffortKeyPaths(
        metric: .rpe,
        single: \.rpe, start: \.rpeStart, end: \.rpeEnd,
        pairedSingle: \.rir, pairedStart: \.rirStart, pairedEnd: \.rirEnd)

    @ViewBuilder
    private func effortControls(
        label: String, paths: EffortKeyPaths,
        range: ClosedRange<Double>, defaultValue: Double
    ) -> some View {
        Picker(
            "Effort",
            selection: Binding(
                get: { prescription.effortMode },
                set: {
                    applyEffortMode($0, paths: paths, defaultValue: defaultValue)
                }
            )
        ) {
            Text("None").tag(EffortMode.none)
            Text("Same Target").tag(EffortMode.single)
            Text("Progression").tag(EffortMode.progression)
            Text("Custom Per Set").tag(EffortMode.custom)
        }
        // Keep a custom list in step with the set count as the user edits it:
        // added sets repeat the last authored target, removed sets truncate,
        // and earlier targets are untouched. The resolver applies the same
        // rule on read, so this is about what is *stored* matching what is
        // *shown* — not about correctness of the display.
        .onChange(of: prescription.sets ?? 0) { _, newCount in
            prescription.resizeCustomEffortTargets(
                to: newCount, metric: paths.metric)
        }

        // M3 — the picker offers four modes and named none of them. Its own
        // row cannot carry the glyph: a `Picker` in a Form owns the whole
        // row's tap, so a button inside its label would be swallowed by the
        // menu. This sits directly under it instead, in the caption + info
        // idiom the app already uses for Cardio and Bodyweight.
        HStack(spacing: DSSpacing.xs) {
            Text(LocalizedStringKey(EffortTargetHelp.modesTitle))
                .font(.dsCaption)
                .foregroundStyle(.secondary)
            InfoButton(
                LocalizedStringKey(EffortTargetHelp.modesTitle),
                message: LocalizedStringKey(EffortTargetHelp.modesMessage))
            Spacer()
        }

        switch prescription.effortMode {
        case .none:
            EmptyView()
        case .single:
            doubleStepperRow(
                label, active: doubleBinding(paths.single),
                paired: doubleBinding(paths.pairedSingle),
                range: range, step: 0.5) { 10 - $0 }
        case .progression:
            doubleStepperRow(
                "\(String(localized: "Start")) \(label)",
                active: doubleBinding(paths.start),
                paired: doubleBinding(paths.pairedStart),
                range: range, step: 0.5) { 10 - $0 }
            doubleStepperRow(
                "\(String(localized: "End")) \(label)",
                active: doubleBinding(paths.end),
                paired: doubleBinding(paths.pairedEnd),
                range: range, step: 0.5) { 10 - $0 }
            effortPreview
        case .custom:
            customEffortRows(
                paths: paths, range: range, defaultValue: defaultValue)
        }
    }

    // MARK: - Custom per-set targets

    /// One stepper per working set (`Set 1`, `Set 2`, …).
    ///
    /// Values are stored and displayed **verbatim** — half steps included —
    /// because the whole point of this mode is that the user, not the
    /// generator, decides each set's target. Nothing here rounds.
    ///
    /// Every row writes the **whole** list back through
    /// `setCustomEffortTargets`, so the stored list is always exactly as long
    /// as the set count and the opposite metric stays mirrored.
    @ViewBuilder
    private func customEffortRows(
        paths: EffortKeyPaths, range: ClosedRange<Double>, defaultValue: Double
    ) -> some View {
        let count = max(0, prescription.sets ?? 0)
        if count == 0 {
            Text("Add at least one set to enter per-set targets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let values = displayedCustomTargets(
                paths: paths, count: count, defaultValue: defaultValue)
            ForEach(0..<count, id: \.self) { index in
                Stepper(
                    "\(String(localized: "Set \(index + 1)")): "
                        + EffortTargetResolver.format(values[index]),
                    value: Binding(
                        get: { values[index] },
                        set: { newValue in
                            var updated = values
                            updated[index] = newValue
                            prescription.setCustomEffortTargets(
                                updated, metric: paths.metric)
                        }
                    ),
                    in: range,
                    step: 0.5
                )
            }
        }
    }

    /// The stored custom list for the active metric, through the same paired
    /// `10 - x` fallback every other effort read applies.
    private func customTargets(paths: EffortKeyPaths) -> [Double] {
        prescription.effortState(metric: paths.metric).custom
    }

    /// The list the rows actually render: the stored list fitted to the set
    /// count, or — when the column is empty or unreadable — a list seeded from
    /// whatever the prescription still carries, so the editor always shows one
    /// editable target per set rather than a blank section.
    ///
    /// The seed goes through the **same** transition the Custom mode switch
    /// applies, so what the rows show before the first edit and what gets
    /// stored on the switch cannot drift apart.
    private func displayedCustomTargets(
        paths: EffortKeyPaths, count: Int, defaultValue: Double
    ) -> [Double] {
        let stored = EffortTargetList.resized(
            customTargets(paths: paths), to: count)
        if !stored.isEmpty { return stored }
        var seed = prescription.effortState(metric: paths.metric)
        seed.custom = []
        return EffortTargetModeTransition.applying(
            .custom, to: seed, metric: paths.metric, setCount: count,
            defaultValue: defaultValue
        ).custom
    }

    /// Live "Set targets: 2 · 1 · 0" preview. Resolves through
    /// `WorkoutEffortTargetResolver` so it uses the **same** derived effort mode
    /// and paired-metric `10 - x` fallback as the Start/End steppers, the block
    /// summary, and the active-workout rows — never the active metric's fields
    /// alone. Hidden when there are no usable targets (no sets / missing values).
    @ViewBuilder
    private var effortPreview: some View {
        let values = WorkoutEffortTargetResolver.perSetValues(
            fields: WorkoutEffortTargetResolver.Fields(prescription: prescription),
            autoregMode: autoregMode,
            workingSetCount: max(0, prescription.sets ?? 0))
        if !values.isEmpty {
            Text(
                "Set targets: \(values.map(EffortTargetResolver.format).joined(separator: "/"))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func doubleBinding(
        _ kp: ReferenceWritableKeyPath<SlotPrescription, Double?>
    ) -> Binding<Double?> {
        Binding(
            get: { prescription[keyPath: kp] },
            set: { prescription[keyPath: kp] = $0 }
        )
    }

    /// Apply a mode change, seeding the new mode from what the old one said.
    ///
    /// Both the rules (`EffortTargetModeTransition`) and the model adapter
    /// (`SlotPrescription.applyEffortMode`) live outside the view, so the
    /// picker owns no behavior of its own and the seeding is testable without
    /// rendering anything.
    private func applyEffortMode(
        _ newMode: EffortMode, paths: EffortKeyPaths, defaultValue: Double
    ) {
        prescription.applyEffortMode(
            newMode, metric: paths.metric, defaultValue: defaultValue)
    }

    /// Exercise-duration field (6h bound). Writes are normalized by the row, so
    /// the stored value stays nil-or-positive and within range.
    private func durationRow(
        _ label: String,
        keyPath: ReferenceWritableKeyPath<SlotPrescription, Int?>
    ) -> some View {
        DurationFieldRow(
            title: label,
            seconds: secondsBinding(keyPath),
            maxSeconds: DurationLimits.maxExerciseSeconds,
            presets: DurationPresets.exerciseDuration
        )
    }

    /// Rest field (60m bound). `zeroLabel` keeps the stepper's "no rest"
    /// wording for an unset value.
    private func restRow(
        _ label: String,
        keyPath: ReferenceWritableKeyPath<SlotPrescription, Int?>
    ) -> some View {
        DurationFieldRow(
            title: label,
            seconds: secondsBinding(keyPath),
            maxSeconds: DurationLimits.maxRestSeconds,
            zeroLabel: "None",
            presets: DurationPresets.rest
        )
    }

    private func secondsBinding(
        _ keyPath: ReferenceWritableKeyPath<SlotPrescription, Int?>
    ) -> Binding<Int?> {
        Binding(
            get: { prescription[keyPath: keyPath] },
            set: { prescription[keyPath: keyPath] = $0 }
        )
    }

    private func optionalIntStepper(
        _ label: String,
        keyPath: ReferenceWritableKeyPath<SlotPrescription, Int?>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String? = nil,
        zeroLabel: String = "—"
    ) -> some View {
        let current = prescription[keyPath: keyPath] ?? 0
        let valStr = current == 0 ? zeroLabel : (unit.map { "\(current)\($0)" } ?? "\(current)")
        let title = NSLocalizedString(label, comment: "")
        return Stepper(
            "\(title): \(valStr)",
            value: Binding(
                get: { prescription[keyPath: keyPath] ?? 0 },
                set: { prescription[keyPath: keyPath] = $0 == 0 ? nil : $0 }
            ),
            in: range,
            step: step
        )
    }

    /// Stepper for an optional-Double intensity field that keeps its paired counterpart in sync.
    /// On write: stores the active value and updates `paired` via `convert` (or nil if clearing).
    /// On display: shows `active` if stored; otherwise derives from `paired` via `convert`.
    private func doubleStepperRow(
        _ label: String,
        active: Binding<Double?>,
        paired: Binding<Double?>,
        range: ClosedRange<Double>,
        step: Double,
        convert: @escaping (Double) -> Double
    ) -> some View {
        let sentinel = range.lowerBound - step
        let displayValue = active.wrappedValue ?? paired.wrappedValue.map(convert)
        let formatted: (Double) -> String = { v in
            v.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(v)) : String(format: "%.1f", v)
        }
        return Stepper(
            "\(label): \(displayValue.map(formatted) ?? "—")",
            value: Binding(
                get: {
                    if let v = active.wrappedValue { return v }
                    if let pv = paired.wrappedValue { return convert(pv) }
                    return sentinel
                },
                set: { newVal in
                    let stored: Double? = newVal < range.lowerBound ? nil : newVal
                    active.wrappedValue = stored
                    paired.wrappedValue = stored.map(convert)
                }
            ),
            in: sentinel...range.upperBound,
            step: step
        )
    }
}

// MARK: - Tempo Editor

struct TempoEditorView: View {
    @Binding var tempo: String?

    @State private var eccentric: Int = 0
    @State private var stretchPause: Int = 0
    @State private var concentric: Int = 0
    @State private var squeezePause: Int = 0

    var body: some View {
        Stepper("Eccentric: \(label(eccentric))", value: $eccentric, in: 0...10)
            .onAppear { parseTempo() }
            .onChange(of: eccentric) { serializeTempo() }
        Stepper("Stretch pause: \(label(stretchPause))", value: $stretchPause, in: 0...10)
            .onChange(of: stretchPause) { serializeTempo() }
        Stepper("Concentric: \(label(concentric))", value: $concentric, in: 0...10)
            .onChange(of: concentric) { serializeTempo() }
        Stepper("Squeeze pause: \(label(squeezePause))", value: $squeezePause, in: 0...10)
            .onChange(of: squeezePause) { serializeTempo() }
        Text("Tempo = eccentric – stretch pause – concentric – squeeze pause")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func label(_ v: Int) -> String { v == 0 ? "—" : "\(v)s" }

    private func parseTempo() {
        guard let t = tempo, !t.isEmpty else {
            eccentric = 0; stretchPause = 0; concentric = 0; squeezePause = 0
            return
        }
        let parts = t.split(separator: "-").compactMap { Int($0) }
        eccentric    = parts.count > 0 ? parts[0] : 0
        stretchPause = parts.count > 1 ? parts[1] : 0
        concentric   = parts.count > 2 ? parts[2] : 0
        squeezePause = parts.count > 3 ? parts[3] : 0
    }

    private func serializeTempo() {
        let vals = [eccentric, stretchPause, concentric, squeezePause]
        tempo = vals.allSatisfy({ $0 == 0 }) ? nil
              : vals.map(String.init).joined(separator: "-")
    }
}

// MARK: - Cardio target distance (Slice 5)

/// The optional target-distance row for a cardio slot.
///
/// Its own view rather than a helper on `PrescriptionFields` because it owns
/// entry text: the stored value is canonical meters, but a user mid-typing has
/// "6." in the field, and normalizing on every keystroke would delete the dot.
/// The text is local `@State`, sanitized per keystroke, and committed to the
/// model through `CardioTargetDistance` — the same draft-then-normalize shape
/// `CardioEntryDraft` uses on the logging side.
///
/// Empty, non-numeric, zero, negative and out-of-range input all commit **nil**
/// ("no target"), which is the correct reading of a field the user cleared or
/// fumbled. Nothing here can fail loudly.
///
/// **The row has no unit control.** The unit is `AppSettings.distanceUnit` and
/// is shown as a static suffix, so there is exactly one place in the app to
/// change it. Changing it there re-seeds this field from the stored meters, so
/// a 5 km target becomes "3.11 mi" without the persisted value moving.
private struct TargetDistanceRow: View {
    @Bindable var prescription: SlotPrescription
    /// The unit this row displays and edits in — the Settings preference.
    let displayUnit: DistanceUnit

    @State private var text: String = ""
    /// The unit the field's text is currently expressed in. Tracked so a
    /// preference change can be told apart from a re-render and re-seed only
    /// then; never user-settable.
    @State private var seededUnit: DistanceUnit?

    private static let fieldWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text("Target distance")
            Spacer(minLength: DSSpacing.sm)
            TextField("0.0", text: distanceBinding)
                .font(.dsBody.monospacedDigit())
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.fieldWidth)
                .multilineTextAlignment(.trailing)
            // Label, not a control: the unit is chosen in Settings.
            Text(displayUnit.symbol)
                .font(.dsBody)
                .foregroundStyle(.secondary)
        }
        .toolbar {
            // `.decimalPad` has no Return key, so the field needs a
            // keyboard-integrated dismiss like every other decimal entry.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                KeyboardDismissButton()
            }
        }
        .onAppear(perform: seedFromModel)
        .onChange(of: displayUnit) { _, _ in reseedForUnitChange() }
    }

    private var distanceBinding: Binding<String> {
        Binding(
            get: { text },
            set: {
                text = CardioEntryDraft.sanitizeDecimal($0)
                commit()
            }
        )
    }

    /// Read the committed target back into entry text, once. The `seededUnit`
    /// guard is what stops `onAppear` firing again (a re-render, a navigation
    /// return) from overwriting in-progress text with the committed value.
    private func seedFromModel() {
        guard seededUnit == nil else { return }
        seededUnit = displayUnit
        text = prescription.targetDistance(displayUnit: displayUnit)?.valueText
            ?? ""
    }

    /// Re-express the field when the Settings unit changes underneath it.
    ///
    /// Re-reads from the stored meters rather than converting `text`, so a
    /// half-typed "6." cannot be turned into a committed number.
    ///
    /// Deliberately does **not** commit. The displayed text is rounded for
    /// legibility (4988.9664 m reads "4.99 km"), so writing it back would round
    /// the stored meters every time the preference was toggled — a silent edit
    /// to the user's data for a display change they made in another screen. The
    /// meters stay exactly as authored; `targetDistanceUnitRaw` keeps its old
    /// value until the user actually types, which is harmless because nothing
    /// reads it for display.
    private func reseedForUnitChange() {
        guard seededUnit != displayUnit else { return }
        seededUnit = displayUnit
        text = prescription.targetDistance(displayUnit: displayUnit)?.valueText
            ?? ""
    }

    /// Normalize and write both columns together. An unusable value clears the
    /// target rather than leaving a stale one behind, so what the field shows
    /// and what the routine stores never disagree.
    private func commit() {
        prescription.applyTargetDistance(
            CardioTargetDistance(text: text, unit: displayUnit))
    }
}

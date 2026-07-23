import Foundation

// MARK: - Active-Workout Pure Helpers (Phase 11.6-A)
//
// These four helpers were lifted out of `ActiveWorkoutView` as part of
// Phase 11.6-A. Each is pure — it reads only its parameters plus a small
// number of module-level statics (`Units.weightIsKg`,
// `RestTimer.stableNotificationID(workoutID:slotID:)`) — so promoting them
// to module-internal free functions widens no `ActiveWorkoutView` state.

// MARK: - Weight rounding / formatting

/// Rounds a raw weight to the nearest 0.5 (kg) or 1.0 (lb) depending on
/// the user's current `Units.weightIsKg` setting. Pure.
func roundWeight(_ raw: Double) -> Double {
    Units.weightIsKg
        ? (raw * 2).rounded() / 2  // nearest 0.5
        : raw.rounded()             // nearest 1.0
}

/// Formats a rounded weight value for display in set/drop rows. Integer
/// values render without a decimal point. Pure.
func formatWeight(_ w: Double) -> String {
    w.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(w)) : String(w)
}

// MARK: - Session elapsed clock formatting

/// Formats the active session's elapsed time for the toolbar clock.
/// Returns "00:00" when no `start` is set, clamps negative intervals to 0,
/// and switches from MM:SS to H:MM:SS once an hour has elapsed. Pure — the
/// caller supplies `now` so the per-second redraw can live in an isolated
/// `TimelineView`/clock subview instead of `ActiveWorkoutView`'s body.
func formatSessionElapsed(start: Date?, now: Date) -> String {
    guard let start else { return "00:00" }
    let total = max(0, Int(now.timeIntervalSince(start)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
}

// MARK: - Note normalization

/// Canonical optional form for free-text note input. Trims whitespace and
/// newlines only to decide emptiness; when non-empty, stores the **original
/// (untrimmed)** text. This matches the pre-existing inline bindings in
/// `ActiveWorkoutView` (session notes) and `ExerciseNotesEditSheet`, where
/// `trimmed.isEmpty ? nil : original` cleared blank/whitespace-only notes to
/// nil while preserving the user's exact text otherwise. Pure.
func normalizedOptionalNote(_ text: String) -> String? {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
}

// MARK: - Equipment classification

/// The canonical equipment-type string for bodyweight exercises.
let bodyweightEquipment = "Bodyweight"

/// True when an `Exercise.equipmentType` / snapshot `equipment` string
/// represents a bodyweight exercise. Trimmed + case-insensitive so
/// imported/legacy casings (e.g. " bodyweight ") still match. Pure.
func isBodyweightEquipment(_ equipment: String?) -> Bool {
    guard let equipment else { return false }
    return equipment.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(bodyweightEquipment) == .orderedSame
}

/// Inferred default for `Exercise.includesBodyweightInLoad` from equipment:
/// bodyweight equipment counts bodyweight toward load; everything else does
/// not. Used to seed sensible defaults (catalog / new exercises) — the stored
/// flag remains user-overridable (e.g. a weighted pull-up on a Dip Belt sets it
/// true manually). Pure.
func defaultIncludesBodyweightInLoad(equipmentType: String?) -> Bool {
    isBodyweightEquipment(equipmentType)
}

// MARK: - Swapped-exercise info resolution

/// Resolves which value an active-workout slot should use for a field that
/// has both an immutable session-start snapshot value and a live
/// swapped-in value (equipment, setup notes, bodyweight classification).
///
/// - When the slot's exercise was swapped during the session
///   (`currentExerciseID != originalExerciseID`), the `live` value of the
///   swapped-in exercise wins so the displayed info and prefill reflect the
///   exercise the user actually selected.
/// - Otherwise the `snapshot` value wins so later library edits never
///   retroactively change a non-swapped active workout (the Phase 10
///   snapshot-immutability invariant). Pure.
func resolvedSwappedValue<T>(isSwapped: Bool, live: T, snapshot: T) -> T {
    isSwapped ? live : snapshot
}

/// Resolves the setup-notes string the active workout should **display** in
/// its "Equipment & Setup" section.
///
/// Unlike equipment (which stays snapshot-sourced for non-swapped slots),
/// setup notes read the **live** `Exercise.setupDefaults` whenever the
/// library exercise still exists, so an in-workout edit via
/// `SetupNotesEditSheet` is visible immediately — the same live-read contract
/// the Exercise Notes section already uses for `Exercise.notes`. The
/// session-start snapshot value is only the fallback for a slot whose
/// exercise was deleted from the library mid-session (no live row to read or
/// edit). Display resolution only — the committed edit is propagated into
/// the current session's snapshots separately by
/// `applyActiveSetupNotesEdit`, so what this row shows and what finished
/// History records stay in agreement. Pure.
func resolvedActiveSetupNotes(
    liveExerciseExists: Bool,
    liveSetupNotes: String?,
    snapshotSetupNotes: String?
) -> String? {
    liveExerciseExists ? liveSetupNotes : snapshotSetupNotes
}

/// Propagates a committed in-workout setup-notes edit (`SetupNotesEditSheet`
/// Done) into the **current** session's snapshots so this workout's finished
/// History records the setup notes the user actually used/corrected while
/// training:
///
///  * the in-memory plan payload (`PlanExercise.prescriptionSnapshot`) of
///    every non-swapped slot currently running the edited exercise — so a
///    `WorkoutItem` created later (at the slot's first log) freezes the new
///    value via `populateSnapshotFields`;
///  * the persisted `WorkoutItem.plannedPrescriptionSnapshot` of every slot
///    currently running the edited exercise that already has an item — so
///    already-logged slots freeze the new value too.
///
/// A swapped slot's payload is left untouched: that payload still describes
/// the slot's ORIGINAL exercise (the keep-plan swap contract preserves it
/// verbatim, including across a swap-back), and swapped item creation
/// resolves live exercise values anyway.
///
/// This runs ONLY from the sheet's Done commit — Cancel never reaches it,
/// and no other code path writes session setup snapshots — so finished
/// (past) workouts stay frozen: later edits to `Exercise.setupDefaults`
/// never touch a completed workout's snapshot rows.
///
/// Returns the number of matched slots (test hook).
@discardableResult
func applyActiveSetupNotesEdit(
    _ normalizedSetupNotes: String?,
    editedExerciseID: UUID,
    plan: inout WorkoutPlan,
    itemsBySlotID: [UUID: WorkoutItem]
) -> Int {
    var matched = 0
    for bi in plan.blocks.indices {
        for ei in plan.blocks[bi].exercises.indices {
            let slot = plan.blocks[bi].exercises[ei]
            guard slot.currentExerciseID == editedExerciseID else { continue }
            matched += 1
            if slot.currentExerciseID == slot.originalExerciseID {
                plan.blocks[bi].exercises[ei].prescriptionSnapshot?
                    .setupNotes = normalizedSetupNotes
            }
            itemsBySlotID[slot.routineSlotID]?
                .plannedPrescriptionSnapshot?.setupNotes = normalizedSetupNotes
        }
    }
    return matched
}

/// Resolves the `(equipment, setupNotes)` pair to **freeze** into a finished
/// `WorkoutItem`'s `plannedPrescriptionSnapshot` at session-snapshot time.
///
/// History reads Equipment & Setup exclusively from that frozen snapshot
/// (never live `Exercise` fields), so the value chosen here is exactly what
/// History will display:
/// - **Non-swapped slot** → the session-start snapshot values win, preserving
///   the Phase 10 snapshot-immutability invariant (later library edits to the
///   exercise never retroactively change finished History).
/// - **Swapped slot** (`currentExerciseID != originalExerciseID`) → the
///   swapped-in exercise's LIVE values win — the same `resolvedSwappedValue`
///   contract the live Active Workout "Equipment & Setup" section uses — so a
///   finished workout that records the switched exercise's NAME also records
///   the switched exercise's equipment/setup, never the original's. The live
///   value is frozen at snapshot time; subsequent library edits do not mutate
///   it. A nil live value resolves to nil (the field is hidden) rather than
///   falling back to the stale original snapshot. Pure.
func resolvedSnapshotEquipmentSetup(
    isSwapped: Bool,
    liveEquipment: String?,
    liveSetup: String?,
    snapshotEquipment: String?,
    snapshotSetup: String?
) -> (equipment: String?, setupNotes: String?) {
    (
        resolvedSwappedValue(
            isSwapped: isSwapped,
            live: liveEquipment,
            snapshot: snapshotEquipment
        ),
        resolvedSwappedValue(
            isSwapped: isSwapped,
            live: liveSetup,
            snapshot: snapshotSetup
        )
    )
}

// MARK: - Stable rest notification ID

/// Builds a stable rest-timer notification ID of the form
/// `"rest.<workoutID>.<slotID>"`, falling back to
/// `"rest.unknown.<slotID>"` when the workout has not yet been fetched.
///
/// Behavior is byte-identical to the original `ActiveWorkoutView.restNotificationID(slotID:)`:
/// callers pass the current `workout?.id` straight through. The optional is
/// preserved so the "unknown" fallback string still appears whenever the
/// active `Workout` has not yet been hydrated — `RestTimer` keys
/// pending UNUserNotificationCenter requests off this string, so the
/// fallback shape **must not** change.
///
/// `@MainActor`-isolated because the underlying
/// `RestTimer.stableNotificationID(workoutID:slotID:)` is a static on a
/// `@MainActor` final class. Every existing call site is already
/// `@MainActor` (inside `ActiveWorkoutView`, a SwiftUI `View`), so the
/// isolation requirement is invisible at the call sites.
@MainActor
func activeRestNotificationID(workoutID: UUID?, slotID: UUID) -> String {
    guard let wID = workoutID else {
        return "rest.unknown.\(slotID.uuidString)"
    }
    return RestTimer.stableNotificationID(workoutID: wID, slotID: slotID)
}

// MARK: - Lightweight default plan template

/// Builds a lightweight `PlanSetTemplate` for set indices that go beyond
/// the resolved templates array (e.g., a session-plan-driven set count
/// that exceeds the prescription snapshot's template count). Pure — the
/// resulting template carries the synthetic id `"<exercise>-extra<index>"`
/// matching the original inline construction.
func defaultTemplate(for exercise: PlanExercise, at index: Int) -> PlanSetTemplate {
    PlanSetTemplate(
        id: "\(exercise.currentExerciseID.uuidString)-extra\(index)",
        kind: .working,
        targetReps: 0,
        targetWeight: nil,
        restSecondsAfter: nil,
        durationSeconds: nil
    )
}

// MARK: - Swap defaults (Phase 9-B2)

/// Builds the `[PlanSetTemplate]` for the new exercise after a mid-workout
/// `swapExercise(planExercise:with:)`. Pre-9-B2 the swap path read
/// `newEx.defaultTemplates` directly and mapped each row 1:1 — including
/// `targetWeight`, warmup/dropset kinds, and any per-row rest values.
/// 9-A.5 audit accepted the loss of those fields here (no
/// `SlotPrescription` landing for `targetWeight`; warmup/dropset rows on
/// `Exercise.defaultTemplates` are vestigial relative to the new
/// `WarmupScheme` / `TechniquePlan` authoring path). Per 9-B2 audit
/// guidance, this helper produces N uniform `.working` rows whose count
/// and rest are sourced from the slot's existing session plan or
/// snapshot — preserving the slot's structure across the swap — and
/// falls back to `AppSettings` defaults when neither is set.
///
/// Caller does the priority chain inline (`sessionPlan?.X ?? snapshot?.X`)
/// so this helper stays trivial to unit-test with literals — no
/// `SlotPrescription` / `ModelContext` fixture required.
///
/// Field-by-field contract:
///   - `id`: `"<exerciseID>-set<i>"` (matches the pre-9-B2 stable composite key)
///   - `kind`: `.working` always
///   - `targetReps`: `0` — `SessionPlanResolver.plannedRepTarget` reads
///     from sessionPlan/snapshot at row-render time; the template's
///     `targetReps` is only used when both higher tiers are nil
///   - `targetWeight`: `nil` — the 9-A.5 audit's documented loss; the
///     weight column starts blank after a swap and the logged-history
///     auto-suggest path takes over on subsequent sets
///   - `restSecondsAfter`: from `restBetweenSetsHint` (caller composes
///     this from sessionPlan/snapshot) else `AppSettings.defaultRestBetweenSets`
///   - `durationSeconds`: nil for rep-based exercises; for time-based
///     exercises, sourced from `durationMaxHint ?? durationMinHint`,
///     falling back to a hardcoded 60s that matches the
///     `BackfillService.hydrate(_:from:)` 9-A1 fallback
///
/// `setsHint` is the slot's expected working-set count from
/// sessionPlan/snapshot; falls back to `AppSettings.defaultSets`. The
/// final count is clamped to ≥1 so the active-workout UI always
/// renders at least one row.
func makeSwapDefaultTemplates(
    forExerciseID exerciseID: UUID,
    isTimeBased: Bool,
    setsHint: Int?,
    restBetweenSetsHint: Int?,
    durationMinHint: Int?,
    durationMaxHint: Int?
) -> [PlanSetTemplate] {
    let resolvedSets = setsHint.flatMap { $0 > 0 ? $0 : nil }
        ?? AppSettings.defaultSets
    let count = max(1, resolvedSets)

    let rest = restBetweenSetsHint.flatMap { $0 > 0 ? $0 : nil }
        ?? AppSettings.defaultRestBetweenSets

    let duration: Int? = isTimeBased
        ? (durationMaxHint ?? durationMinHint ?? 60)
        : nil

    return (0..<count).map { i in
        PlanSetTemplate(
            id: "\(exerciseID.uuidString)-set\(i)",
            kind: .working,
            targetReps: 0,
            targetWeight: nil,
            restSecondsAfter: rest,
            durationSeconds: duration
        )
    }
}

// MARK: - Last-performance prefill merge (Slice 2)

/// Merges a last-performance suggestion (Slice 1) into the tier-4
/// prescription-default draft tuple for a single set. This is the lowest
/// tier of `ActiveWorkoutView`'s seeding priority chain — it runs only after
/// logged `SetLog`s, persisted `ParentDraftStore` drafts, and the in-process
/// `ActiveWorkoutGuard` cache have all been ruled out, so it never overrides
/// user data.
///
/// Rules (v1):
///   * No suggestion → return the prescription defaults verbatim (existing
///     behavior, byte-for-byte).
///   * Time-based exercise → prefill **duration only**; reps/weight keep the
///     prescription defaults.
///   * Bodyweight equipment → prefill **reps only**; weight keeps the
///     prescription default (which is empty) so user bodyweight is never
///     injected into the load field.
///   * Otherwise (normal weighted) → prefill reps + weight; duration keeps
///     the prescription default.
///
/// Weight is formatted with `Units.formatWeight` — the same canonical
/// formatter used for logged-set rehydration — so prefilled and rehydrated
/// values render identically (no decimal/grouping drift). Pure.
func resolvedDraftDefault(
    suggestion: LastPerformancePrefillService.LastPerformanceSetSuggestion?,
    prescriptionReps: String,
    prescriptionWeight: String,
    prescriptionDuration: String,
    isTimeBased: Bool,
    isBodyweight: Bool
) -> (reps: String, weight: String, duration: String) {
    guard let s = suggestion else {
        return (prescriptionReps, prescriptionWeight, prescriptionDuration)
    }

    if isTimeBased {
        let duration = s.durationSeconds.map(String.init) ?? prescriptionDuration
        return (prescriptionReps, prescriptionWeight, duration)
    }

    let reps = s.reps.map(String.init) ?? prescriptionReps
    let weight: String
    if isBodyweight {
        weight = prescriptionWeight  // stays empty; never inject load
    } else {
        weight = s.weight.map { Units.formatWeight($0) } ?? prescriptionWeight
    }
    return (reps, weight, prescriptionDuration)
}

/// Resolves the displayed reps/weight for one dropset sub-row, overlaying a
/// last-performance drop suggestion (Slice 3) as a **read-time fallback**. The
/// caller must pass live state (typed reps, override flag, override value,
/// dynamic percentage suggestion) so prefill never seeds `@State` and never
/// marks a weight as user-overridden — preserving the "↩ suggest" reset and
/// the reactive percentage-of-parent behavior.
///
/// Priority:
///   * reps:   typed → suggestion → technique fixed reps → "".
///   * weight: overridden (logged / persisted draft / typed) → non-empty
///             percentage suggestion → suggestion (formatted) → "".
///
/// Weight is formatted with `Units.formatWeight` to match logged-set
/// rehydration. Pure.
func resolvedDropDraft(
    suggestion: LastPerformancePrefillService.LastPerformanceDropSuggestion?,
    typedReps: String?,
    isWeightOverridden: Bool,
    overriddenWeight: String?,
    percentageSuggestion: String,
    techniqueFixedReps: Int?
) -> (reps: String, weight: String) {
    let reps: String
    if let typedReps {
        reps = typedReps
    } else if let r = suggestion?.reps {
        reps = String(r)
    } else if let fixed = techniqueFixedReps {
        reps = String(fixed)
    } else {
        reps = ""
    }

    let weight: String
    if isWeightOverridden {
        weight = overriddenWeight ?? ""
    } else if !percentageSuggestion.isEmpty {
        weight = percentageSuggestion
    } else if let w = suggestion?.weight {
        weight = Units.formatWeight(w)
    } else {
        weight = ""
    }

    return (reps, weight)
}

// MARK: - Bottom-panel Next / Finish navigation decision

/// The action the active-workout bottom "Next / Finish" button resolves to for
/// a given position in the plan. Pure decision, split out from
/// `ActiveWorkoutView.next()` so the finish-safety contract is unit-testable:
/// reaching the last step yields `.confirmFinish` (which drives the finish
/// confirmation dialog) and NEVER finishes the workout outright, so repeatedly
/// tapping Next near the end can't skip the confirmation.
enum WorkoutNextAction: Equatable {
    /// Advance within the current block to this new exercise index.
    case advanceExercise(Int)
    /// Advance to the next block, starting at its first exercise.
    case advanceBlock
    /// Last step of the workout — request finish confirmation (never finish
    /// directly).
    case confirmFinish
}

/// Resolves the next navigation action from the current position and the
/// per-block exercise counts. Mirrors the original inline logic in
/// `ActiveWorkoutView.next()` exactly:
///   * not at the last exercise of the block → advance the exercise index;
///   * at the last exercise but not the last block → advance the block;
///   * at the last exercise of the last block → `.confirmFinish`.
/// Pure — no SwiftUI/SwiftData state.
func workoutNextAction(
    currentBlockIndex: Int,
    currentExerciseIndex: Int,
    exerciseCountsPerBlock: [Int]
) -> WorkoutNextAction {
    let exCount: Int = {
        guard currentBlockIndex >= 0,
              currentBlockIndex < exerciseCountsPerBlock.count
        else { return 0 }
        return exerciseCountsPerBlock[currentBlockIndex]
    }()

    if currentExerciseIndex < max(0, exCount - 1) {
        return .advanceExercise(currentExerciseIndex + 1)
    } else if currentBlockIndex < exerciseCountsPerBlock.count - 1 {
        return .advanceBlock
    } else {
        return .confirmFinish
    }
}

// MARK: - Finish-confirmation dialog options + single-fire consumption

/// One finish variant offered by the active workout's finish-confirmation
/// dialog. Each case carries the apply-back flags `finishWorkout` needs; the
/// user-facing label stays in `ActiveWorkoutView` so this file remains
/// SwiftUI-free.
enum FinishDialogOption: CaseIterable, Hashable {
    /// Plain finish — never applies anything back to the routine.
    case finishOnly
    /// Finish and write mid-workout exercise swaps back to the template.
    case applySwaps
    /// Finish and write dirty session-plan edits back to slot prescriptions.
    case applySlotPrescription
    /// Combined option, offered only when both categories are pending.
    case applyAll

    var applySwaps: Bool {
        self == .applySwaps || self == .applyAll
    }
    var applySlotPrescription: Bool {
        self == .applySlotPrescription || self == .applyAll
    }
}

/// The ordered finish options the confirmation dialog offers for the current
/// pending state. `finishOnly` is always first (and Cancel is appended by the
/// dialog itself), preserving the finish-safety contract: reaching the last
/// step only ever *presents* this dialog, and a plain no-apply finish is
/// always available. Exercise.notes / setup notes are intentionally NOT a
/// pending category — both are edited write-through via their sheets, so
/// there is nothing to apply at finish. Pure.
func finishDialogOptions(
    hasSwapsPending: Bool,
    hasSessionPlanPending: Bool
) -> [FinishDialogOption] {
    var options: [FinishDialogOption] = [.finishOnly]
    if hasSwapsPending { options.append(.applySwaps) }
    if hasSessionPlanPending { options.append(.applySlotPrescription) }
    if hasSwapsPending && hasSessionPlanPending { options.append(.applyAll) }
    return options
}

/// Consumes the pending finish request exactly once: returns the stored
/// option and clears the slot; a second consume returns nil.
///
/// This is the single-fire mechanism behind the finish-confirmation
/// reliability fix: the dialog buttons only *record* their option, and the
/// actual `finishWorkout` runs on the next main-actor turn — after the
/// dialog's dismissal transaction has committed, so the navigation pop in
/// `unlockAndDismiss()` no longer races the dialog teardown. Consuming
/// through this helper guarantees a duplicate tap or a duplicate change
/// notification can never run the finish pipeline twice, while leaving the
/// slot re-armable if the view ever survives (the user can simply confirm
/// again). Pure.
func consumePendingFinish(
    _ slot: inout FinishDialogOption?
) -> FinishDialogOption? {
    defer { slot = nil }
    return slot
}

// MARK: - Slot lookup (Phase 6.C1 follow-up: duplicate-Exercise superset)

/// Locate the `(blockIndex, exerciseIndex)` of the plan slot whose
/// `routineSlotID` matches the given UUID. Returns nil if not found.
///
/// **Why this exists**: `PlanExercise.id` is set to `Exercise.id` at
/// plan-build time (see `StartWorkoutFromRoutineView.makePlan`), so it
/// is NOT unique across slots when the same `Exercise` appears in
/// multiple superset members. Lookups that key on `planExercise.id`
/// silently target the first matching slot, which corrupts swap and
/// reset-plan flows for duplicate-Exercise supersets (the original
/// 6.C1 manual-test bug: swapping the second of two same-Exercise
/// superset slots was actually mutating the first, wiping its
/// already-logged set).
///
/// The single source of slot identity is
/// `RoutineExercise.slotID` (mirrored as `PlanExercise.routineSlotID`
/// and `WorkoutItem.routineSlotID`). All in-workout state stores
/// (`sessionPlans`, `loggedByExercise`, `itemsByExerciseID`,
/// `dropsLoggedByExercise`, the drop-draft stores) already key on it;
/// plan-graph lookups must too.
///
/// Pure. No SwiftData access. Safe in any context that has a
/// `WorkoutPlan` in hand.
func findSlotIndex(
    in plan: WorkoutPlan,
    routineSlotID: UUID
) -> (blockIndex: Int, exerciseIndex: Int)? {
    for (bi, block) in plan.blocks.enumerated() {
        if let ei = block.exercises.firstIndex(
            where: { $0.routineSlotID == routineSlotID }
        ) {
            return (bi, ei)
        }
    }
    return nil
}

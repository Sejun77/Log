import Foundation
import SwiftData

/// DTO → model import for Routine Transfer v2 (REMAINING_WORK_PLAN.md §2.14,
/// Slice C). Materializes a `RoutineTransferDocument` into a **brand-new**
/// `Routine` graph — the structural inverse of `RoutineTransfer.export` and a
/// DTO-sourced sibling of `RoutineDuplicator.duplicate`.
///
/// **Additive-only:** it creates a new routine (never overwrites/merges),
/// resolves `Exercise` references by name (linking existing rows, creating
/// missing ones as custom user data), and `ctx.save()`s **once** at the end.
/// Existing `Routine` / `Exercise` rows are never mutated; no `Workout` /
/// history is touched; the imported routine starts with zero history. The
/// schema version is validated **before** anything is inserted, so an
/// unsupported document throws and writes nothing.
extension RoutineTransfer {

    /// Outcome of an import pass — enough for a future preview / result UI.
    struct ImportReport: Equatable {
        /// The DTO's original routine name (pre-collision-rename).
        var sourceRoutineName: String = ""
        /// The name the new routine was actually saved under (may be uniqued).
        var importedRoutineName: String = ""
        /// Distinct names linked to existing `Exercise` rows (first-seen order).
        var matchedExerciseNames: [String] = []
        /// Distinct names newly created as custom `Exercise` rows.
        var createdExerciseNames: [String] = []
        /// Slots skipped because their `exerciseName` was empty (the export-side
        /// sentinel for a deleted/unlinked slot).
        var skippedSlotCount: Int = 0
        /// Materialized block / slot counts (after empty-name slots are skipped
        /// and any resulting empty blocks dropped).
        var blockCount: Int = 0
        var slotCount: Int = 0
    }

    /// Read-only, **pure** projection of what an import *would* do, computed
    /// against the current exercise-name set **without inserting anything** —
    /// drives the import preview UI. Mirrors `import`'s skip / dedupe /
    /// drop-empty-block accounting so the preview counts match the result.
    struct ImportPreview: Equatable {
        var sourceRoutineName: String = ""
        var blockCount: Int = 0
        var slotCount: Int = 0
        /// Distinct names that resolve to an existing exercise (display names
        /// from `existingExerciseNames`, first-seen order).
        var matchedExerciseNames: [String] = []
        /// Distinct names with no match — these would be created on import.
        var createdExerciseNames: [String] = []
        var skippedSlotCount: Int = 0
    }

    /// Materialize `document` into a new `Routine` inserted into `ctx`.
    ///
    /// - `routines`: existing routines (for unique-name + trailing-order).
    /// - `exercises`: existing exercise library (for name resolution + trailing
    ///   `order` on any auto-created rows).
    ///
    /// Throws `RoutineTransferError.unsupportedSchemaVersion` (before any insert)
    /// if the document is newer than this build supports.
    @MainActor
    @discardableResult
    static func `import`(
        _ document: RoutineTransferDocument,
        among routines: [Routine],
        exercises: [Exercise],
        in ctx: ModelContext
    ) throws -> ImportReport {
        // Validate first — nothing is inserted on an unsupported version.
        try document.validateSupportedSchemaVersion()

        var report = ImportReport()
        report.sourceRoutineName = document.routine.name

        // New routine + fresh Default variant (mirrors RoutineDuplicator).
        let name = uniqueRoutineName(
            for: document.routine.name, existingNames: routines.map(\.name))
        report.importedRoutineName = name
        let routine = Routine(name: name, notes: document.routine.notes, blocks: [])
        routine.order = (routines.map(\.order).max() ?? -1) + 1
        ctx.insert(routine)
        let variant = RoutineVariant(name: "Default", order: 0)
        ctx.insert(variant)
        routine.variants.append(variant)

        // Exercise resolution state, shared across the whole batch.
        var existingByKey: [String: Exercise] = [:]
        for ex in exercises { existingByKey[normalize(ex.name)] = ex }
        var createdByKey: [String: Exercise] = [:]
        var nextExerciseOrder = (exercises.map(\.order).max() ?? -1) + 1
        var matchedSeen = Set<String>()
        var createdSeen = Set<String>()

        // Resolve (or create) the Exercise for one **name + hints** reference.
        // Returns nil for an empty name (the caller skips whatever held it).
        // Empty-name references never create a blank junk exercise.
        //
        // Shared by slots and by prepared alternatives (Phase H2): every
        // exercise reference in the document goes through this one function, so
        // an alternative links to an existing row, or stub-creates, or dedupes
        // within the batch on exactly the rules a slot does — and an
        // alternative naming the same exercise as a slot links to that one row
        // rather than a second copy of it.
        func resolveExercise(
            named rawName: String,
            bodyPart: String?,
            equipmentType: String?,
            isTimeBased: Bool?
        ) -> Exercise? {
            let trimmed = rawName.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = normalize(trimmed)

            if let existing = existingByKey[key] {
                if matchedSeen.insert(key).inserted {
                    report.matchedExerciseNames.append(existing.name)
                }
                return existing
            }
            if let created = createdByKey[key] {
                return created  // deduped within this batch
            }

            let ex = Exercise(
                name: trimmed,
                bodyPart: bodyPart,
                equipmentType: equipmentType,
                isCustom: true)
            ex.isTimeBased = isTimeBased ?? false
            ex.order = nextExerciseOrder
            nextExerciseOrder += 1
            ctx.insert(ex)
            createdByKey[key] = ex
            if createdSeen.insert(key).inserted {
                report.createdExerciseNames.append(trimmed)
            }
            return ex
        }

        func resolveExercise(for slot: RoutineTransferSlotDTO) -> Exercise? {
            resolveExercise(
                named: slot.exerciseName,
                bodyPart: slot.exerciseBodyPart,
                equipmentType: slot.exerciseEquipmentType,
                isTimeBased: slot.exerciseIsTimeBased)
        }

        func resolveExercise(
            for alternative: RoutineTransferAlternativeDTO
        ) -> Exercise? {
            resolveExercise(
                named: alternative.exerciseName,
                bodyPart: alternative.exerciseBodyPart,
                equipmentType: alternative.exerciseEquipmentType,
                isTimeBased: alternative.exerciseIsTimeBased)
        }

        // Build blocks in DTO order, assigning clean contiguous block/slot
        // orders. A block whose every slot was skipped is itself dropped.
        var blockIndex = 0
        for blockDTO in document.routine.blocks.sorted(by: { $0.order < $1.order }) {
            var slots: [RoutineExercise] = []
            var slotIndex = 0
            for slotDTO in blockDTO.slots.sorted(by: { $0.order < $1.order }) {
                guard let exercise = resolveExercise(for: slotDTO) else {
                    report.skippedSlotCount += 1
                    continue
                }
                let re = RoutineExercise(
                    exercise: exercise, order: slotIndex, setTemplates: [])
                ctx.insert(re)
                re.templateNotes = slotDTO.templateNotes
                re.setTemplates = slotDTO.setTemplates
                    .sorted { $0.order < $1.order }
                    .map { makeSetTemplate($0, in: ctx) }
                if let p = slotDTO.prescription {
                    re.prescription = makePrescription(
                        p, in: ctx, resolveExercise: resolveExercise)
                }
                slots.append(re)
                slotIndex += 1
            }

            guard !slots.isEmpty else { continue }  // drop emptied block
            let block = RoutineBlock(
                isSuperset: blockDTO.isSuperset,
                order: blockIndex,
                restAfterSeconds: blockDTO.restAfterSeconds,
                exercises: slots)
            block.supersetRoundRestSeconds = blockDTO.supersetRoundRestSeconds
            ctx.insert(block)
            routine.blocks.append(block)
            blockIndex += 1
            report.slotCount += slots.count
        }
        report.blockCount = blockIndex

        try ctx.save()
        return report
    }

    // MARK: - Preview (pure, no insert)

    /// Compute the import preview for `document` against `existingExerciseNames`
    /// (e.g. the live `@Query` exercise names). Pure value-in / value-out — no
    /// `ModelContext`, no mutation — so it is unit-testable and safe to run while
    /// the preview sheet is up.
    static func preview(
        _ document: RoutineTransferDocument,
        existingExerciseNames: [String]
    ) -> ImportPreview {
        var p = ImportPreview()
        p.sourceRoutineName = document.routine.name

        let existingKeys = Set(existingExerciseNames.map { normalize($0) })
        var displayByKey: [String: String] = [:]
        for n in existingExerciseNames where displayByKey[normalize(n)] == nil {
            displayByKey[normalize(n)] = n
        }

        var matchedSeen = Set<String>()
        var createdSeen = Set<String>()

        // One reference (slot or alternative) against the current library.
        // Returns false for a blank name so the caller can account for it.
        @discardableResult
        func account(_ rawName: String) -> Bool {
            let trimmed = rawName.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let key = normalize(trimmed)
            if existingKeys.contains(key) {
                if matchedSeen.insert(key).inserted {
                    p.matchedExerciseNames.append(displayByKey[key] ?? trimmed)
                }
            } else if createdSeen.insert(key).inserted {
                p.createdExerciseNames.append(trimmed)
            }
            return true
        }

        for block in document.routine.blocks {
            var slotsInBlock = 0
            for slot in block.slots {
                guard account(slot.exerciseName) else {
                    p.skippedSlotCount += 1
                    continue
                }
                // Prepared alternatives resolve through the same rule and can
                // therefore create library rows too (Phase H2) — counted here
                // in the same slot-then-alternatives order `import` visits
                // them, so the preview's "will be created" list stays an
                // accurate promise rather than an undercount.
                for alternative in (slot.prescription?.alternatives?.alternatives
                    ?? [])
                    .sorted(by: { $0.order < $1.order })
                {
                    account(alternative.exerciseName)
                }
                slotsInBlock += 1
                p.slotCount += 1
            }
            if slotsInBlock > 0 { p.blockCount += 1 }
        }
        return p
    }

    // MARK: - Unique name

    /// Keep the original routine name when free; otherwise disambiguate with an
    /// `" (imported)"` / `" (imported 2)"` … suffix. An empty/whitespace name
    /// falls back to `"Imported Routine"`. Case-insensitive, trimmed — distinct
    /// from `RoutineDuplicator.copiedName` (which always appends `" copy"`,
    /// wrong semantics for a transfer).
    static func uniqueRoutineName(
        for raw: String, existingNames: [String]
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Imported Routine" : trimmed
        let taken = Set(
            existingNames
                .map { normalize($0) }
                .filter { !$0.isEmpty })

        func isTaken(_ s: String) -> Bool { taken.contains(normalize(s)) }
        if !isTaken(base) { return base }
        if !isTaken("\(base) (imported)") { return "\(base) (imported)" }
        var n = 2
        while isTaken("\(base) (imported \(n))") { n += 1 }
        return "\(base) (imported \(n))"
    }

    // MARK: - Private leaf materialization (DTO → model)

    /// Trim + lowercase — identical key to `ExerciseCSVImporter` /
    /// `ExerciseSeedService` so all import paths agree on exercise identity.
    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func makeSetTemplate(
        _ dto: RoutineTransferSetTemplateDTO, in ctx: ModelContext
    ) -> SetTemplate {
        let t = SetTemplate(
            kind: SetKind(rawValue: dto.kindRaw) ?? .working,
            targetReps: dto.targetReps,
            targetWeight: dto.targetWeight,
            restSecondsAfter: dto.restSecondsAfter)
        t.kindRaw = dto.kindRaw       // preserve raw exactly (unknown-safe)
        t.order = dto.order
        t.durationSeconds = dto.durationSeconds
        ctx.insert(t)
        return t
    }

    private static func makePrescription(
        _ dto: RoutineTransferSlotPrescriptionDTO,
        in ctx: ModelContext,
        resolveExercise: (RoutineTransferAlternativeDTO) -> Exercise?
    ) -> SlotPrescription {
        let p = SlotPrescription(
            sets: dto.sets,
            repMin: dto.repMin,
            repMax: dto.repMax,
            restSecondsBetweenSets: dto.restSecondsBetweenSets,
            restSecondsAfterExercise: dto.restSecondsAfterExercise,
            rir: dto.rir,
            rpe: dto.rpe,
            tempo: dto.tempo,
            effortModeRaw: dto.effortModeRaw,
            rirStart: dto.rirStart,
            rirEnd: dto.rirEnd,
            rpeStart: dto.rpeStart,
            rpeEnd: dto.rpeEnd,
            // Re-normalized rather than trusted, the same rule the distance
            // below follows: `EffortTargetList.encode` refuses a list carrying
            // a value the app's steppers cannot produce, so a hand-edited or
            // corrupt list lands as "no custom targets" and the slot degrades
            // to the progression / single values it still carries.
            customRIRTargetsRaw: EffortTargetList.encode(
                dto.customRIRTargets ?? []),
            customRPETargetsRaw: EffortTargetList.encode(
                dto.customRPETargets ?? []),
            durationMinSeconds: dto.durationMinSeconds,
            durationMaxSeconds: dto.durationMaxSeconds,
            usesDuration: dto.usesDuration,
            // Re-normalized rather than trusted: an imported document is
            // outside data, and a hand-edited or corrupt distance must land as
            // "no target" rather than reaching a formatter. An unparseable unit
            // is dropped with the distance it belonged to, so the two columns
            // cannot disagree.
            targetDistanceMeters: CardioMetrics.normalizedDistanceMeters(
                dto.targetDistanceMeters),
            targetDistanceUnitRaw: CardioMetrics.normalizedDistanceMeters(
                dto.targetDistanceMeters) == nil
                ? nil
                : DistanceUnit.from(raw: dto.targetDistanceUnitRaw)?.rawValue)
        ctx.insert(p)
        // Structured Cardio Slice 12E — same "re-normalized rather than
        // trusted" rule as the distance above. The plan arriving here has
        // already been through the Slice 12B decoder (bad segments dropped,
        // counts clamped, unknown kinds read as `.work`), and
        // `setStructuredCardioPlan` clears the column for a nil or empty plan
        // rather than storing an empty payload — so an absent key, a malformed
        // value, and a plan whose every segment normalized away all land as the
        // one representation of "no structure", exactly as a slot authored
        // without segments would.
        p.setStructuredCardioPlan(dto.cardioSegments?.plan)
        p.techniquePlans = dto.techniquePlans
            .sorted { $0.order < $1.order }
            .map { makeTechnique($0, in: ctx) }
        if let scheme = dto.warmupScheme {
            p.warmupScheme = makeWarmupScheme(scheme, in: ctx)
        }
        p.setSlotAlternatives(
            makeAlternatives(dto.alternatives, resolveExercise: resolveExercise))
        return p
    }

    /// Prepared alternatives (Phase H2): wire form → stored value list.
    ///
    /// Written through `setSlotAlternatives`, never straight to the column, so
    /// the Phase B normalization (stable order, dense `order`, unique ids,
    /// trimmed strings, empty list ⇒ nil column) is the one implementation that
    /// governs authoring, duplication and import alike.
    ///
    /// What changes on the way in, and why:
    ///
    ///  * **`id` is fresh** — the wire format carries none, so a new one is
    ///    minted here. An imported routine must not share authored alternative
    ///    identity with the sender's copy (§12.2), the same rule duplication
    ///    follows.
    ///  * **`exerciseID` is the recipient's** — the reference arrives as a
    ///    name and resolves through the document's single exercise-resolution
    ///    rule, linking to an existing library row or a stub created for it.
    ///    So an alternative always resolves after import; the "exercise
    ///    unavailable" state belongs to a *later* deletion, not to import.
    ///  * **`exerciseName` is the resolved row's name**, not the document's
    ///    spelling of it, so the frozen display fallback agrees with the
    ///    library it now points at.
    ///  * **The target distance is re-normalized**, exactly like the primary
    ///    prescription's above: an imported document is outside data, and a
    ///    hand-edited or corrupt distance must land as "no target" rather than
    ///    reaching a formatter. An unparseable unit is dropped with the
    ///    distance it belonged to, so the two fields cannot disagree.
    ///
    /// Everything else is carried verbatim: order, `isEnabled`, the note, and
    /// the whole prescription down to the warm-up snapshots, technique
    /// snapshots and the Cardio Plan's segment ids — which are **preserved**,
    /// matching what the primary slot's plan already does on this path.
    ///
    /// An alternative whose name cannot be resolved (blank after trimming) is
    /// dropped; its siblings survive. A nil / corrupt / empty list all produce
    /// an empty result, which clears the column.
    private static func makeAlternatives(
        _ dto: RoutineTransferAlternativesDTO?,
        resolveExercise: (RoutineTransferAlternativeDTO) -> Exercise?
    ) -> [SlotAlternative] {
        (dto?.alternatives ?? [])
            .sorted { $0.order < $1.order }
            .enumerated()
            .compactMap { index, alternative in
                guard let exercise = resolveExercise(alternative) else {
                    return nil
                }
                var prescription = alternative.prescription
                let meters = CardioMetrics.normalizedDistanceMeters(
                    prescription.targetDistanceMeters)
                prescription.targetDistanceMeters = meters
                prescription.targetDistanceUnitRaw =
                    meters == nil
                    ? nil
                    : DistanceUnit.from(
                        raw: prescription.targetDistanceUnitRaw)?.rawValue
                return SlotAlternative(
                    id: UUID(),
                    order: index,
                    isEnabled: alternative.isEnabled,
                    exerciseID: exercise.id,
                    exerciseName: exercise.name,
                    note: alternative.note,
                    prescription: prescription)
            }
    }

    private static func makeTechnique(
        _ dto: RoutineTransferTechniquePlanDTO, in ctx: ModelContext
    ) -> TechniquePlan {
        let t = TechniquePlan(
            order: dto.order,
            type: TechniqueType(rawValue: dto.typeRaw) ?? .dropset,
            repMin: dto.repMin,
            repMax: dto.repMax,
            reps: dto.reps,
            durationSeconds: dto.durationSeconds,
            restSeconds: dto.restSeconds,
            rounds: dto.rounds,
            dropPercent: dto.dropPercent,
            dropCount: dto.dropCount,
            partialRangeNote: dto.partialRangeNote,
            partialRangeRaw: dto.partialRangeRaw,
            note: dto.note,
            appliesToRaw: dto.appliesToRaw,
            appliesToSetNumber: dto.appliesToSetNumber,
            appliesToSetIndicesRaw: dto.appliesToSetIndicesRaw ?? "",
            dropsetEffortRaw: dto.dropsetEffortRaw,
            dropsetEffortReps: dto.dropsetEffortReps)
        t.typeRaw = dto.typeRaw       // preserve raw exactly (unknown-safe)
        ctx.insert(t)
        return t
    }

    private static func makeWarmupScheme(
        _ dto: RoutineTransferWarmupSchemeDTO, in ctx: ModelContext
    ) -> WarmupScheme {
        let s = WarmupScheme(name: dto.name)
        ctx.insert(s)
        s.steps = dto.steps
            .sorted { $0.order < $1.order }
            .map { makeWarmupStep($0, in: ctx) }
        return s
    }

    private static func makeWarmupStep(
        _ dto: RoutineTransferWarmupStepDTO, in ctx: ModelContext
    ) -> WarmupStep {
        let w = WarmupStep(
            order: dto.order,
            kind: WarmupStepKind(rawValue: dto.kindRaw) ?? .fixedReps,
            reps: dto.reps,
            percentOfWorking: dto.percentOfWorking,
            restSecondsAfter: dto.restSecondsAfter,
            note: dto.note,
            weight: dto.weight)
        w.kindRaw = dto.kindRaw       // preserve raw exactly (unknown-safe)
        ctx.insert(w)
        return w
    }
}

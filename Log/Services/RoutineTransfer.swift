import Foundation

/// Model → DTO export for Routine Transfer v2 (REMAINING_WORK_PLAN.md §2.14,
/// Slice B). Converts a live `Routine` graph into the pure `Codable`
/// `RoutineTransferDocument` wire format (Slice A).
///
/// **Read-only and ModelContext-free:** it only *reads* model properties, never
/// inserts / mutates / saves. It deliberately does **not** use
/// `RoutineExercise.safeExercise(in:)` (which needs a `ModelContext`); like
/// `RoutineDuplicator.copySlot`, it reads `re.exercise` directly, and a nil
/// reference exports a sentinel (see `slotDTO`). The DTO carries **content
/// only** — no `id` / `slotID` / `PersistentIdentifier`, no `Routine.order`, no
/// `RoutineVariant`, no `Workout` / history. Enum-backed fields are copied as
/// their **raw strings** so unknown future cases survive losslessly.
@MainActor
enum RoutineTransfer {

    /// Export `routine` as a versioned transfer document. `exportedAt` /
    /// `appVersion` are diagnostic-only metadata; the source graph is never
    /// touched.
    static func export(
        _ routine: Routine,
        exportedAt: Date? = Date(),
        appVersion: String? = nil
    ) -> RoutineTransferDocument {
        RoutineTransferDocument(
            schemaVersion: RoutineTransferDocument.currentSchemaVersion,
            exportedAt: exportedAt,
            appVersion: appVersion,
            routine: routineDTO(routine)
        )
    }

    // MARK: - Shared JSON coders

    /// Encoder for routine transfer JSON. `exportedAt` is written as an
    /// **ISO-8601 string** (e.g. `"2026-06-01T00:00:00Z"`), not a numeric
    /// timestamp, so files are human-readable and interoperable. Use this for
    /// every routine-transfer encode (export UI, tests).
    nonisolated static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Decoder paired with `makeJSONEncoder` — parses ISO-8601 `exportedAt`
    /// strings (a plain `JSONDecoder` defaults to numeric timestamps and would
    /// reject the string form). `exportedAt` stays optional, so `null` / a
    /// missing key still decode. Use this for every routine-transfer decode
    /// (import UI, tests).
    nonisolated static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Private mapping (each level sorts children by `order`)

    private static func routineDTO(
        _ r: Routine
    ) -> RoutineTransferRoutineDTO {
        RoutineTransferRoutineDTO(
            name: r.name,
            notes: r.notes,
            blocks: r.blocks.sorted { $0.order < $1.order }.map(blockDTO)
        )
    }

    private static func blockDTO(
        _ b: RoutineBlock
    ) -> RoutineTransferBlockDTO {
        RoutineTransferBlockDTO(
            order: b.order,
            isSuperset: b.isSuperset,
            restAfterSeconds: b.restAfterSeconds,
            supersetRoundRestSeconds: b.supersetRoundRestSeconds,
            slots: b.exercises.sorted { $0.order < $1.order }.map(slotDTO)
        )
    }

    private static func slotDTO(
        _ re: RoutineExercise
    ) -> RoutineTransferSlotDTO {
        // A deleted / unlinked slot (nil `exercise`) exports an **empty**
        // `exerciseName` sentinel and nil hints — truthful (no fabricated name)
        // and a clean signal for import to skip the slot rather than create a
        // junk "Deleted exercise" row in the recipient's library.
        let ex = re.exercise
        return RoutineTransferSlotDTO(
            order: re.order,
            exerciseName: ex?.name ?? "",
            exerciseBodyPart: ex?.bodyPart,
            exerciseEquipmentType: ex?.equipmentType,
            exerciseIsTimeBased: ex?.isTimeBased,
            templateNotes: re.templateNotes,
            setTemplates: re.setTemplates
                .sorted { $0.order < $1.order }
                .map(setTemplateDTO),
            prescription: re.prescription.map(prescriptionDTO)
        )
    }

    private static func setTemplateDTO(
        _ t: SetTemplate
    ) -> RoutineTransferSetTemplateDTO {
        RoutineTransferSetTemplateDTO(
            order: t.order,
            kindRaw: t.kindRaw,
            targetReps: t.targetReps,
            targetWeight: t.targetWeight,
            restSecondsAfter: t.restSecondsAfter,
            durationSeconds: t.durationSeconds
        )
    }

    private static func prescriptionDTO(
        _ p: SlotPrescription
    ) -> RoutineTransferSlotPrescriptionDTO {
        RoutineTransferSlotPrescriptionDTO(
            sets: p.sets,
            repMin: p.repMin,
            repMax: p.repMax,
            restSecondsBetweenSets: p.restSecondsBetweenSets,
            restSecondsAfterExercise: p.restSecondsAfterExercise,
            rir: p.rir,
            rpe: p.rpe,
            tempo: p.tempo,
            durationMinSeconds: p.durationMinSeconds,
            durationMaxSeconds: p.durationMaxSeconds,
            usesDuration: p.usesDuration,
            techniquePlans: p.techniquePlans
                .sorted { $0.order < $1.order }
                .map(techniqueDTO),
            warmupScheme: p.warmupScheme.map(warmupSchemeDTO)
        )
    }

    private static func techniqueDTO(
        _ t: TechniquePlan
    ) -> RoutineTransferTechniquePlanDTO {
        // Raw strings (`typeRaw`, `appliesToRaw`, `appliesToSetIndicesRaw`,
        // `dropsetEffortRaw`) copied verbatim — no enum round-trip.
        RoutineTransferTechniquePlanDTO(
            order: t.order,
            typeRaw: t.typeRaw,
            repMin: t.repMin,
            repMax: t.repMax,
            reps: t.reps,
            durationSeconds: t.durationSeconds,
            restSeconds: t.restSeconds,
            rounds: t.rounds,
            dropPercent: t.dropPercent,
            dropCount: t.dropCount,
            partialRangeNote: t.partialRangeNote,
            note: t.note,
            appliesToRaw: t.appliesToRaw,
            appliesToSetNumber: t.appliesToSetNumber,
            appliesToSetIndicesRaw: t.appliesToSetIndicesRaw,
            dropsetEffortRaw: t.dropsetEffortRaw,
            dropsetEffortReps: t.dropsetEffortReps
        )
    }

    private static func warmupSchemeDTO(
        _ s: WarmupScheme
    ) -> RoutineTransferWarmupSchemeDTO {
        RoutineTransferWarmupSchemeDTO(
            name: s.name,
            steps: s.steps.sorted { $0.order < $1.order }.map(warmupStepDTO)
        )
    }

    private static func warmupStepDTO(
        _ w: WarmupStep
    ) -> RoutineTransferWarmupStepDTO {
        RoutineTransferWarmupStepDTO(
            order: w.order,
            kindRaw: w.kindRaw,
            reps: w.reps,
            percentOfWorking: w.percentOfWorking,
            restSecondsAfter: w.restSecondsAfter,
            note: w.note,
            weight: w.weight
        )
    }
}

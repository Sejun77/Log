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
    ///
    /// - Parameter exercises: the exercise library, used **only** to turn a
    ///   prepared alternative's `exerciseID` into the name + resolution hints
    ///   the wire format references exercises by (Phase H2). A slot's own
    ///   exercise needs no lookup — it is a live relationship — but an
    ///   alternative holds a bare `UUID`, and a `UUID` from the sender's store
    ///   means nothing on the recipient's device. Defaults to empty, in which
    ///   case an alternative falls back to the name frozen on it at authoring
    ///   time and exports no hints. Read-only and still `ModelContext`-free.
    static func export(
        _ routine: Routine,
        exercises: [Exercise] = [],
        exportedAt: Date? = Date(),
        appVersion: String? = nil
    ) -> RoutineTransferDocument {
        var library: [UUID: Exercise] = [:]
        for ex in exercises where library[ex.id] == nil { library[ex.id] = ex }
        return RoutineTransferDocument(
            schemaVersion: RoutineTransferDocument.currentSchemaVersion,
            exportedAt: exportedAt,
            appVersion: appVersion,
            routine: routineDTO(routine, library)
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

    /// Default export filename (without extension) for a routine, e.g.
    /// `"Upper A"` → `"routine-upper-a"`, `"Push A (imported)"` →
    /// `"routine-push-a-imported"`. Lowercases, replaces every non
    /// alphanumeric run with a single `-`, trims edge dashes, and prefixes
    /// `routine-`. An empty / symbol-only name falls back to `"routine"`. Pure
    /// value-in / value-out — testable; the `fileExporter` appends `.json`.
    nonisolated static func exportFilename(for routineName: String) -> String {
        var slug = ""
        var lastWasDash = false
        for ch in routineName.lowercased() {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "routine" : "routine-\(slug)"
    }

    // MARK: - Private mapping (each level sorts children by `order`)

    private static func routineDTO(
        _ r: Routine, _ library: [UUID: Exercise]
    ) -> RoutineTransferRoutineDTO {
        RoutineTransferRoutineDTO(
            name: r.name,
            notes: r.notes,
            blocks: r.blocks
                .sorted { $0.order < $1.order }
                .map { blockDTO($0, library) }
        )
    }

    private static func blockDTO(
        _ b: RoutineBlock, _ library: [UUID: Exercise]
    ) -> RoutineTransferBlockDTO {
        RoutineTransferBlockDTO(
            order: b.order,
            isSuperset: b.isSuperset,
            restAfterSeconds: b.restAfterSeconds,
            supersetRoundRestSeconds: b.supersetRoundRestSeconds,
            slots: b.exercises
                .sorted { $0.order < $1.order }
                .map { slotDTO($0, library) }
        )
    }

    private static func slotDTO(
        _ re: RoutineExercise, _ library: [UUID: Exercise]
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
            prescription: re.prescription.map { prescriptionDTO($0, library) }
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
        _ p: SlotPrescription, _ library: [UUID: Exercise]
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
            effortModeRaw: p.effortModeRaw,
            rirStart: p.rirStart,
            rirEnd: p.rirEnd,
            rpeStart: p.rpeStart,
            rpeEnd: p.rpeEnd,
            // Exported through the decoding accessor rather than the raw
            // column, matching `cardioSegments` / `alternatives` below: a
            // column this build cannot parse exports as "no custom targets"
            // instead of shipping corruption to someone else's device. A slot
            // without them leaves the keys out of the document entirely.
            customRIRTargets: p.customRIRTargets.isEmpty
                ? nil : p.customRIRTargets,
            customRPETargets: p.customRPETargets.isEmpty
                ? nil : p.customRPETargets,
            durationMinSeconds: p.durationMinSeconds,
            durationMaxSeconds: p.durationMaxSeconds,
            usesDuration: p.usesDuration,
            targetDistanceMeters: p.targetDistanceMeters,
            targetDistanceUnitRaw: p.targetDistanceUnitRaw,
            // Structured Cardio Slice 12E. Exported through the decoding
            // accessor rather than as the raw column, which differs
            // deliberately from `RoutineDuplicator`: duplication stays inside
            // one store, where preserving a payload verbatim is the safe
            // choice, but transfer crosses to someone else's device — so a
            // column this build cannot parse exports as **no plan** instead of
            // shipping corruption onward. A slot with no plan leaves the key
            // out of the document entirely.
            cardioSegments: p.structuredCardioPlan.map(
                RoutineTransferCardioSegmentsDTO.init(plan:)),
            techniquePlans: p.techniquePlans
                .sorted { $0.order < $1.order }
                .map(techniqueDTO),
            warmupScheme: p.warmupScheme.map(warmupSchemeDTO),
            // Alternative Exercises Phase H2. Read through the decoding
            // accessor (`slotAlternatives`), not the raw column — the same
            // choice `cardioSegments` makes above and for the same reason: a
            // column this build cannot parse exports as **no alternatives**
            // rather than shipping corruption to someone else's device. A slot
            // with none leaves the key out of the document entirely, so a
            // routine that never used the feature exports byte-identically to
            // before this slice.
            alternatives: alternativesDTO(p.slotAlternatives, library)
        )
    }

    /// Prepared alternatives → wire form, or nil when the slot has none.
    ///
    /// The one non-mechanical step is the exercise reference. An alternative
    /// stores a bare `exerciseID`; the format references exercises by name, so
    /// the id is resolved against `library` for a **live** name plus the three
    /// resolution hints — exactly what the slot's own exercise contributes, and
    /// what lets import stub-create a cardio alternative as time-based rather
    /// than as a blank strength row.
    ///
    /// Two fallbacks, in order:
    ///
    ///  * the id no longer resolves (deleted exercise, or no library passed) ⇒
    ///    fall back to the `exerciseName` frozen on the alternative at
    ///    authoring time, with no hints. The prepared work is still the user's
    ///    and a name is still a usable reference,
    ///  * that name is blank too ⇒ **drop the alternative**. There is nothing
    ///    left to reference and inventing one is out of scope; this mirrors the
    ///    empty-name sentinel a deleted slot exercise exports.
    private static func alternativesDTO(
        _ alternatives: [SlotAlternative], _ library: [UUID: Exercise]
    ) -> RoutineTransferAlternativesDTO? {
        let dtos: [RoutineTransferAlternativeDTO] = alternatives.compactMap {
            alternative in
            let resolved = library[alternative.exerciseID]
            let name = resolved?.name ?? alternative.exerciseName
            guard
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return RoutineTransferAlternativeDTO(
                order: alternative.order,
                isEnabled: alternative.isEnabled,
                exerciseName: name,
                exerciseBodyPart: resolved?.bodyPart,
                exerciseEquipmentType: resolved?.equipmentType,
                exerciseIsTimeBased: resolved?.isTimeBased,
                note: alternative.note,
                prescription: alternative.prescription)
        }
        return dtos.isEmpty ? nil : RoutineTransferAlternativesDTO(
            alternatives: dtos)
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
            partialRangeRaw: t.partialRangeRaw,
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

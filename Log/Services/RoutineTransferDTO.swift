import Foundation

/// JSON wire format for Routine Transfer v2 (REMAINING_WORK_PLAN.md §2.14).
///
/// These are **pure `Codable` value types** — the shareable, version-stamped
/// representation of a single routine *template*. They carry **content only**:
/// no SwiftData `id` / `PersistentIdentifier`, no `Routine.order`, no
/// `RoutineBlock.slotID` / `RoutineExercise.slotID`, and no `Workout` / history.
/// Exercises are referenced **by name** (plus resolution hints), never by ID.
///
/// Enum-backed model fields are encoded as their **raw strings** (`kindRaw`,
/// `typeRaw`, `appliesToRaw`, `dropsetEffortRaw`) so an unknown future case
/// survives a transfer losslessly — the same raw-copy rule `RoutineDuplicator`
/// uses. Slice A defines the format + its round-trip contract only; the
/// model↔DTO mapping (export) and DTO→model materialization (import) land in
/// later slices.

// MARK: - Errors

/// Thrown when a decoded document cannot be safely consumed by this build.
enum RoutineTransferError: Error, Equatable {
    /// The document's `schemaVersion` is newer than this build understands.
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

// MARK: - Envelope

/// Top-level transfer document. v1 carries exactly **one** routine; the
/// envelope is kept distinct from `RoutineTransferRoutineDTO` so a future
/// version can add a `routines: [...]` array (export-all) without breaking the
/// single-routine readers.
struct RoutineTransferDocument: Codable, Equatable {
    /// The only schema version this build writes / fully supports.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportedAt: Date?
    var appVersion: String?
    var routine: RoutineTransferRoutineDTO

    init(
        schemaVersion: Int = RoutineTransferDocument.currentSchemaVersion,
        exportedAt: Date? = nil,
        appVersion: String? = nil,
        routine: RoutineTransferRoutineDTO
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.routine = routine
    }

    /// Reject a document exported by a newer app whose `schemaVersion` exceeds
    /// what this build understands. An older-or-equal version is accepted (a
    /// future up-migration shim can widen this); a forbidden newer version
    /// throws so the import UI can surface a friendly "exported from a newer
    /// version" message before anything is written.
    func validateSupportedSchemaVersion() throws {
        if schemaVersion > RoutineTransferDocument.currentSchemaVersion {
            throw RoutineTransferError.unsupportedSchemaVersion(
                found: schemaVersion,
                supported: RoutineTransferDocument.currentSchemaVersion
            )
        }
    }
}

// MARK: - Routine

struct RoutineTransferRoutineDTO: Codable, Equatable {
    var name: String
    var notes: String?
    var blocks: [RoutineTransferBlockDTO]
}

// MARK: - Block

struct RoutineTransferBlockDTO: Codable, Equatable {
    var order: Int
    var isSuperset: Bool
    var restAfterSeconds: Int?
    var supersetRoundRestSeconds: Int?
    var slots: [RoutineTransferSlotDTO]
}

// MARK: - Slot (RoutineExercise)

struct RoutineTransferSlotDTO: Codable, Equatable {
    var order: Int
    /// Definition-level exercise reference: resolved by trimmed/case-insensitive
    /// name on import. The hints below let import stub-create a missing exercise
    /// as custom user data without a lossy guess.
    var exerciseName: String
    var exerciseBodyPart: String?
    var exerciseEquipmentType: String?
    var exerciseIsTimeBased: Bool?
    var templateNotes: String?
    var setTemplates: [RoutineTransferSetTemplateDTO]
    var prescription: RoutineTransferSlotPrescriptionDTO?
}

// MARK: - SetTemplate

struct RoutineTransferSetTemplateDTO: Codable, Equatable {
    var order: Int
    var kindRaw: String
    var targetReps: Int
    var targetWeight: Double?
    var restSecondsAfter: Int?
    var durationSeconds: Int?
}

// MARK: - SlotPrescription

struct RoutineTransferSlotPrescriptionDTO: Codable, Equatable {
    var sets: Int?
    var repMin: Int?
    var repMax: Int?
    var restSecondsBetweenSets: Int?
    var restSecondsAfterExercise: Int?
    var rir: Double?
    var rpe: Double?
    var tempo: String?
    // Effort target modes (Slice B). All optional with nil defaults → old
    // documents that predate these keys decode them as nil (synthesized
    // `decodeIfPresent`), a nil `effortModeRaw` derives the legacy
    // `.single`/`.none` mode on import, and existing memberwise-init call
    // sites that don't yet pass them keep compiling.
    var effortModeRaw: String? = nil
    var rirStart: Double? = nil
    var rirEnd: Double? = nil
    var rpeStart: Double? = nil
    var rpeEnd: Double? = nil
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool
    var techniquePlans: [RoutineTransferTechniquePlanDTO]
    var warmupScheme: RoutineTransferWarmupSchemeDTO?
}

// MARK: - TechniquePlan

struct RoutineTransferTechniquePlanDTO: Codable, Equatable {
    var order: Int
    var typeRaw: String
    var repMin: Int?
    var repMax: Int?
    var reps: Int?
    var durationSeconds: Int?
    var restSeconds: Int?
    var rounds: Int?
    var dropPercent: Double?
    var dropCount: Int?
    var partialRangeNote: String?
    /// Preset partial-range raw (`PartialRange.rawValue`); nil = Not set.
    /// Optional/additive — old documents lacking this key decode as nil
    /// (synthesized `decodeIfPresent`); `schemaVersion` is unchanged.
    var partialRangeRaw: String?
    var note: String?
    var appliesToRaw: String
    var appliesToSetNumber: Int?
    var appliesToSetIndicesRaw: String?
    var dropsetEffortRaw: String?
    var dropsetEffortReps: Int?
}

// MARK: - WarmupScheme

struct RoutineTransferWarmupSchemeDTO: Codable, Equatable {
    var name: String
    var steps: [RoutineTransferWarmupStepDTO]
}

// MARK: - WarmupStep

struct RoutineTransferWarmupStepDTO: Codable, Equatable {
    var order: Int
    var kindRaw: String
    var reps: Int?
    var percentOfWorking: Double?
    var restSecondsAfter: Int?
    var note: String?
    var weight: Double?
}

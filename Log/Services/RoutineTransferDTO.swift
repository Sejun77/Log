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
    /// Custom per-set effort targets (`.custom` effort mode), one list per
    /// metric. Optional with nil defaults for exactly the reasons the effort
    /// keys above record: a document exported before these keys existed decodes
    /// them as nil via synthesized `decodeIfPresent`, the synthesized encoder
    /// omits them when nil (so a routine without custom targets exports
    /// byte-identically to before), and the memberwise-init call sites that do
    /// not pass them keep compiling.
    ///
    /// **No `schemaVersion` bump** — nothing about an older document became
    /// invalid, and `validateSupportedSchemaVersion` *rejects* a document whose
    /// version exceeds the reader's, so bumping would make every older build
    /// refuse a routine wholesale rather than import it minus its custom
    /// targets. Same reasoning Slices 5, 9, 12E and Phase H2 recorded.
    ///
    /// Carried as arrays rather than the model's comma-separated column: the
    /// transfer format is human-readable JSON that people inspect and
    /// hand-edit, and `[2, 1.5, 1, 0]` is the shape that audience expects.
    /// Re-normalized on import through `EffortTargetList`, so a hand-edited
    /// list with an impossible value lands as "no custom targets" rather than
    /// reaching a formatter.
    var customRIRTargets: [Double]? = nil
    var customRPETargets: [Double]? = nil
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool
    // Cardio target distance (Slice 5). Optional with nil defaults, exactly
    // like the effort keys above: a document exported before these keys
    // existed decodes them as nil via synthesized `decodeIfPresent`, and the
    // memberwise-init call sites that do not pass them keep compiling. No
    // `schemaVersion` bump — nothing about an older document became invalid.
    var targetDistanceMeters: Double? = nil
    var targetDistanceUnitRaw: String? = nil
    /// Structured cardio segment plan (Slice 12E). Optional with a nil default,
    /// exactly like the two keys above: a document exported before this key
    /// existed decodes it as nil via synthesized `decodeIfPresent`, the
    /// synthesized encoder omits the key entirely when nil (so a routine
    /// without segments exports byte-identically to before), and the
    /// memberwise-init call sites that do not pass it keep compiling.
    ///
    /// **No `schemaVersion` bump** — the design says so explicitly, and the
    /// reason is `validateSupportedSchemaVersion`: it *rejects* a document
    /// whose version exceeds the reader's, so bumping would make every older
    /// build refuse a routine wholesale rather than import it minus its
    /// segments. Nothing about an older document became invalid, which is the
    /// same reasoning Slices 5 and 9 recorded when they added their fields.
    ///
    /// Carried as a nested structure rather than the stored `Data` blob: the
    /// transfer format is human-readable JSON that people inspect and
    /// hand-edit, and a base64 column inside it would be opaque to exactly the
    /// audience the format exists for.
    var cardioSegments: RoutineTransferCardioSegmentsDTO? = nil
    var techniquePlans: [RoutineTransferTechniquePlanDTO]
    var warmupScheme: RoutineTransferWarmupSchemeDTO?
    /// Prepared alternative exercises for this slot (Alternative Exercises
    /// Phase H2, design §12.2). Optional with a nil default, exactly like
    /// `cardioSegments` above: a document exported before this key existed
    /// decodes it as nil via synthesized `decodeIfPresent`, the synthesized
    /// encoder omits the key entirely when nil (so a slot with no alternatives
    /// exports byte-identically to before), and the memberwise-init call sites
    /// that do not pass it keep compiling.
    ///
    /// **No `schemaVersion` bump**, for the reason spelled out on
    /// `cardioSegments`: `validateSupportedSchemaVersion` *rejects* a document
    /// whose version exceeds the reader's, so bumping would make every older
    /// build refuse a routine wholesale rather than import it minus its
    /// alternatives. Nothing about an older document became invalid — the same
    /// reasoning Slices 5, 9 and 12E recorded.
    var alternatives: RoutineTransferAlternativesDTO? = nil
}

// MARK: - Prepared alternatives

/// Transparent wrapper around the slot's `[RoutineTransferAlternativeDTO]`.
///
/// Exists for the same reason `RoutineTransferCardioSegmentsDTO` does, one
/// level deeper. A plain `[RoutineTransferAlternativeDTO]?` field inside a
/// synthesized `Codable` struct fails the **whole document** on two inputs this
/// format has to survive: a value of the wrong JSON shape (a string, a
/// hand-edited mess) and a single malformed element. Both are absorbed here —
///
///  * a wrong-shaped value decodes as **no alternatives**,
///  * a malformed element is **dropped and its siblings survive**,
///
/// which is exactly the tolerance `SlotAlternativesPayload` already gives the
/// stored column (§5.3 / §8.7), so a payload behaves the same in a routine, in
/// a transfer document, and in a frozen session plan. Losing prepared
/// alternatives is a bad outcome; losing the recipient's whole routine over one
/// bad key is a worse one.
struct RoutineTransferAlternativesDTO: Codable, Equatable {

    var alternatives: [RoutineTransferAlternativeDTO]

    init(alternatives: [RoutineTransferAlternativeDTO]) {
        self.alternatives = alternatives
    }

    init(from decoder: Decoder) throws {
        let decoded = (try? [LenientAlternative](from: decoder)) ?? []
        alternatives = decoded.compactMap(\.alternative)
    }

    /// Encodes the list **in place** (no wrapper object), so the document reads
    /// as `"alternatives": [ { ... } ]` rather than carrying an implementation
    /// detail of this type into the wire format.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(alternatives)
    }

    /// Turns a failed element decode into a dropped element. Each array element
    /// gets its own decoder, so one failure cannot disturb the others — the
    /// same shape `SlotAlternativesPayload.LenientAlternative` uses.
    private struct LenientAlternative: Decodable {
        let alternative: RoutineTransferAlternativeDTO?
        init(from decoder: Decoder) throws {
            alternative = try? RoutineTransferAlternativeDTO(from: decoder)
        }
    }
}

/// One prepared alternative, in transfer form.
///
/// Two deliberate differences from the stored `SlotAlternative`:
///
///  1. **No `id`.** The transfer format carries content only — no `id` /
///     `slotID` / `PersistentIdentifier` anywhere else either — and §12.2
///     requires imported alternatives to get fresh ids. Omitting the field
///     makes that structural rather than a rule import has to remember.
///  2. **No `exerciseID`.** A `UUID` pointing at the *sender's* exercise row is
///     meaningless on the recipient's device. The reference travels as a name
///     plus the same three resolution hints `RoutineTransferSlotDTO` carries,
///     so import resolves or stub-creates through one rule for every exercise
///     reference in the document. This is where the payload's `exerciseName`
///     earns its place (§12.2).
///
/// The prescription is `AlternativePrescriptionPayload` itself rather than a
/// mirrored DTO: it is already a pure `Codable` value type with a tolerant
/// decoder, it nests `CardioSegmentPlan` as readable structure (not a blob),
/// and reusing it means a field added to an alternative can never be forgotten
/// here.
struct RoutineTransferAlternativeDTO: Codable, Equatable {
    var order: Int = 0
    var isEnabled: Bool = true
    /// Definition-level exercise reference, resolved by trimmed/case-insensitive
    /// name on import — identical rule to `RoutineTransferSlotDTO`.
    var exerciseName: String
    var exerciseBodyPart: String? = nil
    var exerciseEquipmentType: String? = nil
    var exerciseIsTimeBased: Bool? = nil
    /// "Why/when to use this", distinct from the prescription's slot note.
    var note: String? = nil
    var prescription: AlternativePrescriptionPayload = .init()
}

extension RoutineTransferAlternativeDTO {

    private enum CodingKeys: String, CodingKey {
        case order, isEnabled, exerciseName, exerciseBodyPart
        case exerciseEquipmentType, exerciseIsTimeBased, note, prescription
    }

    /// Requires a **non-blank `exerciseName`** and a readable `prescription`;
    /// everything else falls back to a default.
    ///
    /// Mirrors `SlotAlternative.init(from:)`, with the name standing in for the
    /// id it replaces: an alternative with no exercise to switch to is not an
    /// alternative, and §"do not invent exercise references" forbids the
    /// obvious repair. Both cases throw, and the wrapper above drops the
    /// element, so a malformed alternative costs itself and never its siblings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let name = try? c.decode(String.self, forKey: .exerciseName),
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SlotAlternativeDecodingError.missingExerciseReference }

        let prescription = try c.decode(
            AlternativePrescriptionPayload.self, forKey: .prescription)

        self.init(
            order: (try? c.decodeIfPresent(Int.self, forKey: .order)) ?? 0,
            isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled))
                ?? true,
            exerciseName: name,
            exerciseBodyPart: try? c.decodeIfPresent(
                String.self, forKey: .exerciseBodyPart),
            exerciseEquipmentType: try? c.decodeIfPresent(
                String.self, forKey: .exerciseEquipmentType),
            exerciseIsTimeBased: try? c.decodeIfPresent(
                Bool.self, forKey: .exerciseIsTimeBased),
            note: try? c.decodeIfPresent(String.self, forKey: .note),
            prescription: prescription
        )
    }

    /// The optional hints and the note are omitted when absent; `order`,
    /// `isEnabled`, `exerciseName` and `prescription` are always written,
    /// because each is a positive statement about the alternative.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order, forKey: .order)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(exerciseName, forKey: .exerciseName)
        try c.encodeIfPresent(exerciseBodyPart, forKey: .exerciseBodyPart)
        try c.encodeIfPresent(
            exerciseEquipmentType, forKey: .exerciseEquipmentType)
        try c.encodeIfPresent(
            exerciseIsTimeBased, forKey: .exerciseIsTimeBased)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(prescription, forKey: .prescription)
    }
}

// MARK: - Structured cardio segments

/// Transparent wrapper around `CardioSegmentPlan` for the transfer document.
///
/// The plan is already `Codable`, and its own decoder is the tolerant Slice 12B
/// one — unknown segment kinds read as `.work`, an unknown HR zone drops that
/// field, out-of-range counts clamp, a segment with no target is dropped, and
/// the group list is truncated to the expansion budget. So the payload survives
/// a round trip losslessly (**including each segment's `id` and the group's
/// `repeatCount`**, which is what lets a repeat authored by a future build
/// transfer today) and degrades sanely rather than failing.
///
/// The wrapper exists for one case the plan's own decoder cannot cover: a value
/// of the **wrong JSON shape** entirely — a string, a number, a hand-edited
/// mess. `CardioSegmentPlan.init(from:)` would throw there, and because this is
/// a field inside a synthesized `Codable` struct, that throw would fail the
/// decode of the whole document and the recipient would lose the entire routine
/// over one bad key. Absorbing it here means a malformed plan imports as **no
/// plan**, and everything else about the routine arrives intact — the failure
/// mode the rest of this format already chooses (unknown enum raws are
/// preserved, not rejected).
struct RoutineTransferCardioSegmentsDTO: Codable, Equatable {

    /// nil when the incoming value could not be read as a plan at all.
    var plan: CardioSegmentPlan?

    init(plan: CardioSegmentPlan?) {
        self.plan = plan
    }

    init(from decoder: Decoder) throws {
        plan = try? CardioSegmentPlan(from: decoder)
    }

    /// Encodes the plan **in place** (no wrapper object), so the document reads
    /// as `"cardioSegments": { "version": 1, "groups": [...] }` rather than
    /// carrying an implementation detail of this type into the wire format.
    func encode(to encoder: Encoder) throws {
        guard let plan else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
            return
        }
        try plan.encode(to: encoder)
    }
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

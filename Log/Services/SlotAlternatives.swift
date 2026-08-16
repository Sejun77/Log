import Foundation

// ======================================================
// MARK: - Alternative Exercises — pure value types (Phase B)
// ======================================================
//
// `docs/ALTERNATIVE_EXERCISES_DESIGN.md` §5.2. A prepared alternative is a
// replacement exercise plus the prescription the user authored *for that
// exercise*, attached to a routine slot.
//
// **Value types only.** Nothing here imports SwiftData or SwiftUI, resolves an
// `Exercise`, reads `AppSettings`, or applies a compatibility rule — the
// storage column (`SlotPrescription.alternativesData`, Phase C), the editor
// (Phase D), the session freeze (Phase E) and the switch adapter (Phase F) all
// come later and all consume exactly what this file defines.
//
// The design's reasoning for an encoded payload over a `@Model` graph is
// §5.1; the short version is that alternatives are never queried
// independently, and `PrescriptionSnapshotPayload` / `WarmupStepSnapshot` /
// `TechniquePlanSnapshot` / `CardioSegmentPlan` already are the value shapes a
// `@Model` design would have to convert *to* at plan-build time. So the
// payload stores the destination format directly, and reuses those types
// rather than re-declaring them:
//
//   * `WarmupStepSnapshot`   — reused verbatim
//   * `TechniquePlanSnapshot`— reused verbatim
//   * `CardioSegmentPlan`    — reused verbatim, nested as a structure (not a
//                              nested base64 blob), per §5.2
//   * `PrescriptionSnapshotPayload` — **mirrored, not embedded**. It is not
//     `Codable`, it carries `equipment` / `setupNotes` (definition-level data
//     that resolves from the `Exercise` and must not be frozen into an
//     authoring payload), and it holds structured cardio as an opaque `Data`
//     blob. `AlternativePrescriptionPayload` below carries the same field
//     names for every field they share, so the Phase F bridge is mechanical.
//
// Tolerance rules, all from §5.3 / §8.7 and all mirroring
// `SlotPrescription+StructuredCardio.swift`:
//
//   * nil payload, empty list and unreadable payload all read as `[]` — one
//     representation of "no alternatives", so no view checks three states,
//   * one malformed alternative inside a valid payload is dropped; its
//     siblings survive,
//   * unknown keys and unknown `version` values decode what they can rather
//     than failing the payload,
//   * an empty list clears the column rather than storing an empty payload.

// ======================================================
// MARK: - Prescription payload
// ======================================================

/// The prescription an alternative carries — everything the user authored for
/// the replacement exercise.
///
/// Field-for-field a mirror of `PrescriptionSnapshotPayload` (same names, same
/// optionality) plus the four things a `ResetSource` cannot express today:
/// warm-up steps, techniques, a structured cardio plan, and the slot note.
/// Those four are precisely the detail §1 identifies as impossible to rebuild
/// mid-workout, and therefore the reason this feature exists.
///
/// Every field defaults, so the synthesized memberwise initializer lets a
/// caller state only what it means to set (`Codable` is implemented in an
/// extension for exactly this reason — declaring it in the body would suppress
/// that initializer).
struct AlternativePrescriptionPayload: Codable, Equatable {
    var sets: Int? = nil
    var repMin: Int? = nil
    var repMax: Int? = nil
    var restSecondsBetweenSets: Int? = nil
    var restSecondsAfterExercise: Int? = nil
    var rir: Double? = nil
    var rpe: Double? = nil
    var tempo: String? = nil
    /// Effort target mode fields, matching `PrescriptionSnapshotPayload` —
    /// `EffortMode` raw plus the progression endpoints. Carried verbatim; this
    /// phase asserts no relationship between them and `rir` / `rpe`.
    var effortModeRaw: String? = nil
    var rirStart: Double? = nil
    var rirEnd: Double? = nil
    var rpeStart: Double? = nil
    var rpeEnd: Double? = nil
    /// Custom per-set effort targets for the `.custom` effort mode, one list
    /// per metric and kept mirrored (`10 - x`) exactly as the slot's own
    /// columns are. Carried as decoded arrays rather than the model's
    /// comma-separated string: this payload is JSON that people read and
    /// hand-edit in a transfer document, and `[2, 1.5, 1, 0]` is the shape that
    /// audience expects — the same choice `cardioSegments` makes one field
    /// down. Carried verbatim; this type asserts no relationship between them
    /// and `rir` / `rpe`.
    var customRIRTargets: [Double]? = nil
    var customRPETargets: [Double]? = nil
    var durationMinSeconds: Int? = nil
    var durationMaxSeconds: Int? = nil
    var usesDuration: Bool = false
    var targetDistanceMeters: Double? = nil
    var targetDistanceUnitRaw: String? = nil
    var warmupSteps: [WarmupStepSnapshot] = []
    var techniques: [TechniquePlanSnapshot] = []
    /// Nested as a structure rather than an encoded blob, matching
    /// `RoutineTransferCardioSegmentsDTO`'s reasoning: a blob inside a payload
    /// is opaque to inspection and doubles the decode surface.
    ///
    /// An empty plan normalizes to nil — the same "one representation of no
    /// structure" rule `SlotPrescription.structuredCardioPlan` uses.
    var cardioSegments: CardioSegmentPlan? = nil
    /// The alternative's own slot note. Distinct from `SlotAlternative.note`,
    /// which explains *why/when* to use the alternative; this one is the
    /// prescription note that lands on the session plan.
    var slotNotes: String? = nil

    /// Blank strings collapse to nil and an empty cardio plan collapses to nil.
    ///
    /// Deliberately the *only* normalization applied to a prescription:
    /// clamping durations, suppressing tempo on a duration target, or dropping
    /// a distance on a strength exercise are compatibility rules that belong to
    /// the adapter (Phase F), and applying them here would silently rewrite
    /// what the user authored in the editor.
    /// A custom target list, or nil when it is absent, empty, or unusable.
    /// Round-tripped through `EffortTargetList` so a payload and a slot column
    /// accept exactly the same values.
    private static func normalizedTargets(_ values: [Double]?) -> [Double]? {
        guard let values, EffortTargetList.encode(values) != nil else {
            return nil
        }
        return values
    }

    func normalized() -> AlternativePrescriptionPayload {
        var copy = self
        copy.tempo = SlotAlternatives.trimmedOrNil(tempo)
        copy.slotNotes = SlotAlternatives.trimmedOrNil(slotNotes)
        if let plan = copy.cardioSegments, plan.isEmpty { copy.cardioSegments = nil }
        // An empty custom list is "no custom targets", which is what a nil
        // field already means — one representation, so a payload authored
        // without them encodes exactly as it did before this field existed.
        // A list carrying an unusable value is refused whole by
        // `EffortTargetList`, and re-encoding through it here is what stops a
        // hand-edited document from smuggling one onto a session plan.
        copy.customRIRTargets = Self.normalizedTargets(customRIRTargets)
        copy.customRPETargets = Self.normalizedTargets(customRPETargets)
        return copy
    }
}

extension AlternativePrescriptionPayload {

    private enum CodingKeys: String, CodingKey {
        case sets, repMin, repMax, restSecondsBetweenSets
        case restSecondsAfterExercise, rir, rpe, tempo
        case effortModeRaw, rirStart, rirEnd, rpeStart, rpeEnd
        case customRIRTargets, customRPETargets
        case durationMinSeconds, durationMaxSeconds, usesDuration
        case targetDistanceMeters, targetDistanceUnitRaw
        case warmupSteps, techniques, cardioSegments, slotNotes
    }

    /// Every field is optional at the wire level: a payload written by an older
    /// or newer build decodes with whatever it has, and unknown keys are
    /// ignored. A warm-up step or technique that cannot be decoded is dropped
    /// individually rather than failing the prescription — same "decoding
    /// repairs" split `CardioSegmentGroup` makes.
    ///
    /// This decoder throws only when the value is not an object at all, which
    /// is what lets `SlotAlternative` treat an unreadable prescription as a
    /// malformed alternative and drop it whole.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sets: try? c.decodeIfPresent(Int.self, forKey: .sets),
            repMin: try? c.decodeIfPresent(Int.self, forKey: .repMin),
            repMax: try? c.decodeIfPresent(Int.self, forKey: .repMax),
            restSecondsBetweenSets: try? c.decodeIfPresent(
                Int.self, forKey: .restSecondsBetweenSets),
            restSecondsAfterExercise: try? c.decodeIfPresent(
                Int.self, forKey: .restSecondsAfterExercise),
            rir: try? c.decodeIfPresent(Double.self, forKey: .rir),
            rpe: try? c.decodeIfPresent(Double.self, forKey: .rpe),
            tempo: try? c.decodeIfPresent(String.self, forKey: .tempo),
            effortModeRaw: try? c.decodeIfPresent(
                String.self, forKey: .effortModeRaw),
            rirStart: try? c.decodeIfPresent(Double.self, forKey: .rirStart),
            rirEnd: try? c.decodeIfPresent(Double.self, forKey: .rirEnd),
            rpeStart: try? c.decodeIfPresent(Double.self, forKey: .rpeStart),
            rpeEnd: try? c.decodeIfPresent(Double.self, forKey: .rpeEnd),
            customRIRTargets: try? c.decodeIfPresent(
                [Double].self, forKey: .customRIRTargets),
            customRPETargets: try? c.decodeIfPresent(
                [Double].self, forKey: .customRPETargets),
            durationMinSeconds: try? c.decodeIfPresent(
                Int.self, forKey: .durationMinSeconds),
            durationMaxSeconds: try? c.decodeIfPresent(
                Int.self, forKey: .durationMaxSeconds),
            usesDuration: (try? c.decodeIfPresent(
                Bool.self, forKey: .usesDuration)) ?? false,
            targetDistanceMeters: try? c.decodeIfPresent(
                Double.self, forKey: .targetDistanceMeters),
            targetDistanceUnitRaw: try? c.decodeIfPresent(
                String.self, forKey: .targetDistanceUnitRaw),
            warmupSteps: SlotAlternatives.lenientArray(
                WarmupStepSnapshot.self, in: c, forKey: .warmupSteps),
            techniques: SlotAlternatives.lenientArray(
                TechniquePlanSnapshot.self, in: c, forKey: .techniques),
            cardioSegments: try? c.decodeIfPresent(
                CardioSegmentPlan.self, forKey: .cardioSegments),
            slotNotes: try? c.decodeIfPresent(String.self, forKey: .slotNotes)
        )
        self = normalized()
    }

    /// Absent values are **omitted**, not written as null, and empty arrays are
    /// omitted too: this is a stored column, and the overwhelmingly common
    /// alternative (a few sets and a rep range) should not carry twenty nulls
    /// and two empty arrays.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sets, forKey: .sets)
        try c.encodeIfPresent(repMin, forKey: .repMin)
        try c.encodeIfPresent(repMax, forKey: .repMax)
        try c.encodeIfPresent(
            restSecondsBetweenSets, forKey: .restSecondsBetweenSets)
        try c.encodeIfPresent(
            restSecondsAfterExercise, forKey: .restSecondsAfterExercise)
        try c.encodeIfPresent(rir, forKey: .rir)
        try c.encodeIfPresent(rpe, forKey: .rpe)
        try c.encodeIfPresent(tempo, forKey: .tempo)
        try c.encodeIfPresent(effortModeRaw, forKey: .effortModeRaw)
        try c.encodeIfPresent(rirStart, forKey: .rirStart)
        try c.encodeIfPresent(rirEnd, forKey: .rirEnd)
        try c.encodeIfPresent(rpeStart, forKey: .rpeStart)
        try c.encodeIfPresent(rpeEnd, forKey: .rpeEnd)
        try c.encodeIfPresent(customRIRTargets, forKey: .customRIRTargets)
        try c.encodeIfPresent(customRPETargets, forKey: .customRPETargets)
        try c.encodeIfPresent(durationMinSeconds, forKey: .durationMinSeconds)
        try c.encodeIfPresent(durationMaxSeconds, forKey: .durationMaxSeconds)
        // Written unconditionally: `false` is a positive assertion that the
        // alternative is rep-based, not an absent value.
        try c.encode(usesDuration, forKey: .usesDuration)
        try c.encodeIfPresent(
            targetDistanceMeters, forKey: .targetDistanceMeters)
        try c.encodeIfPresent(
            targetDistanceUnitRaw, forKey: .targetDistanceUnitRaw)
        if !warmupSteps.isEmpty {
            try c.encode(warmupSteps, forKey: .warmupSteps)
        }
        if !techniques.isEmpty {
            try c.encode(techniques, forKey: .techniques)
        }
        if let cardioSegments, !cardioSegments.isEmpty {
            try c.encode(cardioSegments, forKey: .cardioSegments)
        }
        try c.encodeIfPresent(slotNotes, forKey: .slotNotes)
    }
}

// ======================================================
// MARK: - One alternative
// ======================================================

/// One prepared alternative for a routine slot (§4.3).
///
/// `Identifiable` on a stable stored `id` so the editor list, the switch sheet
/// and a future per-alternative statistic all address the same thing across a
/// reorder — the reason `CardioSegment` carries an id too.
struct SlotAlternative: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// User-controlled position, dense and 0-based after normalization.
    var order: Int = 0
    /// `false` hides the alternative from the switch sheet without deleting the
    /// prepared work; the routine editor still shows it (§8.7).
    var isEnabled: Bool = true
    /// Reference to `Exercise.id`, resolved at read time. The one field an
    /// alternative cannot be missing — see the decoder.
    var exerciseID: UUID
    /// Display fallback for when the reference no longer resolves, so a deleted
    /// exercise renders as a named, disabled row rather than vanishing.
    var exerciseName: String = ""
    /// Optional "why/when to use this", distinct from the prescription's slot
    /// note.
    var note: String? = nil
    var prescription: AlternativePrescriptionPayload = .init()

    /// Trims the display name and the note (blank → nil) and normalizes the
    /// prescription. The exercise reference is never invented or altered.
    func normalized() -> SlotAlternative {
        var copy = self
        copy.exerciseName =
            exerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.note = SlotAlternatives.trimmedOrNil(note)
        copy.prescription = prescription.normalized()
        return copy
    }
}

extension SlotAlternative {

    private enum CodingKeys: String, CodingKey {
        case id, order, isEnabled, exerciseID, exerciseName, note, prescription
    }

    /// Requires an `exerciseID` and a readable `prescription`; everything else
    /// falls back to a default.
    ///
    /// Those two are required because the alternatives that would result
    /// without them are actively wrong rather than merely incomplete: no
    /// exercise reference is not an alternative at all (and §"do not invent
    /// exercise references" forbids the obvious repair), and an unreadable
    /// prescription would apply an **empty plan** on switch — worse than not
    /// offering the row. Both cases throw, and
    /// `SlotAlternativesPayload`'s decoder drops the element, so a malformed
    /// alternative costs itself and never its siblings (§8.7).
    ///
    /// A blank `exerciseName` is *not* a failure: the reference may still
    /// resolve, and the resolved `Exercise` supplies the name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let exerciseID = try? c.decode(UUID.self, forKey: .exerciseID)
        else { throw SlotAlternativeDecodingError.missingExerciseReference }

        let prescription = try c.decode(
            AlternativePrescriptionPayload.self, forKey: .prescription)

        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            order: (try? c.decodeIfPresent(Int.self, forKey: .order)) ?? 0,
            isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled))
                ?? true,
            exerciseID: exerciseID,
            exerciseName: (try? c.decodeIfPresent(
                String.self, forKey: .exerciseName)) ?? "",
            note: try? c.decodeIfPresent(String.self, forKey: .note),
            prescription: prescription
        )
        self = normalized()
    }

    /// `note` is omitted when nil; every other field is always written, because
    /// each is a positive statement about the alternative (an id, a position,
    /// an enabled flag, a reference, a display name, a plan).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(order, forKey: .order)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(exerciseID, forKey: .exerciseID)
        try c.encode(exerciseName, forKey: .exerciseName)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(prescription, forKey: .prescription)
    }
}

/// Why a single alternative was refused at decode.
///
/// Typed and `Equatable` so tests can assert the specific reason. Never
/// surfaces to a caller of `SlotAlternatives.decode(from:)` — the payload
/// decoder catches it and drops the element.
enum SlotAlternativeDecodingError: Error, Equatable {
    /// No `exerciseID`. An alternative with no exercise to switch to is not an
    /// alternative, and inventing a reference is explicitly out of scope.
    case missingExerciseReference
}

// ======================================================
// MARK: - Payload root
// ======================================================

/// The encoded root — what Phase C will store in
/// `SlotPrescription.alternativesData`.
struct SlotAlternativesPayload: Codable, Equatable {

    /// Payload version, for forward evolution. Written always; decoded with a
    /// default so a payload from before this field existed still reads.
    static let currentVersion = 1

    var version: Int = currentVersion
    var alternatives: [SlotAlternative] = []
}

extension SlotAlternativesPayload {

    private enum CodingKeys: String, CodingKey {
        case version, alternatives
    }

    /// Repairs rather than rejects (§5.3 "forward tolerance"):
    ///
    ///  - an alternative that fails to decode is **dropped**; its siblings
    ///    survive,
    ///  - a missing `alternatives` key reads as an empty list,
    ///  - an **unknown `version`** — including one from a future build — is
    ///    decoded exactly like the current one and preserved on the value.
    ///    The version is deliberately not a gate: every field in this format is
    ///    optional at the wire level and unknown keys are ignored, so "decode
    ///    what you can" always yields at least the alternatives a future build
    ///    would recognize. A payload this build genuinely cannot parse fails
    ///    the `JSONDecoder` outright and `SlotAlternatives.decode(from:)`
    ///    resolves it to `[]` — costing the alternatives, never the routine.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded =
            (try? c.decodeIfPresent(
                [LenientAlternative].self, forKey: .alternatives)) ?? []
        self.init(
            version: (try? c.decodeIfPresent(Int.self, forKey: .version))
                ?? Self.currentVersion,
            alternatives: decoded.compactMap(\.alternative)
        )
    }

    /// Wrapper that turns a failed element decode into a dropped element. Each
    /// array element gets its own decoder, so one failure cannot disturb the
    /// others — the same shape `CardioSegmentGroup.LenientSegment` uses.
    private struct LenientAlternative: Decodable {
        let alternative: SlotAlternative?
        init(from decoder: Decoder) throws {
            alternative = try? SlotAlternative(from: decoder)
        }
    }
}

// ======================================================
// MARK: - Codec
// ======================================================

/// Encode / decode / normalize for a slot's alternatives.
///
/// The single intended read and write path, mirroring
/// `SlotPrescription+StructuredCardio.swift`. Phase C's
/// `SlotPrescription.slotAlternatives` accessor is a two-line forward to these.
enum SlotAlternatives {

    /// Deterministic by construction: `.sortedKeys` fixes key order, so the
    /// same list always encodes to the same bytes and a future dirty-check can
    /// compare payloads directly.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: Decode

    /// Tolerant decode. `nil` data, empty data, an empty list and an unreadable
    /// payload all read as `[]` — one representation of "no alternatives", so
    /// no caller checks four states and a corrupt column costs the feature
    /// rather than the routine.
    ///
    /// The result is always normalized, so callers get stable ordering and
    /// unique ids without asking.
    static func decode(from data: Data?) -> [SlotAlternative] {
        guard let data, !data.isEmpty else { return [] }
        guard
            let payload = try? JSONDecoder().decode(
                SlotAlternativesPayload.self, from: data)
        else { return [] }
        return normalize(payload.alternatives)
    }

    // MARK: Encode

    /// Encodes a normalized payload, or `nil` when there is nothing to store.
    ///
    /// An empty list clears the column rather than writing an empty payload, so
    /// "the user deleted the last alternative" and "this slot never had any"
    /// persist identically. Encoding failure clears for the same reason the
    /// read path is tolerant: a slot with no alternatives is a valid slot, a
    /// half-written column is not.
    static func encode(_ alternatives: [SlotAlternative]) -> Data? {
        let normalized = normalize(alternatives)
        guard !normalized.isEmpty else { return nil }
        return try? encoder.encode(
            SlotAlternativesPayload(
                version: SlotAlternativesPayload.currentVersion,
                alternatives: normalized))
    }

    // MARK: Normalize

    /// Stable order, dense `order` values, unique ids, trimmed strings.
    ///
    /// Ordering is by `order`, ties broken by the incoming position — the sort
    /// is made stable explicitly because `Array.sorted(by:)` is not guaranteed
    /// to be. `order` is then rewritten to `0..<count`: it is positional
    /// metadata, not an authored value, and a dense sequence is what an
    /// `.onMove` handler writes back.
    ///
    /// Duplicate ids are **repaired, not dropped**. Two rows sharing an id
    /// break `Identifiable` diffing in a `ForEach`, but the prepared work is
    /// still the user's — so the first occurrence keeps the id and each later
    /// one is reissued. `idGenerator` is injected purely so tests can pin the
    /// reissued values; the default is `UUID.init` and the repair is written
    /// back on the next encode.
    ///
    /// Nothing else about a prescription is touched — see
    /// `AlternativePrescriptionPayload.normalized()`.
    static func normalize(
        _ alternatives: [SlotAlternative],
        idGenerator: () -> UUID = UUID.init
    ) -> [SlotAlternative] {
        let ordered =
            alternatives
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.order == rhs.element.order
                    ? lhs.offset < rhs.offset
                    : lhs.element.order < rhs.element.order
            }
            .map(\.element)

        var seen: Set<UUID> = []
        var result: [SlotAlternative] = []
        result.reserveCapacity(ordered.count)

        for (index, alternative) in ordered.enumerated() {
            var normalized = alternative.normalized()
            normalized.order = index
            if !seen.insert(normalized.id).inserted {
                var fresh = idGenerator()
                while !seen.insert(fresh).inserted { fresh = idGenerator() }
                normalized.id = fresh
            }
            result.append(normalized)
        }
        return result
    }

    // MARK: Duplication

    /// Copies a slot's alternatives for a **duplicated routine**, reissuing
    /// every `id` (Phase H1, design §12.1).
    ///
    /// An alternative's `id` identifies a piece of prepared work *within a
    /// slot*, and the duplicate's slots already get fresh `slotID`s. Sharing
    /// ids across two routines would make their alternatives indistinguishable
    /// to any future feature that keys on one (per-alternative usage stats, a
    /// "last used" marker), so they are reissued here for the same reason
    /// `RoutineDuplicator` reissues everything else it copies.
    ///
    /// **Everything else is preserved verbatim**, including:
    ///
    ///  - `exerciseID` — duplication *shares* definition-level exercises by
    ///    design, exactly as the slot's own `Exercise` reference is shared,
    ///  - `order` and `isEnabled` — a disabled alternative copies as disabled,
    ///  - the whole prescription, down to the `CardioSegment` ids inside a
    ///    Cardio Plan. Those are **not** reissued: `RoutineDuplicator` copies
    ///    the slot's own `cardioSegmentsData` as raw bytes, so its segment ids
    ///    are shared with the original, and an alternative's plan behaves the
    ///    same way. One rule for segment identity, not two.
    ///
    /// `idGenerator` is injectable so tests can pin the reissued values.
    static func duplicated(
        _ alternatives: [SlotAlternative],
        idGenerator: () -> UUID = UUID.init
    ) -> [SlotAlternative] {
        alternatives.map { alternative in
            var copy = alternative
            copy.id = idGenerator()
            return copy
        }
    }

    // MARK: Shared helpers

    /// Trim, and treat a blank string as absent. The app's existing note rule.
    static func trimmedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decodes an array element-by-element, dropping the elements that fail.
    ///
    /// Used for the warm-up and technique arrays, whose element types
    /// (`WarmupStepSnapshot`, `TechniquePlanSnapshot`) are owned by the plan
    /// layer and use synthesized `Codable` — so one bad row would otherwise
    /// fail the whole prescription.
    static func lenientArray<T: Decodable, K: CodingKey>(
        _ type: T.Type,
        in container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> [T] {
        let decoded =
            (try? container.decodeIfPresent([LenientElement<T>].self, forKey: key))
            ?? []
        return decoded.compactMap(\.value)
    }
}

/// Wrapper that turns a failed element decode into a dropped element. Each
/// array element gets its own decoder, so one failure cannot disturb the
/// others — the generic form of `CardioSegmentGroup.LenientSegment`.
///
/// File-scoped rather than nested inside `SlotAlternatives.lenientArray`,
/// because a generic type cannot be declared inside a generic function.
private struct LenientElement<Element: Decodable>: Decodable {
    let value: Element?
    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

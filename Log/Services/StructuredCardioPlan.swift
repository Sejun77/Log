import Foundation

// ======================================================
// MARK: - Structured cardio: bounds
// ======================================================

/// Hard bounds for a structured cardio plan, from
/// `docs/STRUCTURED_CARDIO_DESIGN.md` §2.5.
///
/// They exist so the checklist stays renderable and so a future segment timer
/// can never be handed a 10,000-segment plan. Separate from `CardioLimits`,
/// which bounds the *values inside* a segment; these bound the plan's shape.
enum CardioPlanLimits {
    /// A group may repeat at most this many times. "5 rounds" is typical;
    /// 20 is past any interval session a person actually programs.
    static let maxRepeatCount = 20

    /// Segments in one repeat unit. A work/recovery pair is 2; 20 leaves room
    /// for a pyramid without allowing a plan nobody can read on a phone.
    static let maxSegmentsPerGroup = 20

    /// Total segments after repeats are expanded. This is the bound that
    /// actually protects the UI, because it is what gets rendered.
    static let maxExpandedSegments = 60
}

/// Why a structured cardio value was refused at construction.
///
/// Typed rather than a `Bool`, because the 12C routine editor has to tell the
/// user *what* to fix — "add a target" and "too many rounds" need different
/// sentences. `Equatable` so tests can assert the specific reason rather than
/// merely that something threw.
enum CardioPlanError: Error, Equatable {
    /// Every target normalized away, leaving a row that says nothing. A note
    /// alone is not a target — it describes a segment, it does not define one.
    case segmentHasNoTarget
    /// A group with no segments. Repeating nothing five times is still nothing.
    case emptyGroup
    case repeatCountOutOfRange(Int)
    case tooManySegmentsInGroup(Int)
    case tooManyExpandedSegments(Int)
}

// ======================================================
// MARK: - Segment kind
// ======================================================

/// What a segment is *for*.
///
/// A closed enum, deliberately: free-text kinds would need normalizing,
/// deduping, localizing and eventually grouping in analytics — all cost, for a
/// need `CardioSegment.note` already covers ("Hill repeat", "Zone 2 float").
/// Adding a fifth case later is additive; removing a free-text field never is.
enum CardioSegmentKind: String, Codable, CaseIterable, Equatable {
    case warmUp
    case work
    case recovery
    case coolDown

    /// Display label. Plain English by design in this slice — see the file's
    /// summary-text note. The 12C editor is what introduces these as
    /// user-facing strings, and it localizes them there.
    var label: String {
        switch self {
        case .warmUp: return "Warm-up"
        case .work: return "Work"
        case .recovery: return "Recovery"
        case .coolDown: return "Cool-down"
        }
    }

    /// Tolerant lookup for a persisted / imported raw string, matching
    /// `DistanceUnit.from(raw:)` and `HRZone.from(raw:)`.
    static func from(raw: String?) -> CardioSegmentKind? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return CardioSegmentKind.allCases.first { $0.rawValue == key }
    }

    /// An unknown raw kind decodes to `.work` rather than failing the payload,
    /// so a plan written by a future build (with a kind this build has never
    /// heard of) degrades to something sane instead of vanishing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CardioSegmentKind.from(raw: raw) ?? .work
    }
}

// ======================================================
// MARK: - Segment
// ======================================================

/// One planned piece of a cardio bout — "5 minutes easy", "1 km at 1%".
///
/// A **target**, never a result. Nothing here is ever compared against what was
/// performed; the bout is still logged as one aggregate `SetLog`
/// (`STRUCTURED_CARDIO_DESIGN.md` §2.6), and per-segment actuals are explicitly
/// deferred.
///
/// Every value is normalized through the same rules `CardioMetrics` already
/// enforces, so a segment can never hold a negative distance or an implausible
/// incline. What survives normalization is what the segment has: if that is
/// nothing, the segment is refused rather than stored as an empty row.
struct CardioSegment: Codable, Equatable, Identifiable {

    /// Stable identity, persisted with the payload.
    ///
    /// Needed before the UI exists: the 12D checklist keys its tick state by
    /// segment, and that state must survive Save & Exit, cold resume, and a
    /// reorder of the list. An index would not — inserting a warm-up at the top
    /// would silently move every tick down one row.
    let id: UUID

    let kind: CardioSegmentKind

    /// All optional, all normalized. `inclinePercent` keeps 0 (a segment
    /// explicitly programmed flat is meaningful, and distinct from "not set"),
    /// matching `CardioMetrics.normalizedInclinePercent`.
    let durationSeconds: Int?
    let distanceMeters: Double?
    let inclinePercent: Double?
    let resistanceLevel: Double?
    let hrZone: HRZone?

    /// Free text for what the kind cannot say ("Hill repeat"). Trimmed; empty
    /// becomes nil. **Not** a target — a segment carrying only a note is
    /// refused.
    let note: String?

    // MARK: Construction

    /// The only construction path. Normalizes every field, then refuses the
    /// segment if no target survived.
    ///
    /// Throwing rather than failable so the editor can say *why*. Duration is
    /// normalized by `DurationLimits` (≤ 0 collapses to "unset", over-long
    /// clamps to the app's 6-hour exercise ceiling) and the metric fields by
    /// `CardioMetrics`, so this type adds no numeric rules of its own — one
    /// definition of "a plausible incline", app-wide.
    init(
        id: UUID = UUID(),
        kind: CardioSegmentKind,
        durationSeconds: Int? = nil,
        distanceMeters: Double? = nil,
        inclinePercent: Double? = nil,
        resistanceLevel: Double? = nil,
        hrZone: HRZone? = nil,
        note: String? = nil
    ) throws {
        let duration = DurationLimits.normalizedExerciseDuration(durationSeconds)
        let distance = CardioMetrics.normalizedDistanceMeters(distanceMeters)
        let incline = CardioMetrics.normalizedInclinePercent(inclinePercent)
        let resistance = CardioMetrics.normalizedResistanceLevel(resistanceLevel)

        guard
            duration != nil || distance != nil || incline != nil
                || resistance != nil || hrZone != nil
        else { throw CardioPlanError.segmentHasNoTarget }

        self.id = id
        self.kind = kind
        self.durationSeconds = duration
        self.distanceMeters = distance
        self.inclinePercent = incline
        self.resistanceLevel = resistance
        self.hrZone = hrZone
        self.note = Self.normalizedNote(note)
    }

    private static func normalizedNote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, kind, durationSeconds, distanceMeters, inclinePercent
        case resistanceLevel, hrZone, note
    }

    /// Decoding re-runs the same normalization as construction, so a decoded
    /// segment is exactly as valid as an authored one — a payload cannot smuggle
    /// a negative distance past the initializer by going through JSON.
    ///
    /// A segment that normalizes to nothing **throws**; `CardioSegmentGroup`
    /// catches that and drops the row (see its decoder). Authoring rejects,
    /// decoding repairs.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            kind: c.decodeIfPresent(CardioSegmentKind.self, forKey: .kind)
                ?? .work,
            durationSeconds: c.decodeIfPresent(Int.self, forKey: .durationSeconds),
            distanceMeters: c.decodeIfPresent(Double.self, forKey: .distanceMeters),
            inclinePercent: c.decodeIfPresent(Double.self, forKey: .inclinePercent),
            resistanceLevel: c.decodeIfPresent(
                Double.self, forKey: .resistanceLevel),
            // Decoded as a raw string through the tolerant lookup, so an
            // unknown zone drops the field instead of failing the segment.
            hrZone: HRZone.from(
                raw: c.decodeIfPresent(String.self, forKey: .hrZone)),
            note: c.decodeIfPresent(String.self, forKey: .note)
        )
    }

    /// Absent values are **omitted**, not written as null: the payload is a
    /// stored column, and a plan of five duration-only segments should not
    /// carry twenty-five nulls.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(distanceMeters, forKey: .distanceMeters)
        try c.encodeIfPresent(inclinePercent, forKey: .inclinePercent)
        try c.encodeIfPresent(resistanceLevel, forKey: .resistanceLevel)
        try c.encodeIfPresent(hrZone?.rawValue, forKey: .hrZone)
        try c.encodeIfPresent(note, forKey: .note)
    }

    // MARK: Summary

    /// Full detail, kind first: "Work · 20m · 5 km · 1%".
    func summary(distanceUnit: DistanceUnit) -> String {
        ([kind.label] + targetParts(distanceUnit: distanceUnit))
            .joined(separator: " · ")
    }

    /// The targets without the kind — for a row that already shows the kind on
    /// its own line (the 12C editor list, the 12D active checklist). Falls back
    /// to the full summary if the prefix is not there, so this can never return
    /// a blank line.
    func shortTargetSummary(distanceUnit: DistanceUnit) -> String {
        let full = summary(distanceUnit: distanceUnit)
        let prefix = "\(kind.label) · "
        guard full.hasPrefix(prefix) else { return full }
        return String(full.dropFirst(prefix.count))
    }

    /// Compact form for nesting inside a group summary: "1m work", "5 km work".
    /// Only the leading target is used — a group line is a shape, not a spec.
    func shortSummary(distanceUnit: DistanceUnit) -> String {
        guard let lead = targetParts(distanceUnit: distanceUnit).first else {
            return kind.label.lowercased()
        }
        return "\(lead) \(kind.label.lowercased())"
    }

    /// The target values, in a fixed order, skipping whatever is unset.
    /// Deterministic so summaries are stable across renders and test runs.
    private func targetParts(distanceUnit: DistanceUnit) -> [String] {
        var parts: [String] = []
        if let durationSeconds {
            parts.append(DurationFormat.compact(durationSeconds))
        }
        if let text = CardioTargetDistance(
            meters: distanceMeters, displayUnit: distanceUnit)?.displayText
        {
            parts.append(text)
        }
        if let inclinePercent,
            let value = CardioDerived.formatDistance(
                value: abs(inclinePercent))
        {
            // Signed, because decline is a real treadmill setting: "-3%".
            parts.append("\(inclinePercent < 0 ? "-" : "")\(value)%")
        }
        if let resistanceLevel,
            let value = CardioDerived.formatDistance(value: resistanceLevel)
        {
            parts.append("L\(value)")
        }
        if let hrZone {
            parts.append(hrZone.shortLabel)
        }
        return parts
    }
}

// ======================================================
// MARK: - Segment group
// ======================================================

/// One repeat unit: an ordered list of segments and how many times it runs.
///
/// A flat plan is a single group with `repeatCount == 1` — that identity is the
/// reason repeats cost nothing to add later. The 12C editor pins the count to 1
/// and never shows it; the field is in the payload, the decoder and the exports
/// from day one, so the interval UI writes a field that has always been there.
struct CardioSegmentGroup: Codable, Equatable, Identifiable {
    let id: UUID
    let segments: [CardioSegment]
    let repeatCount: Int

    init(
        id: UUID = UUID(),
        segments: [CardioSegment],
        repeatCount: Int = 1
    ) throws {
        guard !segments.isEmpty else { throw CardioPlanError.emptyGroup }
        guard segments.count <= CardioPlanLimits.maxSegmentsPerGroup else {
            throw CardioPlanError.tooManySegmentsInGroup(segments.count)
        }
        guard
            repeatCount >= 1,
            repeatCount <= CardioPlanLimits.maxRepeatCount
        else { throw CardioPlanError.repeatCountOutOfRange(repeatCount) }

        self.id = id
        self.segments = segments
        self.repeatCount = repeatCount
    }

    /// Segments this group contributes once expanded.
    var expandedCount: Int { segments.count * repeatCount }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, segments, repeatCount
    }

    /// Repairs rather than rejects, because the alternative is losing a routine's
    /// whole plan to one bad row:
    ///
    ///  - a segment that fails to decode is **dropped**,
    ///  - a `repeatCount` outside 1...20 is **clamped**,
    ///  - segments past the per-group cap are **truncated**,
    ///  - a group left with no segments still throws, so `CardioSegmentPlan`
    ///    can drop it whole.
    ///
    /// This is the same split `DurationLimits` and `CardioMetrics` already make:
    /// typed entry is rejected (it is a typo the user can fix), stored and
    /// imported data is repaired (nobody is there to fix it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent(
            [LenientSegment].self, forKey: .segments) ?? []
        let segments = Array(
            decoded.compactMap(\.segment)
                .prefix(CardioPlanLimits.maxSegmentsPerGroup))
        let rawRepeat = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1

        try self.init(
            id: c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            segments: segments,
            repeatCount: min(
                max(1, rawRepeat), CardioPlanLimits.maxRepeatCount)
        )
    }

    /// Wrapper that turns a failed segment decode into a dropped element.
    /// Each array element gets its own decoder, so one failure cannot disturb
    /// the others.
    private struct LenientSegment: Decodable {
        let segment: CardioSegment?
        init(from decoder: Decoder) throws {
            segment = try? CardioSegment(from: decoder)
        }
    }

    // MARK: Summary

    /// "5m warm-up · 20m work" for a single round;
    /// "5 × (1m work / 2m recovery)" for a repeat.
    func summary(distanceUnit: DistanceUnit) -> String {
        let parts = segments.map { $0.shortSummary(distanceUnit: distanceUnit) }
        guard repeatCount > 1 else { return parts.joined(separator: " · ") }
        return "\(repeatCount) × (\(parts.joined(separator: " / ")))"
    }
}

// ======================================================
// MARK: - Plan
// ======================================================

/// The whole structured plan for one cardio slot.
///
/// Pure value type with no SwiftData involvement. Slice 12C stores it as
/// JSON in an optional `Data?` column on `SlotPrescription` — the same
/// mechanism `WorkoutItem.warmupStepsSnapshotData` already uses — but nothing
/// in this slice is persisted, read by a view, or exported.
struct CardioSegmentPlan: Codable, Equatable {

    /// Payload version, for forward evolution. Written always, decoded with a
    /// default so a payload from before this field existed still reads.
    static let currentVersion = 1

    let version: Int
    let groups: [CardioSegmentGroup]

    /// The "no structure" value. Valid and round-trippable: deleting the last
    /// segment in the editor must not be an error state, and 12C stores this as
    /// a nil column rather than an empty payload.
    static let empty = CardioSegmentPlan(version: currentVersion, groups: [])

    private init(version: Int, groups: [CardioSegmentGroup]) {
        self.version = version
        self.groups = groups
    }

    /// Builds a plan, enforcing the expanded-segment budget across all groups.
    /// Per-group rules are already guaranteed by `CardioSegmentGroup`.
    init(groups: [CardioSegmentGroup]) throws {
        let expanded = groups.reduce(0) { $0 + $1.expandedCount }
        guard expanded <= CardioPlanLimits.maxExpandedSegments else {
            throw CardioPlanError.tooManyExpandedSegments(expanded)
        }
        self.version = Self.currentVersion
        self.groups = groups
    }

    // MARK: Shape

    var isEmpty: Bool { groups.isEmpty }

    /// Authored segments, before repeats.
    var segmentCount: Int { groups.reduce(0) { $0 + $1.segments.count } }

    /// Segments after repeats — what the checklist will render.
    var expandedCount: Int { groups.reduce(0) { $0 + $1.expandedCount } }

    /// Total planned duration, counting every repeat. `nil` when no segment
    /// carries a duration, so a distance-only plan does not claim 0 minutes.
    var totalDurationSeconds: Int? {
        let total = expandedSegments().reduce(0) {
            $0 + ($1.segment.durationSeconds ?? 0)
        }
        return total > 0 ? total : nil
    }

    /// Total planned distance in canonical meters, counting every repeat.
    var totalDistanceMeters: Double? {
        let total = expandedSegments().reduce(0.0) {
            $0 + ($1.segment.distanceMeters ?? 0)
        }
        return total > 0 ? total : nil
    }

    // MARK: Expansion

    /// Flattens repeats into the list a checklist renders.
    ///
    /// Pure and deterministic: same plan in, same array out, and the receiver is
    /// never mutated (it cannot be — every stored property is a `let`). Bounded
    /// by construction and by the decoder, so this cannot exceed
    /// `CardioPlanLimits.maxExpandedSegments` and does not need to fail.
    func expandedSegments() -> [ResolvedCardioSegment] {
        var resolved: [ResolvedCardioSegment] = []
        resolved.reserveCapacity(expandedCount)

        for (groupIndex, group) in groups.enumerated() {
            for round in 1...max(1, group.repeatCount) {
                for segment in group.segments {
                    resolved.append(
                        ResolvedCardioSegment(
                            index: resolved.count,
                            groupIndex: groupIndex,
                            round: round,
                            roundCount: group.repeatCount,
                            segment: segment
                        ))
                }
            }
        }
        return resolved
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, groups
    }

    /// Repairs, like the group decoder: a group that fails to decode is
    /// dropped, and groups are kept **as a prefix** — the first ones that fit
    /// the expanded budget, stopping at the first that does not. So a corrupt
    /// or oversized payload yields a smaller valid plan rather than an
    /// exception the caller has to have a fallback for.
    ///
    /// Prefix rather than best-fit: "the first N segments of what you planned"
    /// is a plan the user can recognize. Skipping an oversized middle group and
    /// keeping the cool-down after it would silently reorder the session's
    /// meaning, which is a stranger thing to hand back than a truncated one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([LenientGroup].self, forKey: .groups)
            ?? []

        var kept: [CardioSegmentGroup] = []
        var budget = CardioPlanLimits.maxExpandedSegments
        for group in decoded.compactMap(\.group) {
            guard group.expandedCount <= budget else { break }
            kept.append(group)
            budget -= group.expandedCount
        }

        self.version =
            try c.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentVersion
        self.groups = kept
    }

    private struct LenientGroup: Decodable {
        let group: CardioSegmentGroup?
        init(from decoder: Decoder) throws {
            group = try? CardioSegmentGroup(from: decoder)
        }
    }

    // MARK: Summary

    /// Headline for a collapsed row: "6 segments · 32m · 5 km".
    ///
    /// Counts **expanded** segments, because that is what the user performs —
    /// "3 segments" for a 5 × (work/recovery) plan would be the author's view,
    /// not the athlete's.
    func summary(distanceUnit: DistanceUnit) -> String {
        guard !isEmpty else { return "No segments" }

        var parts = ["\(expandedCount) \(expandedCount == 1 ? "segment" : "segments")"]
        if let totalDurationSeconds {
            parts.append(DurationFormat.compact(totalDurationSeconds))
        }
        if let text = CardioTargetDistance(
            meters: totalDistanceMeters, displayUnit: distanceUnit)?.displayText
        {
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }

    /// One line per group: "5m warm-up · 20m work · 5m cool-down", or
    /// "5 × (1m work / 2m recovery)". The detail view of `summary`.
    func structureSummary(distanceUnit: DistanceUnit) -> String {
        guard !isEmpty else { return "No segments" }
        return groups
            .map { $0.summary(distanceUnit: distanceUnit) }
            .joined(separator: " · ")
    }
}

// ======================================================
// MARK: - Expanded segment
// ======================================================

/// One occurrence of a segment in the flattened plan — the unit a checklist
/// row, and one day a segment timer, will consume.
struct ResolvedCardioSegment: Equatable, Identifiable {
    /// Position in the expanded list, 0-based.
    let index: Int
    /// Which group it came from, 0-based.
    let groupIndex: Int
    /// Which round of that group, 1-based.
    let round: Int
    /// The group's `repeatCount`, so a row can render "round 2 of 5" without
    /// looking back at the plan.
    let roundCount: Int
    let segment: CardioSegment

    /// Deterministic identity: the same plan always yields the same ids, so a
    /// SwiftUI list diffs cleanly across recomputes and 12D can key tick state
    /// by it. Derived rather than a fresh `UUID()`, which would change on every
    /// call and defeat both.
    var id: String { "\(segment.id.uuidString)#\(round)" }

    /// True when this occurrence is one of several rounds — the cue a row uses
    /// to show "2/5".
    var isRepeated: Bool { roundCount > 1 }

    func summary(distanceUnit: DistanceUnit) -> String {
        segment.summary(distanceUnit: distanceUnit)
    }
}

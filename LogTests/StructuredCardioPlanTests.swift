import XCTest

@testable import Log

/// Structured Cardio Slice 12B — the pure plan value types.
///
/// Nothing here touches SwiftData: `StructuredCardioPlan.swift` is value types
/// only, so these are plain `XCTestCase` tests with literal fixtures, matching
/// `CardioMetricsTests` and `RoutineDuplicatorTests`' pure half.
///
/// The rule the whole suite is really pinning is the **authoring rejects,
/// decoding repairs** split: typed input is refused with a typed error, because
/// a person is there to fix it; a stored or imported payload is normalized,
/// because nobody is.
final class StructuredCardioPlanTests: XCTestCase {

    // MARK: - Fixtures

    private func segment(
        _ kind: CardioSegmentKind,
        duration: Int? = nil,
        distance: Double? = nil,
        incline: Double? = nil,
        resistance: Double? = nil,
        hrZone: HRZone? = nil,
        note: String? = nil
    ) throws -> CardioSegment {
        try CardioSegment(
            kind: kind, durationSeconds: duration, distanceMeters: distance,
            inclinePercent: incline, resistanceLevel: resistance,
            hrZone: hrZone, note: note)
    }

    /// 5 min warm-up → 20 min work → 5 min cool-down.
    private func simplePlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.warmUp, duration: 300),
                segment(.work, duration: 1_200),
                segment(.coolDown, duration: 300),
            ])
        ])
    }

    /// 5 × (1 min work / 2 min recovery).
    private func intervalPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [
                    segment(.work, duration: 60),
                    segment(.recovery, duration: 120),
                ],
                repeatCount: 5)
        ])
    }

    private func roundTrip(_ plan: CardioSegmentPlan) throws -> CardioSegmentPlan
    {
        let data = try JSONEncoder().encode(plan)
        return try JSONDecoder().decode(CardioSegmentPlan.self, from: data)
    }

    private func assertThrows(
        _ expected: CardioPlanError,
        _ body: () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CardioPlanError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - 1. Segment construction and normalization

    func testSegmentKeepsNormalizedTargets() throws {
        let s = try segment(
            .work, duration: 1_200, distance: 5_000, incline: 1.5,
            resistance: 8, hrZone: .z3, note: "  Steady  ")

        XCTAssertEqual(s.kind, .work)
        XCTAssertEqual(s.durationSeconds, 1_200)
        XCTAssertEqual(s.distanceMeters, 5_000)
        XCTAssertEqual(s.inclinePercent, 1.5)
        XCTAssertEqual(s.resistanceLevel, 8)
        XCTAssertEqual(s.hrZone, .z3)
        XCTAssertEqual(s.note, "Steady", "notes are trimmed")
    }

    func testSegmentWithNoTargetIsRejected() {
        assertThrows(.segmentHasNoTarget) { try self.segment(.work) }
    }

    /// A note describes a segment; it does not define one.
    func testNoteAloneIsNotATarget() {
        assertThrows(.segmentHasNoTarget) {
            try self.segment(.work, note: "Hill repeat")
        }
    }

    /// Zero and negative durations mean "unset" everywhere in this app
    /// (`DurationLimits`), so a segment whose only field is one has no target.
    func testNonPositiveDurationIsUnsetAndLeavesNoTarget() {
        assertThrows(.segmentHasNoTarget) {
            try self.segment(.work, duration: 0)
        }
        assertThrows(.segmentHasNoTarget) {
            try self.segment(.work, duration: -60)
        }
    }

    func testNonPositiveDistanceIsUnsetAndLeavesNoTarget() {
        assertThrows(.segmentHasNoTarget) {
            try self.segment(.work, distance: 0)
        }
        assertThrows(.segmentHasNoTarget) {
            try self.segment(.work, distance: -5_000)
        }
    }

    /// Out-of-range values drop, exactly as `CardioMetrics` drops them — so a
    /// segment carrying only an impossible incline has no target at all.
    func testOutOfRangeMetricsDropToNil() throws {
        assertThrows(.segmentHasNoTarget) {
            try self.segment(.work, incline: 500)
        }
        assertThrows(.segmentHasNoTarget) {
            try self.segment(.work, incline: -50)
        }
        assertThrows(.segmentHasNoTarget) {
            try self.segment(.work, resistance: 500)
        }

        // Dropped alongside a valid target: the segment survives, the bad
        // value does not.
        let s = try segment(.work, duration: 600, incline: 500, resistance: -3)
        XCTAssertEqual(s.durationSeconds, 600)
        XCTAssertNil(s.inclinePercent)
        XCTAssertNil(s.resistanceLevel)
    }

    /// Decline is a real treadmill setting, and 0% is a deliberate choice
    /// distinct from "not set" — both rules inherited from `CardioMetrics`.
    func testInclineAcceptsZeroAndDecline() throws {
        XCTAssertEqual(try segment(.work, incline: 0).inclinePercent, 0)
        XCTAssertEqual(try segment(.work, incline: -3).inclinePercent, -3)
    }

    func testOverlongDurationClampsToTheExerciseCeiling() throws {
        let s = try segment(.work, duration: 99 * 3_600)
        XCTAssertEqual(s.durationSeconds, DurationLimits.maxExerciseSeconds)
    }

    func testEachTargetAloneIsSufficient() throws {
        XCTAssertNoThrow(try segment(.work, duration: 600))
        XCTAssertNoThrow(try segment(.work, distance: 1_000))
        XCTAssertNoThrow(try segment(.work, incline: 0))
        XCTAssertNoThrow(try segment(.work, resistance: 5))
        XCTAssertNoThrow(try segment(.work, hrZone: .z2))
    }

    // MARK: - 2. Group bounds

    func testEmptyGroupIsRejected() {
        assertThrows(.emptyGroup) { try CardioSegmentGroup(segments: []) }
    }

    func testRepeatCountBelowOneIsRejected() throws {
        let s = try segment(.work, duration: 60)
        assertThrows(.repeatCountOutOfRange(0)) {
            try CardioSegmentGroup(segments: [s], repeatCount: 0)
        }
        assertThrows(.repeatCountOutOfRange(-1)) {
            try CardioSegmentGroup(segments: [s], repeatCount: -1)
        }
    }

    func testRepeatCountAboveTwentyIsRejected() throws {
        let s = try segment(.work, duration: 60)
        assertThrows(.repeatCountOutOfRange(21)) {
            try CardioSegmentGroup(segments: [s], repeatCount: 21)
        }
        XCTAssertNoThrow(
            try CardioSegmentGroup(
                segments: [s], repeatCount: CardioPlanLimits.maxRepeatCount))
    }

    func testTooManySegmentsInOneGroupIsRejected() throws {
        let many = try (0..<21).map { _ in try segment(.work, duration: 60) }
        assertThrows(.tooManySegmentsInGroup(21)) {
            try CardioSegmentGroup(segments: many)
        }
    }

    // MARK: - 3. Plan bounds

    func testExpandedSegmentBudgetIsEnforced() throws {
        let pair = [
            try segment(.work, duration: 60),
            try segment(.recovery, duration: 120),
        ]
        // 2 segments × 20 rounds × 2 groups = 80 > 60.
        let group = try CardioSegmentGroup(segments: pair, repeatCount: 20)
        assertThrows(.tooManyExpandedSegments(80)) {
            try CardioSegmentPlan(groups: [group, group])
        }
    }

    func testExactlyTheBudgetIsAccepted() throws {
        let three = try (0..<3).map { _ in try segment(.work, duration: 60) }
        let group = try CardioSegmentGroup(segments: three, repeatCount: 20)
        let plan = try CardioSegmentPlan(groups: [group])
        XCTAssertEqual(plan.expandedCount, CardioPlanLimits.maxExpandedSegments)
    }

    /// Deleting the last segment must not be an error state — an empty plan is
    /// "no structure", which is the ordinary case for every cardio slot today.
    func testEmptyPlanIsValid() throws {
        let plan = try CardioSegmentPlan(groups: [])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.expandedCount, 0)
        XCTAssertNil(plan.totalDurationSeconds)
        XCTAssertNil(plan.totalDistanceMeters)
        XCTAssertEqual(CardioSegmentPlan.empty, plan)
    }

    func testValidPlansPassConstruction() throws {
        XCTAssertNoThrow(try simplePlan())
        XCTAssertNoThrow(try intervalPlan())
    }

    // MARK: - 4. Expansion

    func testSingleRoundExpandsOnce() throws {
        let plan = try simplePlan()
        let expanded = plan.expandedSegments()

        XCTAssertEqual(expanded.count, 3)
        XCTAssertEqual(expanded.map(\.segment.kind), [.warmUp, .work, .coolDown])
        XCTAssertEqual(expanded.map(\.index), [0, 1, 2])
        XCTAssertTrue(expanded.allSatisfy { $0.round == 1 })
        XCTAssertTrue(expanded.allSatisfy { !$0.isRepeated })
    }

    func testRepeatsExpandInOrder() throws {
        let plan = try intervalPlan()
        let expanded = plan.expandedSegments()

        XCTAssertEqual(expanded.count, 10)
        XCTAssertEqual(
            expanded.map(\.segment.kind),
            Array(repeating: [CardioSegmentKind.work, .recovery], count: 5)
                .flatMap { $0 },
            "work/recovery alternate, never grouped by kind")
        XCTAssertEqual(expanded.map(\.round), [1, 1, 2, 2, 3, 3, 4, 4, 5, 5])
        XCTAssertTrue(expanded.allSatisfy { $0.roundCount == 5 })
        XCTAssertTrue(expanded.allSatisfy(\.isRepeated))
    }

    func testMultipleGroupsExpandInGroupOrder() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [segment(.warmUp, duration: 300)]),
            CardioSegmentGroup(
                segments: [
                    segment(.work, duration: 60),
                    segment(.recovery, duration: 60),
                ],
                repeatCount: 2),
            CardioSegmentGroup(segments: [segment(.coolDown, duration: 300)]),
        ])

        XCTAssertEqual(
            plan.expandedSegments().map(\.segment.kind),
            [.warmUp, .work, .recovery, .work, .recovery, .coolDown])
        XCTAssertEqual(
            plan.expandedSegments().map(\.groupIndex), [0, 1, 1, 1, 1, 2])
    }

    func testExpansionPreservesTargets() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [
                    segment(
                        .work, duration: 60, distance: 400, incline: 2,
                        resistance: 7, hrZone: .z4, note: "Hard")
                ],
                repeatCount: 3)
        ])

        for resolved in plan.expandedSegments() {
            XCTAssertEqual(resolved.segment.durationSeconds, 60)
            XCTAssertEqual(resolved.segment.distanceMeters, 400)
            XCTAssertEqual(resolved.segment.inclinePercent, 2)
            XCTAssertEqual(resolved.segment.resistanceLevel, 7)
            XCTAssertEqual(resolved.segment.hrZone, .z4)
            XCTAssertEqual(resolved.segment.note, "Hard")
        }
    }

    func testExpansionIsDeterministicAndDoesNotMutate() throws {
        let plan = try intervalPlan()
        let first = plan.expandedSegments()
        let second = plan.expandedSegments()

        XCTAssertEqual(first, second, "same plan in, same array out")
        XCTAssertEqual(first.map(\.id), second.map(\.id), "ids are derived, not fresh")
        XCTAssertEqual(plan.groups.count, 1, "the source is untouched")
        XCTAssertEqual(plan.segmentCount, 2)
    }

    /// Ids distinguish rounds of the same segment, so a checklist can tick
    /// round 2 without ticking round 1.
    func testResolvedIdsAreUniquePerRound() throws {
        let ids = try intervalPlan().expandedSegments().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testExpansionRespectsTheBound() throws {
        let three = try (0..<3).map { _ in try segment(.work, duration: 60) }
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: three, repeatCount: 20)
        ])
        XCTAssertLessThanOrEqual(
            plan.expandedSegments().count, CardioPlanLimits.maxExpandedSegments)
    }

    func testTotalsCountEveryRound() throws {
        let plan = try intervalPlan()
        XCTAssertEqual(plan.totalDurationSeconds, 5 * (60 + 120))
        XCTAssertNil(plan.totalDistanceMeters, "no distance targets in this plan")

        let distancePlan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [segment(.work, distance: 400)], repeatCount: 4)
        ])
        XCTAssertEqual(distancePlan.totalDistanceMeters, 1_600)
        XCTAssertNil(distancePlan.totalDurationSeconds)
    }

    // MARK: - 5. Codable round-trips

    func testSegmentRoundTrips() throws {
        let original = try segment(
            .recovery, duration: 120, distance: 300, incline: -3, resistance: 4,
            hrZone: .z1, note: "Float")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CardioSegment.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, original.id, "identity survives encoding")
    }

    func testGroupRoundTrips() throws {
        let original = try CardioSegmentGroup(
            segments: [
                segment(.work, duration: 60), segment(.recovery, duration: 120),
            ],
            repeatCount: 5)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(
            try JSONDecoder().decode(CardioSegmentGroup.self, from: data),
            original)
    }

    func testSimplePlanRoundTrips() throws {
        let original = try simplePlan()
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.version, CardioSegmentPlan.currentVersion)
    }

    func testIntervalPlanRoundTrips() throws {
        let original = try intervalPlan()
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.expandedSegments(), original.expandedSegments())
    }

    func testEmptyPlanRoundTrips() throws {
        XCTAssertEqual(try roundTrip(.empty), CardioSegmentPlan.empty)
    }

    /// Encoding is stable — the same value encodes byte-identically every time,
    /// which is what lets 12C skip a write when nothing changed.
    func testEncodingIsStable() throws {
        let plan = try simplePlan()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try encoder.encode(plan), try encoder.encode(plan))
    }

    /// Absent values are omitted rather than written as null.
    func testAbsentFieldsAreOmittedFromJSON() throws {
        let data = try JSONEncoder().encode(
            try segment(.work, duration: 600))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["durationSeconds"])
        XCTAssertNil(json["distanceMeters"])
        XCTAssertNil(json["hrZone"])
        XCTAssertNil(json["note"])
    }

    // MARK: - 6. Decoding repairs rather than rejects

    private func decodePlan(_ json: String) throws -> CardioSegmentPlan {
        try JSONDecoder().decode(
            CardioSegmentPlan.self, from: Data(json.utf8))
    }

    /// An unknown kind from a future build reads as `.work` instead of taking
    /// the whole plan down with it.
    func testUnknownSegmentKindDecodesAsWork() throws {
        let plan = try decodePlan(
            """
            {"version":1,"groups":[{"repeatCount":1,"segments":[
              {"kind":"sprintFartlek","durationSeconds":60}]}]}
            """)
        XCTAssertEqual(plan.groups.first?.segments.first?.kind, .work)
    }

    func testUnknownHRZoneDropsTheFieldNotTheSegment() throws {
        let plan = try decodePlan(
            """
            {"version":1,"groups":[{"repeatCount":1,"segments":[
              {"kind":"work","durationSeconds":60,"hrZone":"z9"}]}]}
            """)
        let segment = try XCTUnwrap(plan.groups.first?.segments.first)
        XCTAssertNil(segment.hrZone)
        XCTAssertEqual(segment.durationSeconds, 60)
    }

    /// One unusable row must not cost the user the rest of the plan.
    func testTargetlessSegmentIsDroppedNotFatal() throws {
        let plan = try decodePlan(
            """
            {"version":1,"groups":[{"repeatCount":1,"segments":[
              {"kind":"warmUp","durationSeconds":300},
              {"kind":"work"},
              {"kind":"coolDown","durationSeconds":300}]}]}
            """)
        XCTAssertEqual(plan.groups.first?.segments.count, 2)
        XCTAssertEqual(
            plan.expandedSegments().map(\.segment.kind), [.warmUp, .coolDown])
    }

    func testGroupWithOnlyBadSegmentsIsDropped() throws {
        let plan = try decodePlan(
            """
            {"version":1,"groups":[
              {"repeatCount":1,"segments":[{"kind":"work"}]},
              {"repeatCount":1,"segments":[{"kind":"work","durationSeconds":60}]}]}
            """)
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.expandedCount, 1)
    }

    func testOutOfRangeRepeatCountIsClampedOnDecode() throws {
        let high = try decodePlan(
            """
            {"version":1,"groups":[{"repeatCount":999,"segments":[
              {"kind":"work","durationSeconds":60}]}]}
            """)
        XCTAssertEqual(
            high.groups.first?.repeatCount, CardioPlanLimits.maxRepeatCount)

        let low = try decodePlan(
            """
            {"version":1,"groups":[{"repeatCount":0,"segments":[
              {"kind":"work","durationSeconds":60}]}]}
            """)
        XCTAssertEqual(low.groups.first?.repeatCount, 1)
    }

    /// An oversized payload yields a smaller valid plan, never an exception the
    /// caller has to have a fallback for.
    func testOversizedPayloadIsTruncatedOnDecode() throws {
        let segmentJSON = #"{"kind":"work","durationSeconds":60}"#
        let group =
            "{\"repeatCount\":20,\"segments\":[\(segmentJSON),\(segmentJSON)]}"
        let plan = try decodePlan(
            "{\"version\":1,\"groups\":[\(group),\(group),\(group)]}")

        XCTAssertLessThanOrEqual(
            plan.expandedCount, CardioPlanLimits.maxExpandedSegments)
        XCTAssertEqual(plan.groups.count, 1, "later groups drop once full")
    }

    /// Truncation keeps a **prefix**: once a group does not fit, decoding stops
    /// rather than skipping ahead to a smaller one. A plan that kept the
    /// cool-down but dropped the work block would silently change what the
    /// session means.
    func testTruncationKeepsAPrefixRatherThanTheBestFit() throws {
        let segmentJSON = #"{"kind":"work","durationSeconds":60}"#
        let bigGroup =
            "{\"repeatCount\":20,\"segments\":[\(segmentJSON),\(segmentJSON),\(segmentJSON),\(segmentJSON)]}"
        let smallGroup =
            "{\"repeatCount\":1,\"segments\":[{\"kind\":\"coolDown\",\"durationSeconds\":300}]}"

        // 80 expanded in the first group alone: it cannot fit, so nothing after
        // it is taken either.
        let plan = try decodePlan(
            "{\"version\":1,\"groups\":[\(bigGroup),\(smallGroup)]}")

        XCTAssertTrue(
            plan.isEmpty,
            "the oversized group stops decoding; the trailing cool-down is not "
                + "promoted into its place")
    }

    /// A payload from before a field existed still reads.
    func testMissingVersionAndFieldsDecodeWithDefaults() throws {
        let plan = try decodePlan(
            """
            {"groups":[{"segments":[{"kind":"work","durationSeconds":60}]}]}
            """)
        XCTAssertEqual(plan.version, CardioSegmentPlan.currentVersion)
        XCTAssertEqual(plan.groups.first?.repeatCount, 1)
        XCTAssertNotNil(plan.groups.first?.segments.first?.id)
    }

    func testEmptyGroupsArrayDecodesAsEmptyPlan() throws {
        XCTAssertTrue(try decodePlan(#"{"version":1,"groups":[]}"#).isEmpty)
    }

    /// A future payload carrying fields this build has never seen decodes
    /// cleanly, ignoring them.
    func testUnknownFieldsAreIgnored() throws {
        let plan = try decodePlan(
            """
            {"version":99,"groups":[{"repeatCount":1,"targetPace":270,
              "segments":[{"kind":"work","durationSeconds":60,"cadence":90}]}]}
            """)
        XCTAssertEqual(plan.expandedCount, 1)
        XCTAssertEqual(plan.version, 99)
    }

    // MARK: - 7. Summary text

    func testSegmentSummaryListsTargetsInAFixedOrder() throws {
        let s = try segment(
            .work, duration: 1_200, distance: 5_000, incline: 1,
            resistance: 8, hrZone: .z3)
        XCTAssertEqual(
            s.summary(distanceUnit: .kilometers),
            "Work · 20m · 5 km · 1% · L8 · Z3")
    }

    func testSegmentSummaryShowsDecline() throws {
        XCTAssertEqual(
            try segment(.work, duration: 600, incline: -3)
                .summary(distanceUnit: .kilometers),
            "Work · 10m · -3%")
    }

    func testShortSummaryUsesTheLeadingTarget() throws {
        XCTAssertEqual(
            try segment(.work, duration: 60).shortSummary(distanceUnit: .kilometers),
            "1m work")
        XCTAssertEqual(
            try segment(.coolDown, distance: 1_000)
                .shortSummary(distanceUnit: .kilometers),
            "1 km cool-down")
    }

    func testSimplePlanSummaryIsStable() throws {
        let plan = try simplePlan()
        XCTAssertEqual(
            plan.summary(distanceUnit: .kilometers), "3 segments · 30m")
        XCTAssertEqual(
            plan.structureSummary(distanceUnit: .kilometers),
            "5m warm-up · 20m work · 5m cool-down")
    }

    func testIntervalPlanSummaryIsStable() throws {
        let plan = try intervalPlan()
        XCTAssertEqual(
            plan.summary(distanceUnit: .kilometers), "10 segments · 15m",
            "the count is what the athlete performs, not what the author typed")
        XCTAssertEqual(
            plan.structureSummary(distanceUnit: .kilometers),
            "5 × (1m work / 2m recovery)")
    }

    func testSummaryCountsSingleSegmentInSingular() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [segment(.work, duration: 600)])
        ])
        XCTAssertEqual(plan.summary(distanceUnit: .kilometers), "1 segment · 10m")
    }

    func testSummaryUsesKilometresWhenAsked() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.work, duration: 1_500, distance: 5_000)
            ])
        ])
        XCTAssertEqual(
            plan.summary(distanceUnit: .kilometers), "1 segment · 25m · 5 km")
    }

    func testSummaryUsesMilesWhenAsked() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.work, duration: 1_500, distance: 8_046.72)
            ])
        ])
        XCTAssertEqual(
            plan.summary(distanceUnit: .miles), "1 segment · 25m · 5 mi")
    }

    /// The same stored plan reads in whichever unit the caller asks for; the
    /// meters never move.
    func testTheSamePlanRendersInBothUnits() throws {
        let plan = try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [segment(.work, distance: 5_000)])
        ])
        XCTAssertEqual(plan.summary(distanceUnit: .kilometers), "1 segment · 5 km")
        XCTAssertEqual(plan.summary(distanceUnit: .miles), "1 segment · 3.11 mi")
        XCTAssertEqual(plan.totalDistanceMeters, 5_000)
    }

    func testEmptyPlanSummariesAreSafe() throws {
        XCTAssertEqual(
            CardioSegmentPlan.empty.summary(distanceUnit: .kilometers),
            "No segments")
        XCTAssertEqual(
            CardioSegmentPlan.empty.structureSummary(distanceUnit: .miles),
            "No segments")
    }

    /// A decoded plan that lost every row still summarizes rather than crashing.
    func testRepairedEmptyPlanSummarizesSafely() throws {
        let plan = try decodePlan(
            """
            {"version":1,"groups":[{"repeatCount":1,"segments":[{"kind":"work"}]}]}
            """)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.summary(distanceUnit: .kilometers), "No segments")
        XCTAssertTrue(plan.expandedSegments().isEmpty)
    }

    // MARK: - 8. Kind

    func testKindRawValuesAreStable() {
        XCTAssertEqual(
            CardioSegmentKind.allCases.map(\.rawValue),
            ["warmUp", "work", "recovery", "coolDown"],
            "raw values are persisted — renaming one silently rewrites history")
    }

    func testKindTolerantLookup() {
        XCTAssertEqual(CardioSegmentKind.from(raw: " warmUp "), .warmUp)
        XCTAssertNil(CardioSegmentKind.from(raw: "sprint"))
        XCTAssertNil(CardioSegmentKind.from(raw: nil))
    }
}

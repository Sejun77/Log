import XCTest

@testable import Log

/// Structured Cardio Slice 12D — the checklist tick store.
///
/// Ticks are **session progress, not a measurement**. That single product rule
/// produces everything asserted here:
///
///  * they persist across Save & Exit and a cold resume, because losing your
///    place mid-interval is the problem the checklist exists to solve;
///  * they live in their own per-workout `UserDefaults` key, so nothing can
///    write them into a `SetLog`, a `WorkoutItem`, or History;
///  * they are keyed by `ResolvedCardioSegment.id` (`"<uuid>#<round>"`), so
///    round 1 and round 2 of a repeat are independent and a reordered plan
///    carries a tick with its segment;
///  * an id that no longer names a segment is **ignored**, never repaired into
///    something else.
final class CardioSegmentCheckStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore(
        workoutID: UUID = UUID()
    ) -> CardioSegmentCheckStore {
        CardioSegmentCheckStore(workoutID: workoutID, defaults: defaults)
    }

    // MARK: - Fixtures

    private func segment(
        _ kind: CardioSegmentKind, duration: Int
    ) throws -> CardioSegment {
        try CardioSegment(kind: kind, durationSeconds: duration)
    }

    /// 5 min warm-up → 20 min work → 5 min cool-down.
    private func flatPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.warmUp, duration: 300),
                segment(.work, duration: 1_200),
                segment(.coolDown, duration: 300),
            ])
        ])
    }

    /// 3 × (1 min work / 2 min recovery).
    private func repeatedPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [
                    segment(.work, duration: 60),
                    segment(.recovery, duration: 120),
                ],
                repeatCount: 3)
        ])
    }

    // MARK: - 1. Round trip

    func testSavedTicksLoadBack() throws {
        let store = makeStore()
        let slot = UUID()
        let plan = try flatPlan()
        let ids = plan.expandedSegments().map(\.id)

        store.save(slotID: slot, checked: [ids[0], ids[2]])

        XCTAssertEqual(store.load(slotID: slot), [ids[0], ids[2]])
        XCTAssertEqual(
            store.checked(slotID: slot, in: plan), [ids[0], ids[2]])
    }

    /// Save & Exit → Resume: a *new* store over the same workout id reads what
    /// the previous one wrote, because the state lives in `UserDefaults` rather
    /// than in the view.
    func testTicksSurviveANewStoreForTheSameWorkout() throws {
        let workoutID = UUID()
        let slot = UUID()
        let plan = try flatPlan()
        let ids = plan.expandedSegments().map(\.id)

        makeStore(workoutID: workoutID)
            .save(slotID: slot, checked: [ids[0], ids[1]])

        let afterResume = makeStore(workoutID: workoutID)
        XCTAssertEqual(
            afterResume.checked(slotID: slot, in: plan), [ids[0], ids[1]])
        XCTAssertFalse(
            afterResume.checked(slotID: slot, in: plan).contains(ids[2]),
            "the cool-down was never ticked and must not come back ticked")
    }

    func testTicksAreScopedToOneWorkout() throws {
        let slot = UUID()
        let ids = try flatPlan().expandedSegments().map(\.id)

        makeStore(workoutID: UUID()).save(slotID: slot, checked: [ids[0]])

        XCTAssertTrue(
            makeStore(workoutID: UUID()).load(slotID: slot).isEmpty,
            "a different workout starts with an empty checklist")
    }

    func testTicksAreScopedToOneSlot() throws {
        let store = makeStore()
        let slotA = UUID()
        let slotB = UUID()
        let ids = try flatPlan().expandedSegments().map(\.id)

        store.save(slotID: slotA, checked: [ids[0]])

        XCTAssertTrue(
            store.load(slotID: slotB).isEmpty,
            "clearing or ticking one slot cannot leak into another")
    }

    // MARK: - 2. Independent segments

    func testTickingOneSegmentLeavesTheOthersAlone() throws {
        let store = makeStore()
        let slot = UUID()
        let plan = try flatPlan()
        let ids = plan.expandedSegments().map(\.id)

        store.save(slotID: slot, checked: [ids[1]])

        let checked = store.checked(slotID: slot, in: plan)
        XCTAssertEqual(checked, [ids[1]])
        XCTAssertFalse(checked.contains(ids[0]))
        XCTAssertFalse(checked.contains(ids[2]))
    }

    /// The whole reason `ResolvedCardioSegment.id` carries the round: ticking
    /// the first work interval must not tick the second.
    func testTickingRoundOneDoesNotTickRoundTwo() throws {
        let store = makeStore()
        let slot = UUID()
        let plan = try repeatedPlan()
        let expanded = plan.expandedSegments()
        let round1Work = try XCTUnwrap(
            expanded.first { $0.segment.kind == .work && $0.round == 1 })
        let round2Work = try XCTUnwrap(
            expanded.first { $0.segment.kind == .work && $0.round == 2 })

        store.save(slotID: slot, checked: [round1Work.id])

        let checked = store.checked(slotID: slot, in: plan)
        XCTAssertTrue(checked.contains(round1Work.id))
        XCTAssertFalse(checked.contains(round2Work.id))
        XCTAssertEqual(
            round1Work.segment.id, round2Work.segment.id,
            "the same authored segment — only the round distinguishes them")
    }

    // MARK: - 3. Orphans

    func testAnIDThatIsNotInThePlanIsIgnored() throws {
        let store = makeStore()
        let slot = UUID()
        let plan = try flatPlan()
        let ids = plan.expandedSegments().map(\.id)

        store.save(
            slotID: slot, checked: [ids[0], "\(UUID().uuidString)#1"])

        XCTAssertEqual(
            store.checked(slotID: slot, in: plan), [ids[0]],
            "an id from an edited or replaced plan simply stops rendering")
    }

    /// The exact "the plan changed under a resume" case: ticks written against
    /// the flat plan name nothing in the repeated one.
    func testEveryTickIsDroppedWhenThePlanIsReplaced() throws {
        let store = makeStore()
        let slot = UUID()
        let old = try flatPlan()
        store.save(
            slotID: slot,
            checked: Set(old.expandedSegments().map(\.id)))

        XCTAssertTrue(
            store.checked(slotID: slot, in: try repeatedPlan()).isEmpty)
    }

    func testNoPlanMeansNothingIsChecked() throws {
        let store = makeStore()
        let slot = UUID()
        store.save(
            slotID: slot,
            checked: Set(try flatPlan().expandedSegments().map(\.id)))

        XCTAssertTrue(
            store.checked(slotID: slot, in: nil).isEmpty,
            "a slot switched onto a strength exercise shows no checklist")
        XCTAssertTrue(store.checked(slotID: slot, in: .empty).isEmpty)
    }

    // MARK: - 4. Clearing

    func testClearDropsOneSlotOnly() throws {
        let store = makeStore()
        let slotA = UUID()
        let slotB = UUID()
        let ids = try flatPlan().expandedSegments().map(\.id)
        store.save(slotID: slotA, checked: [ids[0]])
        store.save(slotID: slotB, checked: [ids[1]])

        store.clear(slotID: slotA)

        XCTAssertTrue(store.load(slotID: slotA).isEmpty)
        XCTAssertEqual(store.load(slotID: slotB), [ids[1]])
    }

    func testSavingAnEmptySetRemovesTheSlotEntry() throws {
        let store = makeStore()
        let slot = UUID()
        store.save(
            slotID: slot, checked: [try flatPlan().expandedSegments()[0].id])

        store.save(slotID: slot, checked: [])

        XCTAssertTrue(store.load(slotID: slot).isEmpty)
        XCTAssertTrue(
            store.loadAll().isEmpty,
            "'nothing ticked' and 'never ticked' persist identically")
    }

    /// Workout finish: nothing may survive, because a tick was never a result.
    func testClearAllRemovesEverything() throws {
        let store = makeStore()
        let ids = try flatPlan().expandedSegments().map(\.id)
        store.save(slotID: UUID(), checked: [ids[0]])
        store.save(slotID: UUID(), checked: [ids[1]])

        store.clearAll()

        XCTAssertTrue(store.loadAll().isEmpty)
    }

    // MARK: - 5. loadAll (the resume read)

    func testLoadAllReturnsEverySlotWithTicks() throws {
        let store = makeStore()
        let slotA = UUID()
        let slotB = UUID()
        let ids = try flatPlan().expandedSegments().map(\.id)
        store.save(slotID: slotA, checked: [ids[0]])
        store.save(slotID: slotB, checked: [ids[1], ids[2]])

        let all = store.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[slotA], [ids[0]])
        XCTAssertEqual(all[slotB], [ids[1], ids[2]])
    }

    // MARK: - 6. Corruption tolerance

    func testAWrongTypedTopLevelValueReadsAsNothingTicked() {
        let workoutID = UUID()
        defaults.set(
            "not a dictionary",
            forKey: "cardioSegmentChecks_\(workoutID.uuidString)")
        let store = makeStore(workoutID: workoutID)

        XCTAssertTrue(store.load(slotID: UUID()).isEmpty)
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testANonUUIDKeyIsSkippedByLoadAll() {
        let workoutID = UUID()
        defaults.set(
            ["not-a-uuid": ["abc#1"]],
            forKey: "cardioSegmentChecks_\(workoutID.uuidString)")

        XCTAssertTrue(makeStore(workoutID: workoutID).loadAll().isEmpty)
    }

    // MARK: - 7. Storage isolation

    /// The guarantee that matters most: ticks live under their own key and
    /// cannot collide with the working-set drafts. Nothing in this store can
    /// reach a `SetLog` — there is no code path from here to one.
    func testTicksDoNotShareStorageWithParentDrafts() throws {
        let workoutID = UUID()
        let slot = UUID()
        let drafts = ParentDraftStore(workoutID: workoutID, defaults: defaults)
        let checks = makeStore(workoutID: workoutID)

        drafts.persist(slotID: slot, setIndex: 0, field: .duration, value: "1800")
        checks.save(
            slotID: slot, checked: [try flatPlan().expandedSegments()[0].id])

        checks.clearAll()

        XCTAssertEqual(
            drafts.load(slotID: slot, setIndex: 0)?.duration, "1800",
            "clearing ticks must not touch the logged/entered values")
    }

    func testClearingParentDraftsLeavesTicksIntact() throws {
        let workoutID = UUID()
        let slot = UUID()
        let drafts = ParentDraftStore(workoutID: workoutID, defaults: defaults)
        let checks = makeStore(workoutID: workoutID)
        let id = try flatPlan().expandedSegments()[0].id

        drafts.persist(slotID: slot, setIndex: 0, field: .duration, value: "1800")
        checks.save(slotID: slot, checked: [id])

        // Logging a set discards its draft — the ticks are unrelated state.
        drafts.clear(slotID: slot, setIndex: 0)

        XCTAssertEqual(checks.load(slotID: slot), [id])
    }
}

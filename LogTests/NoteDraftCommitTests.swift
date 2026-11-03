import SwiftData
import XCTest

@testable import Log

/// Routine Plan Notes and the Alternative Exercise note edit a local draft and
/// reach the model only at a commit boundary, normalized there and not before.
@MainActor
final class NoteDraftCommitTests: SwiftDataTestHarness {

    private let trailing = "abc\n\n\n"

    // MARK: - Fixtures

    private func makeSlot(notes: String? = nil) -> RoutineExercise {
        let exercise = Exercise(name: "Bench")
        context.insert(exercise)
        let slot = RoutineExercise(exercise: exercise, order: 0, setTemplates: [])
        slot.templateNotes = notes
        context.insert(slot)
        try? context.save()
        return slot
    }

    private func makePrescription(
        alternativeNames: [String] = ["Dips"]
    ) throws -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        for name in alternativeNames {
            try XCTUnwrap(
                SlotAlternativeAuthoring.append(
                    exerciseID: UUID(),
                    exerciseName: name,
                    prescription: AlternativePrescriptionPayload(),
                    mainExerciseID: nil,
                    to: p))
        }
        try context.save()
        return p
    }

    private func commitNote(
        _ note: String,
        isEnabled: Bool = true,
        id: UUID,
        into p: SlotPrescription
    ) -> Bool {
        AlternativeDraftCommit.commit(
            draft: nil,
            alternativeID: id,
            isEnabled: isEnabled,
            note: note,
            into: p,
            context: context)
    }

    // MARK: - Routine Plan Notes

    func testPlanNotesDraftDoesNotTouchModelUntilCommit() {
        let slot = makeSlot(notes: "old")
        let draft = TextDraftController("old")

        for text in ["olde", "older", "older\n"] { draft.stage(text) }

        XCTAssertEqual(slot.templateNotes, "old")
        XCTAssertFalse(context.hasChanges)
    }

    func testPlanNotesCommitWritesOnceAndDropsTrailingBlankLines() {
        let slot = makeSlot()
        let draft = TextDraftController("")
        draft.stage(trailing)

        XCTAssertTrue(SlotNotesDraftCommit.commit(draft, to: slot))
        XCTAssertFalse(SlotNotesDraftCommit.commit(draft, to: slot))

        XCTAssertEqual(draft.commitCount, 1)
        XCTAssertEqual(slot.templateNotes, "abc")
        XCTAssertFalse(context.hasChanges, "the commit saves")
    }

    func testPlanNotesOnlyAddingBlankLinesWritesNothing() {
        let slot = makeSlot(notes: "abc")
        let draft = TextDraftController("abc")
        draft.stage(trailing)

        SlotNotesDraftCommit.commit(draft, to: slot)

        XCTAssertEqual(slot.templateNotes, "abc")
        XCTAssertFalse(context.hasChanges)
    }

    func testPlanNotesNoOpCommitLeavesContextClean() {
        let slot = makeSlot(notes: "same")
        let draft = TextDraftController("same")

        XCTAssertFalse(SlotNotesDraftCommit.commit(draft, to: slot))
        XCTAssertFalse(context.hasChanges)
    }

    func testPlanNotesClearingStoresNil() {
        let slot = makeSlot(notes: "old")
        let draft = TextDraftController("old")
        draft.stage(" \n\n ")

        XCTAssertTrue(SlotNotesDraftCommit.commit(draft, to: slot))
        XCTAssertNil(slot.templateNotes)
    }

    func testPlanNotesDeletedSlotIsNotWritten() {
        let slot = makeSlot(notes: "old")
        let draft = TextDraftController("old")
        draft.stage("new")
        context.delete(slot)

        XCTAssertFalse(SlotNotesDraftCommit.commit(draft, to: slot))
    }

    func testPlanNotesPendingEditSurvivesStoredRefresh() {
        let draft = TextDraftController("old")
        draft.stage("typing")

        draft.seed(from: "changed elsewhere")

        XCTAssertEqual(draft.text, "typing")
    }

    // MARK: - Alternative Exercise note

    func testAlternativeNoteDraftDoesNotTouchModelUntilCommit() throws {
        let p = try makePrescription()
        let id = try XCTUnwrap(p.slotAlternatives.first).id
        let written = p.alternativesData
        let draft = TextDraftController("")

        for text in ["a", "ab", "ab\n"] { draft.stage(text) }

        XCTAssertEqual(p.alternativesData, written)
        XCTAssertFalse(context.hasChanges)

        XCTAssertTrue(commitNote(draft.text, id: id, into: p))
        XCTAssertEqual(p.slotAlternatives.first?.note, "ab")
    }

    func testAlternativeNoteDropsTrailingBlankLinesThroughTheColumn() throws {
        let p = try makePrescription()
        let id = try XCTUnwrap(p.slotAlternatives.first).id

        XCTAssertTrue(commitNote(trailing, id: id, into: p))

        let decoded = SlotAlternatives.decode(from: p.alternativesData)
        XCTAssertEqual(decoded.first?.note, "abc")
    }

    func testAlternativeNoteKeepsLeadingAndInternalBlankLines() throws {
        let p = try makePrescription()
        let id = try XCTUnwrap(p.slotAlternatives.first).id

        XCTAssertTrue(commitNote("\n a\n\nb \n\n", id: id, into: p))

        XCTAssertEqual(p.slotAlternatives.first?.note, "\n a\n\nb ")
    }

    func testAlternativeBlankNoteStillNormalizesToNil() throws {
        let p = try makePrescription()
        let id = try XCTUnwrap(p.slotAlternatives.first).id
        XCTAssertTrue(commitNote("note", id: id, into: p))

        XCTAssertTrue(commitNote(" \n\n ", id: id, into: p))

        XCTAssertNil(p.slotAlternatives.first?.note)
    }

    func testAlternativeRepeatedCommitWritesOnce() throws {
        let p = try makePrescription()
        let id = try XCTUnwrap(p.slotAlternatives.first).id
        XCTAssertTrue(commitNote("abc", id: id, into: p))
        let written = p.alternativesData
        XCTAssertFalse(context.hasChanges)

        XCTAssertTrue(commitNote("abc", id: id, into: p))
        // Only adds blank lines, so it normalizes to what is already stored.
        XCTAssertTrue(commitNote(trailing, id: id, into: p))

        XCTAssertFalse(context.hasChanges, "an unchanged commit dirties nothing")
        XCTAssertEqual(p.alternativesData, written)
    }

    func testAlternativeNoteCommitLeavesOrderSiblingsAndIdentityAlone() throws {
        let p = try makePrescription(alternativeNames: ["Dips", "Fly", "Press"])
        let before = p.slotAlternatives
        let target = before[1]

        XCTAssertTrue(
            commitNote(trailing, isEnabled: false, id: target.id, into: p))

        let after = p.slotAlternatives
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.order), [0, 1, 2])
        XCTAssertEqual(after[0], before[0])
        XCTAssertEqual(after[2], before[2])
        XCTAssertEqual(after[1].exerciseID, target.exerciseID)
        XCTAssertEqual(after[1].note, "abc")
        XCTAssertFalse(after[1].isEnabled)
    }

    func testAlternativeUnknownIDWritesNothing() throws {
        let p = try makePrescription()
        let written = p.alternativesData

        XCTAssertFalse(commitNote("x", id: UUID(), into: p))

        XCTAssertEqual(p.alternativesData, written)
    }

    // MARK: - Plan notes on an alternative

    func testAlternativePlanNotesCommitDropsTrailingBlankLines() throws {
        let store = try AlternativeDraftStore(
            exerciseName: "Dips",
            trackingMode: .strength,
            equipmentType: nil,
            includesBodyweightInLoad: false,
            payload: AlternativePrescriptionPayload())
        let draft = TextDraftController("")
        draft.stage(trailing)

        SlotNotesDraftCommit.commit(draft, to: store.slot)

        XCTAssertEqual(store.payload().slotNotes, "abc")
    }

    func testAlternativePlanNotesLoadUnchanged() throws {
        var payload = AlternativePrescriptionPayload()
        payload.slotNotes = trailing

        let store = try AlternativeDraftStore(
            exerciseName: "Dips",
            trackingMode: .strength,
            equipmentType: nil,
            includesBodyweightInLoad: false,
            payload: payload)

        XCTAssertEqual(store.slot.templateNotes, trailing)
    }

    // MARK: - Loading does not normalize

    func testAlternativeNoteLoadsUnchangedAndUntouchedCommitWritesNothing() throws {
        let p = try makePrescription()
        var rows = p.slotAlternatives
        rows[0].note = trailing
        p.setSlotAlternatives(rows)
        try context.save()
        let id = rows[0].id
        let written = p.alternativesData

        XCTAssertEqual(p.slotAlternatives.first?.note, trailing)

        XCTAssertTrue(commitNote(trailing, id: id, into: p))
        XCTAssertEqual(p.alternativesData, written)
        XCTAssertFalse(context.hasChanges)

        XCTAssertTrue(commitNote("abc\n\nd\n", id: id, into: p))
        XCTAssertEqual(p.slotAlternatives.first?.note, "abc\n\nd")
    }

    func testCardioSegmentNoteLoadsUnchangedAndAuthoringNormalizes() throws {
        let json = #"{"kind":"work","durationSeconds":60,"note":"abc\n\n\n"}"#
        let loaded = try JSONDecoder().decode(
            CardioSegment.self, from: Data(json.utf8))
        XCTAssertEqual(loaded.note, trailing)

        let authored = try CardioSegment(
            kind: .warmUp, durationSeconds: 60, note: "  abc\n\n")
        XCTAssertEqual(authored.note, "  abc")
    }

    func testCardioSegmentBlankNoteIsNilOnLoadAndAuthoring() throws {
        let json = #"{"kind":"work","durationSeconds":60,"note":" \n "}"#
        let loaded = try JSONDecoder().decode(
            CardioSegment.self, from: Data(json.utf8))
        XCTAssertNil(loaded.note)
        let authored = try CardioSegment(
            kind: .warmUp, durationSeconds: 60, note: " \n ")
        XCTAssertNil(authored.note)
    }

    func testSessionNotesCommitDropsTrailingBlankLines() {
        let workout = Workout(items: [])
        XCTAssertTrue(applySessionNotesCommit(trailing, to: workout))
        XCTAssertEqual(workout.notes, "abc")
    }

    func testBlankPlanNotesOnAlternativeNormalizeToNil() {
        var payload = AlternativePrescriptionPayload()
        payload.slotNotes = " \n "

        XCTAssertNil(payload.normalized().slotNotes)
    }
}

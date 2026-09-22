import SwiftData
import XCTest

@testable import Log

/// End-to-end coverage for the active workout's Session Notes draft: the
/// commit rule itself, and the two orderings — Save & Exit and Finish — where
/// the previous implementation could lose the last thing typed.
///
/// What went wrong before: typing only ever reached `Workout.notes` from
/// `.onDisappear`, which runs *after* the button has already called
/// `WorkoutLifecycleService.saveAndExit` / `.finish`, and that write did not
/// save the context. `ActiveWorkoutView` now commits before either service
/// call, and the commit saves. The sequences below are those call orders.
@MainActor
final class SessionNotesCommitTests: SwiftDataTestHarness {

    @discardableResult
    private func makeActiveWorkout(notes: String? = nil) -> Workout {
        let w = Workout(items: [])
        w.notes = notes
        context.insert(w)
        try? context.save()
        return w
    }

    private func reload(_ id: UUID) throws -> Workout? {
        try context.fetch(
            FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
        ).first
    }

    // MARK: - The commit rule

    func testCommitStoresTypedText() {
        let w = makeActiveWorkout()
        XCTAssertTrue(applySessionNotesCommit("left knee felt off", to: w))
        XCTAssertEqual(w.notes, "left knee felt off")
    }

    func testCommitOfEmptyStringClearsStoredNote() {
        let w = makeActiveWorkout(notes: "old note")
        XCTAssertTrue(applySessionNotesCommit("", to: w))
        XCTAssertNil(w.notes)
    }

    func testCommitOfWhitespaceOnlyClearsStoredNote() {
        let w = makeActiveWorkout(notes: "old note")
        XCTAssertTrue(applySessionNotesCommit("   \n  ", to: w))
        XCTAssertNil(w.notes)
    }

    func testCommitOfUnchangedTextDoesNotReportAChange() {
        let w = makeActiveWorkout(notes: "same")
        XCTAssertFalse(
            applySessionNotesCommit("same", to: w),
            "A no-op commit must not dirty the model or force a save.")
    }

    func testCommitPreservesUntrimmedUserText() {
        let w = makeActiveWorkout()
        applySessionNotesCommit("  spacing matters  ", to: w)
        XCTAssertEqual(w.notes, "  spacing matters  ")
    }

    // MARK: - Save & Exit

    /// Requirement: the draft is committed *before* Save & Exit persists, and
    /// survives a re-fetch (i.e. it was actually saved, not just left dirty in
    /// the context).
    func testSaveAndExitPersistsPendingSessionNotes() throws {
        let w = makeActiveWorkout()
        let id = w.id

        let draft = TextDraftController()
        draft.seed(from: w.notes ?? "")
        for text in ["f", "fi", "fin", "fina", "final"] { draft.stage(text) }

        // The exact order `ActiveWorkoutView`'s Save & Exit button now uses.
        draft.commit { applySessionNotesCommit($0, to: w) }
        WorkoutLifecycleService.saveAndExit(in: context)

        XCTAssertEqual(try reload(id)?.notes, "final")
        XCTAssertNil(
            try reload(id)?.completedAt,
            "Save & Exit stays resumable.")
    }

    /// Resume: the committed note is what a rebuilt session reads back.
    func testResumeAfterSaveAndExitRestoresCommittedNotes() throws {
        let w = makeActiveWorkout()
        let id = w.id

        let draft = TextDraftController()
        draft.seed(from: w.notes ?? "")
        draft.stage("half way through")
        draft.commit { applySessionNotesCommit($0, to: w) }
        WorkoutLifecycleService.saveAndExit(in: context)

        // Re-entering seeds a fresh editor from the stored value.
        let resumed = try XCTUnwrap(reload(id))
        let reopened = TextDraftController()
        reopened.seed(from: resumed.notes ?? "")

        XCTAssertEqual(reopened.text, "half way through")
        XCTAssertFalse(
            reopened.isDirty,
            "A freshly seeded editor has nothing pending to write back.")
    }

    // MARK: - Finish

    func testFinishPersistsPendingSessionNotes() throws {
        let w = makeActiveWorkout()
        let id = w.id
        let appState = AppState()
        context.insert(appState)

        let draft = TextDraftController()
        draft.seed(from: w.notes ?? "")
        draft.stage("PR on the top set")

        // The order `finishWorkout` now uses.
        draft.commit { applySessionNotesCommit($0, to: w) }
        WorkoutLifecycleService.finish(
            workout: w, appState: appState, in: context)

        let finished = try XCTUnwrap(reload(id))
        XCTAssertEqual(finished.notes, "PR on the top set")
        XCTAssertNotNil(
            finished.completedAt,
            "The note must be on the record History shows.")
    }

    func testFinishPersistsAClearedSessionNote() throws {
        let w = makeActiveWorkout(notes: "typed earlier, deleted before finish")
        let id = w.id
        let appState = AppState()
        context.insert(appState)

        let draft = TextDraftController()
        draft.seed(from: w.notes ?? "")
        draft.stage("")

        draft.commit { applySessionNotesCommit($0, to: w) }
        WorkoutLifecycleService.finish(
            workout: w, appState: appState, in: context)

        XCTAssertNil(try reload(id)?.notes)
    }

    // MARK: - Not once per character

    /// The performance contract, stated as behavior: a full sentence of typing
    /// reaches SwiftData once, at the commit point — not on each character.
    func testTypingDoesNotWriteToSwiftDataPerCharacter() throws {
        let w = makeActiveWorkout()
        var modelWrites = 0

        let draft = TextDraftController()
        draft.seed(from: w.notes ?? "")

        var typed = ""
        for ch in "shoulder tweaked on set 3, dropped the last set" {
            typed.append(ch)
            draft.stage(typed)
            // Nothing is written mid-sentence.
            XCTAssertEqual(modelWrites, 0)
            XCTAssertNil(w.notes)
        }

        draft.commit { text in
            if applySessionNotesCommit(text, to: w) { modelWrites += 1 }
        }

        XCTAssertEqual(modelWrites, 1)
        XCTAssertEqual(draft.commitCount, 1)
        XCTAssertEqual(w.notes, typed)
    }
}

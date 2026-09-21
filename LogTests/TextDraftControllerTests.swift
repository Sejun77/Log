import XCTest

@testable import Log

/// Contract for the shared text-draft abstraction behind Session Notes and the
/// Edit Plan slot notes.
///
/// The point of the type is that a keystroke is cheap and a *write* is rare, so
/// most of what is pinned here is about when the persist closure does and does
/// not run. Nothing here is timing-based.
@MainActor
final class TextDraftControllerTests: XCTestCase {

    // MARK: - Initialization / seeding

    func testInitializesFromStoredText() {
        let c = TextDraftController("felt strong today")
        XCTAssertEqual(c.text, "felt strong today")
        XCTAssertEqual(c.committedText, "felt strong today")
        XCTAssertFalse(c.isDirty)
    }

    func testSeedAdoptsStoredTextWhileClean() {
        let c = TextDraftController()
        c.seed(from: "restored from Workout.notes")
        XCTAssertEqual(c.text, "restored from Workout.notes")
        XCTAssertFalse(c.isDirty)
    }

    // MARK: - Typing does not persist

    func testTypingChangesDraftWithoutPersisting() {
        let c = TextDraftController("start")
        var persisted: [String] = []

        for text in ["s", "sq", "squ", "squa", "squat"] {
            c.stage(text)
            // Nothing writes between keystrokes.
            XCTAssertEqual(persisted, [])
        }

        XCTAssertEqual(c.text, "squat")
        XCTAssertEqual(
            c.committedText, "start",
            "Staging must not move the committed value.")
        XCTAssertTrue(c.isDirty)
        XCTAssertEqual(c.commitCount, 0)

        c.commit { persisted.append($0) }
        XCTAssertEqual(persisted, ["squat"])
    }

    /// The regression this whole change exists to prevent: a per-character
    /// persist. Thirty keystrokes, one commit, one write of the final value.
    func testRapidEditsPersistOnlyTheFinalValueOnce() {
        let c = TextDraftController()
        var persisted: [String] = []

        var typed = ""
        for ch in "back felt tight on the third set" {
            typed.append(ch)
            c.stage(typed)
        }
        XCTAssertEqual(persisted.count, 0)

        c.commit { persisted.append($0) }

        XCTAssertEqual(persisted, ["back felt tight on the third set"])
        XCTAssertEqual(
            c.commitCount, 1,
            "One commit for \(typed.count) keystrokes.")
    }

    // MARK: - Commit boundaries

    func testCommitPersistsLatestText() {
        let c = TextDraftController("old")
        var stored = "old"
        c.stage("new")
        XCTAssertTrue(c.commit { stored = $0 })
        XCTAssertEqual(stored, "new")
        XCTAssertFalse(c.isDirty)
    }

    /// Focus loss, disappear, Save & Exit and Finish can all fire for one edit.
    /// Between them they must write once — otherwise every commit point would
    /// dirty the model context and force a redundant save.
    func testRepeatedCommitPointsWriteOnce() {
        let c = TextDraftController("old")
        var writes = 0

        c.stage("edited")
        XCTAssertTrue(c.commit { _ in writes += 1 })   // focus loss
        XCTAssertFalse(c.commit { _ in writes += 1 })  // disappear
        XCTAssertFalse(c.commit { _ in writes += 1 })  // Save & Exit

        XCTAssertEqual(writes, 1)
        XCTAssertEqual(c.commitCount, 1)
    }

    func testCommitIsNoOpWhenNothingWasTyped() {
        let c = TextDraftController("unchanged")
        var writes = 0
        XCTAssertFalse(c.commit { _ in writes += 1 })
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(c.commitCount, 0)
    }

    /// Re-typing the stored value character by character and landing back on it
    /// is not an edit, so it must not write.
    func testCommitIsNoOpWhenDraftReturnsToStoredValue() {
        let c = TextDraftController("abc")
        var writes = 0
        c.stage("ab")
        c.stage("a")
        c.stage("ab")
        c.stage("abc")
        XCTAssertFalse(c.isDirty)
        XCTAssertFalse(c.commit { _ in writes += 1 })
        XCTAssertEqual(writes, 0)
    }

    // MARK: - Clearing

    func testClearingToEmptyStringPersists() {
        let c = TextDraftController("something worth deleting")
        var stored: String? = "something worth deleting"

        c.stage("")
        XCTAssertTrue(c.isDirty, "Clearing a note is a real edit.")
        XCTAssertTrue(c.commit { stored = $0.isEmpty ? nil : $0 })
        XCTAssertNil(stored)
    }

    // MARK: - Isolation

    func testTwoControllersDoNotShareDraftState() {
        let a = TextDraftController("session note")
        let b = TextDraftController("slot note")

        a.stage("session note edited")

        XCTAssertEqual(b.text, "slot note")
        XCTAssertFalse(b.isDirty)
        XCTAssertEqual(a.text, "session note edited")
    }

    // MARK: - Re-seeding vs. external change

    /// A re-appear (or any other re-seed) while an edit is pending must keep
    /// the edit. Losing it here is exactly the "typed and immediately navigated
    /// away" data loss.
    func testSeedDoesNotOverwriteAnActiveDraft() {
        let c = TextDraftController("stored")
        c.stage("user is mid-sentence")

        c.seed(from: "stored")
        XCTAssertEqual(c.text, "user is mid-sentence")

        // Even an externally CHANGED stored value loses to the pending edit.
        c.seed(from: "changed somewhere else")
        XCTAssertEqual(c.text, "user is mid-sentence")
        XCTAssertTrue(c.isDirty)
    }

    /// The other half of the rule: with nothing pending, a newer stored value
    /// must win, so a stale draft cannot be committed back over it.
    func testSeedAdoptsANewerStoredValueWhenDraftIsClean() {
        let c = TextDraftController("stored")
        c.seed(from: "newer value from the model")
        XCTAssertEqual(c.text, "newer value from the model")
        XCTAssertEqual(c.committedText, "newer value from the model")

        var writes: [String] = []
        XCTAssertFalse(c.commit { writes.append($0) })
        XCTAssertEqual(
            writes, [],
            "Adopting a newer stored value must not queue a write back.")
    }

    /// Reopening an editor on a *different* subject (another routine slot) has
    /// to drop the previous subject's text — `seed` would protect it.
    func testResetReplacesAnActiveDraftForANewSubject() {
        let c = TextDraftController("slot A notes")
        c.stage("slot A notes, edited")

        c.reset(to: "slot B notes")

        XCTAssertEqual(c.text, "slot B notes")
        XCTAssertFalse(c.isDirty)
        var writes = 0
        XCTAssertFalse(c.commit { _ in writes += 1 })
        XCTAssertEqual(writes, 0)
    }
}

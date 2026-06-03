import XCTest

@testable import Log

/// Pure tests for the `PartialRange` enum/resolver (Partial Rep Range picker)
/// and how `TechniquePlanSnapshot.setAttachedLabel` renders the resolved
/// partial-range label. The resolver is a pure static function over a
/// `(raw, note)` pair; the snapshot is a plain value type (no `ModelContext`).
final class PartialRangeTests: XCTestCase {

    // MARK: - 1. Resolver — preset raw → display label

    func testPresetRawsResolveToDisplayNames() {
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "lengthenedHalf", note: nil),
            "Lengthened half")
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "shortenedHalf", note: nil),
            "Shortened half")
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "middleRange", note: nil),
            "Middle range")
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "stickingPoint", note: nil),
            "Sticking point")
    }

    func testPresetRawIgnoresAnyStrayNote() {
        // A preset wins over a stale note (e.g. left over from a prior Custom).
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "lengthenedHalf", note: "top half"),
            "Lengthened half")
    }

    // MARK: - 2. Resolver — custom

    func testCustomWithNoteReturnsNote() {
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "custom", note: "bottom half"),
            "bottom half")
    }

    func testCustomWithEmptyNoteReturnsCustom() {
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "custom", note: ""), "Custom")
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "custom", note: nil), "Custom")
    }

    // MARK: - 3. Resolver — Not set / legacy

    func testNilRawWithNoteReturnsLegacyNote() {
        // Legacy rows: nil raw + free-text note still surface the note.
        XCTAssertEqual(
            PartialRange.displayLabel(raw: nil, note: "top half"), "top half")
    }

    func testNilRawWithEmptyNoteReturnsNil() {
        XCTAssertNil(PartialRange.displayLabel(raw: nil, note: nil))
        XCTAssertNil(PartialRange.displayLabel(raw: nil, note: ""))
    }

    // MARK: - 4. Resolver — unknown raw (forward-compat / corrupt data)

    func testUnknownRawWithNoteFallsBackToNote() {
        // An unknown raw (e.g. a value written by a newer build) is treated
        // like "not a known preset" — fall back to the note if present.
        XCTAssertEqual(
            PartialRange.displayLabel(raw: "quantumRange", note: "my note"),
            "my note")
    }

    func testUnknownRawWithoutNoteReturnsNil() {
        XCTAssertNil(PartialRange.displayLabel(raw: "quantumRange", note: nil))
    }

    // MARK: - 5. Snapshot chip label — setAttachedLabel

    private func partialsSnapshot(
        raw: String?, note: String?, reps: Int? = 8
    ) -> TechniquePlanSnapshot {
        TechniquePlanSnapshot(
            order: 0, type: .partialReps,
            dropPercent: nil, dropCount: nil, rounds: nil, restSeconds: nil,
            partialRangeNote: note, partialRangeRaw: raw,
            note: nil, reps: reps,
            appliesToRaw: nil, appliesToSetNumber: nil,
            dropsetEffortRaw: nil, dropsetEffortReps: nil)
    }

    func testSnapshotCarriesPartialRangeRaw() {
        let snap = partialsSnapshot(raw: "middleRange", note: nil)
        XCTAssertEqual(snap.partialRangeRaw, "middleRange")
    }

    func testLabelUsesPresetDisplayName() {
        let snap = partialsSnapshot(raw: "lengthenedHalf", note: nil)
        XCTAssertEqual(snap.setAttachedLabel, "Partials Lengthened half (8)")
    }

    func testLabelUsesCustomNote() {
        let snap = partialsSnapshot(raw: "custom", note: "bottom half")
        XCTAssertEqual(snap.setAttachedLabel, "Partials bottom half (8)")
    }

    func testLabelPreservesLegacyNote() {
        // Legacy row: nil raw, free-text note — label still shows the note.
        let snap = partialsSnapshot(raw: nil, note: "top half")
        XCTAssertEqual(snap.setAttachedLabel, "Partials top half (8)")
    }

    func testLabelNotSetOmitsRangeSegment() {
        let snap = partialsSnapshot(raw: nil, note: nil)
        XCTAssertEqual(snap.setAttachedLabel, "Partials (8)")
    }

    func testLabelNotSetWithoutRepsIsBare() {
        let snap = partialsSnapshot(raw: nil, note: nil, reps: nil)
        XCTAssertEqual(snap.setAttachedLabel, "Partials")
    }
}

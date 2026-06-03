import XCTest

@testable import Log

/// Pins the canonical/default body-part list (`ExerciseDetailView.canonicalBodyParts`).
/// Cleanup 2026-06-03: "Arms" was removed (like "Legs" before it) because the
/// specific buckets (Biceps / Triceps) already cover it and broad overlapping
/// categories muddy per-body-part analytics. These assertions guard against a
/// regression that re-introduces a broad bucket, while confirming the specific
/// arm buckets are retained. Existing exercises whose `bodyPart` is "Arms" are
/// NOT in this list and therefore surface as a preserved legacy/custom value in
/// `BodyPartPicker` — no migration, no silent rewrite (behavior verified by
/// `ExerciseSorterTests.testSectionsLegacyCustomValueGetsOwnOrderedSection`).
final class CanonicalBodyPartsTests: XCTestCase {

    private var canonical: [String] { ExerciseDetailView.canonicalBodyParts }

    func testArmsIsNotCanonical() {
        XCTAssertFalse(
            canonical.contains("Arms"),
            "\"Arms\" must not be a canonical/default body part")
    }

    func testLegsRemainsRemoved() {
        // Regression guard for the earlier "Legs" removal.
        XCTAssertFalse(canonical.contains("Legs"))
    }

    func testSpecificArmBucketsRetained() {
        XCTAssertTrue(canonical.contains("Biceps"))
        XCTAssertTrue(canonical.contains("Triceps"))
    }

    func testCoreCanonicalBucketsPresent() {
        for expected in ["Chest", "Back", "Shoulders", "Quads", "Core"] {
            XCTAssertTrue(
                canonical.contains(expected),
                "expected canonical body part missing: \(expected)")
        }
    }

    func testNoDuplicateCanonicalEntries() {
        XCTAssertEqual(
            canonical.count, Set(canonical).count,
            "canonical body parts should be unique")
    }
}

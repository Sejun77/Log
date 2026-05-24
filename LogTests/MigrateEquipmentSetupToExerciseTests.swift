import SwiftData
import XCTest

@testable import Log

/// Phase 10-D — `BackfillService.migrateEquipmentSetupToExercise(in:)`
/// copies legacy `SlotPrescription.equipment` / `setupNotes` values onto
/// the linked `Exercise.equipmentType` / `setupDefaults` so Phase 10-E
/// can drop the slot fields without losing any user data.
///
/// Production rows are expected to be all-nil on the maintainer's
/// device (no UI write path exists for the slot fields), but the helper
/// must still be defensive, idempotent, and conflict-safe so it can
/// ship as the canonical migration record before the schema drop.
@MainActor
final class MigrateEquipmentSetupToExerciseTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeExercise(
        name: String = "Bench Press",
        equipmentType: String? = nil,
        setupDefaults: String? = nil
    ) -> Exercise {
        let ex = Exercise(
            name: name,
            equipmentType: equipmentType,
            setupDefaults: setupDefaults,
            isCustom: true
        )
        context.insert(ex)
        return ex
    }

    @discardableResult
    private func makeSlot(
        exercise: Exercise?,
        equipment: String? = nil,
        setupNotes: String? = nil,
        slotID: UUID? = nil
    ) -> RoutineExercise {
        let stand = exercise ?? makeExercise(name: "__placeholder")
        let re = RoutineExercise(exercise: stand, order: 0, setTemplates: [])
        context.insert(re)
        let p = SlotPrescription(equipment: equipment, setupNotes: setupNotes)
        context.insert(p)
        re.prescription = p
        if let slotID { re.slotID = slotID }
        try? context.save()
        if exercise == nil { re.exercise = nil }
        return re
    }

    // MARK: - 1. Empty store no-op

    func testEmptyStoreNoOp() {
        // No slots, no exercises. Helper must return cleanly with no
        // side effects.
        BackfillService.migrateEquipmentSetupToExercise(in: context)

        let exercises =
            (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        let slots =
            (try? context.fetch(FetchDescriptor<RoutineExercise>())) ?? []
        XCTAssertEqual(exercises.count, 0)
        XCTAssertEqual(slots.count, 0)
    }

    // MARK: - 2. Migrates equipment to Exercise.equipmentType

    func testMigratesEquipmentToExercise() {
        let ex = makeExercise()
        XCTAssertNil(ex.equipmentType)

        _ = makeSlot(exercise: ex, equipment: "Barbell")

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        XCTAssertEqual(ex.equipmentType, "Barbell")
        // Setup field untouched.
        XCTAssertNil(ex.setupDefaults)
    }

    // MARK: - 3. Migrates setupNotes to Exercise.setupDefaults

    func testMigratesSetupNotesToExercise() {
        let ex = makeExercise()
        XCTAssertNil(ex.setupDefaults)

        _ = makeSlot(exercise: ex, setupNotes: "Bench, narrow grip")

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        XCTAssertEqual(ex.setupDefaults, "Bench, narrow grip")
        // Equipment field untouched.
        XCTAssertNil(ex.equipmentType)
    }

    // MARK: - 4. Migrates equipment and setup independently

    func testMigratesEquipmentAndSetupIndependently() {
        // Two slots reference different Exercises. Slot A carries only
        // equipment; slot B carries only setup. Each lands on the
        // appropriate target field, and neither bleeds into the other.
        let exA = makeExercise(name: "A")
        let exB = makeExercise(name: "B")
        _ = makeSlot(exercise: exA, equipment: "Cable")
        _ = makeSlot(exercise: exB, setupNotes: "Seated, chest up")

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        XCTAssertEqual(exA.equipmentType, "Cable")
        XCTAssertNil(exA.setupDefaults)
        XCTAssertNil(exB.equipmentType)
        XCTAssertEqual(exB.setupDefaults, "Seated, chest up")
    }

    // MARK: - 5. Does not overwrite existing Exercise.equipmentType

    func testDoesNotOverwriteExistingEquipment() {
        // Exercise already has equipmentType (e.g. set via the 10-C
        // editor). The slot value must NOT win — last-writer-wins
        // protection.
        let ex = makeExercise(equipmentType: "Dumbbell")
        _ = makeSlot(exercise: ex, equipment: "Barbell")

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        XCTAssertEqual(ex.equipmentType, "Dumbbell")
    }

    // MARK: - 6. Does not overwrite existing Exercise.setupDefaults

    func testDoesNotOverwriteExistingSetupDefaults() {
        let ex = makeExercise(setupDefaults: "User-edited setup")
        _ = makeSlot(exercise: ex, setupNotes: "Slot setup")

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        XCTAssertEqual(ex.setupDefaults, "User-edited setup")
    }

    // MARK: - 7. Multi-slot for same Exercise: first-non-nil-wins

    func testMultipleSlotsForSameExercise_FirstNonNilWins() {
        // Two slots reference the SAME Exercise with DIFFERENT slot
        // values. The helper sorts by slotID.uuidString ascending and
        // applies first-non-nil-wins, so the lower-uuidString slot
        // determines the winner. We pin specific UUIDs so the test
        // remains deterministic across runs.
        let ex = makeExercise()

        // 0000... sorts strictly before ffff... in uuidString order.
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-fffffffffffe")!

        _ = makeSlot(
            exercise: ex, equipment: "Barbell",
            setupNotes: "Low-ID setup", slotID: lowID
        )
        _ = makeSlot(
            exercise: ex, equipment: "Cable",
            setupNotes: "High-ID setup", slotID: highID
        )

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        // Low-ID slot wins both fields.
        XCTAssertEqual(ex.equipmentType, "Barbell")
        XCTAssertEqual(ex.setupDefaults, "Low-ID setup")
    }

    // MARK: - 8. Nil Exercise skipped safely

    func testNilExerciseSkippedSafely() {
        // Slot with non-nil equipment but detached Exercise. Helper
        // must skip silently — no crash, no side effects.
        let re = makeSlot(
            exercise: nil, equipment: "Barbell",
            setupNotes: "Should not crash"
        )
        XCTAssertNil(re.exercise)

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        // No exercise to write to; the slot prescription is unchanged.
        XCTAssertEqual(re.prescription?.equipment, "Barbell")
        XCTAssertEqual(re.prescription?.setupNotes, "Should not crash")
    }

    // MARK: - 9. Whitespace-only slot values skipped

    func testWhitespaceOnlySlotValuesSkipped() {
        // Whitespace-only slot values are treated as empty (matches the
        // 10-C editor's nil-collapse) and must NOT land on the Exercise.
        let ex = makeExercise()
        _ = makeSlot(
            exercise: ex, equipment: "   ", setupNotes: "\n\t  "
        )

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        XCTAssertNil(ex.equipmentType)
        XCTAssertNil(ex.setupDefaults)
    }

    // MARK: - 10. Idempotent second run

    func testIdempotentSecondRunNoChange() {
        let exA = makeExercise(name: "A")
        let exB = makeExercise(name: "B", equipmentType: "Pre-existing")
        _ = makeSlot(exercise: exA, equipment: "Barbell", setupNotes: "Cue")
        _ = makeSlot(exercise: exB, equipment: "Cable", setupNotes: "Other")

        BackfillService.migrateEquipmentSetupToExercise(in: context)
        let aEqAfter1 = exA.equipmentType
        let aSetupAfter1 = exA.setupDefaults
        let bEqAfter1 = exB.equipmentType
        let bSetupAfter1 = exB.setupDefaults

        BackfillService.migrateEquipmentSetupToExercise(in: context)

        // Byte-equal values after run 2 — proves the helper
        // short-circuits when target fields are already filled (or
        // pre-existing, in B's case).
        XCTAssertEqual(exA.equipmentType, aEqAfter1)
        XCTAssertEqual(exA.setupDefaults, aSetupAfter1)
        XCTAssertEqual(exB.equipmentType, bEqAfter1)
        XCTAssertEqual(exB.setupDefaults, bSetupAfter1)

        // Spot-check the actual values too.
        XCTAssertEqual(exA.equipmentType, "Barbell")
        XCTAssertEqual(exA.setupDefaults, "Cue")
        XCTAssertEqual(exB.equipmentType, "Pre-existing") // never overwritten
        XCTAssertEqual(exB.setupDefaults, "Other")
    }
}

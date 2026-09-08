import SwiftData
import XCTest

@testable import Log

/// Alternative Exercises — the slot's own exercise is not one of its
/// alternatives.
///
/// The manual finding this pins: the routine editor's Add Alternative picker
/// listed the slot's own exercise, and adding it stored a row the switch sheet
/// would then refuse to offer. The rule now lives in one place,
/// `SlotAlternativeEligibility`, and is applied in three layers — the picker,
/// the `append` guard behind it, and the two workout-facing readers
/// (`PreparedAlternatives`, `BlockPrescriptionSummary`).
///
/// Two properties of the rule are load-bearing and each has its own test:
///
///  1. **It compares `exerciseID`, never a name.** Two library rows may share
///     a display name and still be different exercises; one is a perfectly
///     valid alternative for the other.
///  2. **It never deletes.** A row authored before the rule existed (or
///     carried in by import / duplication) survives, is marked in the editor,
///     and is simply not offered.
@MainActor
final class SlotAlternativeEligibilityTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private let benchID = UUID()
    private let machineID = UUID()

    private func prescription() -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        return p
    }

    private func exercise(_ name: String) -> Exercise {
        let e = Exercise(name: name)
        context.insert(e)
        return e
    }

    private func alternative(
        _ name: String,
        exerciseID: UUID,
        order: Int = 0,
        enabled: Bool = true
    ) -> SlotAlternative {
        SlotAlternative(
            order: order, isEnabled: enabled, exerciseID: exerciseID,
            exerciseName: name, prescription: AlternativePrescriptionPayload())
    }

    // ==================================================
    // MARK: - 1. The rule
    // ==================================================

    func testTheSlotsOwnExerciseIsNotEligible() {
        XCTAssertFalse(
            SlotAlternativeEligibility.isEligible(
                exerciseID: benchID, slotExerciseID: benchID))
    }

    func testAnyOtherExerciseIsEligible() {
        XCTAssertTrue(
            SlotAlternativeEligibility.isEligible(
                exerciseID: machineID, slotExerciseID: benchID))
    }

    /// An orphan slot has no exercise to collide with, so nothing is refused.
    func testAnOrphanSlotRefusesNothing() {
        XCTAssertTrue(
            SlotAlternativeEligibility.isEligible(
                exerciseID: benchID, slotExerciseID: nil))
        XCTAssertFalse(
            SlotAlternativeEligibility.isSameAsSlotExercise(
                alternative("Bench Press", exerciseID: benchID),
                slotExerciseID: nil))
    }

    // ==================================================
    // MARK: - 2. The picker filter
    // ==================================================

    /// What `SlotAlternativesEditor.libraryExercises()` does before handing the
    /// library to `ExercisePickerSingle`: the slot's exercise is gone, every
    /// other row survives, and the order is untouched.
    func testTheSlotsOwnExerciseIsFilteredOutOfThePickerList() {
        let bench = exercise("Bench Press")
        let machine = exercise("Machine Chest Press")
        let dumbbell = exercise("Dumbbell Press")

        let selectable = SlotAlternativeEligibility.selectable(
            [bench, dumbbell, machine], slotExerciseID: bench.id, id: \.id)

        XCTAssertEqual(
            selectable.map(\.name), ["Dumbbell Press", "Machine Chest Press"])
    }

    /// Requirement 10 — two library rows can legitimately share a display
    /// name. They are different exercises, so only the slot's own one goes.
    func testASameNamedButDifferentExerciseStaysSelectable() {
        let bench = exercise("Bench Press")
        let twin = exercise("Bench Press")
        XCTAssertNotEqual(bench.id, twin.id)

        let selectable = SlotAlternativeEligibility.selectable(
            [bench, twin], slotExerciseID: bench.id, id: \.id)

        XCTAssertEqual(selectable.map(\.id), [twin.id])
    }

    // ==================================================
    // MARK: - 3. The append guard
    // ==================================================

    /// The defensive half: even with the picker bypassed, the write path
    /// refuses and stores nothing.
    func testAppendRefusesTheSlotsOwnExercise() throws {
        let p = prescription()
        let bench = exercise("Bench Press")

        let added = SlotAlternativeAuthoring.append(
            exerciseID: bench.id,
            exerciseName: bench.name,
            prescription: AlternativeDraftStore.defaultPayload(for: .strength),
            mainExerciseID: bench.id,
            to: p)
        try context.save()

        XCTAssertNil(added, "the slot's own exercise is refused")
        XCTAssertNil(p.alternativesData, "and nothing is written")
        XCTAssertEqual(p.slotAlternatives, [])
    }

    /// Refusing one must not disturb the alternatives already prepared.
    func testARefusedAppendLeavesExistingAlternativesAlone() throws {
        let p = prescription()
        let bench = exercise("Bench Press")
        let machine = exercise("Machine Chest Press")

        let kept = try XCTUnwrap(
            SlotAlternativeAuthoring.append(
                exerciseID: machine.id,
                exerciseName: machine.name,
                prescription: AlternativePrescriptionPayload(sets: 3),
                mainExerciseID: bench.id,
                to: p))
        XCTAssertNil(
            SlotAlternativeAuthoring.append(
                exerciseID: bench.id,
                exerciseName: bench.name,
                prescription: AlternativePrescriptionPayload(),
                mainExerciseID: bench.id,
                to: p))
        try context.save()

        XCTAssertEqual(p.slotAlternatives.map(\.id), [kept.id])
        XCTAssertEqual(p.slotAlternatives.first?.prescription.sets, 3)
    }

    /// Requirement 10 again, at the write path.
    func testAppendAcceptsADifferentExerciseWithTheSameName() throws {
        let p = prescription()
        let bench = exercise("Bench Press")
        let twin = exercise("Bench Press")

        let added = try XCTUnwrap(
            SlotAlternativeAuthoring.append(
                exerciseID: twin.id,
                exerciseName: twin.name,
                prescription: AlternativePrescriptionPayload(),
                mainExerciseID: bench.id,
                to: p))

        XCTAssertEqual(p.slotAlternatives.map(\.id), [added.id])
        XCTAssertEqual(p.slotAlternatives.first?.exerciseID, twin.id)
    }

    /// An orphan slot still adds normally.
    func testAppendWithNoSlotExerciseIsUnrestricted() throws {
        let p = prescription()
        let bench = exercise("Bench Press")

        XCTAssertNotNil(
            SlotAlternativeAuthoring.append(
                exerciseID: bench.id,
                exerciseName: bench.name,
                prescription: AlternativePrescriptionPayload(),
                mainExerciseID: nil,
                to: p))
        XCTAssertEqual(p.slotAlternatives.count, 1)
    }

    // ==================================================
    // MARK: - 4. Legacy rows survive and are marked
    // ==================================================

    /// Requirement 6/7 — a same-as-slot alternative stored before this rule
    /// (or arriving through import / duplication) is **kept**. The editor list
    /// still renders it, so the user can see it and swipe it away; only the
    /// workout-facing readers skip it.
    func testAnExistingSameAsSlotAlternativeIsNotDeletedOnRead() throws {
        let p = prescription()
        let bench = exercise("Bench Press")
        let machine = exercise("Machine Chest Press")

        // Written the way a pre-rule build would have.
        p.setSlotAlternatives([
            alternative("Bench Press", exerciseID: bench.id, order: 0),
            alternative("Machine Chest Press", exerciseID: machine.id, order: 1),
        ])
        try context.save()

        XCTAssertEqual(
            p.slotAlternatives.map(\.exerciseID), [bench.id, machine.id],
            "the editor list shows both — nothing is dropped on read")
        XCTAssertTrue(
            SlotAlternativeEligibility.isSameAsSlotExercise(
                p.slotAlternatives[0], slotExerciseID: bench.id),
            "and the first is marked, which is what the row label reads")
        XCTAssertFalse(
            SlotAlternativeEligibility.isSameAsSlotExercise(
                p.slotAlternatives[1], slotExerciseID: bench.id))
    }

    /// Deleting the marked row is the user's escape hatch, and it leaves the
    /// valid sibling intact.
    func testDeletingAnExistingSameAsSlotAlternativeWorks() throws {
        let p = prescription()
        let bench = exercise("Bench Press")
        let machine = exercise("Machine Chest Press")
        p.setSlotAlternatives([
            alternative("Bench Press", exerciseID: bench.id, order: 0),
            alternative("Machine Chest Press", exerciseID: machine.id, order: 1),
        ])

        SlotAlternativeAuthoring.delete(atOffsets: IndexSet(integer: 0), in: p)
        try context.save()

        XCTAssertEqual(p.slotAlternatives.map(\.exerciseID), [machine.id])
        XCTAssertEqual(p.slotAlternatives.map(\.order), [0])
    }

    /// Editing the *other* alternative on a slot that holds an invalid one
    /// must still work — the invalid row is inert, not poisonous.
    func testALegacySameAsSlotAlternativeDoesNotBreakEditingItsSiblings() throws {
        let p = prescription()
        let bench = exercise("Bench Press")
        let machine = exercise("Machine Chest Press")
        p.setSlotAlternatives([
            alternative("Bench Press", exerciseID: bench.id, order: 0),
            alternative("Machine Chest Press", exerciseID: machine.id, order: 1),
        ])
        let siblingID = p.slotAlternatives[1].id

        SlotAlternativeAuthoring.update(id: siblingID, in: p) {
            $0.note = "when the rack is busy"
            $0.prescription.sets = 4
        }
        try context.save()

        XCTAssertEqual(p.slotAlternatives.count, 2)
        XCTAssertEqual(p.slotAlternatives[1].note, "when the rack is busy")
        XCTAssertEqual(p.slotAlternatives[1].prescription.sets, 4)
        XCTAssertEqual(
            p.slotAlternatives[0].exerciseID, bench.id,
            "the invalid row is untouched, not repaired and not removed")
    }

    // ==================================================
    // MARK: - 5. Workout-facing counts
    // ==================================================

    /// `workoutFacing` is the shared basis for the routine editor's block
    /// subtitle and the active workout's Switch Exercise badge.
    func testWorkoutFacingDropsSameAsSlotAndDisabled() {
        let list = [
            alternative("Bench Press", exerciseID: benchID, order: 0),
            alternative("Machine", exerciseID: machineID, order: 1),
            alternative("Off one", exerciseID: UUID(), order: 2, enabled: false),
        ]

        XCTAssertEqual(
            SlotAlternativeEligibility
                .workoutFacing(list, slotExerciseID: benchID)
                .map(\.exerciseID),
            [machineID])
        XCTAssertEqual(
            SlotAlternativeEligibility
                .workoutFacing(list, slotExerciseID: nil).count,
            2,
            "with no slot exercise only the disabled one is dropped")
    }

    /// The routine editor's `… · N alternatives` block subtitle. A slot whose
    /// only prepared alternative is its own exercise promises nothing.
    func testTheBlockSubtitleDoesNotCountASameAsSlotAlternative() throws {
        let bench = exercise("Bench Press")
        let machine = exercise("Machine Chest Press")

        let p = SlotPrescription()
        p.sets = 3
        p.repMin = 8
        p.repMax = 12
        context.insert(p)
        p.setSlotAlternatives([
            alternative("Bench Press", exerciseID: bench.id, order: 0),
            alternative("Machine Chest Press", exerciseID: machine.id, order: 1),
        ])

        let slot = RoutineExercise(exercise: bench, order: 0, setTemplates: [])
        slot.prescription = p
        context.insert(slot)
        let block = RoutineBlock(order: 0, exercises: [slot])
        context.insert(block)
        try context.save()

        let subtitle = BlockPrescriptionSummary(block: block).subtitle
        XCTAssertTrue(
            subtitle.contains("1 alternative"),
            "only the valid one is promised — got \(subtitle)")
        XCTAssertFalse(subtitle.contains("2 alternative"))
    }

    /// And a slot whose *only* alternative is its own exercise shows no count
    /// at all, exactly as a slot with none does.
    func testTheBlockSubtitleOmitsTheCountWhenTheOnlyAlternativeIsTheSlots()
        throws
    {
        let bench = exercise("Bench Press")

        let p = SlotPrescription()
        p.sets = 3
        p.repMin = 8
        p.repMax = 12
        context.insert(p)
        p.setSlotAlternatives([
            alternative("Bench Press", exerciseID: bench.id, order: 0)
        ])

        let slot = RoutineExercise(exercise: bench, order: 0, setTemplates: [])
        slot.prescription = p
        context.insert(slot)
        let block = RoutineBlock(order: 0, exercises: [slot])
        context.insert(block)
        try context.save()

        XCTAssertFalse(
            BlockPrescriptionSummary(block: block).subtitle
                .contains("alternative"))
        XCTAssertEqual(
            SlotAlternativeSummary.countLabel(p.slotAlternatives.count), "1",
            "the authoring row still counts it — a different question")
    }
}

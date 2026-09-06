import SwiftData
import XCTest

@testable import Log

/// Covers the editable-warmup-step behavior of `WarmupSchemeEditor`.
///
/// The editor's add / edit / delete methods are private SwiftUI View methods,
/// but each is now a thin wrapper over `WarmupSchemeAuthoring`, so these tests
/// call the **production** authoring API directly rather than re-implementing
/// it — the mirrors they used to carry could drift from the code they
/// documented, and the immediate-render fix touched exactly those methods.
///
/// The snapshot-immutability test additionally proves the data-safety
/// invariant — an already-captured `WarmupStepSnapshot` is a value type fully
/// decoupled from the live routine step, so editing the routine never touches
/// a started workout's snapshot.
@MainActor
final class WarmupStepEditTests: SwiftDataTestHarness {

    // The **production** edit write-back, no longer a hand-copied mirror:
    // `WarmupSchemeEditor.updateStep` is a thin wrapper over this call, so
    // these tests can no longer drift from the code they document.
    private func applyEdit(
        to step: WarmupStep,
        kind: WarmupStepKind,
        reps: Int?,
        pct: Double?,
        rest: Int?,
        note: String?,
        weight: Double?
    ) {
        WarmupSchemeAuthoring.updateStep(
            step,
            in: owner(of: step),
            kind: kind,
            reps: reps,
            percentOfWorking: pct,
            restSecondsAfter: rest,
            note: note,
            weight: weight,
            fallbackContext: context)
    }

    // The **production** delete path. Maps offsets from the *sorted* display
    // list to steps, reassigns the relationship array without them, deletes
    // them, then renumbers the sorted survivors 0..<count (NOT the raw
    // relationship array, which is the bug these tests guard).
    private func deleteSteps(in scheme: WarmupScheme, at offsets: IndexSet) {
        WarmupSchemeAuthoring.deleteSteps(
            at: offsets, in: owner(of: scheme), fallbackContext: context)
    }

    /// Notes of the scheme's steps in display (order-ascending) order.
    private func orderedNotes(_ scheme: WarmupScheme) -> [String] {
        scheme.steps.sorted { $0.order < $1.order }.compactMap { $0.note }
    }

    /// Owning prescription per scheme. The production authoring API is
    /// addressed by prescription (it resolves the write context from the model
    /// being edited — see `WarmupSchemeAuthoring`), so every fixture scheme
    /// gets one and the tests look it back up rather than mirroring the code.
    private var owners: [PersistentIdentifier: SlotPrescription] = [:]

    private func owner(of scheme: WarmupScheme) -> SlotPrescription {
        owners[scheme.persistentModelID] ?? makePrescription()
    }

    private func owner(of step: WarmupStep) -> SlotPrescription {
        for (schemeID, prescription) in owners {
            guard let scheme = context.model(for: schemeID) as? WarmupScheme
            else { continue }
            if scheme.steps.contains(where: {
                $0.persistentModelID == step.persistentModelID
            }) {
                return prescription
            }
        }
        return makePrescription()
    }

    private func makeScheme(_ steps: [WarmupStep]) -> WarmupScheme {
        let scheme = WarmupScheme(name: "Warmup")
        context.insert(scheme)
        for s in steps { context.insert(s) }
        scheme.steps = steps
        let prescription = makePrescription()
        prescription.warmupScheme = scheme
        try? context.save()
        owners[scheme.persistentModelID] = prescription
        return scheme
    }

    // Value-type snapshot construction mirroring StartWorkoutFromRoutineView.
    private func snapshot(_ scheme: WarmupScheme) -> [WarmupStepSnapshot] {
        scheme.steps
            .sorted { $0.order < $1.order }
            .map { step in
                WarmupStepSnapshot(
                    order: step.order,
                    kind: step.kind,
                    reps: step.reps,
                    percentOfWorking: step.percentOfWorking,
                    note: step.note,
                    restSecondsAfter: step.restSecondsAfter,
                    weight: step.weight
                )
            }
    }

    // MARK: - 1+2+3. Edit touches only the selected step; siblings + order intact.

    func testEditingStepChangesOnlySelectedStepAndPreservesOrder() {
        let s0 = WarmupStep(order: 0, kind: .percentage, reps: 8, percentOfWorking: 0.4)
        let s1 = WarmupStep(order: 1, kind: .fixedReps, reps: 5, weight: 40)
        let s2 = WarmupStep(order: 2, kind: .noteOnly, note: "stretch")
        _ = makeScheme([s0, s1, s2])

        // Edit the middle step: switch kind percentage -> fixedReps with new fields.
        applyEdit(to: s1, kind: .fixedReps, reps: 3, pct: nil, rest: 60,
                  note: "deload bar", weight: 60.5)

        // Selected step reflects every change.
        XCTAssertEqual(s1.kind, .fixedReps)
        XCTAssertEqual(s1.reps, 3)
        XCTAssertNil(s1.percentOfWorking)
        XCTAssertEqual(s1.restSecondsAfter, 60)
        XCTAssertEqual(s1.note, "deload bar")
        XCTAssertEqual(s1.weight, 60.5)

        // Siblings untouched.
        XCTAssertEqual(s0.kind, .percentage)
        XCTAssertEqual(s0.percentOfWorking, 0.4)
        XCTAssertEqual(s0.reps, 8)
        XCTAssertEqual(s2.kind, .noteOnly)
        XCTAssertEqual(s2.note, "stretch")

        // Order is never modified by an edit.
        XCTAssertEqual(s0.order, 0)
        XCTAssertEqual(s1.order, 1)
        XCTAssertEqual(s2.order, 2)
    }

    // MARK: - 4. All editable fields round-trip through a save + refetch.

    func testAllEditableFieldsRoundTrip() {
        let step = WarmupStep(order: 0, kind: .fixedReps, reps: 5, weight: 20)
        let scheme = makeScheme([step])
        let stepID = step.persistentModelID

        applyEdit(to: step, kind: .percentage, reps: 12, pct: 0.75, rest: 45,
                  note: "tempo focus", weight: nil)

        // Refetch the persisted step to confirm values survived the save.
        let schemeID = scheme.persistentModelID
        let refetched = (context.model(for: schemeID) as? WarmupScheme)?
            .steps.first { $0.persistentModelID == stepID }
        XCTAssertNotNil(refetched)
        XCTAssertEqual(refetched?.kind, .percentage)
        XCTAssertEqual(refetched?.kindRaw, "percentage")
        XCTAssertEqual(refetched?.reps, 12)
        XCTAssertEqual(refetched?.percentOfWorking, 0.75)
        XCTAssertEqual(refetched?.restSecondsAfter, 45)
        XCTAssertEqual(refetched?.note, "tempo focus")
        XCTAssertNil(refetched?.weight)
        XCTAssertEqual(refetched?.order, 0) // order unchanged
    }

    // Switching kind clears the now-irrelevant fields (sheet nil-s them).
    func testKindSwitchClearsStaleFields() {
        let step = WarmupStep(order: 0, kind: .percentage,
                              reps: 6, percentOfWorking: 0.5)
        _ = makeScheme([step])

        // percentage -> fixedReps: pct cleared, weight set.
        applyEdit(to: step, kind: .fixedReps, reps: 4, pct: nil, rest: nil,
                  note: nil, weight: 50)
        XCTAssertNil(step.percentOfWorking)
        XCTAssertEqual(step.weight, 50)

        // fixedReps -> noteOnly: reps + weight cleared, note kept.
        applyEdit(to: step, kind: .noteOnly, reps: nil, pct: nil, rest: nil,
                  note: "band pull-apart", weight: nil)
        XCTAssertNil(step.reps)
        XCTAssertNil(step.weight)
        XCTAssertEqual(step.note, "band pull-apart")
    }

    // MARK: - 6. Snapshot immutability after a routine warmup edit.

    func testEditingRoutineStepDoesNotMutateCapturedSnapshot() {
        let step = WarmupStep(order: 0, kind: .percentage,
                              reps: 8, percentOfWorking: 0.5, restSecondsAfter: 30)
        let scheme = makeScheme([step])

        // Capture the value-type snapshot as a started workout would.
        let captured = snapshot(scheme)
        XCTAssertEqual(captured.count, 1)

        // Edit the live routine step substantially.
        applyEdit(to: step, kind: .fixedReps, reps: 2, pct: nil, rest: 90,
                  note: "changed", weight: 70)

        // The previously captured snapshot is unchanged.
        let snap = captured[0]
        XCTAssertEqual(snap.order, 0)
        XCTAssertEqual(snap.kind, .percentage)
        XCTAssertEqual(snap.reps, 8)
        XCTAssertEqual(snap.percentOfWorking, 0.5)
        XCTAssertEqual(snap.restSecondsAfter, 30)
        XCTAssertNil(snap.weight)
        XCTAssertNil(snap.note)

        // And re-snapshotting now reflects the edit (sanity check the edit took).
        let after = snapshot(scheme)[0]
        XCTAssertEqual(after.kind, .fixedReps)
        XCTAssertEqual(after.weight, 70)
        XCTAssertEqual(after.reps, 2)
    }

    // MARK: - 5. Delete preserves relative order + renumbers contiguously.

    private func makeABC() -> WarmupScheme {
        let a = WarmupStep(order: 0, kind: .noteOnly, note: "A")
        let b = WarmupStep(order: 1, kind: .noteOnly, note: "B")
        let c = WarmupStep(order: 2, kind: .noteOnly, note: "C")
        return makeScheme([a, b, c])
    }

    func testDeletingMiddleStepPreservesOrder() {
        let scheme = makeABC()
        deleteSteps(in: scheme, at: IndexSet(integer: 1)) // delete B

        // A and C must NOT swap — this is the reported bug.
        XCTAssertEqual(orderedNotes(scheme), ["A", "C"])
        let orders = scheme.steps.map(\.order).sorted()
        XCTAssertEqual(orders, [0, 1]) // contiguous 0..<count
    }

    func testDeletingTopStepPreservesOrder() {
        let scheme = makeABC()
        deleteSteps(in: scheme, at: IndexSet(integer: 0)) // delete A

        XCTAssertEqual(orderedNotes(scheme), ["B", "C"])
        XCTAssertEqual(scheme.steps.map(\.order).sorted(), [0, 1])
    }

    func testDeletingBottomStepPreservesOrder() {
        let scheme = makeABC()
        deleteSteps(in: scheme, at: IndexSet(integer: 2)) // delete C

        XCTAssertEqual(orderedNotes(scheme), ["A", "B"])
        XCTAssertEqual(scheme.steps.map(\.order).sorted(), [0, 1])
    }

    func testDeletingSingleStepEmptiesScheme() {
        let only = WarmupStep(order: 0, kind: .noteOnly, note: "only")
        let scheme = makeScheme([only])
        deleteSteps(in: scheme, at: IndexSet(integer: 0))

        XCTAssertTrue(scheme.steps.isEmpty)
    }

    // Even when the underlying relationship array order does not match `order`,
    // deleting a middle row keeps the survivors in `order` sequence. (Renumber
    // must operate on the sorted survivors, not the raw relationship array.)
    func testDeleteRenumbersByOrderNotRelationshipArray() {
        // Insert intentionally out of relationship-array order.
        let c = WarmupStep(order: 2, kind: .noteOnly, note: "C")
        let a = WarmupStep(order: 0, kind: .noteOnly, note: "A")
        let b = WarmupStep(order: 1, kind: .noteOnly, note: "B")
        let scheme = makeScheme([c, a, b]) // array order C,A,B; order field 2,0,1

        deleteSteps(in: scheme, at: IndexSet(integer: 1)) // sorted index 1 = B

        XCTAssertEqual(orderedNotes(scheme), ["A", "C"])
        // A keeps the lower order, C the higher — contiguous.
        let aOrder = scheme.steps.first { $0.note == "A" }?.order
        let cOrder = scheme.steps.first { $0.note == "C" }?.order
        XCTAssertEqual(aOrder, 0)
        XCTAssertEqual(cOrder, 1)
    }

    // MARK: - 6. Add appends immediately + preserves order.

    /// The **production** add path: lazily creates the scheme on the
    /// prescription, computes the next `order` from the max, inserts the step,
    /// and appends via a whole-array reassignment (`steps + [step]`).
    @discardableResult
    private func addStep(
        to prescription: SlotPrescription,
        kind: WarmupStepKind,
        reps: Int?,
        pct: Double?,
        rest: Int?,
        note: String?,
        weight: Double?
    ) -> WarmupStep {
        let step = WarmupSchemeAuthoring.addStep(
            to: prescription,
            kind: kind,
            reps: reps,
            percentOfWorking: pct,
            restSecondsAfter: rest,
            note: note,
            weight: weight,
            fallbackContext: context)
        if let scheme = prescription.warmupScheme {
            owners[scheme.persistentModelID] = prescription
        }
        return step
    }

    private func makePrescription() -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        try? context.save()
        return p
    }

    // Adding the very first step lazily creates the scheme and the new step is
    // immediately present in the relationship (no pop/re-push needed).
    func testAddingFirstStepCreatesSchemeAndAppearsImmediately() {
        let p = makePrescription()
        XCTAssertNil(p.warmupScheme)

        addStep(to: p, kind: .fixedReps, reps: 5, pct: nil, rest: nil,
                note: "first", weight: 40)

        XCTAssertNotNil(p.warmupScheme)
        XCTAssertEqual(p.warmupScheme?.steps.count, 1)
        XCTAssertEqual(p.warmupScheme?.steps.first?.note, "first")
        XCTAssertEqual(p.warmupScheme?.steps.first?.order, 0)
    }

    // Each subsequent add appends to the end (monotonically increasing order),
    // and every step is present in the live relationship right after the call.
    func testAddingStepsAppendsInOrderAndAllPresentImmediately() {
        let p = makePrescription()
        addStep(to: p, kind: .noteOnly, reps: nil, pct: nil, rest: nil, note: "A", weight: nil)
        addStep(to: p, kind: .noteOnly, reps: nil, pct: nil, rest: nil, note: "B", weight: nil)
        addStep(to: p, kind: .noteOnly, reps: nil, pct: nil, rest: nil, note: "C", weight: nil)

        guard let scheme = p.warmupScheme else {
            return XCTFail("scheme should exist after adds")
        }
        // All three visible immediately, in insertion order.
        XCTAssertEqual(scheme.steps.count, 3)
        XCTAssertEqual(orderedNotes(scheme), ["A", "B", "C"])
        XCTAssertEqual(
            scheme.steps.sorted { $0.order < $1.order }.map(\.order), [0, 1, 2])
    }

    // A new step's order is derived from the current max, so it lands last even
    // when the existing relationship array is stored out of `order` sequence.
    func testAddedStepOrderIsAfterExistingMaxRegardlessOfArrayOrder() {
        let p = makePrescription()
        // Seed a scheme whose relationship-array order does not match `order`.
        let scheme = WarmupScheme(name: "Warmup")
        context.insert(scheme)
        let s1 = WarmupStep(order: 1, kind: .noteOnly, note: "B")
        let s0 = WarmupStep(order: 0, kind: .noteOnly, note: "A")
        context.insert(s1); context.insert(s0)
        scheme.steps = [s1, s0] // array order B,A; order field 1,0
        p.warmupScheme = scheme
        try? context.save()

        let added = addStep(to: p, kind: .noteOnly, reps: nil, pct: nil,
                            rest: nil, note: "C", weight: nil)

        XCTAssertEqual(added.order, 2) // max(1,0)+1
        XCTAssertEqual(orderedNotes(scheme), ["A", "B", "C"])
    }
}

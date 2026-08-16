import SwiftData
import XCTest

@testable import Log

/// Custom per-set effort targets on a **prepared alternative** — authoring it,
/// storing it, applying it mid-workout, summarizing it, and shipping it in a
/// transfer document.
///
/// An alternative's prescription is authored through the *same*
/// `PrescriptionFields` editor as a routine slot (bound to
/// `AlternativeDraftStore`'s scratch slot), so the editor half needs no new
/// rules — what these tests pin is that the value payload carries the targets
/// losslessly in every direction the slot's own columns do.
@MainActor
final class AlternativeCustomEffortTargetTests: XCTestCase {

    private typealias Adapter = ExerciseSwitchPlanAdapter

    private let machineID = UUID()

    /// A strength alternative whose effort is authored per set.
    private func customPayload(
        rir: [Double] = [2, 1.5, 1, 0]
    ) -> AlternativePrescriptionPayload {
        AlternativePrescriptionPayload(
            sets: rir.count, repMin: 10, repMax: 15,
            restSecondsBetweenSets: 75,
            effortModeRaw: EffortMode.custom.rawValue,
            customRIRTargets: rir,
            customRPETargets: rir.map { 10 - $0 })
    }

    // ==================================================
    // MARK: - 1. Authoring (draft ⇄ payload)
    // ==================================================

    /// The editor writes onto a scratch `SlotPrescription`; `payload()` reads it
    /// back. Both halves must round-trip the list exactly.
    func testAuthoringAnAlternativeWithCustomTargetsRoundTrips() throws {
        let store = try AlternativeDraftStore(
            exerciseName: "Machine Chest Press",
            trackingMode: .strength,
            equipmentType: nil,
            includesBodyweightInLoad: false,
            payload: customPayload())

        // Hydrated onto the scratch slot exactly as the editor will show it.
        XCTAssertEqual(store.prescription.effortMode, .custom)
        XCTAssertEqual(store.prescription.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(store.prescription.customRPETargets, [8, 8.5, 9, 10])

        // …and read back out unchanged.
        let readBack = store.payload()
        XCTAssertEqual(readBack.effortModeRaw, EffortMode.custom.rawValue)
        XCTAssertEqual(readBack.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(readBack.customRPETargets, [8, 8.5, 9, 10])
    }

    /// Editing the scratch slot the way the custom rows do is picked up by
    /// `payload()` — the only route edits leave the draft.
    func testEditingTheDraftsPerSetTargetsIsReadBack() throws {
        let store = try AlternativeDraftStore(
            exerciseName: "Machine Chest Press",
            trackingMode: .strength,
            equipmentType: nil,
            includesBodyweightInLoad: false,
            payload: AlternativePrescriptionPayload(sets: 3))

        store.prescription.effortModeRaw = EffortMode.custom.rawValue
        store.prescription.setCustomEffortTargets([3, 2, 0.5], metric: .rir)

        XCTAssertEqual(store.payload().customRIRTargets, [3, 2, 0.5])
        XCTAssertEqual(store.payload().customRPETargets, [7, 8, 9.5])
    }

    func testAnAlternativeWithNoCustomTargetsReadsBackNil() throws {
        let store = try AlternativeDraftStore(
            exerciseName: "Machine Chest Press",
            trackingMode: .strength,
            equipmentType: nil,
            includesBodyweightInLoad: false,
            payload: AlternativePrescriptionPayload(sets: 3, rir: 2))

        XCTAssertNil(store.payload().customRIRTargets)
        XCTAssertNil(store.payload().customRPETargets)
    }

    // ==================================================
    // MARK: - 2. Storage (payload codec)
    // ==================================================

    func testPayloadEncodesAndDecodesCustomTargets() throws {
        let data = try JSONEncoder().encode(customPayload())
        let decoded = try JSONDecoder().decode(
            AlternativePrescriptionPayload.self, from: data)

        XCTAssertEqual(decoded.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(decoded.customRPETargets, [8, 8.5, 9, 10])
    }

    /// A payload without the keys encodes byte-identically to before the
    /// feature existed.
    func testPayloadOmitsTheKeysWhenThereAreNoCustomTargets() throws {
        let json = try XCTUnwrap(
            String(
                data: try JSONEncoder().encode(
                    AlternativePrescriptionPayload(sets: 3, rir: 2)),
                encoding: .utf8))
        XCTAssertFalse(json.contains("customRIRTargets"))
        XCTAssertFalse(json.contains("customRPETargets"))
    }

    /// Normalization refuses a list the app's steppers could not have produced,
    /// whole — the same rule the slot's column applies.
    func testPayloadNormalizationRejectsAnImpossibleList() {
        var payload = AlternativePrescriptionPayload(sets: 3)
        payload.customRIRTargets = [2, 999, 0]
        XCTAssertNil(payload.normalized().customRIRTargets)

        var empty = AlternativePrescriptionPayload(sets: 3)
        empty.customRIRTargets = []
        XCTAssertNil(empty.normalized().customRIRTargets)
    }

    /// Round-tripping through the slot column (the whole-alternatives codec)
    /// preserves the list, including a half step.
    func testSlotAlternativesCodecPreservesCustomTargets() throws {
        let authored = SlotAlternative(
            exerciseID: machineID, exerciseName: "Machine Chest Press",
            prescription: customPayload())
        let data = try XCTUnwrap(SlotAlternatives.encode([authored]))
        let decoded = try XCTUnwrap(SlotAlternatives.decode(from: data).first)

        XCTAssertEqual(
            decoded.prescription.customRIRTargets, [2, 1.5, 1, 0])
    }

    // ==================================================
    // MARK: - 3. Applying during a workout
    // ==================================================

    /// `SessionPlan` carries a single rir/rpe and has nowhere to put a per-set
    /// list, so the adapted **snapshot** is what must carry it — exactly as it
    /// already does for a progression.
    func testApplyingAnAlternativeAppliesItsCustomTargets() {
        let outcome = Adapter.outcome(
            choice: .useAlternative(customPayload()),
            current: SessionPlan(),
            oldMode: .strength,
            newMode: .strength,
            resetSource: .appDefaults(for: .strength))

        let snapshot = Adapter.adaptedSnapshot(
            from: outcome, base: .empty, equipment: nil, setupNotes: nil)

        XCTAssertEqual(snapshot.effortModeRaw, EffortMode.custom.rawValue)
        XCTAssertEqual(snapshot.customRIRTargetsRaw, "2,1.5,1,0")
        XCTAssertEqual(snapshot.customRPETargetsRaw, "8,8.5,9,10")
        XCTAssertEqual(
            WorkoutEffortTargetResolver.perSetLabels(
                payload: snapshot, autoregMode: .rir, workingSetCount: 4),
            ["RIR 2", "RIR 1.5", "RIR 1", "RIR 0"])
    }

    /// The replaced exercise's custom list must not survive onto the
    /// switched-in one.
    func testApplyingAnAlternativeClearsTheReplacedSlotsCustomTargets() {
        var payload = AlternativePrescriptionPayload(sets: 3)
        payload.rir = 2

        let outcome = Adapter.outcome(
            choice: .useAlternative(payload),
            current: SessionPlan(),
            oldMode: .strength,
            newMode: .strength,
            resetSource: .appDefaults(for: .strength))

        let snapshot = Adapter.adaptedSnapshot(
            from: outcome,
            base: PrescriptionSnapshotPayload(
                effortModeRaw: EffortMode.custom.rawValue,
                customRIRTargetsRaw: "5,4,3"),
            equipment: nil, setupNotes: nil)

        XCTAssertNil(snapshot.customRIRTargetsRaw)
        XCTAssertNil(snapshot.customRPETargetsRaw)
    }

    /// A cardio switch-in shows no effort control, so its snapshot must carry
    /// no effort state — custom targets included.
    func testSwitchingToCardioDropsCustomTargets() {
        let outcome = Adapter.outcome(
            choice: .useAlternative(customPayload()),
            current: SessionPlan(),
            oldMode: .strength,
            newMode: .cardio,
            resetSource: .appDefaults(for: .cardio))

        let snapshot = Adapter.adaptedSnapshot(
            from: outcome,
            base: PrescriptionSnapshotPayload(customRIRTargetsRaw: "2,1,0"),
            equipment: nil, setupNotes: nil)

        XCTAssertNil(snapshot.customRIRTargetsRaw)
        XCTAssertNil(snapshot.customRPETargetsRaw)
    }

    /// An explicit **Reset** likewise clears them: the user asked to start over.
    func testResetPlanClearsCustomTargets() {
        let outcome = Adapter.outcome(
            choice: .resetPlan,
            current: SessionPlan(),
            oldMode: .strength,
            newMode: .strength,
            resetSource: Adapter.ResetSource(sets: 3, rir: 2))

        let snapshot = Adapter.adaptedSnapshot(
            from: outcome,
            base: PrescriptionSnapshotPayload(
                effortModeRaw: EffortMode.custom.rawValue,
                customRIRTargetsRaw: "2,1,0"),
            equipment: nil, setupNotes: nil)

        XCTAssertNil(snapshot.customRIRTargetsRaw)
    }

    /// **Keep current plan** preserves them — the effort target applies to the
    /// new exercise just as a progression does.
    func testKeepCurrentPlanPreservesCustomTargets() {
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan,
            current: SessionPlan(),
            oldMode: .strength,
            newMode: .strength,
            resetSource: .appDefaults(for: .strength))

        let snapshot = Adapter.adaptedSnapshot(
            from: outcome,
            base: PrescriptionSnapshotPayload(
                effortModeRaw: EffortMode.custom.rawValue,
                customRIRTargetsRaw: "2,1.5,1,0"),
            equipment: nil, setupNotes: nil)

        XCTAssertEqual(snapshot.customRIRTargetsRaw, "2,1.5,1,0")
    }

    // ==================================================
    // MARK: - 4. Summary
    // ==================================================

    func testSummaryStatesTheCustomTargets() {
        let alternative = SlotAlternative(
            exerciseID: machineID, exerciseName: "Machine Chest Press",
            prescription: customPayload())

        XCTAssertTrue(
            SlotAlternativeSummary.subtitle(
                for: alternative, effortMetric: .rir
            ).contains("RIR 2/1.5/1/0"),
            SlotAlternativeSummary.subtitle(
                for: alternative, effortMetric: .rir))
    }

    func testSummaryFitsTheAlternativesOwnSetCount() {
        var payload = customPayload()
        payload.sets = 2

        XCTAssertTrue(
            SlotAlternativeSummary.subtitle(
                for: payload, effortMetric: .rir
            ).contains("RIR 2/1.5"),
            SlotAlternativeSummary.subtitle(for: payload, effortMetric: .rir))
    }

    func testSummaryConvertsToTheAppsMetric() {
        XCTAssertTrue(
            SlotAlternativeSummary.subtitle(
                for: customPayload(), effortMetric: .rpe
            ).contains("RPE 8/8.5/9/10"))
    }

    func testSummaryOmitsEffortWhenAutoregIsOff() {
        XCTAssertFalse(
            SlotAlternativeSummary.subtitle(
                for: customPayload(), effortMetric: nil
            ).contains("RIR"))
    }

    // ==================================================
    // MARK: - 5. Transfer
    // ==================================================

    /// The transfer DTO embeds `AlternativePrescriptionPayload` verbatim, so a
    /// document round trip is the payload's own round trip.
    func testTransferDTORoundTripsCustomTargets() throws {
        let dto = RoutineTransferAlternativeDTO(
            order: 0, isEnabled: true, exerciseName: "Machine Chest Press",
            prescription: customPayload())

        let decoded = try JSONDecoder().decode(
            RoutineTransferAlternativeDTO.self,
            from: try JSONEncoder().encode(dto))

        XCTAssertEqual(decoded.prescription.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(decoded.prescription.customRPETargets, [8, 8.5, 9, 10])
    }

    /// An alternative exported before this feature has no custom keys and must
    /// decode exactly as it always did.
    func testOlderAlternativePayloadWithoutCustomKeysDecodes() throws {
        let json = """
            {
              "order": 0,
              "isEnabled": true,
              "exerciseName": "Machine Chest Press",
              "prescription": {
                "sets": 3, "repMin": 8, "repMax": 12,
                "usesDuration": false, "rir": 2
              }
            }
            """
        let decoded = try JSONDecoder().decode(
            RoutineTransferAlternativeDTO.self, from: Data(json.utf8))

        XCTAssertNil(decoded.prescription.customRIRTargets)
        XCTAssertNil(decoded.prescription.customRPETargets)
        XCTAssertEqual(
            SlotAlternativeSummary.effortMode(for: decoded.prescription),
            .single)
    }
}

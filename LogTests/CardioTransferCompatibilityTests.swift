import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 9 — routine transfer compatibility.
///
/// Slice 5 already added `targetDistanceMeters` / `targetDistanceUnitRaw` to
/// `RoutineTransferSlotPrescriptionDTO` as additive keys with nil defaults, and
/// `CardioTargetTransferTests` pins the DTO-level behavior. What is *not*
/// covered there, and is this slice's job, is the whole pipe end to end —
/// model → export → JSON bytes → decode → import → model — plus the rule that
/// an imported target renders in the **Settings** unit rather than in whatever
/// `targetDistanceUnitRaw` the file happened to carry.
///
/// No `schemaVersion` bump: nothing about a document written by an earlier
/// build became invalid, which is exactly what the legacy-payload tests here
/// assert.
@MainActor
final class CardioTransferCompatibilityTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles
    private let fiveKmInMeters = 5_000.0

    /// The Settings preference lives in `UserDefaults.standard`; save and
    /// restore it so a unit change never leaks into the rest of the suite.
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(
            forKey: AppSettings.Keys.distanceIsMetric)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(
                savedValue, forKey: AppSettings.Keys.distanceIsMetric)
        } else {
            UserDefaults.standard.removeObject(
                forKey: AppSettings.Keys.distanceIsMetric)
        }
        super.tearDown()
    }

    private func selectUnit(_ unit: DistanceUnit) {
        AppSettings.distanceIsMetric = (unit == .kilometers)
    }

    // MARK: - Fixtures

    /// A saved cardio routine whose single slot carries `target`.
    @discardableResult
    private func makeCardioRoutine(
        name: String = "Cardio Day", target: CardioTargetDistance?
    ) throws -> Routine {
        let ex = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        context.insert(ex)
        ex.setTimeBased(true)
        ex.setCardio(true)

        let p = SlotPrescription(usesDuration: true)
        p.sets = 1
        p.durationMaxSeconds = 1_800
        if let target { p.applyTargetDistance(target) }
        context.insert(p)

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p

        let block = RoutineBlock(
            isSuperset: false, order: 0, restAfterSeconds: nil, exercises: [re])
        context.insert(block)
        let routine = Routine(name: name, blocks: [block])
        context.insert(routine)
        try context.save()
        return routine
    }

    /// Export `routine`, push it through real JSON bytes, import it back, and
    /// return the imported copy's prescription. The JSON hop matters: it is the
    /// only way to prove the keys actually survive the wire rather than merely
    /// surviving a struct copy.
    private func roundTrip(_ routine: Routine) throws -> SlotPrescription {
        let data = try JSONEncoder().encode(RoutineTransfer.export(routine))
        let decoded = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: data)
        return try importPrescription(from: decoded)
    }

    /// Import `document` and return the prescription of the routine it created.
    /// The imported copy is identified by *identity*, not by name: importing a
    /// routine that already exists renames the copy, so matching on the name
    /// would be ambiguous exactly where these tests need to be precise.
    private func importPrescription(
        from document: RoutineTransferDocument
    ) throws -> SlotPrescription {
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        let exercises = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        let before = Set(routines.map(\.id))

        _ = try RoutineTransfer.import(
            document, among: routines, exercises: exercises, in: context)

        let after = try context.fetch(FetchDescriptor<Routine>())
        let imported = try XCTUnwrap(
            after.first { !before.contains($0.id) },
            "the import should have created a routine")
        return try XCTUnwrap(
            imported.blocks.first?.exercises.first?.prescription)
    }

    // MARK: - 19/20. Round-trip

    func testTargetDistanceSurvivesAFullExportImportRoundTrip() throws {
        let routine = try makeCardioRoutine(
            target: CardioTargetDistance(text: "5", unit: km))

        let imported = try roundTrip(routine)

        XCTAssertEqual(
            try XCTUnwrap(imported.targetDistanceMeters), fiveKmInMeters,
            accuracy: 0.001)
        XCTAssertEqual(imported.targetDistanceUnitRaw, "km")
    }

    /// An imperial target round-trips as canonical meters — the value on the
    /// wire is never the number the user typed.
    func testMilesTargetRoundTripsAsCanonicalMeters() throws {
        let routine = try makeCardioRoutine(
            target: CardioTargetDistance(text: "3.1", unit: mi))

        let data = try JSONEncoder().encode(RoutineTransfer.export(routine))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(
            json.contains("targetDistanceMeters"),
            "the canonical distance is what goes on the wire")

        let imported = try roundTrip(routine)
        XCTAssertEqual(
            try XCTUnwrap(imported.targetDistanceMeters), 3.1 * 1_609.344,
            accuracy: 0.001)
        XCTAssertEqual(
            imported.targetDistanceUnitRaw, "mi",
            "the entry unit rides along as compatibility metadata")
    }

    func testRoutineWithoutATargetRoundTripsWithNoTarget() throws {
        let routine = try makeCardioRoutine(name: "No Target", target: nil)

        let imported = try roundTrip(routine)

        XCTAssertNil(imported.targetDistanceMeters)
        XCTAssertNil(imported.targetDistanceUnitRaw)
        XCTAssertNil(imported.targetDistance(displayUnit: km))
    }

    // MARK: - 21. Old payloads without the keys still decode and import

    /// Literal pre-Slice-5 JSON: the shape every routine exported by an earlier
    /// build has on disk. It must decode, import, and simply carry no target.
    func testLegacyPayloadWithoutTargetKeysImports() throws {
        let json = """
            {
              "schemaVersion": 1,
              "routine": {
                "name": "Legacy Cardio",
                "blocks": [{
                  "order": 0,
                  "isSuperset": false,
                  "slots": [{
                    "order": 0,
                    "exerciseName": "Treadmill Run",
                    "exerciseIsTimeBased": true,
                    "setTemplates": [],
                    "prescription": {
                      "sets": 1,
                      "usesDuration": true,
                      "durationMaxSeconds": 1800,
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))
        try document.validateSupportedSchemaVersion()

        let imported = try importPrescription(from: document)

        XCTAssertNil(imported.targetDistanceMeters)
        XCTAssertNil(imported.targetDistanceUnitRaw)
        XCTAssertTrue(imported.usesDuration, "the rest of the slot still imports")
        XCTAssertEqual(imported.durationMaxSeconds, 1_800)
    }

    /// The two keys are additive, so the version guard is untouched — an older
    /// document is not "an older version" as far as this build is concerned.
    func testSchemaVersionWasNotConsumed() {
        XCTAssertEqual(RoutineTransferDocument.currentSchemaVersion, 1)
    }

    // MARK: - 22. Imported targets display in the Settings unit

    /// `targetDistanceUnitRaw` is compatibility metadata, not a display
    /// override: a routine exported in miles renders in km for a reader whose
    /// Settings say km, and flips the moment the preference changes. Nothing
    /// stored moves — only the expression of it.
    func testImportedTargetRendersInTheSettingsUnitNotTheFilesUnit() throws {
        let routine = try makeCardioRoutine(
            name: "Imperial", target: CardioTargetDistance(text: "3.1", unit: mi))
        let imported = try roundTrip(routine)
        XCTAssertEqual(imported.targetDistanceUnitRaw, "mi")

        selectUnit(km)
        let metric = try XCTUnwrap(
            imported.targetDistance(displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(metric.unit, km)
        XCTAssertEqual(metric.displayText, "4.99 km")

        selectUnit(mi)
        let imperial = try XCTUnwrap(
            imported.targetDistance(displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(imperial.unit, mi)
        XCTAssertEqual(imperial.displayText, "3.1 mi")

        XCTAssertEqual(
            imported.targetDistanceUnitRaw, "mi",
            "changing the preference moves nothing in storage")
    }

    func testAMetricFileAlsoFollowsTheReadersImperialSetting() throws {
        let routine = try makeCardioRoutine(
            name: "Metric", target: CardioTargetDistance(text: "5", unit: km))
        let imported = try roundTrip(routine)

        selectUnit(mi)
        let target = try XCTUnwrap(
            imported.targetDistance(displayUnit: AppSettings.distanceUnit))
        XCTAssertEqual(target.unit, mi)
        XCTAssertEqual(target.displayText, "3.11 mi")
    }
}

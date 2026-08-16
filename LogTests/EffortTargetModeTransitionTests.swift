import XCTest

@testable import Log

/// The routine prescription editor's mode-switch seeding rules, tested without
/// a view (`EffortTargetModeTransition` is pure by design — see its header).
final class EffortTargetModeTransitionTests: XCTestCase {

    private typealias Transition = EffortTargetModeTransition
    private typealias State = EffortTargetModeTransition.State

    private func apply(
        _ mode: EffortMode,
        to state: State,
        metric: EffortMetric = .rir,
        setCount: Int = 4,
        defaultValue: Double = 2
    ) -> State {
        Transition.applying(
            mode, to: state, metric: metric, setCount: setCount,
            defaultValue: defaultValue)
    }

    // MARK: - → Custom

    func testProgressionToCustomSeedsFromTheGeneratedProgression() {
        let result = apply(
            .custom, to: State(mode: .progression, start: 2, end: 0),
            setCount: 4)
        XCTAssertEqual(result.mode, .custom)
        XCTAssertEqual(result.custom, [2, 2, 1, 0])
    }

    func testProgressionToCustomSeedsTheRPESequenceInRPEMode() {
        let result = apply(
            .custom, to: State(mode: .progression, start: 8, end: 10),
            metric: .rpe, setCount: 4, defaultValue: 8)
        XCTAssertEqual(result.custom, [8, 8, 9, 10])
    }

    func testSameTargetToCustomSeedsTheValueRepeated() {
        let result = apply(
            .custom, to: State(mode: .single, single: 1.5), setCount: 3)
        XCTAssertEqual(result.custom, [1.5, 1.5, 1.5])
    }

    func testNoneToCustomSeedsTheAppDefaultRepeated() {
        let result = apply(
            .custom, to: State(mode: .none), setCount: 3, defaultValue: 2)
        XCTAssertEqual(result.custom, [2, 2, 2])
    }

    /// Leaving Custom and coming back must not discard authored per-set work;
    /// the existing list is kept and only refitted to the set count.
    func testReturningToCustomKeepsTheAuthoredList() {
        let authored: [Double] = [2, 1.5, 1, 0]
        let kept = apply(
            .custom,
            to: State(mode: .progression, start: 2, end: 0, custom: authored),
            setCount: 4)
        XCTAssertEqual(kept.custom, authored)

        let grown = apply(
            .custom,
            to: State(mode: .progression, start: 2, end: 0, custom: authored),
            setCount: 6)
        XCTAssertEqual(grown.custom, [2, 1.5, 1, 0, 0, 0])

        let shrunk = apply(
            .custom,
            to: State(mode: .progression, start: 2, end: 0, custom: authored),
            setCount: 2)
        XCTAssertEqual(shrunk.custom, [2, 1.5])
    }

    func testOneSetCustomSeedsOneTarget() {
        let result = apply(
            .custom, to: State(mode: .progression, start: 2, end: 0),
            setCount: 1)
        XCTAssertEqual(result.custom, [2])
    }

    /// A set count of zero (a slot mid-edit) still seeds one editable target
    /// rather than an empty section.
    func testZeroSetsSeedsOneTarget() {
        let result = apply(
            .custom, to: State(mode: .single, single: 2), setCount: 0)
        XCTAssertEqual(result.custom, [2])
    }

    // MARK: - Custom → other modes

    func testCustomToProgressionUsesFirstAndLastTargets() {
        let result = apply(
            .progression,
            to: State(mode: .custom, custom: [2, 1.5, 1, 0]))
        XCTAssertEqual(result.mode, .progression)
        XCTAssertEqual(result.start, 2)
        XCTAssertEqual(result.end, 0)
    }

    func testCustomToProgressionOverwritesStaleEndpoints() {
        let result = apply(
            .progression,
            to: State(mode: .custom, start: 5, end: 4, custom: [3, 2, 1]))
        XCTAssertEqual(result.start, 3)
        XCTAssertEqual(result.end, 1)
    }

    func testCustomToSameTargetUsesTheFirstTarget() {
        let result = apply(
            .single, to: State(mode: .custom, single: 5, custom: [2, 1, 0]))
        XCTAssertEqual(result.single, 2)
    }

    // MARK: - Existing (pre-custom) behavior is unchanged

    func testProgressionToSameTargetKeepsAnExistingSingle() {
        let result = apply(
            .single, to: State(mode: .progression, single: 3, start: 2, end: 0))
        XCTAssertEqual(result.single, 3)
    }

    func testProgressionToSameTargetSeedsFromStartWhenSingleIsMissing() {
        let result = apply(
            .single, to: State(mode: .progression, start: 2, end: 0))
        XCTAssertEqual(result.single, 2)
    }

    func testSameTargetToProgressionSeedsAFlatRampFromTheSingle() {
        let result = apply(.progression, to: State(mode: .single, single: 3))
        XCTAssertEqual(result.start, 3)
        XCTAssertEqual(result.end, 3)
    }

    func testSameTargetToProgressionKeepsExistingEndpoints() {
        let result = apply(
            .progression, to: State(mode: .single, single: 3, start: 2, end: 0))
        XCTAssertEqual(result.start, 2)
        XCTAssertEqual(result.end, 0)
    }

    func testNoneKeepsEveryStoredValue() {
        let before = State(
            mode: .progression, single: 3, start: 2, end: 0, custom: [2, 1, 0])
        let result = apply(.none, to: before)
        XCTAssertEqual(result.mode, .none)
        XCTAssertEqual(result.single, before.single)
        XCTAssertEqual(result.start, before.start)
        XCTAssertEqual(result.end, before.end)
        XCTAssertEqual(result.custom, before.custom)
    }
}

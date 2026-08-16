import Foundation

/// Pure seeding rules for switching a slot between effort target modes.
///
/// Extracted from the routine prescription editor so the rules are testable
/// without a view and stated in exactly one place. No SwiftData, no SwiftUI, no
/// `AppSettings` read at call time — the caller supplies the metric's values
/// (already resolved through the paired `10 - x` fallback), the set count and
/// the app default, and gets back the state to write.
///
/// The governing idea is **never discard authored work**: a mode switch seeds
/// what the new mode needs from what the old mode already said, and leaves
/// everything else alone. Switching away and back is therefore lossless.
enum EffortTargetModeTransition {

    /// One metric's effort state on a slot.
    ///
    /// `custom` is the decoded per-set list (`[]` when the slot has none);
    /// `single` / `start` / `end` are the scalar values behind the other two
    /// modes. All four are carried together because a transition reads from one
    /// and writes to another.
    struct State: Equatable {
        var mode: EffortMode
        var single: Double?
        var start: Double?
        var end: Double?
        var custom: [Double]

        init(
            mode: EffortMode,
            single: Double? = nil,
            start: Double? = nil,
            end: Double? = nil,
            custom: [Double] = []
        ) {
            self.mode = mode
            self.single = single
            self.start = start
            self.end = end
            self.custom = custom
        }
    }

    /// Apply a mode change, seeding whatever the new mode needs.
    ///
    /// - **→ None** — nothing is seeded or cleared. The mode flag suppresses
    ///   display; the stored values wait for the user to come back.
    /// - **→ Same Target** — seeds from the **first** custom target when
    ///   leaving Custom (the natural reading of "collapse this list to one
    ///   value"); otherwise, and only when no single value is stored, from the
    ///   progression's start (Progression → Same) or the app default.
    /// - **→ Progression** — seeds start/end from the **first and last** custom
    ///   targets when leaving Custom; otherwise seeds a nil endpoint from the
    ///   single value (or the default), so a fresh ramp starts flat rather than
    ///   empty.
    /// - **→ Custom** — seeds the list from what the **current** mode resolves
    ///   to: a progression seeds its generated sequence, a same-target seeds
    ///   the value repeated, and a slot with no usable effort seeds the app
    ///   default repeated. An **existing** list is kept and merely refitted to
    ///   the set count — leaving Custom and coming back must not throw away
    ///   per-set work the user authored.
    ///
    /// - Parameters:
    ///   - metric: decides interior rounding when a progression is used as the
    ///     seed for a custom list.
    ///   - setCount: the slot's working set count; `<= 0` is treated as 1, so a
    ///     slot mid-edit still seeds something editable.
    ///   - defaultValue: `AppSettings.defaultRIR` / `defaultRPE`, supplied by
    ///     the caller so this stays pure.
    static func applying(
        _ newMode: EffortMode,
        to state: State,
        metric: EffortMetric,
        setCount: Int,
        defaultValue: Double
    ) -> State {
        var next = state
        next.mode = newMode
        let count = Swift.max(1, setCount)

        switch newMode {
        case .none:
            break

        case .single:
            if let first = state.custom.first {
                next.single = first
            } else if state.single == nil {
                next.single = state.start ?? defaultValue
            }

        case .progression:
            if let first = state.custom.first, let last = state.custom.last {
                next.start = first
                next.end = last
            } else {
                let base = state.single ?? defaultValue
                if next.start == nil { next.start = base }
                if next.end == nil { next.end = base }
            }

        case .custom:
            next.custom =
                state.custom.isEmpty
                ? seed(for: state, metric: metric, count: count,
                       defaultValue: defaultValue)
                : EffortTargetList.resized(state.custom, to: count)
        }

        return next
    }

    /// The list a freshly entered Custom mode starts from: whatever the slot's
    /// current mode resolves to, falling back to a flat list of the slot's own
    /// value (or the app default) when it resolves to nothing.
    private static func seed(
        for state: State,
        metric: EffortMetric,
        count: Int,
        defaultValue: Double
    ) -> [Double] {
        let resolved = EffortTargetResolver.resolve(
            metric: metric,
            mode: state.mode,
            single: state.single,
            start: state.start,
            end: state.end,
            custom: state.custom,
            setCount: count)
        if resolved.count == count { return resolved }
        let base = state.single ?? state.start ?? defaultValue
        return Array(repeating: base, count: count)
    }
}

// ======================================================
// MARK: - SlotPrescription adapter
// ======================================================

extension SlotPrescription {

    /// The slot's effort state for one metric, read through the paired
    /// `10 - x` fallback so a value stored only under the opposite metric
    /// still participates — the same rule every other effort read applies.
    func effortState(metric: EffortMetric) -> EffortTargetModeTransition.State {
        let convert: (Double) -> Double = { 10 - $0 }
        let single: Double?
        let start: Double?
        let end: Double?
        var custom: [Double]
        switch metric {
        case .rir:
            single = rir ?? rpe.map(convert)
            start = rirStart ?? rpeStart.map(convert)
            end = rirEnd ?? rpeEnd.map(convert)
            custom = customRIRTargets
            if custom.isEmpty { custom = customRPETargets.map(convert) }
        case .rpe:
            single = rpe ?? rir.map(convert)
            start = rpeStart ?? rirStart.map(convert)
            end = rpeEnd ?? rirEnd.map(convert)
            custom = customRPETargets
            if custom.isEmpty { custom = customRIRTargets.map(convert) }
        }
        return EffortTargetModeTransition.State(
            mode: effortMode, single: single, start: start, end: end,
            custom: custom)
    }

    /// Apply an effort mode change to this slot — what the routine
    /// prescription editor's mode picker does.
    ///
    /// The *rules* live in `EffortTargetModeTransition` (pure, tested without a
    /// view); this is the model adapter around them. It writes back **only what
    /// changed**, mirroring each changed scalar onto the opposite metric
    /// exactly as the steppers do — so a legacy slot that stores `rir` but no
    /// `rpe` does not silently gain one just because the user tapped through
    /// the picker.
    ///
    /// - Parameter defaultValue: `AppSettings.defaultRIR` / `defaultRPE`,
    ///   passed in by the caller so the transition rules stay pure.
    func applyEffortMode(
        _ newMode: EffortMode, metric: EffortMetric, defaultValue: Double
    ) {
        let convert: (Double) -> Double = { 10 - $0 }
        let before = effortState(metric: metric)
        let after = EffortTargetModeTransition.applying(
            newMode,
            to: before,
            metric: metric,
            setCount: sets ?? 1,
            defaultValue: defaultValue)

        if after.single != before.single {
            setEffortScalar(after.single, \.rir, \.rpe, metric: metric)
        }
        if after.start != before.start {
            setEffortScalar(after.start, \.rirStart, \.rpeStart, metric: metric)
        }
        if after.end != before.end {
            setEffortScalar(after.end, \.rirEnd, \.rpeEnd, metric: metric)
        }
        if after.custom != before.custom {
            setCustomEffortTargets(after.custom, metric: metric)
        }
        effortModeRaw = after.mode.rawValue

        /// Write one scalar into the active metric's column and its `10 - x`
        /// mirror into the other's.
        func setEffortScalar(
            _ value: Double?,
            _ rirPath: ReferenceWritableKeyPath<SlotPrescription, Double?>,
            _ rpePath: ReferenceWritableKeyPath<SlotPrescription, Double?>,
            metric: EffortMetric
        ) {
            switch metric {
            case .rir:
                self[keyPath: rirPath] = value
                self[keyPath: rpePath] = value.map(convert)
            case .rpe:
                self[keyPath: rpePath] = value
                self[keyPath: rirPath] = value.map(convert)
            }
        }
    }

    /// Fit a stored custom list to a new set count, keeping earlier targets
    /// untouched — what the editor does when the sets stepper moves while
    /// Custom Per Set is selected. A no-op unless the slot is actually in
    /// `.custom` mode with an authored list.
    func resizeCustomEffortTargets(to setCount: Int, metric: EffortMetric) {
        guard effortMode == .custom else { return }
        let current = effortState(metric: metric).custom
        guard !current.isEmpty else { return }
        setCustomEffortTargets(
            EffortTargetList.resized(current, to: Swift.max(1, setCount)),
            metric: metric)
    }
}

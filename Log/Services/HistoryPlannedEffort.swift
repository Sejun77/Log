import Foundation

// ======================================================
// MARK: - Planned effort targets, for History (Build 10 H5a)
// ======================================================

/// The planned effort target a finished workout was started with.
///
/// Build 9 shipped Custom Per Set targets, and then History showed nothing of
/// them: the frozen values were on `PlannedPrescriptionSnapshot` all along, with
/// no reader. That made the whole feature feel write-only the moment a workout
/// ended.
///
/// **Planned, never achieved.** No `SetLog` carries a logged RIR/RPE, so there
/// is no "actual" to compare against and nothing here may imply one. This type
/// reports what was programmed and stops — the same discipline
/// `CardioPlannedHistory` follows for segment plans, and for the same reason: a
/// plan is not a measurement, and History must not claim the app observed
/// something it did not.
///
/// Pure value type — no SwiftData, no SwiftUI, no live-template read. The view
/// hands it fields already extracted from the frozen snapshot, so "editing the
/// routine afterwards cannot change what an old workout says it planned" is a
/// property of the call site *and* testable here without a store.
enum HistoryPlannedEffort {

    /// One-line planned-effort summary, or `nil` when there is nothing
    /// truthful to show.
    ///
    /// Delegates the wording wholesale to `WorkoutEffortTargetResolver`, so a
    /// History row is formatted by exactly the code that writes the routine
    /// row, the plan card and the in-session sheet:
    ///
    ///  - Same Target → `RIR 2`
    ///  - Progression → `RIR 2 → 0` (directional arrow, never a range)
    ///  - Custom Per Set → `RIR 2/1.5/1/0`, elided after four values
    ///    (`RIR 3/3/2/2…`) by the Build 10 C6 rule
    ///  - either metric, including the paired `10 - x` fallback, so a target
    ///    authored under RIR still reads for a user who has since switched the
    ///    app to RPE
    ///
    /// Returns `nil` — meaning the view renders no row at all — for every
    /// shape that has nothing to say:
    ///
    ///  - no frozen snapshot (a legacy item, or one that never had one),
    ///  - effort mode `.none`, or a mode whose values are missing,
    ///  - a corrupt or out-of-range custom list, which `EffortTargetList`
    ///    rejects whole and which then degrades to whatever single/progression
    ///    values the snapshot still carries — and to `nil` when it carries none,
    ///  - autoregulation switched off in Settings, matching every other effort
    ///    display in the app: with no metric selected there is no unit to state
    ///    the target in.
    ///
    /// - Parameter workingSetCount: the **planned** set count from the same
    ///   frozen snapshot, so a custom list is fitted to the sets the workout
    ///   was programmed for rather than to however many were logged. `nil`
    ///   summarizes the authored list as stored.
    static func summary(
        fields: WorkoutEffortTargetResolver.Fields?,
        autoregMode: AutoregMode,
        workingSetCount: Int?
    ) -> String? {
        guard let fields else { return nil }
        return WorkoutEffortTargetResolver.summary(
            fields: fields,
            autoregMode: autoregMode,
            workingSetCount: workingSetCount.flatMap { $0 > 0 ? $0 : nil })
    }
}

extension WorkoutEffortTargetResolver.Fields {
    /// Extract the effort fields from a **frozen** `PlannedPrescriptionSnapshot`
    /// — the immutable copy taken at session start.
    ///
    /// The whole point of reading this rather than the live `SlotPrescription`:
    /// a completed workout states the target it was started with, and editing
    /// the routine afterwards cannot rewrite history. Additive — it reads
    /// existing columns and stores nothing.
    init(snapshot: PlannedPrescriptionSnapshot) {
        self.init(
            effortModeRaw: snapshot.effortModeRaw,
            rir: snapshot.rir,
            rpe: snapshot.rpe,
            rirStart: snapshot.rirStart,
            rirEnd: snapshot.rirEnd,
            rpeStart: snapshot.rpeStart,
            rpeEnd: snapshot.rpeEnd,
            customRIRTargetsRaw: snapshot.customRIRTargetsRaw,
            customRPETargetsRaw: snapshot.customRPETargetsRaw
        )
    }
}

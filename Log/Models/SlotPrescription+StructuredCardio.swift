import Foundation

// ======================================================
// MARK: - SlotPrescription ↔ CardioSegmentPlan
// ======================================================

extension SlotPrescription {

    /// The slot's structured cardio plan, decoded.
    ///
    /// This is the **only** intended read path for `cardioSegmentsData`.
    /// Decoding runs the Slice 12B normalization (bad segments dropped, counts
    /// clamped, unknown kinds read as `.work`), and anything that still fails —
    /// truncated data, a payload from a format this build cannot parse, a
    /// column hand-edited in a test — resolves to `nil` rather than throwing.
    /// A routine can therefore never be made unopenable by its own plan.
    ///
    /// An empty plan reads as `nil` too: "no groups" and "no payload" are the
    /// same state to every caller, and collapsing them here means no view has
    /// to check both.
    var structuredCardioPlan: CardioSegmentPlan? {
        guard let cardioSegmentsData else { return nil }
        guard
            let plan = try? JSONDecoder().decode(
                CardioSegmentPlan.self, from: cardioSegmentsData),
            !plan.isEmpty
        else { return nil }
        return plan
    }

    /// Write site. A nil or empty plan clears the column rather than storing an
    /// empty payload, so "the user deleted the last segment" and "this slot was
    /// never structured" persist identically — there is one representation of
    /// no-structure, not two.
    ///
    /// Encoding failure also clears, for the same reason the read path is
    /// tolerant: a slot with no plan is a valid slot, and a half-written column
    /// is not.
    func setStructuredCardioPlan(_ plan: CardioSegmentPlan?) {
        guard let plan, !plan.isEmpty else {
            cardioSegmentsData = nil
            return
        }
        cardioSegmentsData = try? JSONEncoder().encode(plan)
    }

    /// Explicit clear, for call sites where `setStructuredCardioPlan(nil)`
    /// would read as an accident.
    func clearStructuredCardioPlan() {
        cardioSegmentsData = nil
    }

    /// Whether this slot carries a structured plan. Cheaper to read than
    /// decoding when a view only needs to decide between two labels.
    var hasStructuredCardioPlan: Bool { structuredCardioPlan != nil }
}

// ======================================================
// MARK: - PlannedPrescriptionSnapshot ↔ CardioSegmentPlan
// ======================================================

extension PlannedPrescriptionSnapshot {

    /// The plan this workout was **started with**, decoded.
    ///
    /// Structured Cardio Slice 12E — History's only read path. Deliberately the
    /// frozen snapshot rather than the live `SlotPrescription`: a routine edited
    /// after the workout must not rewrite what that workout says it planned,
    /// which is the same snapshot-immutability invariant Equipment & Setup
    /// already relies on.
    ///
    /// Byte-for-byte the same tolerance as the routine-side accessor — nil
    /// payload, empty plan, and unreadable payload all read as nil — so a
    /// corrupt column costs the Planned section and never the History row.
    ///
    /// Nil is also what makes History's visibility rule structural: only a
    /// cardio slot can author segments (`CardioRoutineRules.showsCardioSegments`
    /// is true for `.cardio` alone), and the switch adapter writes nil onto any
    /// snapshot it adapts to a non-cardio mode. So a strength item and a timed
    /// hold read nil here without History having to ask what tracking mode the
    /// item was.
    var structuredCardioPlan: CardioSegmentPlan? {
        guard let cardioSegmentsData else { return nil }
        guard
            let plan = try? JSONDecoder().decode(
                CardioSegmentPlan.self, from: cardioSegmentsData),
            !plan.isEmpty
        else { return nil }
        return plan
    }
}

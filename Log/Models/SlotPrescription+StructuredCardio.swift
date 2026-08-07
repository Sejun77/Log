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

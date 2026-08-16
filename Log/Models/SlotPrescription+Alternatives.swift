import Foundation

// ======================================================
// MARK: - SlotPrescription ↔ [SlotAlternative]
// ======================================================
//
// Alternative Exercises Phase C — the routine-slot storage for prepared
// alternatives. Deliberately the exact shape of
// `SlotPrescription+StructuredCardio.swift`: an additive optional `Data?`
// column, read and written through one normalizing pair, tolerant on the way
// out.
//
// **Persistence only.** Nothing in the app authors or reads alternatives yet —
// the routine editor (Phase D), the session freeze (Phase E) and the switch
// sheet (Phase F) all come later. This slice adds a column that is nil for
// every existing and every newly-created prescription.
//
// No codec logic lives here. Encoding, decoding and normalization are all the
// Phase B `SlotAlternatives` helpers, so the rules that govern a payload in a
// routine, in a transfer document, and (later) in a frozen session plan are one
// implementation rather than three.

extension SlotPrescription {

    /// The slot's prepared alternatives, decoded and normalized.
    ///
    /// This is the **only** intended read path for `alternativesData`. It
    /// inherits the whole Phase B tolerance contract: a nil column, empty data,
    /// an empty list, a payload from a format this build cannot parse, and a
    /// column hand-edited in a test all read as `[]`; one malformed alternative
    /// inside an otherwise valid payload is dropped and its siblings survive.
    /// A routine can therefore never be made unopenable by its own
    /// alternatives.
    ///
    /// "No alternatives" has exactly one representation — the same rule
    /// `structuredCardioPlan` uses — so no caller checks three states.
    ///
    /// Ordering, dense `order` values and unique ids are guaranteed by the
    /// decode, so a list read here is directly renderable.
    var slotAlternatives: [SlotAlternative] {
        SlotAlternatives.decode(from: alternativesData)
    }

    /// Write site. The list is normalized before encoding, so what lands in the
    /// column is ordered, densely indexed and id-unique regardless of what the
    /// caller assembled.
    ///
    /// An empty list clears the column rather than storing an empty payload, so
    /// "the user deleted the last alternative" and "this slot never had any"
    /// persist identically. Encoding failure also clears, for the same reason
    /// the read path is tolerant: a slot with no alternatives is a valid slot,
    /// a half-written column is not. (Both cases are the Phase B
    /// `SlotAlternatives.encode` contract — it returns nil for each.)
    func setSlotAlternatives(_ alternatives: [SlotAlternative]) {
        alternativesData = SlotAlternatives.encode(alternatives)
    }

    /// Explicit clear, for call sites where `setSlotAlternatives([])` would
    /// read as an accident.
    func clearSlotAlternatives() {
        alternativesData = nil
    }

    /// Whether this slot has any prepared alternative — including disabled
    /// ones, which are still prepared work and still shown in the editor
    /// (§8.7). The switch sheet's "does this slot have anything to offer"
    /// question is a different one and belongs to Phase F, which filters on
    /// `isEnabled` and on whether the exercise still resolves.
    var hasSlotAlternatives: Bool { !slotAlternatives.isEmpty }
}

import Foundation
import SwiftData

// ======================================================
// MARK: - Committing an alternative's scratch draft
// ======================================================
//
// `SlotAlternativeDetailEditor` edits a prepared alternative through a
// **scratch** slot in `AlternativeDraftStore`'s own in-memory container, then
// writes the result back into the `SlotAlternative` payload. Until this slice
// that write-back was *incidental*: the editor read `store.payload()` inside
// its `body` and let `.onChange` notice the value had changed.
//
// That works only while the editor's body keeps being re-evaluated. The warm-up
// and technique editors are **pushed on top of it**, so a step added there
// mutates the scratch graph while the view that owns the commit is off-screen —
// and if the user leaves by a route that never brings it back (switching tabs,
// popping straight to the routine list), the body never runs again, the commit
// never fires, and the draft container is deallocated with the edit still in
// it. Pop back one level first and the same edit *is* saved, which is exactly
// the "sometimes" in the bug report.
//
// The fix is to stop inferring the commit from a value change and to make it a
// call. This is the call, extracted so the write-back rule is testable without
// a view — and so the nested editors can trigger it directly through the
// `onGraphChange` hook they now take.

/// Writes a prepared alternative's in-progress draft back into its slot.
@MainActor
enum AlternativeDraftCommit {

    /// Replace exactly this alternative's fields in `slotPrescription`.
    ///
    /// Reads the stored list, changes only the alternative with `alternativeID`,
    /// and writes the whole list back through `setSlotAlternatives` — so the
    /// slot's own prescription and every sibling alternative are untouched, and
    /// `id` and `order` survive an edit.
    ///
    /// A `nil` draft commits the metadata alone (the enabled toggle and the
    /// note), which is what the editor has before its scratch store finishes
    /// loading. An unknown `alternativeID` writes nothing: the row may have been
    /// deleted on another screen while this editor was open, and re-adding it
    /// from a stale editor would resurrect deleted work.
    ///
    /// - Returns: whether the alternative was found and rewritten.
    @discardableResult
    static func commit(
        draft: AlternativeDraftStore?,
        alternativeID: UUID,
        isEnabled: Bool,
        note: String,
        payload: AlternativePrescriptionPayload? = nil,
        into slotPrescription: SlotPrescription,
        context: ModelContext?
    ) -> Bool {
        var found = false
        // `payload` wins when the caller already has one in hand (the change
        // that triggered the commit); otherwise take the draft's current state.
        let resolved = payload ?? draft?.payload()

        SlotAlternativeAuthoring.update(
            id: alternativeID, in: slotPrescription
        ) {
            found = true
            $0.isEnabled = isEnabled
            $0.note = note
            if let resolved { $0.prescription = resolved }
        }

        if found { try? context?.save() }
        return found
    }
}

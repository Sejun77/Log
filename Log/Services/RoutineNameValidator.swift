import Foundation

/// Pure, UI-free validation for routine renames. Mirrors the trim +
/// case-insensitive duplicate rules used by routine creation
/// (`RoutinesView.addRoutine`), but adds an explicit "revert to previous on
/// empty" outcome and excludes the routine being edited from the duplicate
/// scan — the caller supplies only the names of *other* routines.
///
/// Value-in / value-out: no `ModelContext`, `@Query`, or UI. Safe to unit-test
/// with literal fixtures, mirroring the `RestPlanner` / `SessionPlanResolver`
/// extraction pattern.
enum RoutineNameValidator {
    /// Trims leading/trailing whitespace and newlines.
    /// Returns `nil` when the trimmed result is empty.
    static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    enum RenameOutcome: Equatable {
        /// Trimmed value is empty → caller should revert to `previous`.
        case empty
        /// Trimmed value equals `previous` exactly → no write needed.
        case unchanged
        /// Trimmed value collides (case-insensitively) with another routine.
        case duplicate(String)
        /// Accept this trimmed value as the new name.
        case ok(String)
    }

    /// - Parameters:
    ///   - raw: user-entered text.
    ///   - previous: the routine's current (already-valid) name.
    ///   - otherNames: names of every *other* routine; the edited routine must
    ///     be excluded by the caller (by `id`) so a no-op re-save of the same
    ///     name is never misread as a duplicate.
    static func validateRename(
        raw: String,
        previous: String,
        otherNames: [String]
    ) -> RenameOutcome {
        guard let trimmed = sanitized(raw) else { return .empty }
        if trimmed == previous { return .unchanged }
        if otherNames.contains(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .duplicate(trimmed)
        }
        return .ok(trimmed)
    }
}

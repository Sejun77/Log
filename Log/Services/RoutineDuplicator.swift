import Foundation

/// Authoring-side helper for duplicating a routine. Slice A provides only the
/// pure copied-name generator; the deep-copy service (Slice B) and UI (Slice C)
/// land later. Kept as an `enum` namespace mirroring `RoutineBlockBuilder` /
/// `RoutineNameValidator`.
enum RoutineDuplicator {
    /// Fallback base used when the original routine name is empty / whitespace
    /// only, so a duplicate always gets a sensible non-empty name.
    static let fallbackBaseName = "Routine"

    /// Generates a unique name for a duplicated routine.
    ///
    /// Rule (confirmed): base = `"<trimmed original> copy"`; if that collides
    /// (case-insensitively) with an existing routine name, append an
    /// incrementing suffix — `"… copy 2"`, `"… copy 3"`, … — until unique.
    /// Both the original name and the `existingNames` are trimmed of leading /
    /// trailing whitespace and newlines before comparison. An empty /
    /// whitespace-only original falls back to `"Routine"` (→ `"Routine copy"`).
    ///
    /// Pure value-in / value-out — no `ModelContext`, no SwiftData, no
    /// mutation — so it is unit-testable with literal fixtures, mirroring
    /// `RoutineNameValidator`.
    static func copiedName(
        for originalName: String,
        existingNames: [String]
    ) -> String {
        let trimmedOriginal = originalName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let base = trimmedOriginal.isEmpty ? fallbackBaseName : trimmedOriginal

        // Normalize existing names once for case-insensitive lookup.
        let taken = Set(
            existingNames
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                .filter { !$0.isEmpty }
        )

        func isTaken(_ candidate: String) -> Bool {
            taken.contains(candidate.lowercased())
        }

        let first = "\(base) copy"
        if !isTaken(first) { return first }

        // Start suffixing at 2: "… copy 2", "… copy 3", …
        var n = 2
        while isTaken("\(base) copy \(n)") { n += 1 }
        return "\(base) copy \(n)"
    }
}

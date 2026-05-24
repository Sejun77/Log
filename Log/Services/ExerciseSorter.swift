import Foundation

// MARK: - ExerciseSortMode

/// User-selectable display order for the Exercises tab list. Stored as the
/// raw `String` value in `@AppStorage("exercisesSortMode")` so the enum can
/// be reordered without invalidating saved preferences. `.manual` is the
/// default, preserves the pre-Phase-10-polish drag-to-reorder behavior, and
/// is the only mode under which `Exercise.order` writes have any effect.
enum ExerciseSortMode: String, CaseIterable, Identifiable {
    case manual
    case alphabetical
    case bodyPart
    case equipment

    var id: String { rawValue }

    /// User-facing label for the toolbar Picker.
    var label: String {
        switch self {
        case .manual: return "Manual"
        case .alphabetical: return "Name"
        case .bodyPart: return "Body Part"
        case .equipment: return "Equipment"
        }
    }

    /// SF Symbol for the Picker row icon.
    var systemImage: String {
        switch self {
        case .manual: return "line.3.horizontal"
        case .alphabetical: return "textformat"
        case .bodyPart: return "figure.strengthtraining.traditional"
        case .equipment: return "dumbbell"
        }
    }
}

// MARK: - ExerciseSorter

/// Pure namespace that sorts an `[Exercise]` array by the user-selected
/// `ExerciseSortMode`. Takes the array by value and returns a new array —
/// never mutates the input or touches any `ModelContext` / `@Query`.
///
/// `.manual` mirrors the existing `@Query(sort: [order, name])` ordering so
/// the helper is self-contained and tests pin the rule independent of how
/// the input was sourced. `.alphabetical`, `.bodyPart`, and `.equipment`
/// use `localizedStandardCompare` for case-, diacritic-, and locale-aware
/// natural ordering. Trailing whitespace and empty strings are treated as
/// nil (same `trimmedOrNil` semantics as the 10-polish-A/B display helpers)
/// so a blank `bodyPart` / `equipmentType` never sorts between two named
/// rows.
///
/// Nil/blank `bodyPart` / `equipmentType` rows sort **after** all named
/// rows under `.bodyPart` / `.equipment`. Within each named bucket, rows
/// are ordered by name. Within the trailing nil bucket, rows are ordered
/// by name as a stable tiebreaker.
enum ExerciseSorter {
    static func sort(_ items: [Exercise], mode: ExerciseSortMode) -> [Exercise] {
        switch mode {
        case .manual:
            return items.sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .alphabetical:
            return items.sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .bodyPart:
            return sortedByOptionalString(items, key: \.bodyPart)
        case .equipment:
            return sortedByOptionalString(items, key: \.equipmentType)
        }
    }

    private static func sortedByOptionalString(
        _ items: [Exercise],
        key: KeyPath<Exercise, String?>
    ) -> [Exercise] {
        items.sorted { lhs, rhs in
            let lv = trimmedOrNil(lhs[keyPath: key])
            let rv = trimmedOrNil(rhs[keyPath: key])
            switch (lv, rv) {
            case let (l?, r?):
                let result = l.localizedStandardCompare(r)
                if result != .orderedSame { return result == .orderedAscending }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private static func trimmedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

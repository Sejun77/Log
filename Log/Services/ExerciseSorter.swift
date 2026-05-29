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

// MARK: - ExerciseSection

/// One contiguous group of exercises sharing the same `bodyPart` /
/// `equipmentType` value, produced by `ExerciseSorter.sections(_:mode:)`.
/// `title` is the display/header string — either the (trimmed) field value
/// or the shared `ExerciseSorter.unspecifiedSectionTitle` for the trailing
/// nil/blank bucket. `id == title`; titles are unique within a result
/// because the producer merges adjacent runs of an identical title.
struct ExerciseSection: Identifiable {
    let title: String
    let items: [Exercise]
    var id: String { title }
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
    /// Header title for the trailing group of rows whose grouping field is
    /// nil / empty / whitespace-only (see `trimmedOrNil`). Shared constant so
    /// the helper and any UI / tests agree on the exact string.
    static let unspecifiedSectionTitle = "Unspecified"

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

    /// Groups `items` into ordered sections for the grouped sort modes.
    ///
    /// Returns `nil` for `.manual` and `.alphabetical` — those modes have no
    /// headers and the UI should render the flat `sort(_:mode:)` result. For
    /// `.bodyPart` / `.equipment` it returns sections in the **same order**
    /// the rows appear in `sort(_:mode:)` (so named sections follow the
    /// `localizedStandardCompare` ascending order and the nil/blank bucket —
    /// titled `unspecifiedSectionTitle` — always lands last). Rows inside each
    /// section keep their sorted order (name tiebreaker).
    ///
    /// Pure: reads `bodyPart` / `equipmentType` only, never mutates any
    /// exercise, `order`, or store. Pass an already name-filtered array to get
    /// search-compatible sections — empty groups simply never appear because
    /// the grouping walks only the rows it is given. Sections are built by
    /// partitioning contiguous runs of an identical title (not
    /// `Dictionary(grouping:)`), so ordering never depends on dictionary
    /// iteration order.
    static func sections(
        _ items: [Exercise],
        mode: ExerciseSortMode
    ) -> [ExerciseSection]? {
        let key: KeyPath<Exercise, String?>
        switch mode {
        case .manual, .alphabetical:
            return nil
        case .bodyPart:
            key = \.bodyPart
        case .equipment:
            key = \.equipmentType
        }

        let sorted = sort(items, mode: mode)
        var sections: [ExerciseSection] = []
        var currentTitle: String?
        var bucket: [Exercise] = []

        for ex in sorted {
            let title = trimmedOrNil(ex[keyPath: key]) ?? unspecifiedSectionTitle
            if title == currentTitle {
                bucket.append(ex)
            } else {
                if let currentTitle {
                    sections.append(
                        ExerciseSection(title: currentTitle, items: bucket)
                    )
                }
                currentTitle = title
                bucket = [ex]
            }
        }
        if let currentTitle {
            sections.append(ExerciseSection(title: currentTitle, items: bucket))
        }
        return sections
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

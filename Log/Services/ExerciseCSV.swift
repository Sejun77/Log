import Foundation

/// One row of the v1 `exercises.csv` schema — the flat projection of an
/// `Exercise` used by CSV export/import (REMAINING_WORK_PLAN.md §3.10).
///
/// Carries no `id` / `isCustom` / `order`: those are never read from a file.
/// The importer (Slice 4) generates `id`, forces `isCustom = true`, and assigns
/// `order` after `max(existing.order)` — see the §3.10 data-safety rules.
/// All optional string fields use `nil` as the canonical "absent" form; the
/// parser normalizes empty/whitespace-only cells to `nil`.
struct ExerciseCSVRow: Equatable {
    var name: String
    var bodyPart: String?
    var equipmentType: String?
    var setupDefaults: String?
    var isTimeBased: Bool
    var notes: String?

    init(
        name: String,
        bodyPart: String? = nil,
        equipmentType: String? = nil,
        setupDefaults: String? = nil,
        isTimeBased: Bool = false,
        notes: String? = nil
    ) {
        self.name = name
        self.bodyPart = bodyPart
        self.equipmentType = equipmentType
        self.setupDefaults = setupDefaults
        self.isTimeBased = isTimeBased
        self.notes = notes
    }
}

/// Pure parser / validator + exporter for the v1 `exercises.csv` schema. Maps
/// between CSV text (via `CSVCodec`) and `[ExerciseCSVRow]`. No SwiftData, no
/// UI, no file I/O — the dedupe-against-existing-rows + insert behavior is a
/// later slice (Slice 4) layered on top of the `valid` rows this produces.
///
/// Validation contract:
///   - A **header** problem fails the whole file (`.failure`) before any data
///     row is considered — there is never a partial commit on a malformed file.
///   - Each **data row** lands in exactly one bucket: `valid`, `skipped`, or
///     `rejected`. Skips are benign (empty rows, in-file duplicate names);
///     rejects are errors (wrong column count, missing name, unparseable
///     `isTimeBased`) and carry a reason for the import preview.
///   - Body part / equipment / setup / notes are **soft**: any free-text value
///     is accepted (non-canonical values persist as custom later, matching
///     `CustomOptionStore`); they are never a reject reason.
enum ExerciseCSV {
    /// Canonical v1 header, fixed column order. Export emits exactly this;
    /// import requires exactly these columns (compared trimmed + case-insensitive).
    static let header = [
        "name", "bodyPart", "equipmentType", "setupDefaults", "isTimeBased", "notes",
    ]

    private static let columnCount = header.count

    // MARK: - Export

    /// Serialize rows to CSV text: the canonical header followed by one record
    /// per row. `nil` optionals are written as empty cells; `isTimeBased`
    /// writes `"true"` / `"false"`.
    static func export(_ rows: [ExerciseCSVRow]) -> String {
        var grid: [[String]] = [header]
        for r in rows {
            grid.append([
                r.name,
                r.bodyPart ?? "",
                r.equipmentType ?? "",
                r.setupDefaults ?? "",
                r.isTimeBased ? "true" : "false",
                r.notes ?? "",
            ])
        }
        return CSVCodec.encode(grid)
    }

    // MARK: - Parse / validate

    /// Why an otherwise well-formed data row was skipped (not an error).
    enum SkipReason: Equatable {
        /// Every cell was empty/whitespace (or a blank line).
        case emptyRow
        /// A row earlier in the same file already used this name
        /// (trimmed + lowercased). The first occurrence is kept.
        case duplicateNameInFile(String)
    }

    /// Why a data row was rejected as invalid.
    enum RejectReason: Equatable {
        case wrongColumnCount(expected: Int, found: Int)
        case missingName
        case invalidIsTimeBased(String)

        /// Human-readable reason for the import preview.
        var message: String {
            switch self {
            case let .wrongColumnCount(expected, found):
                return "Expected \(expected) columns, found \(found)."
            case .missingName:
                return "Missing exercise name."
            case let .invalidIsTimeBased(value):
                return "Invalid isTimeBased value \"\(value)\" (use true or false)."
            }
        }
    }

    struct SkippedRow: Equatable {
        /// 1-based source row number, counting the header as row 1.
        let row: Int
        let reason: SkipReason
    }

    struct RejectedRow: Equatable {
        /// 1-based source row number, counting the header as row 1.
        let row: Int
        let reason: RejectReason
        /// The raw fields, preserved so the preview can echo the offending row.
        let fields: [String]
    }

    /// A whole-file failure surfaced before any data row is processed.
    enum HeaderError: Error, Equatable {
        /// The file had no rows at all (empty input).
        case empty
        case mismatch(expected: [String], found: [String])

        var message: String {
            switch self {
            case .empty:
                return "The file is empty."
            case let .mismatch(expected, found):
                return "Header mismatch. Expected: \(expected.joined(separator: ", ")). "
                    + "Found: \(found.joined(separator: ", "))."
            }
        }
    }

    struct ParseReport: Equatable {
        var valid: [ExerciseCSVRow]
        var skipped: [SkippedRow]
        var rejected: [RejectedRow]
    }

    /// Parse + validate CSV text. Returns `.failure` on a header problem (no
    /// rows processed), otherwise a `.success(ParseReport)` partitioning every
    /// data row into valid / skipped / rejected.
    static func parse(_ text: String) -> Result<ParseReport, HeaderError> {
        let grid = CSVCodec.parse(text)
        guard let headerRow = grid.first else { return .failure(.empty) }

        guard headerMatches(headerRow) else {
            return .failure(.mismatch(expected: header, found: headerRow))
        }

        var report = ParseReport(valid: [], skipped: [], rejected: [])
        var seenNameKeys = Set<String>()

        for (index, fields) in grid.enumerated() where index > 0 {
            let rowNumber = index + 1  // 1-based, header is row 1

            if isBlank(fields) {
                report.skipped.append(.init(row: rowNumber, reason: .emptyRow))
                continue
            }

            guard fields.count == columnCount else {
                report.rejected.append(.init(
                    row: rowNumber,
                    reason: .wrongColumnCount(expected: columnCount, found: fields.count),
                    fields: fields
                ))
                continue
            }

            let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                report.rejected.append(.init(
                    row: rowNumber, reason: .missingName, fields: fields
                ))
                continue
            }

            let rawTimeBased = fields[4]
            guard let isTimeBased = parseBool(rawTimeBased) else {
                report.rejected.append(.init(
                    row: rowNumber,
                    reason: .invalidIsTimeBased(
                        rawTimeBased.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    fields: fields
                ))
                continue
            }

            let nameKey = name.lowercased()
            guard seenNameKeys.insert(nameKey).inserted else {
                report.skipped.append(.init(
                    row: rowNumber, reason: .duplicateNameInFile(name)
                ))
                continue
            }

            report.valid.append(ExerciseCSVRow(
                name: name,
                bodyPart: trimmedToNil(fields[1]),
                equipmentType: trimmedToNil(fields[2]),
                setupDefaults: trimmedToNil(fields[3]),
                isTimeBased: isTimeBased,
                notes: trimmedToNil(fields[5])
            ))
        }

        return .success(report)
    }

    // MARK: - Helpers

    /// Header is accepted when it has the right column count and each column
    /// matches the canonical name trimmed + case-insensitively (so `Name` or
    /// ` name ` from a spreadsheet still validate).
    private static func headerMatches(_ row: [String]) -> Bool {
        guard row.count == header.count else { return false }
        for (lhs, rhs) in zip(row, header) {
            let l = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if l != rhs.lowercased() { return false }
        }
        return true
    }

    /// True when every field is empty or whitespace-only (covers blank lines,
    /// which the codec yields as `[""]`, and all-comma `,,,,,` rows).
    private static func isBlank(_ fields: [String]) -> Bool {
        fields.allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func trimmedToNil(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Lenient boolean cell parse. Empty/whitespace defaults to `false`;
    /// accepts true/false, yes/no, 1/0 (case-insensitive). Returns `nil` for
    /// anything else so the caller can reject the row with the raw value.
    private static func parseBool(_ raw: String) -> Bool? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch t {
        case "": return false
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
}

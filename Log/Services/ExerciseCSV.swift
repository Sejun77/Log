import Foundation

/// One row of the `exercises.csv` schema — the flat projection of an
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

    /// Cardio Phase 1, Slice 9. Appended **last** in the parameter list (and
    /// last in the CSV column order) so every existing construction site keeps
    /// compiling and every v1 file keeps parsing; absent means `false`.
    var isCardio: Bool

    /// The initializer normalizes `Exercise`'s cardio invariant — cardio
    /// implies time-based — so a row can never carry the impossible
    /// `isCardio && !isTimeBased` state that `Exercise.trackingMode` would have
    /// to degrade to `.strength`. A hand-edited file claiming cardio therefore
    /// imports *as cardio* rather than being silently downgraded.
    init(
        name: String,
        bodyPart: String? = nil,
        equipmentType: String? = nil,
        setupDefaults: String? = nil,
        isTimeBased: Bool = false,
        notes: String? = nil,
        isCardio: Bool = false
    ) {
        self.name = name
        self.bodyPart = bodyPart
        self.equipmentType = equipmentType
        self.setupDefaults = setupDefaults
        self.isTimeBased = isTimeBased || isCardio
        self.notes = notes
        self.isCardio = isCardio
    }
}

/// Pure parser / validator + exporter for the `exercises.csv` schema. Maps
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
///     `isTimeBased` / `isCardio`) and carry a reason for the import preview.
///   - Body part / equipment / setup / notes are **soft**: any free-text value
///     is accepted (non-canonical values persist as custom later, matching
///     `CustomOptionStore`); they are never a reject reason.
///
/// **Versioning (Cardio Phase 1, Slice 9).** v2 appends one column, `isCardio`,
/// to the end of the v1 order. There is no version *marker* column — the header
/// itself identifies the format, which is what lets a v1 file keep importing
/// untouched. Export always writes v2; import accepts either header and treats
/// a v1 file as `isCardio = false` throughout. New columns are always appended,
/// never inserted, so a v1 reader still finds each old column at its old index.
enum ExerciseCSV {

    /// The header shapes this parser understands. Column *order* is fixed
    /// within each; the format is chosen by matching the file's header row.
    enum Format: Equatable {
        /// Pre-cardio, 6 columns.
        case v1
        /// v1 + `isCardio`, 7 columns.
        case v2

        var columns: [String] {
            switch self {
            case .v1: return ExerciseCSV.headerV1
            case .v2: return ExerciseCSV.header
            }
        }

        var columnCount: Int { columns.count }
    }

    /// Canonical **v2** header, fixed column order. Export emits exactly this.
    static let header = [
        "name", "bodyPart", "equipmentType", "setupDefaults", "isTimeBased",
        "notes", "isCardio",
    ]

    /// The v1 header, still accepted on import (backward compatibility).
    static let headerV1 = Array(header.dropLast())

    /// Zero-based index of the `isCardio` cell in a v2 row.
    private static let isCardioColumn = header.count - 1

    // MARK: - Export

    /// Serialize rows to CSV text: the canonical **v2** header followed by one
    /// record per row. `nil` optionals are written as empty cells;
    /// `isTimeBased` / `isCardio` write `"true"` / `"false"`.
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
                r.isCardio ? "true" : "false",
            ])
        }
        return CSVCodec.encode(grid)
    }

    /// Pure projection of `Exercise` definition rows onto the flat CSV schema,
    /// preserving the given order (the caller — e.g. the Exercises tab — decides
    /// ordering; this never sorts or mutates). Only the definition-level fields
    /// are carried; `id`, `order`, `isCustom`, and the `routineUsages` /
    /// `workoutItems` relationships are intentionally omitted (see the §3.10
    /// data-safety rules — identifiers are never round-tripped). Empty /
    /// whitespace-only optional fields are normalized to the canonical `nil`
    /// form so exported data round-trips cleanly back through `parse`.
    static func rows(from exercises: [Exercise]) -> [ExerciseCSVRow] {
        exercises.map { ex in
            ExerciseCSVRow(
                name: ex.name,
                bodyPart: trimmedToNil(ex.bodyPart),
                equipmentType: trimmedToNil(ex.equipmentType),
                setupDefaults: trimmedToNil(ex.setupDefaults),
                isTimeBased: ex.isTimeBased,
                notes: trimmedToNil(ex.notes),
                // Read the stored flag rather than `trackingMode`: the mode is
                // a *derived view* that degrades an inconsistent store to
                // `.strength`, and an export should carry what is actually
                // recorded. `ExerciseCSVRow`'s initializer applies the same
                // cardio-implies-time-based normalization the model does.
                isCardio: ex.isCardio
            )
        }
    }

    /// Convenience: map `Exercise` definitions to rows and serialize in one
    /// step. Read-only — touches no `ModelContext`. Distinct argument label
    /// avoids overload ambiguity with `export(_ rows:)` for empty literals.
    static func export(exercises: [Exercise]) -> String {
        export(rows(from: exercises))
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
        /// Unparseable `isCardio` cell (v2 files only). Rejecting rather than
        /// defaulting to `false` matches how `isTimeBased` already behaves —
        /// a value the user typed and we cannot read is an error to surface,
        /// not one to silently reinterpret.
        case invalidIsCardio(String)

        /// Human-readable reason for the import preview.
        var message: String {
            switch self {
            case let .wrongColumnCount(expected, found):
                return "Expected \(expected) columns, found \(found)."
            case .missingName:
                return "Missing exercise name."
            case let .invalidIsTimeBased(value):
                return "Invalid isTimeBased value \"\(value)\" (use true or false)."
            case let .invalidIsCardio(value):
                return "Invalid isCardio value \"\(value)\" (use true or false)."
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
                // `expected` is the current (v2) header. The older header
                // without `isCardio` is still accepted, so say so rather than
                // letting someone with a pre-cardio export conclude their file
                // is unusable.
                return "Header mismatch. Expected: \(expected.joined(separator: ", ")). "
                    + "Found: \(found.joined(separator: ", ")). "
                    + "The older header without isCardio is also accepted."
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
    ///
    /// Accepts both the v2 header and the older v1 header; a v1 file yields
    /// rows with `isCardio == false`.
    static func parse(_ text: String) -> Result<ParseReport, HeaderError> {
        let grid = CSVCodec.parse(text)
        guard let headerRow = grid.first else { return .failure(.empty) }

        guard let format = format(for: headerRow) else {
            return .failure(.mismatch(expected: header, found: headerRow))
        }
        let columnCount = format.columnCount

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

            // v1 files have no cell here at all; absent means "not cardio".
            var isCardio = false
            if format == .v2 {
                let rawCardio = fields[isCardioColumn]
                guard let parsed = parseBool(rawCardio) else {
                    report.rejected.append(.init(
                        row: rowNumber,
                        reason: .invalidIsCardio(
                            rawCardio.trimmingCharacters(in: .whitespacesAndNewlines)
                        ),
                        fields: fields
                    ))
                    continue
                }
                isCardio = parsed
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
                notes: trimmedToNil(fields[5]),
                isCardio: isCardio
            ))
        }

        return .success(report)
    }

    // MARK: - Helpers

    /// Identify the file's format from its header row, or `nil` when it matches
    /// neither. v2 is tried first so the current export always resolves in one
    /// comparison. A header is accepted when it has that format's column count
    /// and each column matches the canonical name trimmed + case-insensitively
    /// (so `Name` or ` name ` from a spreadsheet still validate).
    static func format(for row: [String]) -> Format? {
        [Format.v2, .v1].first { matches(row, $0.columns) }
    }

    private static func matches(_ row: [String], _ columns: [String]) -> Bool {
        guard row.count == columns.count else { return false }
        for (lhs, rhs) in zip(row, columns) {
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

    /// Optional-accepting overload for mapping `Exercise` fields (which are
    /// `String?`); `nil` in stays `nil` out.
    private static func trimmedToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return trimmedToNil(raw)
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

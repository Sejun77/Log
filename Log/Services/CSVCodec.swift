import Foundation

/// Pure, dependency-free RFC 4180 CSV codec. Encodes/parses a grid of `String`
/// fields and knows nothing about the Log domain (see `ExerciseCSV` for the
/// Exercise-row mapping built on top of it). Value-in / value-out — no
/// Foundation file I/O, no SwiftData, no UI — so it is fully unit-testable with
/// literal fixtures, mirroring `RoutineNameValidator` / `RestPlanner`.
///
/// This is CSV Slice 1 (see REMAINING_WORK_PLAN.md §3.10): the foundation every
/// later export/import slice sits on.
enum CSVCodec {
    /// Encode rows of fields into a single CSV string.
    ///
    /// A field is quoted only when it contains a comma, double-quote, CR, or LF;
    /// embedded double-quotes are escaped by doubling (`"` → `""`). Records are
    /// CRLF-terminated *between* rows (no trailing newline after the last row),
    /// so `encode` round-trips cleanly back through `parse`.
    static func encode(_ rows: [[String]]) -> String {
        rows
            .map { row in row.map(escapeField).joined(separator: ",") }
            .joined(separator: "\r\n")
    }

    private static func escapeField(_ field: String) -> String {
        let needsQuoting =
            field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        guard needsQuoting else { return field }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Parse a CSV string into rows of fields.
    ///
    /// Handles quoted fields with embedded commas, doubled-quote escapes, and
    /// embedded CR/LF newlines. Accepts CRLF, LF, or a lone CR as a record
    /// break, and strips a leading UTF-8 BOM (Excel/Numbers commonly prepend
    /// one). A single trailing newline does not produce a spurious empty
    /// trailing record. An empty input yields `[]`; a blank line yields a
    /// one-element `[""]` record (the `ExerciseCSV` layer treats that as an
    /// empty row and skips it).
    static func parse(_ text: String) -> [[String]] {
        // Iterate over Unicode scalars, not `Character`s: Swift treats a CRLF
        // pair as a *single* grapheme-cluster `Character`, which would hide the
        // record break. Scalars keep CR and LF distinct.
        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        let bom: Unicode.Scalar = "\u{FEFF}"

        var scalars = Array(text.unicodeScalars)
        if scalars.first == bom { scalars.removeFirst() }

        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        // Tracks whether the current record has produced any content at all, so
        // a terminating newline doesn't synthesize a phantom empty final record.
        var recordHasContent = false

        func endField() {
            row.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            rows.append(row)
            row = []
            recordHasContent = false
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    // Doubled quote inside a quoted field == one literal quote.
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        field.unicodeScalars.append(quote)
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.unicodeScalars.append(c)
                    i += 1
                }
                continue
            }

            switch c {
            case quote:
                inQuotes = true
                recordHasContent = true
                i += 1
            case comma:
                recordHasContent = true
                endField()
                i += 1
            case cr:
                endRecord()
                // Swallow the LF of a CRLF pair.
                if i + 1 < scalars.count && scalars[i + 1] == lf {
                    i += 2
                } else {
                    i += 1
                }
            case lf:
                endRecord()
                i += 1
            default:
                field.unicodeScalars.append(c)
                recordHasContent = true
                i += 1
            }
        }

        // Flush a final record that wasn't newline-terminated.
        if recordHasContent || !field.isEmpty || !row.isEmpty {
            endRecord()
        }
        return rows
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Minimal `FileDocument` wrapping a UTF-8 JSON string, used by `fileExporter`
/// to write a routine export to a user-chosen location (Routine Transfer v2,
/// REMAINING_WORK_PLAN.md §2.14, Slice E). Sibling of `CSVDocument` —
/// intentionally tiny; the JSON itself is produced by the already-tested
/// `RoutineTransfer.export` + `RoutineTransfer.makeJSONEncoder`.
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    static var writableContentTypes: [UTType] { [.json] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        // Read exists only to satisfy the protocol; this document is write-only
        // in practice (export). Decode best-effort.
        if let data = configuration.file.regularFileContents,
            let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

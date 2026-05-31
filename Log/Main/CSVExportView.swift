import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Minimal `FileDocument` wrapping a UTF-8 CSV string, used by `fileExporter`
/// to write the export to a user-chosen location (CSV Slice 6,
/// REMAINING_WORK_PLAN.md §3.10). Intentionally tiny — no custom document
/// system; just enough to satisfy `fileExporter`'s write path. CSV generation
/// itself lives in the already-tested `ExerciseCSV` / `WorkoutHistoryCSV`
/// services.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        // Read is only here to satisfy the protocol; this document is
        // write-only in practice (export). Decode best-effort.
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

/// Settings rows for exporting the exercise library and workout history as CSV.
/// Self-contained: owns the `fileExporter` state and reads the store via
/// `@Environment(\.modelContext)`. Export is read-only — it fetches, serializes,
/// and presents a Save dialog; it never mutates or deletes anything, and the
/// generated CSV carries no IDs / SwiftData identifiers (the export services
/// omit them).
///
/// Empty-data behavior: export is always allowed. With no rows the serializers
/// emit a header-only CSV (a valid, useful template), so there is no special
/// disabled state or warning to reason about.
struct DataExportButtons: View {
    @Environment(\.modelContext) private var modelContext

    @State private var document = CSVDocument(text: "")
    @State private var filename = "export"
    @State private var isExporterPresented = false
    @State private var alert: AlertInfo?

    var body: some View {
        Group {
            Button(action: exportExercises) {
                Label("Export Exercises CSV", systemImage: "square.and.arrow.up")
            }
            Button(action: exportHistory) {
                Label("Export Workout History CSV", systemImage: "square.and.arrow.up")
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: document,
            contentType: .commaSeparatedText,
            defaultFilename: filename,
            onCompletion: handleExport
        )
        .alert(
            alert?.title ?? "",
            isPresented: Binding(
                get: { alert != nil },
                set: { if !$0 { alert = nil } }
            ),
            presenting: alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { info in
            Text(info.message)
        }
    }

    // MARK: - Export actions (generate on tap, not in body)

    private func exportExercises() {
        let exercises = (try? modelContext.fetch(
            FetchDescriptor<Exercise>(
                sortBy: [SortDescriptor(\.order), SortDescriptor(\.name)]
            )
        )) ?? []
        present(text: ExerciseCSV.export(exercises: exercises), filename: "log-exercises")
    }

    private func exportHistory() {
        let workouts = (try? modelContext.fetch(
            FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.date)])
        )) ?? []
        present(text: WorkoutHistoryCSV.export(workouts: workouts), filename: "log-workout-history")
    }

    private func present(text: String, filename: String) {
        document = CSVDocument(text: text)
        self.filename = filename
        isExporterPresented = true
    }

    // MARK: - Completion

    private func handleExport(_ result: Result<URL, Error>) {
        if case let .failure(error) = result {
            // The system reports an explicit user cancel as an error on some
            // OS versions; don't surface that as a failure.
            let nsError = error as NSError
            guard nsError.code != NSUserCancelledError else { return }
            alert = AlertInfo(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}

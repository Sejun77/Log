import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings row + flow for importing an `exercises.csv` file (CSV Slice 5,
/// REMAINING_WORK_PLAN.md §3.10). Self-contained: owns all import state so the
/// host (`SettingsView`) just embeds it. Wires the existing pure
/// `ExerciseCSV.parse` validator to the `ExerciseCSVImporter` SwiftData service
/// behind an explicit preview + confirm step.
///
/// Flow: tap → `fileImporter` → read UTF-8 → parse → either an error alert
/// (unreadable file / non-UTF-8 / invalid header) or a preview sheet. The
/// preview's **Import** runs the importer (additive-only; never overwrites or
/// deletes); **Cancel** commits nothing. A result alert follows a completed
/// import. The import is performed *before* the sheet dismisses and the result
/// alert is raised in the sheet's `onDismiss`, so the data write never races the
/// sheet/alert presentation.
struct ExerciseCSVImportButton: View {
    @Environment(\.modelContext) private var modelContext

    @State private var isPickerPresented = false
    @State private var preview: PreviewData?
    @State private var pendingResult: ExerciseCSVImporter.ImportReport?
    @State private var alert: AlertInfo?

    var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            Label("Import Exercises from CSV", systemImage: "square.and.arrow.down")
        }
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false,
            onCompletion: handlePick
        )
        .sheet(item: $preview, onDismiss: handleSheetDismiss) { data in
            ExerciseImportPreview(
                report: data.report,
                onConfirm: {
                    // Commit the import while the sheet is still up, then drop
                    // the binding to dismiss it; the result alert is raised in
                    // onDismiss so it doesn't collide with the sheet animation.
                    pendingResult = ExerciseCSVImporter.import(
                        data.report, into: modelContext
                    )
                    preview = nil
                },
                onCancel: { preview = nil }  // commits nothing
            )
        }
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

    // MARK: - File pick → parse

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            alert = AlertInfo(title: "Import Failed", message: error.localizedDescription)
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                let text = try readUTF8(at: url)
                switch ExerciseCSV.parse(text) {
                case let .failure(headerError):
                    // Invalid header → error alert, do NOT open the preview.
                    alert = AlertInfo(title: "Invalid CSV", message: headerError.message)
                case let .success(report):
                    preview = PreviewData(report: report)
                }
            } catch let error as ReadError {
                alert = AlertInfo(title: "Couldn’t Read File", message: error.message)
            } catch {
                alert = AlertInfo(
                    title: "Couldn’t Read File", message: error.localizedDescription
                )
            }
        }
    }

    /// Read a security-scoped file as UTF-8 text, throwing `ReadError` when the
    /// bytes aren't valid UTF-8.
    private func readUTF8(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReadError(message: "This file isn’t valid UTF-8 text.")
        }
        return text
    }

    // MARK: - Result alert (after sheet dismissal)

    private func handleSheetDismiss() {
        guard let result = pendingResult else { return }  // Cancel leaves it nil
        pendingResult = nil
        alert = AlertInfo(title: "Import Complete", message: Self.resultMessage(result))
    }

    /// Build the result-alert body from the import report. Internal + static so
    /// it stays a pure value-in/value-out function (testable, no view state).
    static func resultMessage(_ r: ExerciseCSVImporter.ImportReport) -> String {
        var lines = ["Added \(r.insertedCount) \(plural("exercise", r.insertedCount))."]
        if r.skippedDuplicateCount > 0 {
            lines.append(
                "Skipped \(r.skippedDuplicateCount) duplicate \(plural("name", r.skippedDuplicateCount))."
            )
        }
        if !r.parseRejected.isEmpty {
            lines.append(
                "Ignored \(r.parseRejected.count) invalid \(plural("row", r.parseRejected.count))."
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func plural(_ noun: String, _ count: Int) -> String {
        count == 1 ? noun : noun + "s"
    }

    // MARK: - Local value types

    /// Identifiable wrapper so `ParseReport` can drive `.sheet(item:)`.
    private struct PreviewData: Identifiable {
        let id = UUID()
        let report: ExerciseCSV.ParseReport
    }

    private struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Thrown by `readUTF8` for a non-UTF-8 file (distinct from the
    /// `Data(contentsOf:)` system error so the alert copy is clearer).
    private struct ReadError: Error {
        let message: String
    }
}

/// Read-only preview of a parsed `exercises.csv`: a summary of how many rows
/// will import / were skipped in-file / are invalid, the list of names to add,
/// and the reasons for skips/rejects. **Import** is disabled when there is
/// nothing to import. Confirms/cancels via injected closures so the host owns
/// the actual SwiftData write.
struct ExerciseImportPreview: View {
    let report: ExerciseCSV.ParseReport
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var hasImportable: Bool { !report.valid.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                summarySection

                if hasImportable {
                    Section("Exercises to add (\(report.valid.count))") {
                        ForEach(Array(report.valid.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                if let subtitle = subtitle(for: row) {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("No importable rows were found in this file.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !report.skipped.isEmpty {
                    Section("Skipped in file (\(report.skipped.count))") {
                        ForEach(Array(report.skipped.enumerated()), id: \.offset) { _, s in
                            Text("Row \(s.row): \(Self.skipText(s.reason))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !report.rejected.isEmpty {
                    Section("Invalid rows (\(report.rejected.count))") {
                        ForEach(Array(report.rejected.enumerated()), id: \.offset) { _, r in
                            Text("Row \(r.row): \(r.reason.message)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Import Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onConfirm)
                        .disabled(!hasImportable)
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("Ready to import", value: "\(report.valid.count)")
            LabeledContent("Skipped in file", value: "\(report.skipped.count)")
            LabeledContent("Invalid rows", value: "\(report.rejected.count)")
        } footer: {
            Text("Exercises whose name already exists are skipped on import. "
                + "Nothing is overwritten or deleted.")
        }
    }

    private func subtitle(for row: ExerciseCSVRow) -> String? {
        var parts: [String] = []
        if let bodyPart = row.bodyPart { parts.append(bodyPart) }
        if let equipment = row.equipmentType { parts.append(equipment) }
        if row.isTimeBased { parts.append("Time-based") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func skipText(_ reason: ExerciseCSV.SkipReason) -> String {
        switch reason {
        case .emptyRow:
            return "Empty row"
        case let .duplicateNameInFile(name):
            return "Duplicate of “\(name)” earlier in the file"
        }
    }
}

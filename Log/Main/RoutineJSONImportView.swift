import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings row + flow for importing a routine JSON file (Routine Transfer v2,
/// REMAINING_WORK_PLAN.md §2.14, Slice D). Self-contained: owns all import
/// state so the host (`SettingsView`) just embeds it. Wires the existing
/// `RoutineTransferDocument` decoder + schema validation (Slice A) and the
/// `RoutineTransfer.import` SwiftData service (Slice C) behind an explicit
/// preview + confirm step.
///
/// Flow: tap → `fileImporter` → read file → decode `RoutineTransferDocument` →
/// validate `schemaVersion` → either a friendly error alert (unreadable /
/// invalid JSON / newer-version) or a preview sheet. The preview's **Import**
/// runs the service (additive-only; new routine, never overwrites/deletes);
/// **Cancel** commits nothing. A result alert follows a completed import,
/// raised in the sheet's `onDismiss` so the write never races presentation.
struct RoutineJSONImportButton: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var routines: [Routine]
    @Query private var exercises: [Exercise]

    @State private var isPickerPresented = false
    @State private var preview: PreviewData?
    /// Alert to raise once the preview sheet finishes dismissing (result on a
    /// committed import, or a graceful failure). `nil` ⇒ Cancel ⇒ no alert.
    @State private var deferredAlert: AlertInfo?
    @State private var alert: AlertInfo?

    var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            Label("Import Routine from JSON", systemImage: "square.and.arrow.down.on.square")
        }
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false,
            onCompletion: handlePick
        )
        .sheet(item: $preview, onDismiss: handleSheetDismiss) { data in
            RoutineImportPreviewView(
                preview: data.preview,
                onConfirm: {
                    // Commit while the sheet is still up, then drop the binding
                    // to dismiss; the result alert fires in onDismiss.
                    do {
                        let report = try RoutineTransfer.import(
                            data.document,
                            among: routines,
                            exercises: exercises,
                            in: modelContext
                        )
                        deferredAlert = AlertInfo(
                            title: "Routine Imported",
                            message: Self.resultMessage(report))
                    } catch {
                        deferredAlert = AlertInfo(
                            title: "Import Failed",
                            message: Self.errorMessage(error))
                    }
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

    // MARK: - File pick → decode → preview

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            alert = AlertInfo(title: "Import Failed", message: error.localizedDescription)
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                let document = try decodeDocument(at: url)
                // Validate before opening the preview — nothing is inserted here.
                try document.validateSupportedSchemaVersion()
                preview = PreviewData(
                    document: document,
                    preview: RoutineTransfer.preview(
                        document, existingExerciseNames: exercises.map(\.name)))
            } catch {
                alert = AlertInfo(
                    title: "Couldn’t Import Routine", message: Self.errorMessage(error))
            }
        }
    }

    /// Read a security-scoped file and decode the transfer document.
    private func decodeDocument(at url: URL) throws -> RoutineTransferDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try RoutineTransfer.makeJSONDecoder()
            .decode(RoutineTransferDocument.self, from: data)
    }

    // MARK: - Result alert (after sheet dismissal)

    private func handleSheetDismiss() {
        guard let pending = deferredAlert else { return }  // Cancel ⇒ nil
        deferredAlert = nil
        alert = pending
    }

    // MARK: - Pure formatting helpers (testable)

    /// Result-alert body for a completed import. Internal + static so it stays a
    /// pure value-in / value-out function (no view state).
    static func resultMessage(_ r: RoutineTransfer.ImportReport) -> String {
        var lines = [
            String(localized: "Imported “\(r.importedRoutineName)”.")
        ]
        lines.append(
            r.slotCount == 1
                ? String(localized: "1 exercise.")
                : String(localized: "\(r.slotCount) exercises."))
        if !r.createdExerciseNames.isEmpty {
            let n = r.createdExerciseNames.count
            lines.append(
                n == 1
                    ? String(localized: "Created 1 new exercise.")
                    : String(localized: "Created \(n) new exercises."))
        }
        if !r.matchedExerciseNames.isEmpty {
            let n = r.matchedExerciseNames.count
            lines.append(
                n == 1
                    ? String(localized: "Linked 1 existing exercise.")
                    : String(localized: "Linked \(n) existing exercises."))
        }
        if r.skippedSlotCount > 0 {
            let n = r.skippedSlotCount
            lines.append(
                n == 1
                    ? String(localized: "Skipped 1 exercise with no name.")
                    : String(localized: "Skipped \(n) exercises with no name."))
        }
        return lines.joined(separator: "\n")
    }

    /// Preview footer for entries the import will drop because the exported
    /// slot carried no exercise name.
    ///
    /// Singular / plural branches routed through `String(localized:)` rather
    /// than one `+`-concatenated literal: concatenation binds `Text`'s verbatim
    /// initializer, which is why this sentence and the counts above shipped
    /// English-only in every Korean build.
    static func skippedPreviewMessage(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 exercise has no name and will be skipped.")
            : String(
                localized: "\(count) exercises have no name and will be skipped."
            )
    }

    /// Friendly copy for the decode / validation / read failure paths.
    static func errorMessage(_ error: Error) -> String {
        if let e = error as? RoutineTransferError {
            switch e {
            case let .unsupportedSchemaVersion(found, supported):
                return "This routine was exported from a newer version of the app "
                    + "(format \(found); this app supports \(supported)). "
                    + "Update the app to import it."
            }
        }
        if error is DecodingError {
            return "This file isn’t a valid routine JSON export."
        }
        return "Couldn’t read this file."
    }

    // MARK: - Local value types

    private struct PreviewData: Identifiable {
        let id = UUID()
        let document: RoutineTransferDocument
        let preview: RoutineTransfer.ImportPreview
    }

    private struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}

/// Read-only preview of a decoded routine JSON: the routine name, how many
/// exercises it holds, the existing exercises that will be linked, the new
/// exercises that will be created, and any entries that will be skipped.
/// Confirms/cancels via injected closures so the host owns the actual
/// SwiftData write.
struct RoutineImportPreviewView: View {
    let preview: RoutineTransfer.ImportPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Routine", value: preview.sourceRoutineName)
                    LabeledContent("Exercises", value: "\(preview.slotCount)")
                } footer: {
                    Text("A new routine will be created. Nothing existing is "
                        + "overwritten or deleted.")
                }

                if !preview.matchedExerciseNames.isEmpty {
                    Section("Linked existing exercises (\(preview.matchedExerciseNames.count))") {
                        ForEach(preview.matchedExerciseNames, id: \.self) { Text($0) }
                    }
                }

                if !preview.createdExerciseNames.isEmpty {
                    Section("New exercises to create (\(preview.createdExerciseNames.count))") {
                        ForEach(preview.createdExerciseNames, id: \.self) { Text($0) }
                    }
                }

                if preview.skippedSlotCount > 0 {
                    Section {
                        Text(
                            RoutineJSONImportButton.skippedPreviewMessage(
                                preview.skippedSlotCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onConfirm)
                }
            }
        }
    }
}

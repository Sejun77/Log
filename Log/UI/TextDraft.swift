import SwiftUI

// ======================================================
// MARK: - Text Draft Controller
// ======================================================

/// Holds the in-flight text of one editor plus the last value written through
/// to storage, so the write can happen at controlled commit boundaries instead
/// of on every character.
///
/// Deliberately a **plain class** — not `@Observable`, not `ObservableObject`.
/// That is the whole point. The editors this backs live inside very large
/// parent bodies (`ActiveWorkoutView` is ~4.9k lines and evaluates SwiftData
/// fetches, per-set technique resolution and superset completeness checks on
/// every pass), and the previous "local draft" fix still kept the draft as
/// `@State` **on that parent**, so every keystroke re-evaluated the whole body
/// anyway. Staging a keystroke here mutates an ordinary reference-type
/// property: SwiftUI observes nothing, invalidates nothing, and only the small
/// editor view that owns the mirrored `@State` redraws.
///
/// A parent can still hold the controller (as `@State`, which stores the
/// reference once and is never reassigned) and drive `commit(_:)` from its own
/// lifecycle — Save & Exit, Finish, sheet dismissal — without ever reading the
/// draft text in `body`.
///
/// Not thread-safe by design: `@MainActor`, like the views that use it.
@MainActor
final class TextDraftController {

    /// What the editor is currently showing. Updated synchronously on every
    /// keystroke, so the visible text is never debounced.
    private(set) var text: String

    /// The value most recently handed to `commit(_:)`'s persist closure (or
    /// seeded from storage). The difference between this and `text` is the
    /// pending edit.
    private(set) var committedText: String

    /// Number of times `commit(_:)` actually persisted. Used by tests to prove
    /// the persist closure does not run once per character; free at runtime.
    private(set) var commitCount = 0

    init(_ initial: String = "") {
        text = initial
        committedText = initial
    }

    /// True when the editor holds text that storage has not seen yet.
    /// Clearing a non-empty note to `""` is dirty, so an intentional clear
    /// persists like any other edit.
    var isDirty: Bool { text != committedText }

    /// Adopts a value read back from storage.
    ///
    /// Ignored while a pending edit exists, so an unrelated model change (or a
    /// re-seed on reappear) can never clobber what the user is typing. When the
    /// draft is clean it takes the stored value, so a newer persistent value
    /// does replace a stale-but-unedited draft.
    func seed(from stored: String) {
        guard !isDirty else { return }
        text = stored
        committedText = stored
    }

    /// Records a keystroke. Cheap and non-observable by design.
    func stage(_ newText: String) {
        text = newText
    }

    /// Writes the pending edit through `persist`, then marks it committed.
    ///
    /// A no-op (returning `false`, leaving `commitCount` alone) when nothing is
    /// pending, so repeated commit points — focus loss *and* disappear *and*
    /// Save & Exit — cost one write between them rather than one each, and a
    /// commit never dirties a model context that had no change to record.
    @discardableResult
    func commit(_ persist: (String) -> Void) -> Bool {
        guard isDirty else { return false }
        let value = text
        persist(value)
        committedText = value
        commitCount += 1
        return true
    }

    /// Discards any pending edit and re-anchors on `stored`.
    ///
    /// Used when the editor is about to show a *different* subject (a new slot,
    /// a different exercise) rather than a newer value of the same one — there
    /// `seed(from:)`'s protect-the-draft rule would carry the previous
    /// subject's text over.
    func reset(to stored: String) {
        text = stored
        committedText = stored
    }
}

// ======================================================
// MARK: - Growing Text Editor
// ======================================================

/// A multiline editor that only ever grows with its content, with a placeholder
/// and a minimum height. It holds no state and decides nothing about saving:
/// whatever `text` is bound to keeps its own commit behavior.
///
/// **One vertical scrolling owner.** The editor's own scrolling is disabled, so
/// the enclosing `List`/`Form` does all the scrolling, and keeps the caret line
/// visible as new lines are added: a `TextField(axis: .vertical)` in a `List`
/// grew without any scroll, so typing could continue behind the keyboard. A
/// closed line range on that field also clamped its frame while its text
/// container kept growing, which is what produced the untypeable blank region
/// under long notes.
///
/// Inherits font, line spacing, capitalization, focus and disabled state from
/// modifiers applied to it.
struct GrowingTextEditor: View {
    /// `UITextView`'s default text insets, which `TextEditor` keeps. Cancelled so
    /// the text and row height line up with the app's other text fields.
    private static let editorInsets = EdgeInsets(
        top: -8, leading: -5, bottom: -8, trailing: -5)

    private let titleKey: LocalizedStringKey
    @Binding private var text: String
    private let minLines: Int

    init(
        _ titleKey: LocalizedStringKey,
        text: Binding<String>,
        minLines: Int = 1
    ) {
        self.titleKey = titleKey
        _text = text
        self.minLines = minLines
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Reserves the minimum height: `TextEditor` has no line limit.
            Text(verbatim: " ")
                .lineLimit(minLines, reservesSpace: true)
                .hidden()

            if text.isEmpty {
                Text(titleKey)
                    .foregroundStyle(Color(uiColor: .placeholderText))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .padding(Self.editorInsets)
                .accessibilityLabel(Text(titleKey))
        }
    }
}

// ======================================================
// MARK: - Draft Notes Field
// ======================================================

/// A multiline notes editor whose per-keystroke state lives **here**, in a
/// small leaf view, rather than in whatever large screen hosts it.
///
/// Nothing outside this view changes while typing. The draft is mirrored into a
/// `TextDraftController` the host owns, which is a plain class, so the host's
/// `body` is not invalidated and no SwiftData write happens per character.
/// Layout and scrolling come from `GrowingTextEditor`.
///
/// Focus is owned here too, so commit-on-focus-loss needs no plumbing; hosts
/// that must commit for other reasons (navigating away, Save & Exit) call
/// `commit` on the controller themselves.
struct DraftNotesField: View {
    private let titleKey: LocalizedStringKey
    private let controller: TextDraftController
    private let lineLimit: PartialRangeFrom<Int>
    private let autocapitalization: TextInputAutocapitalization
    private let onCommit: () -> Void

    /// The only per-keystroke state in the whole screen. Mirrored into
    /// `controller` so the host can commit it without reading it in `body`.
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    init(
        _ titleKey: LocalizedStringKey,
        controller: TextDraftController,
        lineLimit: PartialRangeFrom<Int> = 1...,
        autocapitalization: TextInputAutocapitalization = .sentences,
        onCommit: @escaping () -> Void
    ) {
        self.titleKey = titleKey
        self.controller = controller
        self.lineLimit = lineLimit
        self.autocapitalization = autocapitalization
        self.onCommit = onCommit
    }

    var body: some View {
        GrowingTextEditor(
            titleKey, text: $draft, minLines: lineLimit.lowerBound
        )
        .textInputAutocapitalization(autocapitalization)
        .focused($isFocused)
        .onChange(of: draft) { _, newValue in
            controller.stage(newValue)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                onCommit()
                showCommittedText()
            }
        }
        // Re-reads the controller rather than the model: a `List` may
        // discard and rebuild this row's `@State` when it scrolls out of
        // view, and the controller is what survives that. Skipped while
        // focused so an appear callback mid-edit cannot reset the caret.
        .onAppear {
            if !isFocused, draft != controller.text {
                draft = controller.text
            }
        }
    }

    /// Shows what the commit stored, without trailing blank lines. Only on focus
    /// loss: while typing, Returns and blank lines stay as entered.
    private func showCommittedText() {
        let committed = normalizedOptionalNote(draft) ?? ""
        guard committed != draft else { return }
        draft = committed
        controller.stage(committed)
    }
}

import SwiftUI

// ======================================================
// MARK: - Keyboard Dismiss Accessory
// ======================================================

/// A compact trailing checkmark for the `.keyboard` toolbar placement that
/// resigns the first responder. Use it as the shared dismissal control for
/// fields whose keyboard has no usable Return key:
///   • numeric pads (`.numberPad` / `.decimalPad`) — no Return key at all,
///   • multiline fields (`axis: .vertical`) — Return inserts a newline, and
///   • `.searchable` fields — the system Search key does NOT deliver
///     `.onSubmit(of: .search)` when the query is empty (e.g. after typing
///     then deleting back to empty), so the Return key alone can't dismiss.
///
/// Plain single-line text fields should NOT pair this with the accessory: they
/// dismiss via their own Return key (`.submitLabel(.done)` + `.onSubmit`), so
/// adding a checkmark there would be a redundant external Done control.
///
/// Usage:
/// ```
/// .toolbar {
///     ToolbarItemGroup(placement: .keyboard) {
///         Spacer()
///         KeyboardDismissButton()
///     }
/// }
/// ```
struct KeyboardDismissButton: View {
    var body: some View {
        Button {
            dismissKeyboard()
        } label: {
            Image(systemName: "checkmark").fontWeight(.semibold)
        }
        .accessibilityLabel("Done")
    }
}

/// Resign the current first responder — dismisses the keyboard regardless of
/// which field is focused. Use it as the shared submit-dismiss action for
/// fields whose Return-key contract isn't enough on its own:
///
/// ```
/// .onSubmit(of: .search) { dismissKeyboard() }
/// ```
///
/// `.searchable`'s system Search key (the keyboard's "Search" return key) can
/// stay blue/enabled after you type-then-delete back to empty, yet pressing it
/// while empty does NOT fire `.onSubmit(of: .search)`. Investigated and
/// confirmed unfixable with standard APIs (do not re-litigate): SwiftUI exposes
/// no modifier for the search field's return-key state; the field already
/// behaves as `enablesReturnKeyAutomatically == true` (grey when first empty),
/// so there is no missing flag to set; the stuck-blue case is a UIKit refresh
/// defect on the private text field inside the search bar. Rejected routes —
/// `UITextField.appearance().enablesReturnKeyAutomatically` (not a
/// `UI_APPEARANCE_SELECTOR` property so unsupported, applies globally to every
/// field, and still wouldn't fix the refresh defect), introspection into the
/// `UISearchTextField`, and a custom `inputView`/`UIViewRepresentable` — are all
/// fragile/private/out-of-scope. So the dismissal contract is split:
///   • non-empty submit → `.onSubmit(of: .search) { dismissKeyboard() }`, and
///   • empty-after-delete → the compact `.keyboard` `KeyboardDismissButton`,
/// which calls this and resigns focus regardless of the dead Search key.
func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

// ======================================================
// MARK: - Primary Button
// ======================================================

struct DSPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }

                Text(title)
                    .font(.dsBody)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .padding(.vertical, DSSpacing.sm)
            .padding(.horizontal, DSSpacing.lg)
            .frame(maxWidth: .infinity)
            .background(
                isDisabled ? DSColor.brand.opacity(0.40) : DSColor.brand
            )
            .cornerRadius(DSRadius.md)
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
    }
}

// ======================================================
// MARK: - Secondary / Outline Button
// ======================================================

struct DSSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDestructive: Bool = false
    var action: () -> Void

    private var borderColor: Color {
        isDestructive
            ? DSColor.error.opacity(0.7)
            : DSColor.brand.opacity(0.6)
    }

    private var textColor: Color {
        isDestructive
            ? DSColor.error
            : DSColor.brand
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                }

                Text(title)
                    .font(.dsBody)
                    .fontWeight(.medium)
            }
            .foregroundColor(textColor)
            .padding(.vertical, DSSpacing.sm)
            .padding(.horizontal, DSSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
    }
}

// ======================================================
// MARK: - Card
// ======================================================

struct DSCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            content
        }
        .padding(DSSpacing.md)
        .background(DSColor.surface)
        .cornerRadius(DSRadius.lg)
        .dsCardShadow()
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }
}

// ======================================================
// MARK: - Tag / Chip
// ======================================================

struct DSTag: View {
    enum Style { case neutral, accent, error }

    let text: String
    var style: Style = .neutral

    private var backgroundColor: Color {
        switch style {
        case .neutral: DSColor.surfaceAlt
        case .accent: DSColor.accent.opacity(0.16)
        case .error: DSColor.error.opacity(0.12)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .neutral: DSColor.textSecondary
        case .accent: DSColor.accent
        case .error: DSColor.error
        }
    }

    var body: some View {
        Text(text.uppercased())
            .font(.dsCaption)
            .fontWeight(.semibold)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 3)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .cornerRadius(DSRadius.pill)
    }
}

// ======================================================
// MARK: - Status Pill
// ======================================================

/// Compact, neutral status label (e.g. "In Progress") rendered as a material
/// capsule. Centralizes the previously hand-rolled `.thinMaterial` status chip
/// so these labels read consistently across screens. Neutral by design — reach
/// for `DSTag` when accent/error emphasis is wanted. The two existing
/// `LockBadge` types are intentionally left as-is for now (separate slice).
struct StatusPill: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.dsCaption.weight(.semibold))
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 3)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .foregroundStyle(.secondary)
    }
}

// ======================================================
// MARK: - Section Header
// ======================================================

struct DSSectionHeader: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(LocalizedStringKey(title))
                .font(.dsSection)
                .foregroundColor(DSColor.textSecondary)

            Spacer()
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, DSSpacing.md)
        .padding(.bottom, DSSpacing.xs)
    }
}

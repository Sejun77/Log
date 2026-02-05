import SwiftUI

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

            Text(title)
                .font(.dsSection)
                .foregroundColor(DSColor.textSecondary)

            Spacer()
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, DSSpacing.md)
        .padding(.bottom, DSSpacing.xs)
    }
}

import SwiftUI

// ======================================================
// MARK: - COLORS
// ======================================================

/// Central color namespace. Backed entirely by Assets.xcassets.
/// Ensures consistent styling throughout the app.
enum DSColor {
    // Backgrounds
    static let bg = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let surfaceAlt = Color(uiColor: .tertiarySystemBackground)

    // Text
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textMuted = Color.secondary.opacity(0.7)
    static let textInverse = Color.white

    // Brand / Accent
    static let brand = Color("dsBrand")
    static let accent = brand

    // States
    static let success = Color.green.opacity(0.75)
    static let error = Color.red.opacity(0.75)
    static let warning = Color.yellow.opacity(0.75)

    // Borders
    static let border = Color.secondary.opacity(0.3)
}

// ======================================================
// MARK: - TYPOGRAPHY (Manrope)
// ======================================================

/// Centralized font tokens for consistent typography.
/// All sizes and weights are deliberate choices based on usability standards.
extension Font {
    static var dsTitle: Font {
        .custom("Manrope-SemiBold", size: 24)
    }

    static var dsSection: Font {
        .custom("Manrope-SemiBold", size: 17)
    }

    static var dsBody: Font {
        .custom("Manrope-Regular", size: 16)
    }

    static var dsBodySecondary: Font {
        .custom("Manrope-Regular", size: 14)
    }

    static var dsCaption: Font {
        .custom("Manrope-Regular", size: 12)
    }

    static var dsNumeric: Font {
        .custom("Manrope-SemiBold", size: 18)
    }

    static var dsNumericSmall: Font {
        .custom("Manrope-Medium", size: 14)
    }
}

// ======================================================
// MARK: - SPACING
// ======================================================

/// Unified spacing scale used throughout UI for consistency.
enum DSSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// ======================================================
// MARK: - CORNERS
// ======================================================

/// Corner radius scale for cards, buttons, chips, sheets, etc.
enum DSRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let pill: CGFloat = 999
}

// ======================================================
// MARK: - SHADOWS
// ======================================================

/// Subtle elevation shadow used for primary cards.
extension View {
    func dsCardShadow() -> some View {
        shadow(
            color: Color.black.opacity(0.06),
            radius: 12,
            x: 0,
            y: 4
        )
    }
}

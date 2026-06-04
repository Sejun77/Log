import Foundation

// MARK: - Autoregulation Mode

enum AutoregMode: String {
    case rir
    case rpe
    case none
}

// MARK: - App Settings

enum AppSettings {
    enum Keys {
        static let weightIsKg             = "settings.weightIsKg"
        static let autoregMode            = "settings.autoregMode"
        static let defaultSets            = "settings.defaultSets"
        static let defaultRepMin          = "settings.defaultRepMin"
        static let defaultRepMax          = "settings.defaultRepMax"
        static let defaultRestBetweenSets = "settings.defaultRestBetweenSets"
        static let defaultRestAfterExercise = "settings.defaultRestAfterExercise"
        static let defaultRIR             = "settings.defaultRIR"
        static let defaultRPE             = "settings.defaultRPE"
        static let userBodyweight         = "settings.userBodyweight"
    }

    // MARK: Units

    /// Whether weight units are kilograms (true) or pounds (false).
    static var weightIsKg: Bool {
        get {
            UserDefaults.standard.object(forKey: Keys.weightIsKg) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.weightIsKg) }
    }

    // MARK: Autoregulation

    static var autoregMode: AutoregMode {
        get {
            AutoregMode(rawValue: UserDefaults.standard.string(forKey: Keys.autoregMode) ?? "") ?? .rir
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.autoregMode) }
    }

    // MARK: New Slot Defaults

    static var defaultSets: Int {
        get { let v = UserDefaults.standard.integer(forKey: Keys.defaultSets); return v > 0 ? v : 3 }
        set { UserDefaults.standard.set(newValue, forKey: Keys.defaultSets) }
    }

    static var defaultRepMin: Int {
        get { let v = UserDefaults.standard.integer(forKey: Keys.defaultRepMin); return v > 0 ? v : 8 }
        set { UserDefaults.standard.set(newValue, forKey: Keys.defaultRepMin) }
    }

    static var defaultRepMax: Int {
        get { let v = UserDefaults.standard.integer(forKey: Keys.defaultRepMax); return v > 0 ? v : 12 }
        set { UserDefaults.standard.set(newValue, forKey: Keys.defaultRepMax) }
    }

    static var defaultRestBetweenSets: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Keys.defaultRestBetweenSets)
            return v > 0 ? v : 90
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.defaultRestBetweenSets) }
    }

    /// 0 = no default rest after exercise.
    static var defaultRestAfterExercise: Int {
        get { max(0, UserDefaults.standard.integer(forKey: Keys.defaultRestAfterExercise)) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.defaultRestAfterExercise) }
    }

    static var defaultRIR: Double {
        get {
            let v = UserDefaults.standard.double(forKey: Keys.defaultRIR)
            return v > 0 ? v : 2.0
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.defaultRIR) }
    }

    static var defaultRPE: Double {
        get {
            let v = UserDefaults.standard.double(forKey: Keys.defaultRPE)
            return v > 0 ? v : 8.0
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.defaultRPE) }
    }

    // MARK: User Bodyweight

    /// User's bodyweight in the currently displayed weight unit (no kg/lb
    /// conversion is performed anywhere in the app). `nil` = not set. Only
    /// positive values are stored; absent / ≤ 0 reads back as `nil`.
    static var userBodyweight: Double? {
        get {
            guard
                let v = UserDefaults.standard.object(forKey: Keys.userBodyweight) as? Double,
                v > 0
            else { return nil }
            return v
        }
        set {
            if let v = newValue, v > 0 {
                UserDefaults.standard.set(v, forKey: Keys.userBodyweight)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.userBodyweight)
            }
        }
    }
}

/// Parses a free-text bodyweight entry into a positive `Double`, or `nil` for
/// empty / zero / negative / invalid input. Accepts decimals (e.g. "72.5").
/// Pure — used by Settings to drive `AppSettings.userBodyweight`.
func normalizedBodyweight(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let v = Double(trimmed), v > 0 else { return nil }
    return v
}

// MARK: - Backwards Compatibility

/// Legacy access point for weight units, kept so existing code using `Units.weightIsKg`
/// continues to work. New code should prefer `AppSettings.weightIsKg`.
enum Units {
    static var weightIsKg: Bool {
        get { AppSettings.weightIsKg }
        set { AppSettings.weightIsKg = newValue }
    }

    /// Canonical weight formatter for both display and text-field rehydration.
    /// Whole numbers show no decimals (8 → "8"); fractional values keep up to
    /// two meaningful decimals with trailing zeros trimmed (8.5 → "8.5",
    /// 8.25 → "8.25", 8.333 → "8.33"). Always uses "." as the separator —
    /// `%g`/NumberFormatter localisation is avoided so the result round-trips
    /// through `Double(_:)` when reused as a `.decimalPad` field's value.
    ///
    /// Replaces scattered `Int(w.rounded())` formatting, which rounded e.g.
    /// 8.5 kg to "9 kg" in History and lost decimals on log→undo rehydration.
    static func formatWeight(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        var s = String(format: "%.2f", value)  // C-locale "." separator
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

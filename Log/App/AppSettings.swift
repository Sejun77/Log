import Foundation

// MARK: - App Settings

enum AppSettings {
    private enum Keys {
        static let weightIsKg = "settings.weightIsKg"
    }

    /// Whether weight units are kilograms (true) or pounds (false).
    /// Defaults to `true` (kg) if no value has been stored yet.
    static var weightIsKg: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: Keys.weightIsKg)
                as? Bool
            {
                return value
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.weightIsKg)
        }
    }
}

// MARK: - Backwards Compatibility

/// Legacy access point for weight units, kept so existing code using `Units.weightIsKg`
/// continues to work. New code should prefer `AppSettings.weightIsKg`.
enum Units {
    static var weightIsKg: Bool {
        get { AppSettings.weightIsKg }
        set { AppSettings.weightIsKg = newValue }
    }
}

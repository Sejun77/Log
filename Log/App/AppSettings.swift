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

import Combine
import Foundation

/// Phase 10-polish-H (2026-05-24): lightweight persistent store for
/// user-added Body Part / Equipment options surfaced in the pickers on the
/// Exercise detail screen. Backed by `UserDefaults` (a `[String]` value
/// under a per-domain key) so the data is durable across launches and
/// shared across every exercise without requiring a SwiftData schema
/// change.
///
/// Pattern matches `ActiveWorkoutGuard`: a `final class : ObservableObject`
/// with a `static let shared`-style singleton per domain (`bodyParts` /
/// `equipment`). SwiftUI views observe via `@ObservedObject`, so the
/// pickers reactively update across exercises whenever the list changes.
/// All call sites run on the main actor; UserDefaults itself is
/// thread-safe for these scalar reads/writes.
///
/// Storage rules (enforced by `add(_:excludingCanonical:)`):
///   * trimmed: leading/trailing whitespace removed before any comparison
///   * non-empty: blank / whitespace-only adds are dropped
///   * canonical exclusion: a value that matches a supplied canonical
///     option (case-insensitive) is dropped — canonical is the
///     authoritative source for those strings
///   * dedupe: a value already present (case-insensitive) is dropped,
///     so "Forearms" and "forearms" never coexist
///
/// Deletion (`remove(at:)`, `remove(_:)`) only mutates the persisted
/// option list. It never reaches into SwiftData to clear
/// `Exercise.bodyPart` or `Exercise.equipmentType` on existing rows —
/// that preserves the "no silent mutation" rule from CLAUDE.md. An
/// exercise that was tagged with a now-removed custom value keeps the
/// value and resurfaces in its picker as a legacy/custom row until the
/// user explicitly changes it.
final class CustomOptionStore: ObservableObject {

    // MARK: - UserDefaults keys

    /// Key under which the shared Body Part custom options list is stored.
    static let bodyPartsKey = "customBodyPartOptions"
    /// Key under which the shared Equipment custom options list is stored.
    static let equipmentKey = "customEquipmentOptions"

    // MARK: - Production singletons

    /// Shared instance the BodyPartPicker observes.
    static let bodyParts = CustomOptionStore(key: CustomOptionStore.bodyPartsKey)
    /// Shared instance the EquipmentPicker observes.
    static let equipment = CustomOptionStore(key: CustomOptionStore.equipmentKey)

    // MARK: - State

    private let key: String
    private let defaults: UserDefaults

    /// Current ordered list of custom options. Insertion appends; deletion
    /// preserves the relative order of the remaining entries.
    @Published private(set) var options: [String]

    // MARK: - Init

    /// Memberwise init exposed so tests can drive an isolated UserDefaults
    /// suite without leaking entries into the simulator's standard suite.
    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        self.options = defaults.stringArray(forKey: key) ?? []
    }

    // MARK: - Mutation

    /// Attempt to add `raw` to the option list. Returns `true` when a new
    /// entry was appended, `false` when the value was rejected as blank,
    /// canonical, or a case-insensitive duplicate. The stored string is
    /// the trimmed form so persisted entries never carry whitespace
    /// padding.
    @discardableResult
    func add(_ raw: String, excludingCanonical canonical: [String]) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        if canonical.contains(where: { $0.lowercased() == lowered }) {
            return false
        }
        if options.contains(where: { $0.lowercased() == lowered }) {
            return false
        }

        options.append(trimmed)
        persist()
        return true
    }

    /// `.onDelete` handler for `ForEach` over `options`. Removes only the
    /// entries at the supplied indices; never touches Exercise rows.
    /// Iterates the IndexSet in descending order so the trailing removals
    /// don't shift the indices of the earlier ones — this is the
    /// equivalent of SwiftUI's `removeAtOffsets`, written out by hand so
    /// the service stays free of a `SwiftUI` import.
    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where index < options.count {
            options.remove(at: index)
        }
        persist()
    }

    /// Convenience case-insensitive removal by value. No-op when the
    /// value is not present.
    func remove(_ value: String) {
        let lowered = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        options.removeAll { $0.lowercased() == lowered }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(options, forKey: key)
    }
}

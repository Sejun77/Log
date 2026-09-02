import Foundation

// ======================================================
// MARK: - Showcase visibility (Build 10, audit M9)
// ======================================================

/// Whether Settings offers the **Calculus Analytics** showcase.
///
/// The showcase is a development artifact: an AP Calculus AB demo that analyses
/// in-memory sample data and touches nothing a user owns. Inside a gym app on a
/// tester's phone it reads as a stray academic feature, and its strings are
/// English-only — so a Korean tester met an untranslated section describing
/// coursework. Audit finding M9.
///
/// **Debug builds only.** The rule is stated once, here, so the two places that
/// care — the `#if DEBUG` block in `SettingsView` and the test that pins the
/// intent — cannot drift into disagreeing about it.
///
/// Deliberately **not** a runtime feature flag: no `UserDefaults`, nothing
/// togglable, nothing a shipped build could be talked into showing.
/// `isVisibleInThisBuild` is resolved by the compiler, and the section it guards
/// is itself inside `#if DEBUG`, so a Release binary does not merely hide the
/// showcase — it does not build the row at all.
enum SettingsShowcaseVisibility {

    /// The rule, as a pure function of the build configuration, so a Debug test
    /// run can assert **both** directions — including the Release behavior it
    /// can never observe directly.
    static func isVisible(isDebug: Bool) -> Bool { isDebug }

    /// The rule applied to the configuration this binary was compiled with.
    #if DEBUG
        static let isVisibleInThisBuild = isVisible(isDebug: true)
    #else
        static let isVisibleInThisBuild = isVisible(isDebug: false)
    #endif
}

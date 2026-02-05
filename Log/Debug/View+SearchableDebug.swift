import SwiftUI

extension View {
    /// Wrapper around `.searchable` that can suppress console warnings in DEBUG builds.
    ///
    /// In DEBUG: returns the original view (no search field).
    /// In RELEASE: applies `.searchable(text: prompt:)` normally.
    @ViewBuilder
    func searchableDebug<S: StringProtocol>(
        text: Binding<String>,
        prompt: S
    ) -> some View {
        #if DEBUG
            self
        #else
            self.searchable(text: text, prompt: Text(prompt))
        #endif
    }

    /// Simpler overload when you don't need a custom prompt.
    ///
    /// In DEBUG: returns the original view.
    /// In RELEASE: applies `.searchable(text:)` normally.
    @ViewBuilder
    func searchableDebug(text: Binding<String>) -> some View {
        #if DEBUG
            self
        #else
            self.searchable(text: text)
        #endif
    }
}

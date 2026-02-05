import SwiftUI

#if DEBUG

    // MARK: - Layout Probe (DEBUG only)

    private let LOG_ALL_SIZES = false
    private let LOG_INVALID_SIZES = true
    private let BREAK_ON_INVALID = false

    private struct LayoutProbe: ViewModifier {
        let tag: String

        @State private var lastSize: CGSize = .zero

        func body(content: Content) -> some View {
            content.background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            reportSize(proxy.size)
                        }
                        // iOS 17+ compliant onChange: two-parameter closure
                        .onChange(of: proxy.size) { _, newValue in
                            reportSize(newValue)
                        }
                }
            )
        }

        private func reportSize(_ size: CGSize) {
            guard size != lastSize else { return }
            lastSize = size

            let invalid =
                !size.width.isFinite || !size.height.isFinite || size.width < 0
                || size.height < 0

            if invalid {
                if LOG_INVALID_SIZES {
                    print("⚠️ [LayoutProbe:\(tag)] Invalid size: \(size)")
                }
                if BREAK_ON_INVALID {
                    assertionFailure(
                        "Invalid size in LayoutProbe(\(tag)): \(size)"
                    )
                }
                return
            }

            if LOG_ALL_SIZES {
                print("ℹ️ [LayoutProbe:\(tag)] size = \(size)")
            }
        }
    }

    extension View {
        /// Debug helper that logs layout size changes in DEBUG builds.
        func probe(_ tag: String) -> some View {
            modifier(LayoutProbe(tag: tag))
        }
    }

#else

    // MARK: - No-op in Release

    extension View {
        /// No-op in non-DEBUG builds so `.probe()` calls don't affect release behavior.
        func probe(_ tag: String) -> some View { self }
    }

#endif

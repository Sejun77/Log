import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RestLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            // LOCK SCREEN / BANNER
            HStack(alignment: .center, spacing: 12) {
                // LOCK SCREEN / BANNER (left side: Rest)
                VStack(spacing: 2) {
                    Text("Rest")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if context.state.endDate > Date() {
                        Text(
                            timerInterval: Date.now...context.state.endDate,
                            countsDown: true
                        )
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    } else {
                        Text("—")
                            .font(
                                .system(.title2, design: .rounded).weight(.bold)
                            )
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                // Vertical divider (Divider inside HStack is vertical)
                Divider()

                // RIGHT: Global workout timer (elapsed since sessionStart)
                VStack(spacing: 2) {
                    Text("Session")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let start = context.state.sessionStart {
                        // Use a future upper bound so animation continues while app is backgrounded
                        Text(
                            timerInterval: start...Date.distantFuture,
                            countsDown: false
                        )
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    } else {
                        Text("—")
                            .font(
                                .system(.title2, design: .rounded).weight(.bold)
                            )
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .modifier(LockScreenPaddingAndBackground())  // consistent margins/background
        } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { EmptyView() }
                // (You can omit leading/trailing if you don’t need them in expanded)
            } compactLeading: {
                EmptyView()
            } compactTrailing: {
                EmptyView()
            } minimal: {
                EmptyView()
            }
        }
    }
}

// MARK: - Helpers

/// Gives the Lock-Screen view proper margins on iOS 17+,
/// and a safe horizontal padding fallback on iOS 16.2–16.6.
private struct LockScreenPaddingAndBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentMargins(.all, 12)
                .containerBackground(for: .widget) { Rectangle().fill(.clear) }
        } else {
            content
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
        }
    }
}

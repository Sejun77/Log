import SwiftUI

/// Isolated toolbar clock for the active workout.
///
/// Slice C performance fix: the session elapsed time previously lived in an
/// `ActiveWorkoutView`-level `@State now` updated by a 1 Hz `Timer.publish`.
/// Because `now` was read inside `ActiveWorkoutView.body`, every tick
/// invalidated the entire ~3400-line body — including every input row — once
/// per second, competing with keystrokes and tap-to-switch focus changes.
///
/// This view owns its per-second refresh via `TimelineView(.periodic)`, so a
/// tick redraws ONLY the clock `Text`, never the parent body. The displayed
/// string is byte-identical to the old `sessionElapsedString` (same
/// `formatSessionElapsed` helper, same "00:00" empty state, same accessibility
/// identifier).
struct SessionClockView: View {
    /// Session start instant (from `ActiveWorkoutGuard.sessionStart`); nil
    /// before a session is active, in which case the clock shows "00:00".
    let sessionStart: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatSessionElapsed(start: sessionStart, now: context.date))
                .font(.dsBody.monospacedDigit())
                .accessibilityIdentifier("sessionElapsedTimer")
        }
    }
}

import UIKit

/// The app's one haptic system. Every haptic in Log goes through
/// `AppHaptics.play(_:)` with a semantic `HapticCue` — views never construct a
/// feedback generator or choose an intensity themselves, so the whole policy
/// is the `event` table below and is searchable as `AppHaptics.play`.
///
/// Policy:
/// - **selection** — a choice or checked state changed (checkbox rows,
///   checklist ticks).
/// - **light impact** — an ordinary user-triggered state change (Back / Next,
///   log or undo a set, switch an exercise, add or duplicate an item).
/// - **medium impact** — a larger workflow transition (Start Workout,
///   Save & Exit).
/// - **success** — only after a major operation has actually succeeded
///   (Finish, Save Selected Changes, an import, rest completion).
/// - **warning** — a destructive action the user has already confirmed.
/// - **error** — an action that could not proceed, at the moment the UI
///   surfaces it.
///
/// Deliberately silent: navigation, typing, focus, scrolling, appearance,
/// resume/restoration, programmatic sync, and native controls (Toggle,
/// Picker, Stepper, Menu, DatePicker, list reorder/swipe) that already supply
/// their own feedback.
enum HapticEvent: Equatable {
    case selection
    case lightImpact
    case mediumImpact
    case success
    case warning
    case error
}

/// What happened, in the app's terms. Call sites name the event they just
/// produced; `event` decides how it feels.
enum HapticCue: Equatable, CaseIterable {
    /// A checkbox / checklist row's selected state changed.
    case selectionChanged
    /// Back / Next moved the active-workout cursor.
    case workoutStepChanged
    /// A working set, warm-up step, or drop was logged.
    case setLogged
    /// A logged set, warm-up step, or drop was undone.
    case setUnlogged
    /// A duration set's countdown was started by the user.
    case setTimerStarted
    /// An exercise switch (including a prepared alternative) was applied.
    case exerciseSwitched
    /// A new workout session was created.
    case workoutStarted
    /// Save & Exit persisted the resumable workout.
    case workoutSavedAndExited
    /// The workout was completed and recorded.
    case workoutFinished
    /// The workout finished, but the selected routine changes failed to save.
    case workoutFinishedRoutineSaveFailed
    /// A rest countdown reached zero while the app was running it live.
    case restCompleted
    /// A routine, exercise, block, or alternative was created or duplicated.
    case itemCreated
    /// A destructive action (discard, delete) ran after user confirmation.
    case destructiveConfirmed
    /// An import committed successfully.
    case importSucceeded
    /// An action was rejected and the UI is showing why (duplicate name,
    /// locked item, unreadable import).
    case actionRejected

    var event: HapticEvent {
        switch self {
        case .selectionChanged: return .selection
        case .workoutStepChanged, .setLogged, .setUnlogged, .setTimerStarted,
            .exerciseSwitched, .itemCreated:
            return .lightImpact
        case .workoutStarted, .workoutSavedAndExited,
            .workoutFinishedRoutineSaveFailed:
            return .mediumImpact
        case .workoutFinished, .restCompleted, .importSucceeded:
            return .success
        case .destructiveConfirmed: return .warning
        case .actionRejected: return .error
        }
    }
}

/// Pure trigger decisions for the cases where whether — or which — haptic
/// fires depends on an outcome. Kept free of UIKit so tests can assert
/// action → cue without touching hardware.
enum HapticPolicy {
    /// Back / Next / Finish. Only a cursor move is felt; reaching the end
    /// opens the finish confirmation, whose own outcome is felt later.
    static func cue(for next: WorkoutNextAction) -> HapticCue? {
        switch next {
        case .advanceExercise, .advanceBlock: return .workoutStepChanged
        case .confirmFinish: return nil
        }
    }

    /// The single haptic for a finish. Nil when no workout was recorded.
    /// A failed routine save must not read as a full success.
    static func finishCue(
        workoutRecorded: Bool,
        routineChangesRequested: Bool,
        routineChangesSaved: Bool
    ) -> HapticCue? {
        guard workoutRecorded else { return nil }
        if routineChangesRequested && !routineChangesSaved {
            return .workoutFinishedRoutineSaveFailed
        }
        return .workoutFinished
    }

    /// An import is a success only when it actually added something; a run
    /// that skipped every row reports its result without a success haptic.
    static func importCue(insertedCount: Int) -> HapticCue? {
        insertedCount > 0 ? .importSucceeded : nil
    }

    /// A log / undo is only felt when it actually wrote or removed a SetLog.
    static func setLogCue(logged: Bool, didRecord: Bool) -> HapticCue? {
        guard didRecord else { return nil }
        return logged ? .setLogged : .setUnlogged
    }
}

/// Performs `HapticCue`s on the device. Generators are created per call —
/// no persistent engine, no preparation, no state.
@MainActor
enum AppHaptics {
    static func play(_ cue: HapticCue?) {
        guard let cue else { return }
        switch cue.event {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

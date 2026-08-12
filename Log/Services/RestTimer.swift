import ActivityKit
import Combine
import Foundation
import UIKit
import UserNotifications

/// UserDefaults keys for **one** `RestTimer` instance.
///
/// These were previously three global constants, which meant the two live
/// `RestTimer` instances (`rest` and `setTimer` in `ActiveWorkoutView`) read
/// and wrote the same slots. A running duration set would therefore be
/// rehydrated into the *rest* timer on foreground, surfacing the duration
/// countdown behind the "Rest" overlay. Keys are now namespaced per instance;
/// the rest namespace keeps the original key strings so already-persisted
/// rest state still rehydrates across this change.
private struct RestStoreKeys {
    let endDate: String
    let total: String
    let mode: String

    init(namespace: String) {
        endDate = "\(namespace).endDate"
        total = "\(namespace).total"
        mode = "\(namespace).mode"
    }
}

extension RestTimer {
    enum Mode: String { case rest, set }

    /// Persistence namespaces. One per live `RestTimer` instance — never share.
    enum Namespace {
        /// Real between-sets rest. Original key prefix, kept for continuity.
        static let rest = "restTimer"
        /// Duration-based set ("Duration") countdown.
        static let set = "setTimer"

        static let all = [rest, set]
    }

    func resumeIfScheduled() {
        let ud = UserDefaults.standard
        let keys = storeKeys
        guard
            let endTs = ud.object(forKey: keys.endDate)
                as? TimeInterval,
            let total = ud.object(forKey: keys.total) as? Int,
            let modeStr = ud.string(forKey: keys.mode),
            let mode = Mode(rawValue: modeStr)
        else { return }

        let end = Date(timeIntervalSince1970: endTs)
        let remainingNow = secondsRemaining(until: end)
        guard remainingNow > 0 else {
            clearPersistence()
            if mode == .rest { updateActivityNeutral() }
            return
        }

        // Rehydrate live state
        self.mode = mode
        self.endDate = end
        self.total = total
        self.remaining = remainingNow
        self.isRunning = true

        // Restart ticker (simple 1s cadence)
        ticker?.cancel()
        ticker = nil
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }

        if mode == .rest { startOrUpdateActivity() }
    }

    private func persistState() {
        guard let end = endDate else { return }
        let ud = UserDefaults.standard
        let keys = storeKeys
        ud.set(end.timeIntervalSince1970, forKey: keys.endDate)
        ud.set(total, forKey: keys.total)
        ud.set(mode.rawValue, forKey: keys.mode)
    }

    private func clearPersistence() {
        let ud = UserDefaults.standard
        let keys = storeKeys
        ud.removeObject(forKey: keys.endDate)
        ud.removeObject(forKey: keys.total)
        ud.removeObject(forKey: keys.mode)
    }

    /// Clears persisted timer state (UserDefaults) and cancels any
    /// scheduled/delivered notifications with the given IDs.
    /// Safe to call from any context (does not require a RestTimer instance).
    ///
    /// Clears **every** namespace by default: workout-end / discard paths must
    /// not leave a stale duration countdown behind for the next session to
    /// rehydrate. Only rest schedules notifications, so the ID handling below
    /// is unchanged.
    static func clearPersistedStateAndNotifications(
        namespaces: [String] = Namespace.all,
        cancelNotificationIDs: [String] = []
    ) {
        let ud = UserDefaults.standard
        for keys in namespaces.map(RestStoreKeys.init(namespace:)) {
            ud.removeObject(forKey: keys.endDate)
            ud.removeObject(forKey: keys.total)
            ud.removeObject(forKey: keys.mode)
        }

        if !cancelNotificationIDs.isEmpty {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(
                withIdentifiers: cancelNotificationIDs
            )
            center.removeDeliveredNotifications(
                withIdentifiers: cancelNotificationIDs
            )
        }
    }

    /// Builds the stable notification ID format used by rest timers.
    static func stableNotificationID(
        workoutID: UUID,
        slotID: UUID
    ) -> String {
        "rest.\(workoutID.uuidString).\(slotID.uuidString)"
    }
}

@MainActor
final class RestTimer: ObservableObject {
    @Published private(set) var remaining: Int = 0
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var total: Int = 0
    private var mode: Mode = .rest

    /// Role of the countdown currently running, or `nil` when idle.
    ///
    /// Rest-specific presentation — the "Rest" overlay title, the rest
    /// notification, the Live Activity — must key off this rather than
    /// assuming any running `RestTimer` is a rest.
    var runningMode: Mode? { isRunning ? mode : nil }

    /// UserDefaults namespace owned by this instance. Two instances must never
    /// share one, or each will rehydrate the other's countdown on foreground.
    let storeNamespace: String
    private var storeKeys: RestStoreKeys

    /// - Parameter namespace: persistence namespace, defaulting to the rest
    ///   timer's original key prefix so existing rest state keeps rehydrating.
    ///   Pass `Namespace.set` for the duration-set timer.
    init(namespace: String = Namespace.rest) {
        self.storeNamespace = namespace
        self.storeKeys = RestStoreKeys(namespace: namespace)
    }

    // Foreground ticker (suspends in background; corrected via wall-clock on resume)
    private var ticker: AnyCancellable?

    // Wall-clock anchor so the countdown survives background
    private var endDate: Date?

    // For canceling/replacing the scheduled local notification
    private var pendingNotificationID: String?

    /// Stable notification ID set externally (e.g. "rest.<workoutID>.<slotID>").
    /// When set, replaces the random UUID-based ID for deduplication.
    var stableNotificationID: String?

    private func clearDeliveredNotificationIfAny() {
        var ids: [String] = []
        if let id = pendingNotificationID { ids.append(id) }
        if let id = stableNotificationID, !ids.contains(id) { ids.append(id) }
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - Time Math (for resume / sync)

    /// Floor-based whole seconds remaining (never negative).
    private func secondsRemaining(until end: Date) -> Int {
        return max(0, Int(floor(end.timeIntervalSinceNow)))
    }

    // Live Activity instance
    private var activity: Activity<RestActivityAttributes>?

    @MainActor
    private func attachExistingActivityIfPresent() {
        // If we already have a handle, nothing to do.
        guard activity == nil else { return }
        guard activityKitAvailable else { return }

        // If there is an OS-level RestActivity already running, attach to it.
        if let existing = Activity<RestActivityAttributes>.activities.first {
            activity = existing
            monitorActivityState(existing)
        }
    }

    /// Start (or restart) a rest countdown. Title appears on the Lock Screen widget.
    func start(seconds: Int, mode: Mode = .rest) {
        guard seconds > 0 else {
            stop()
            return
        }

        // Cancel prior state
        cancelPendingNotification()
        ticker?.cancel()
        ticker = nil

        self.mode = mode
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
        remaining = seconds
        isRunning = true
        total = seconds
        persistState()

        if let endDate, mode == .rest {  // only rest gets a local notification
            scheduleRestDoneNotification(at: endDate)
        }
        if mode == .rest {  // only rest drives Live Activity
            startOrUpdateActivity()
        }

        // Simple 1s ticker: we just decrement remaining each second.
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func stop() {
        isRunning = false
        remaining = 0
        endDate = nil
        total = 0

        ticker?.cancel()
        ticker = nil

        // Transition to neutral (keep activity visible for session)
        if mode == .rest { updateActivityNeutral() }
        cancelPendingNotification()
        clearPersistence()
        mode = .rest  // reset for next use
    }

    /// Call this when app returns to foreground to re-sync remaining time.
    func handleLifecycleDidBecomeActive() {
        clearDeliveredNotificationIfAny()
        if !isRunning {
            resumeIfScheduled()  // rehydrate if we had a persisted countdown
        }
        if isRunning {
            ticker?.cancel()
            ticker = nil

            recomputeFromWallClock()

            ticker = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
        } else {
            if mode == .rest { updateActivityNeutral() }
        }
    }

    private func tick() {
        guard endDate != nil else {
            stop()
            return
        }

        // Normal foreground ticking: just decrement by 1 each second.
        if remaining > 0 {
            remaining -= 1
        }

        if remaining <= 0 {
            finish()
        } else if mode == .rest {
            updateActivity()
        }
    }

    private func finish() {
        isRunning = false
        remaining = 0
        endDate = nil
        total = 0

        ticker?.cancel()
        ticker = nil

        // Switch to a neutral (non-rest) state; Session keeps animating automatically
        if mode == .rest { updateActivityNeutral() }

        // Let the scheduled notification fire naturally as well.
        if mode == .rest {
            // haptic only for rest completion
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        clearPersistence()
    }

    private func recomputeFromWallClock() {
        guard let end = endDate else { return }
        let wall = secondsRemaining(until: end)
        if wall <= 0 {
            finish()
        } else {
            // On explicit resyncs we snap to the true value.
            remaining = wall
            if mode == .rest { updateActivity() }
        }
    }

    /// Public: update `remaining` immediately from wall clock.
    /// Call on view appear / resume so the UI reflects the true value right away.
    @MainActor
    func syncNow() {
        guard isRunning, endDate != nil else { return }
        recomputeFromWallClock()
    }

    private func scheduleRestDoneNotification(at date: Date) {
        let id = stableNotificationID ?? UUID().uuidString

        // Cancel any existing notification with this ID before scheduling
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = "Rest finished"
        content.body = "Ready for your next set."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        // UNTimeIntervalNotificationTrigger needs ≥ 1s
        let interval = max(1, Int(ceil(date.timeIntervalSinceNow)))
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(interval),
            repeats: false
        )
        let req = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: trigger
        )
        center.add(req, withCompletionHandler: nil)
        pendingNotificationID = id
    }

    private func cancelPendingNotification() {
        var ids: [String] = []
        if let id = pendingNotificationID { ids.append(id) }
        if let id = stableNotificationID, !ids.contains(id) { ids.append(id) }
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ids)
        pendingNotificationID = nil
    }

    private func startOrUpdateActivity() {
        guard let end = endDate else { return }
        let content = makeContent(end: end)

        // First, try to re-attach to an existing OS-level Live Activity.
        if activity == nil {
            if let existing = Activity<RestActivityAttributes>.activities.first
            {
                activity = existing
                monitorActivityState(existing)
            }
        }

        if let activity {
            // Update the existing activity (local or re-attached).
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            // No existing activity at all – request a fresh one.
            do {
                activity = try Activity.request(
                    attributes: RestActivityAttributes(),
                    content: content,
                    pushType: nil
                )
                if let activity { monitorActivityState(activity) }
            } catch {
                #if DEBUG
                    print("Failed to start Live Activity:", error)
                #endif
            }
        }
    }

    private func updateActivity() {
        guard let end = endDate, let activity else { return }
        let content = makeContent(end: end)
        Task { await activity.update(content) }
    }

    private func updateActivityNeutral() {
        guard let activity else { return }
        let content = makeContent(end: Date())
        Task { await activity.update(content) }
    }

    private func makeContent(end: Date) -> ActivityContent<
        RestActivityAttributes.ContentState
    > {
        let start = ActiveWorkoutGuard.shared.sessionStart
        let state = RestActivityAttributes.ContentState(
            endDate: end,
            sessionStart: start
        )

        let stale = Date().addingTimeInterval(12 * 3600)  // 12h horizon
        return ActivityContent(state: state, staleDate: stale)
    }

    private var activityKitAvailable: Bool {
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        } else {
            return false
        }
    }

    @MainActor
    private func monitorActivityState(
        _ activity: Activity<RestActivityAttributes>
    ) {
        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    self?.activity = nil
                    break
                }
            }
        }
    }

    @MainActor
    func ensureActivityStartedForSession() {
        guard activityKitAvailable else { return }

        // First, try to attach to an existing OS-level activity.
        if activity == nil {
            if let existing = Activity<RestActivityAttributes>.activities.first
            {
                activity = existing
                monitorActivityState(existing)
                return  // Already have a neutral/session activity; don't create another.
            }
        }

        if activity != nil { return }

        // No existing activity — start a neutral (no-rest) Live Activity for the session.
        let content = makeContent(end: Date())  // neutral
        Task {
            do {
                activity = try Activity.request(
                    attributes: RestActivityAttributes(),
                    content: content,
                    pushType: nil
                )
                if let activity { monitorActivityState(activity) }
            } catch {
                #if DEBUG
                    print("Failed to start Live Activity:", error)
                #endif
            }
        }
    }

    @MainActor
    func endLiveActivityForWorkout() {
        cancelPendingNotification()
        clearDeliveredNotificationIfAny()

        Task {
            for act in Activity<RestActivityAttributes>.activities {
                await act.end(
                    makeContent(end: Date()),
                    dismissalPolicy: .immediate
                )
            }
            self.activity = nil

            #if DEBUG
                print(
                    "✅ All RestActivity live activities force-ended at workout completion."
                )
            #endif
        }
    }
}

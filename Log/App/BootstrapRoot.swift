import SwiftData
import SwiftUI

struct BootstrapRoot: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var ctx

    // MARK: - Static (test-only)

    /// Ensures UI test data reset runs only once per test session.
    private static var didResetUITestData = false

    // MARK: - State

    @State private var isLoading = true
    @State private var launchStart = Date()

    // MARK: - Environment Flags

    /// Returns true when running under UI tests (Xcode launch argument).
    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    // MARK: - Body

    var body: some View {
        RootTabView()
            // Prevent the tab view itself from animating when loading finishes.
            .animation(.none, value: isLoading)
            .overlay {
                LoadingView()
                    .opacity(isLoading ? 1 : 0)
                    // Fade only the opacity of the overlay.
                    .animation(.easeOut(duration: 1.0), value: isLoading)
                    // Ensure the overlay covers the entire UI.
                    .modifier(IgnoreAllSafeAreas())
                    // Block taps while loading is visible.
                    .allowsHitTesting(isLoading)
            }
            .task {
                launchStart = Date()

                // For UI tests, reset the data store once per session.
                if isUITesting && !Self.didResetUITestData {
                    await resetDataForUITests()
                    Self.didResetUITestData = true
                }

                // Backfill stable slot IDs and default variants for existing data.
                backfillPhase1()
                backfillPhase3_1()
                // Phase 3.3a: no backfill needed — snapshots are nil for old items.

                // Phase 10-polish-F (2026-05-24): seed the built-in exercise
                // catalogue on first launch so new installs do not start with
                // an empty Exercises tab. Idempotent — gated by a
                // UserDefaults version flag; subsequent launches are a no-op
                // under the same `ExerciseCatalog.currentVersion`. Placed
                // after Phase 1/3.1 backfills (no ordering dependency, but
                // keeps "schema-shaping backfills first, then data
                // population") and before `hydrateEmptySlotPrescriptions`
                // (which only walks pre-existing `RoutineExercise` rows, so
                // ordering between the two is purely defensive).
                ExerciseSeedService.seedIfNeeded(in: ctx)

                // Phase 9-A2: hydrate empty/missing SlotPrescription content
                // from each slot's setTemplates → AppSettings defaults so
                // legacy slots become self-sufficient (Tier 3 source was
                // removed alongside the Exercise.defaultTemplates field
                // deletion in Phase 9-E2). MUST run after backfillPhase3_1()
                // so every RoutineExercise already has a SlotPrescription
                // instance attached. Idempotent — the service's `hasContent`
                // guard makes every subsequent launch a no-op for
                // already-hydrated slots.
                BackfillService.hydrateEmptySlotPrescriptions(in: ctx)

                // Phase 10-E (2026-05-24): the Phase 10-D
                // `migrateEquipmentSetupToExercise(in: ctx)` call site
                // was removed here once `SlotPrescription.equipment` /
                // `setupNotes` were dropped from the schema. The
                // helper had already populated `Exercise.equipmentType`
                // / `setupDefaults` on every launch since 10-D
                // shipped, so the migration was complete on every
                // active device before the field deletion.

                // Phase 6.B Slice B: link pre-existing Workouts to their
                // routine's preferred variant. Must run AFTER backfillPhase1()
                // so every routine has at least one variant to point at.
                BackfillService.backfillRoutineVariantIDs(in: ctx)

                // Phase 9-E2: sweep SetTemplate rows that were children
                // of the (now deleted) Exercise.defaultTemplates
                // relationship. No-op on stores where the relationship
                // was already empty (the pre-9-E2 Debug diagnostic showed
                // 0 such rows on the maintainer's data). Idempotent on
                // subsequent launches. Runs AFTER hydration so any
                // RoutineExercise.setTemplates references stay intact.
                BackfillService.purgeOrphanSetTemplates(in: ctx)

                // Phase 4a: validate persisted active session state.
                validateActiveSession()

                // Enforce a minimum splash duration only for real users.
                if !isUITesting {
                    let elapsed = Date().timeIntervalSince(launchStart)
                    let remaining = max(0, 1.5 - elapsed)
                    if remaining > 0 {
                        try? await Task.sleep(
                            nanoseconds: UInt64(remaining * 1_000_000_000)
                        )
                    }
                }

                isLoading = false
            }
    }

    // MARK: - Test Data Reset

    /// Clears all persistent data for UI tests so each run starts clean.
    @MainActor
    private func resetDataForUITests() async {
        deleteAll(AppState.self)
        deleteAll(PlannedPrescriptionSnapshot.self)
        deleteAll(SetLog.self)
        deleteAll(WorkoutItem.self)
        deleteAll(Workout.self)
        deleteAll(TechniquePlan.self)
        deleteAll(SlotPrescription.self)
        deleteAll(WarmupStep.self)
        deleteAll(WarmupScheme.self)
        deleteAll(RoutineVariant.self)
        deleteAll(Routine.self)
        deleteAll(RoutineBlock.self)
        deleteAll(RoutineExercise.self)
        deleteAll(SetTemplate.self)
        deleteAll(Exercise.self)
        try? ctx.save()

        // Phase 10-polish-F: clear the seed-version flag so UI tests
        // starting from a clean store also start from a clean "never
        // seeded" state. Without this, the in-memory data is wiped but
        // `ExerciseSeedService.seedIfNeeded` would short-circuit on the
        // persisted UserDefaults flag and the seeded rows would never
        // reappear under UI tests.
        UserDefaults.standard.removeObject(
            forKey: ExerciseSeedService.seedVersionKey
        )
    }

    /// Deletes all instances of a given SwiftData model type.
    private func deleteAll<T: PersistentModel>(_ type: T.Type) {
        if let all = try? ctx.fetch(FetchDescriptor<T>()) {
            all.forEach { ctx.delete($0) }
        }
    }

    // MARK: - Phase 1 Backfill

    /// Idempotent backfill that runs on every launch.
    /// 1) Ensures every RoutineBlock and RoutineExercise has a unique slotID.
    /// 2) Ensures every Routine has at least one RoutineVariant ("Default").
    @MainActor
    private func backfillPhase1() {
        var dirty = false

        // --- Deduplicate RoutineBlock.slotID ---
        if let blocks = try? ctx.fetch(FetchDescriptor<RoutineBlock>()) {
            var seen = Set<UUID>()
            for block in blocks {
                if !seen.insert(block.slotID).inserted {
                    block.slotID = UUID()
                    dirty = true
                }
            }
        }

        // --- Deduplicate RoutineExercise.slotID ---
        if let exercises = try? ctx.fetch(FetchDescriptor<RoutineExercise>()) {
            var seen = Set<UUID>()
            for re in exercises {
                if !seen.insert(re.slotID).inserted {
                    re.slotID = UUID()
                    dirty = true
                }
            }
        }

        // --- Create default RoutineVariant for routines that lack one ---
        if let routines = try? ctx.fetch(FetchDescriptor<Routine>()) {
            for routine in routines where routine.variants.isEmpty {
                let variant = RoutineVariant(name: "Default", order: 0)
                ctx.insert(variant)
                routine.variants.append(variant)
                dirty = true
            }
        }

        if dirty {
            try? ctx.save()
        }
    }

    // MARK: - Phase 3.1 Backfill

    /// Idempotent backfill: ensures every RoutineExercise has a SlotPrescription.
    /// Does NOT migrate data from setTemplates — that is Phase 3.2+.
    @MainActor
    private func backfillPhase3_1() {
        guard let slots = try? ctx.fetch(FetchDescriptor<RoutineExercise>()) else { return }

        var dirty = false
        for re in slots where re.prescription == nil {
            let p = SlotPrescription()
            ctx.insert(p)
            re.prescription = p
            dirty = true
        }

        if dirty {
            try? ctx.save()
        }
    }

    // MARK: - Phase 4a: AppState Helpers

    /// Idempotent: fetches the singleton AppState or creates one.
    @MainActor
    @discardableResult
    static func fetchOrCreateAppState(in ctx: ModelContext) -> AppState {
        let descriptor = FetchDescriptor<AppState>(
            predicate: #Predicate { $0.key == "appState" }
        )
        if let existing = try? ctx.fetch(descriptor).first {
            return existing
        }
        let state = AppState()
        ctx.insert(state)
        try? ctx.save()
        return state
    }

    /// Validates persisted active session state on launch.
    /// Resets to `.idle` if the referenced workout no longer exists.
    @MainActor
    private func validateActiveSession() {
        let appState = Self.fetchOrCreateAppState(in: ctx)

        guard appState.workoutState == .active else { return }

        var shouldReset = false

        if let workoutID = appState.activeWorkoutID {
            let descriptor = FetchDescriptor<Workout>(
                predicate: #Predicate { $0.id == workoutID }
            )
            let workoutExists = (try? ctx.fetch(descriptor).first) != nil
            if !workoutExists {
                shouldReset = true
            }
        } else {
            // State is .active but no workout ID — inconsistent
            shouldReset = true
        }

        if shouldReset {
            // Clear orphaned rest persistence before resetting AppState
            var notificationIDs: [String] = []
            if let wID = appState.activeWorkoutID,
                let slotID = appState.activeRestSlotID
            {
                notificationIDs.append(
                    RestTimer.stableNotificationID(
                        workoutID: wID, slotID: slotID
                    )
                )
            }
            RestTimer.clearPersistedStateAndNotifications(
                cancelNotificationIDs: notificationIDs
            )

            appState.workoutState = .idle
            appState.activeWorkoutID = nil
            appState.activeWorkoutStartedAt = nil
            appState.activeRestEndsAt = nil
            appState.activeRestSlotID = nil
            try? ctx.save()
        }
    }

}

// MARK: - Safe-Area Ignoring Modifier

/// Ensures the overlay covers the whole screen, including the tab bar.
/// Uses the iOS 17 `.container` behavior when available.
private struct IgnoreAllSafeAreas: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.ignoresSafeArea(.container, edges: .all)
        } else {
            content.ignoresSafeArea(.all)
        }
    }
}

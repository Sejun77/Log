import Foundation
import SwiftData

/// Phase 6.B Slice B launch-time backfill, extracted from `BootstrapRoot` so
/// it can be unit-tested in isolation. Behavior is identical to the previous
/// inline `BootstrapRoot.backfillPhase6B()` — the function body is preserved
/// verbatim, only `self.ctx` becomes the `in ctx:` parameter.
@MainActor
enum BackfillService {

    /// Idempotent: for every existing `Workout` whose `routineVariantID` is
    /// nil, resolve a `RoutineVariant` and write its id. Matches by
    /// `routineID` first; falls back to lowercased `routineName` only if the
    /// id can't resolve. Leaves the field nil when no routine can be found,
    /// so the row remains eligible for a future backfill pass if the routine
    /// later reappears. Never overwrites a non-nil `routineVariantID`. Must
    /// run AFTER the routine/variant backfills (e.g. `BootstrapRoot.backfillPhase1`)
    /// so every routine has at least one variant.
    static func backfillRoutineVariantIDs(in ctx: ModelContext) {
        // Fetch unlinked workouts. We filter in Swift rather than via a
        // SwiftData `#Predicate { $0.routineVariantID == nil }` — optional
        // UUID predicates have been historically finicky and the candidate
        // set is small, so an in-memory filter is the safer, equivalent path.
        guard let allWorkouts = try? ctx.fetch(FetchDescriptor<Workout>())
        else { return }
        let candidates = allWorkouts.filter { $0.routineVariantID == nil }
        guard !candidates.isEmpty else { return }

        // Build lookup tables once.
        let routines: [Routine] =
            (try? ctx.fetch(FetchDescriptor<Routine>())) ?? []
        guard !routines.isEmpty else { return }

        let byID: [UUID: Routine] = Dictionary(
            routines.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Name fallback. For duplicate lowercased names, deterministically
        // keep the routine with the lowest `(order, name)` so reruns are
        // stable and not dependent on fetch order.
        let byLowercaseName: [String: Routine] = Dictionary(
            grouping: routines,
            by: { $0.name.lowercased() }
        ).mapValues { group in
            group.sorted { ($0.order, $0.name) < ($1.order, $1.name) }.first!
        }

        // Precompute each routine's preferred variant id so we don't recompute
        // per candidate. Uses the shared rule from `Routine.preferredVariantID`.
        let preferredByRoutineID: [UUID: UUID] =
            routines.reduce(into: [:]) { acc, r in
                if let vid = r.preferredVariantID { acc[r.id] = vid }
            }

        var dirty = false
        for w in candidates {
            var resolved: UUID? = nil

            if let rid = w.routineID,
                let r = byID[rid],
                let vid = preferredByRoutineID[r.id]
            {
                resolved = vid
            } else if let rname = w.routineName?.lowercased(),
                let r = byLowercaseName[rname],
                let vid = preferredByRoutineID[r.id]
            {
                resolved = vid
            }

            if let vid = resolved {
                w.routineVariantID = vid
                dirty = true
            }
        }

        if dirty {
            try? ctx.save()
        }
    }

    /// Phase 9-A backfill: hydrate every `RoutineExercise` whose
    /// `prescription` is missing or has `hasContent == false` so the slot
    /// becomes self-sufficient. Additive only — never deletes Tier-1
    /// overrides, and never overwrites a content-bearing prescription.
    ///
    /// Hydration source priority (post Phase 9-E2 — Tier 3
    /// `Exercise.defaultTemplates` source removed alongside the model
    /// field deletion):
    ///   1) `re.setTemplates` if non-empty (Tier 1 explicit overrides)
    ///   2) `AppSettings` defaults (final fallback)
    ///
    /// Field mapping:
    ///   - `usesDuration = exercise.isTimeBased` (Exercise owns its mode)
    ///   - `sets = max(1, working.count)`, else `AppSettings.defaultSets`
    ///   - Rep-based: `repMin`/`repMax` = min/max positive `targetReps`
    ///     across working sets, else `AppSettings.defaultRepMin`/`Max`
    ///   - Time-based: `durationMin`/`Max` = min/max positive
    ///     `durationSeconds`, else a hardcoded 60s
    ///   - `restSecondsBetweenSets` = first positive `restSecondsAfter`
    ///     across working sets, else `AppSettings.defaultRestBetweenSets`
    ///   - `restSecondsAfterExercise` set only when the source is fully
    ///     empty AND `AppSettings.defaultRestAfterExercise > 0`
    ///
    /// Never mined: `targetWeight` (no landing field — accepted loss per
    /// 9-A.5 audit), `rir` / `rpe` / `tempo` (templates carry no autoreg).
    ///
    /// Idempotent: re-running on an already-hydrated store is a no-op
    /// (the `hasContent` guard at the top short-circuits every slot).
    static func hydrateEmptySlotPrescriptions(in ctx: ModelContext) {
        guard let slots = try? ctx.fetch(FetchDescriptor<RoutineExercise>())
        else { return }

        var dirty = false
        for re in slots {
            // Skip content-bearing prescriptions (idempotency guard).
            if let p = re.prescription, p.hasContent { continue }

            // Defensive: create prescription if missing. Phase 3.1 backfill
            // should have created one already; pinned by the create-if-nil test.
            let p: SlotPrescription
            if let existing = re.prescription {
                p = existing
            } else {
                let new = SlotPrescription()
                ctx.insert(new)
                re.prescription = new
                p = new
            }

            hydrate(p, from: re)
            dirty = true
        }

        if dirty {
            try? ctx.save()
        }
    }

    /// Pure mapping step shared by every backfilled slot. Mutates `p` only;
    /// never mutates `re.setTemplates`.
    private static func hydrate(
        _ p: SlotPrescription, from re: RoutineExercise
    ) {
        // Phase 9-E2: source priority collapsed to Tier 1 → empty.
        // The former Tier-3 `Exercise.defaultTemplates` branch went away
        // with the model field deletion.
        let source: [SetTemplate] =
            re.setTemplates.isEmpty ? [] : re.setTemplates

        // 2) Mode: Exercise owns its own time/rep mode. Wins over heuristics
        // on template shape. Defaults to rep-based when exercise is nil.
        let isTimeBased = re.exercise?.isTimeBased ?? false
        p.usesDuration = isTimeBased

        // 3) Working-only filter (warmup + dropset rows do NOT contribute
        // to sets, reps, duration, or rest).
        let working = source
            .filter { $0.kind == .working }
            .sorted { $0.order < $1.order }

        // 4) Sets count.
        if working.isEmpty {
            p.sets = AppSettings.defaultSets
        } else {
            p.sets = max(1, working.count)
        }

        // 5) Rep- vs. time-based core fields.
        if isTimeBased {
            let durations = working
                .compactMap(\.durationSeconds)
                .filter { $0 > 0 }
            if let mn = durations.min(), let mx = durations.max() {
                p.durationMinSeconds = mn
                p.durationMaxSeconds = mx
            } else {
                // Hardcoded 60s — no AppSettings.defaultDuration exists today.
                // Phase 9-A.5 audit will decide whether to add one.
                p.durationMinSeconds = 60
                p.durationMaxSeconds = 60
            }
        } else {
            let reps = working.compactMap {
                $0.targetReps > 0 ? $0.targetReps : nil
            }
            if let mn = reps.min(), let mx = reps.max() {
                p.repMin = mn
                p.repMax = mx
            } else {
                p.repMin = AppSettings.defaultRepMin
                p.repMax = AppSettings.defaultRepMax
            }
        }

        // 6) Rest between sets: first positive working rest, else AppSettings.
        // First-positive avoids locking to a longer late-set rest.
        let firstWorkingRest = working
            .compactMap(\.restSecondsAfter)
            .first { $0 > 0 }
        p.restSecondsBetweenSets = firstWorkingRest
            ?? AppSettings.defaultRestBetweenSets

        // 7) Rest after exercise: only set under full-AppSettings fallback
        // (no template source at all) AND when the user setting is positive.
        // Per-template restSecondsAfter values are not aggregated into this
        // field because templates have no "after-exercise" notion.
        if source.isEmpty, AppSettings.defaultRestAfterExercise > 0 {
            p.restSecondsAfterExercise = AppSettings.defaultRestAfterExercise
        }
    }

    // MARK: - Phase 9 diagnostic

    // Phase 10-E (2026-05-24): the Phase 10-D helper
    // `migrateEquipmentSetupToExercise(in:)` retired here. It read
    // `SlotPrescription.equipment` / `setupNotes` to backfill the
    // matching `Exercise` fields; once those slot columns were
    // dropped by 10-E it could no longer compile. The helper had
    // already run on every launch since 10-D shipped, so all
    // eligible Exercises were populated before the schema drop.

    // MARK: - Phase 9-E2 orphan sweep

    /// One-time defensive cleanup for `SetTemplate` rows that were
    /// children of the (now deleted) `Exercise.defaultTemplates`
    /// relationship. After SwiftData performs lightweight migration for
    /// the property drop, those child rows become standalone — no
    /// parent references them. The pre-9-E2 Debug-simulator diagnostic
    /// returned `exercisesWithDefaultTemplates = 0` so on the
    /// maintainer's data this sweep is a no-op, but it ships as
    /// defense-in-depth for any device whose pre-9-E store carried
    /// defaults content.
    ///
    /// Implementation: enumerate every `SetTemplate`, collect the set
    /// of model IDs referenced by `RoutineExercise.setTemplates` (the
    /// only remaining `@Relationship` to `SetTemplate`), delete the
    /// difference.
    ///
    /// Idempotent — once orphans are gone, every subsequent run sees
    /// only the referenced rows and the difference is empty. Safe to
    /// call on every launch.
    static func purgeOrphanSetTemplates(in ctx: ModelContext) {
        guard let templates = try? ctx.fetch(FetchDescriptor<SetTemplate>())
        else { return }
        guard let slots = try? ctx.fetch(FetchDescriptor<RoutineExercise>())
        else { return }

        let referenced: Set<PersistentIdentifier> = Set(
            slots.flatMap { $0.setTemplates.map(\.persistentModelID) }
        )

        var dirty = false
        for tpl in templates
        where !referenced.contains(tpl.persistentModelID) {
            ctx.delete(tpl)
            dirty = true
        }

        if dirty {
            try? ctx.save()
        }
    }
}

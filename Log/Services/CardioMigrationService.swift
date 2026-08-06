import Foundation
import SwiftData

/// Cardio Slice 10 — the assisted, **user-approved** upgrade of pre-cardio
/// exercises.
///
/// Catalogue v3 marks the built-in Cardio entries `isCardio = true`, but that
/// only reaches a *fresh* install: the seeder dedupes by name, so a user who
/// already has "Treadmill Run" keeps their own row exactly as it is. Those rows
/// are time-based Cardio exercises created before `Exercise.isCardio` existed,
/// so they render as timed holds — right duration, no distance / pace / heart
/// rate / calories / incline / resistance.
///
/// Converting them silently at launch would violate the "no silent mutation"
/// rule in CLAUDE.md, so this service only *detects* candidates and *offers*
/// the conversion. `BootstrapRoot` presents a one-time alert; nothing is written
/// unless the user taps "Mark as Cardio".
///
/// ## Candidate rule (deliberately conservative)
/// An exercise is a candidate when **all three** hold:
///   - `bodyPart` is Cardio (trimmed, case-insensitive — legacy rows and CSV
///     imports carry casing/whitespace variants of the canonical string),
///   - `isTimeBased == true`,
///   - `isCardio == false`.
///
/// Nothing is inferred from the exercise *name*. A "Treadmill Run" filed under
/// Legs stays untouched, and so do Plank and every other timed hold outside
/// Cardio — the whole point is that the user can still say no, and that saying
/// yes is safe.
///
/// ## Prompt policy: one-time **per catalogue version**
/// The dismissal flag stores `ExerciseCatalog.currentVersion`, not a bool. Under
/// v3 the prompt is offered exactly once — "Not Now" silences it for good on
/// that version, so there is no nagging across launches. A future catalogue
/// version that adds cardio entries may offer it again, once, to users who
/// still have candidates. That is the reason for the version rather than a
/// bool: the alternative (one-time forever) would permanently strand anyone who
/// dismissed the prompt before creating their cardio exercises.
@MainActor
enum CardioMigrationService {

    /// Persistent flag key. Holds the `ExerciseCatalog.currentVersion` under
    /// which the prompt was last resolved (shown-and-answered, or made moot by
    /// a fresh install). Absent / lower than the current version means the
    /// prompt may still be offered. Cleared by `BootstrapRoot.resetDataForUITests`
    /// alongside the seed-version flag.
    static let promptVersionKey = "cardioMigrationPromptVersion"

    /// The canonical Cardio body part, matched leniently (see `isCandidate`).
    private static let cardioBodyPart = "Cardio"

    // MARK: - Detection

    /// Whether a single exercise qualifies for the assisted conversion.
    /// Pure — no fetch, no write — so the rule is testable in isolation from
    /// both the store and the prompt state.
    static func isCandidate(_ exercise: Exercise) -> Bool {
        guard exercise.isTimeBased, !exercise.isCardio else { return false }
        guard let bodyPart = exercise.bodyPart else { return false }
        return
            bodyPart
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(cardioBodyPart) == .orderedSame
    }

    /// Every candidate currently in the store, in fetch order. Returns `[]` —
    /// never throws — when the fetch fails or the store is empty, so a launch
    /// path can call this unconditionally.
    static func candidates(in ctx: ModelContext) -> [Exercise] {
        let all = (try? ctx.fetch(FetchDescriptor<Exercise>())) ?? []
        return all.filter(isCandidate)
    }

    // MARK: - Prompt state

    /// Whether the prompt should be shown right now: the flag has not been
    /// resolved for this catalogue version **and** at least one candidate
    /// exists. Both halves matter — the flag alone would nag users with nothing
    /// to convert, and the candidates alone would nag on every launch after
    /// "Not Now".
    static func shouldPrompt(
        in ctx: ModelContext,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard
            defaults.integer(forKey: promptVersionKey)
                < ExerciseCatalog.currentVersion
        else { return false }
        return !candidates(in: ctx).isEmpty
    }

    /// Records that the prompt no longer needs to be shown under this catalogue
    /// version. Called for "Not Now", after a successful conversion, and by the
    /// seeder on a fresh install (where v3 already seeds cardio correctly).
    static func resolvePrompt(defaults: UserDefaults = .standard) {
        defaults.set(ExerciseCatalog.currentVersion, forKey: promptVersionKey)
    }

    // MARK: - Conversion

    /// Marks every current candidate as cardio and resolves the prompt.
    ///
    /// Writes exactly one field per row, through `Exercise.setCardio`, which
    /// keeps the `isCardio ⇒ isTimeBased` invariant. Nothing else is touched:
    /// names, notes, equipment, setup defaults, order, `isCustom`, routine
    /// slots, `SetLog` history rows and workout snapshots are all left as they
    /// are. Routines change only in the derived sense that their slots now
    /// resolve to `trackingMode == .cardio`.
    ///
    /// - Returns: the number of exercises converted (0 when there were none).
    @discardableResult
    static func markCandidatesAsCardio(
        in ctx: ModelContext,
        defaults: UserDefaults = .standard
    ) -> Int {
        let targets = candidates(in: ctx)
        for exercise in targets {
            exercise.setCardio(true)
        }
        if !targets.isEmpty {
            try? ctx.save()
        }
        resolvePrompt(defaults: defaults)
        return targets.count
    }
}

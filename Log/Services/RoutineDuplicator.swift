import Foundation
import SwiftData

/// Authoring-side helper for duplicating a routine. Provides the pure
/// copied-name generator (Slice A) and the deep-copy service (Slice B); the UI
/// wiring (Slice C) lands later. Kept as an `enum` namespace mirroring
/// `RoutineBlockBuilder` / `RoutineNameValidator`.
enum RoutineDuplicator {
    /// Fallback base used when the original routine name is empty / whitespace
    /// only, so a duplicate always gets a sensible non-empty name.
    static let fallbackBaseName = "Routine"

    /// Generates a unique name for a duplicated routine.
    ///
    /// Rule (confirmed): base = `"<trimmed original> copy"`; if that collides
    /// (case-insensitively) with an existing routine name, append an
    /// incrementing suffix — `"… copy 2"`, `"… copy 3"`, … — until unique.
    /// Both the original name and the `existingNames` are trimmed of leading /
    /// trailing whitespace and newlines before comparison. An empty /
    /// whitespace-only original falls back to `"Routine"` (→ `"Routine copy"`).
    ///
    /// Pure value-in / value-out — no `ModelContext`, no SwiftData, no
    /// mutation — so it is unit-testable with literal fixtures, mirroring
    /// `RoutineNameValidator`.
    static func copiedName(
        for originalName: String,
        existingNames: [String]
    ) -> String {
        let trimmedOriginal = originalName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let base = trimmedOriginal.isEmpty ? fallbackBaseName : trimmedOriginal

        // Normalize existing names once for case-insensitive lookup.
        let taken = Set(
            existingNames
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                .filter { !$0.isEmpty }
        )

        func isTaken(_ candidate: String) -> Bool {
            taken.contains(candidate.lowercased())
        }

        let first = "\(base) copy"
        if !isTaken(first) { return first }

        // Start suffixing at 2: "… copy 2", "… copy 3", …
        var n = 2
        while isTaken("\(base) copy \(n)") { n += 1 }
        return "\(base) copy \(n)"
    }

    // MARK: - Deep copy (Slice B)

    /// Deep-copies `source` into a brand-new `Routine` inserted into `ctx`.
    ///
    /// What is **deep-copied** (fresh, independent instances): every
    /// `RoutineBlock`, `RoutineExercise`, `SetTemplate`, `SlotPrescription`,
    /// `TechniquePlan`, and `WarmupScheme` + its `WarmupStep`s. What is
    /// **shared**: the definition-level `Exercise` references only (a deleted /
    /// unlinked source slot copies as a still-nil reference). Every copied
    /// block / slot / routine / variant gets a **fresh** `slotID` / `id`
    /// automatically by virtue of being a new instance (nothing is carried over
    /// from the source).
    ///
    /// A single fresh empty `Default` `RoutineVariant` is attached (matching the
    /// bootstrap behavior); source variants are intentionally **not** copied —
    /// they are empty grouping containers and `Routine.blocks` is the
    /// editable/startable source.
    ///
    /// The source routine and all its children are **never mutated**, and no
    /// `Workout` / history is touched. `ctx.save()` runs once after the whole
    /// new graph is built.
    @MainActor
    @discardableResult
    static func duplicate(
        _ source: Routine,
        among allRoutines: [Routine],
        in ctx: ModelContext
    ) -> Routine {
        let name = copiedName(
            for: source.name, existingNames: allRoutines.map(\.name)
        )
        let copy = Routine(name: name, notes: source.notes, blocks: [])
        copy.order = (allRoutines.map(\.order).max() ?? -1) + 1
        ctx.insert(copy)

        // Fresh empty Default variant (new id); do NOT copy source variants.
        let variant = RoutineVariant(name: "Default", order: 0)
        ctx.insert(variant)
        copy.variants.append(variant)

        for srcBlock in source.blocks.sorted(by: { $0.order < $1.order }) {
            copy.blocks.append(copyBlock(srcBlock, in: ctx))
        }

        try? ctx.save()
        return copy
    }

    // MARK: - Block deep copy

    /// Deep-copies a single `RoutineBlock` into a brand-new, inserted
    /// `RoutineBlock` (no parent attached — the caller appends it to whichever
    /// `Routine.blocks` it belongs in). Carries `isSuperset`, `order`,
    /// `restAfterSeconds`, and `supersetRoundRestSeconds`; deep-copies every
    /// `RoutineExercise` slot (and its `SetTemplate`s / `SlotPrescription` /
    /// `TechniquePlan`s / `WarmupScheme` + `WarmupStep`s) via `copySlot`, sharing
    /// only the definition-level `Exercise` references. The new block and every
    /// copied slot get a **fresh** `slotID` automatically by being new instances;
    /// the source block and its children are **never mutated**.
    ///
    /// `order` is copied verbatim from the source — callers that insert the copy
    /// into an *existing* routine (rather than a fresh duplicate) are responsible
    /// for assigning the destination `order` and renumbering siblings. This is
    /// the per-block primitive shared by whole-routine `duplicate(_:among:in:)`
    /// and the upcoming same-routine block-duplicate path.
    @MainActor
    static func copyBlock(
        _ src: RoutineBlock, in ctx: ModelContext
    ) -> RoutineBlock {
        let newBlock = RoutineBlock(
            isSuperset: src.isSuperset,
            order: src.order,
            restAfterSeconds: src.restAfterSeconds,
            exercises: []
        )
        newBlock.supersetRoundRestSeconds = src.supersetRoundRestSeconds
        ctx.insert(newBlock)

        for srcRE in src.exercises.sorted(by: { $0.order < $1.order }) {
            newBlock.exercises.append(copySlot(srcRE, in: ctx))
        }
        return newBlock
    }

    // MARK: - Private deep-copy primitives

    @MainActor
    private static func copySlot(
        _ src: RoutineExercise, in ctx: ModelContext
    ) -> RoutineExercise {
        let newRE: RoutineExercise
        if let ex = src.exercise {
            // Share the definition-level Exercise reference (never cloned).
            newRE = RoutineExercise(exercise: ex, order: src.order, setTemplates: [])
        } else {
            // Deleted/unlinked source slot: the designated init requires a
            // non-nil Exercise, so pass a transient placeholder (never inserted)
            // and immediately detach it so the copied slot stays unlinked,
            // exactly like the source.
            newRE = RoutineExercise(
                exercise: Exercise(name: ""), order: src.order, setTemplates: []
            )
            newRE.exercise = nil
        }
        ctx.insert(newRE)

        newRE.templateNotes = src.templateNotes
        newRE.setTemplates = src.setTemplates.map { copyTemplate($0, in: ctx) }
        if let p = src.prescription {
            newRE.prescription = copyPrescription(p, in: ctx)
        }
        return newRE
    }

    @MainActor
    private static func copyTemplate(
        _ src: SetTemplate, in ctx: ModelContext
    ) -> SetTemplate {
        let t = SetTemplate(
            kind: src.kind,
            targetReps: src.targetReps,
            targetWeight: src.targetWeight,
            restSecondsAfter: src.restSecondsAfter
        )
        t.kindRaw = src.kindRaw   // copy raw exactly
        t.order = src.order
        t.durationSeconds = src.durationSeconds
        ctx.insert(t)
        return t
    }

    @MainActor
    private static func copyPrescription(
        _ src: SlotPrescription, in ctx: ModelContext
    ) -> SlotPrescription {
        let p = SlotPrescription(
            sets: src.sets,
            repMin: src.repMin,
            repMax: src.repMax,
            restSecondsBetweenSets: src.restSecondsBetweenSets,
            restSecondsAfterExercise: src.restSecondsAfterExercise,
            rir: src.rir,
            rpe: src.rpe,
            tempo: src.tempo,
            effortModeRaw: src.effortModeRaw,
            rirStart: src.rirStart,
            rirEnd: src.rirEnd,
            rpeStart: src.rpeStart,
            rpeEnd: src.rpeEnd,
            durationMinSeconds: src.durationMinSeconds,
            durationMaxSeconds: src.durationMaxSeconds,
            usesDuration: src.usesDuration
        )
        ctx.insert(p)
        p.techniquePlans = src.techniquePlans.map { copyTechnique($0, in: ctx) }
        // WarmupScheme is mutated in place per-prescription
        // (`WarmupSchemeEditor`), so it must be deep-copied, never shared.
        if let scheme = src.warmupScheme {
            p.warmupScheme = copyWarmupScheme(scheme, in: ctx)
        }
        return p
    }

    @MainActor
    private static func copyTechnique(
        _ src: TechniquePlan, in ctx: ModelContext
    ) -> TechniquePlan {
        let t = TechniquePlan(
            order: src.order,
            type: src.type,
            repMin: src.repMin,
            repMax: src.repMax,
            reps: src.reps,
            durationSeconds: src.durationSeconds,
            restSeconds: src.restSeconds,
            rounds: src.rounds,
            dropPercent: src.dropPercent,
            dropCount: src.dropCount,
            partialRangeNote: src.partialRangeNote,
            partialRangeRaw: src.partialRangeRaw,
            note: src.note,
            appliesToRaw: src.appliesToRaw,
            appliesToSetNumber: src.appliesToSetNumber,
            appliesToSetIndicesRaw: src.appliesToSetIndicesRaw,
            dropsetEffortRaw: src.dropsetEffortRaw,
            dropsetEffortReps: src.dropsetEffortReps
        )
        t.typeRaw = src.typeRaw   // copy raw exactly (avoid lossy round-trip)
        ctx.insert(t)
        return t
    }

    @MainActor
    private static func copyWarmupScheme(
        _ src: WarmupScheme, in ctx: ModelContext
    ) -> WarmupScheme {
        let s = WarmupScheme(name: src.name)
        ctx.insert(s)
        s.steps = src.steps.map { copyStep($0, in: ctx) }
        return s
    }

    @MainActor
    private static func copyStep(
        _ src: WarmupStep, in ctx: ModelContext
    ) -> WarmupStep {
        let w = WarmupStep(
            order: src.order,
            kind: src.kind,
            reps: src.reps,
            percentOfWorking: src.percentOfWorking,
            restSecondsAfter: src.restSecondsAfter,
            note: src.note,
            weight: src.weight
        )
        w.kindRaw = src.kindRaw   // copy raw exactly
        ctx.insert(w)
        return w
    }
}

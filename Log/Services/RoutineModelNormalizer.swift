import Foundation
import SwiftData

/// Repairs a routine's stored structure when its editor opens: removes orphaned
/// slots, clears set templates that only duplicate the slot's prescription, and
/// renumbers `order` values.
///
/// **Writes only what differs.** SwiftData marks a model as updated on any
/// assignment, including one that stores the value already there, and saving
/// that makes every loaded `@Query` screen re-evaluate. So opening a routine that
/// is already normalized must leave the context clean and skip the save.
@MainActor
enum RoutineModelNormalizer {

    static func normalize(_ routine: Routine, in ctx: ModelContext) {
        // Clean orphaned RoutineExercise objects
        for b in Array(routine.blocks) {
            for re in Array(b.exercises) {
                if re.safeExercise(in: ctx) == nil {
                    ctx.delete(re)
                }
            }
        }
        // The pass below reads relationships as they stand after these deletes.
        if ctx.hasChanges { try? ctx.save() }

        // Normalize supersets and non-supersets
        for b in Array(routine.blocks) {
            if b.isSuperset {
                if b.exercises.contains(where: { re in
                    re.safeExercise(in: ctx) == nil
                }) {
                    ctx.delete(b)
                    continue
                }
            } else {
                for re in Array(b.exercises) {
                    guard re.safeExercise(in: ctx) != nil else {
                        ctx.delete(re)
                        continue
                    }

                    clearTemplatesIfExactCopyOfPrescription(re)
                }

                let sortedRE = b.exercises.filter(isLive).sorted { $0.order < $1.order }
                for (i, re) in sortedRE.enumerated() where re.order != i {
                    re.order = i
                }
            }
        }

        // Renumber blocks
        let sortedBlocks = routine.blocks.filter(isLive).sorted { $0.order < $1.order }
        for (i, blk) in sortedBlocks.enumerated() where blk.order != i {
            blk.order = i
        }

        if ctx.hasChanges { try? ctx.save() }
    }

    /// A relationship array can keep listing a model after it is deleted, until
    /// something refreshes it. Numbering only the live ones leaves no gap behind,
    /// which matters now that a clean routine no longer gets a save on every open.
    private static func isLive(_ model: some PersistentModel) -> Bool {
        !model.isDeleted && model.modelContext != nil
    }

    /// Phase 9-B1: clear Tier 1 overrides if they exactly match what the slot's
    /// prescription (Tier 2) would generate — was a comparison against
    /// `ex.defaultTemplates` (Tier 3) pre-9-B1. Only runs when the prescription
    /// has content; otherwise we'd generate against an empty/default prescription
    /// and potentially strip a slot's only template source.
    private static func clearTemplatesIfExactCopyOfPrescription(_ re: RoutineExercise) {
        guard let p = re.prescription, p.hasContent else { return }

        let a = re.setTemplates.sorted { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.persistentModelID < rhs.persistentModelID
        }
        let g = p.generateTemplates()
            .sorted { $0.order < $1.order }

        var isExactCopy = (a.count == g.count)

        if isExactCopy {
            for i in 0..<a.count {
                if a[i].kind != g[i].kind {
                    isExactCopy = false
                    break
                }
                if a[i].targetReps != g[i].targetReps {
                    isExactCopy = false
                    break
                }

                let aw = a[i].targetWeight ?? 0
                let gw = g[i].targetWeight ?? 0
                if aw != gw {
                    isExactCopy = false
                    break
                }

                let ar = a[i].restSecondsAfter ?? 0
                let gr = g[i].restSecondsAfter ?? 0
                if ar != gr {
                    isExactCopy = false
                    break
                }

                let ad = a[i].durationSeconds ?? 0
                let gd = g[i].durationSeconds ?? 0
                if ad != gd {
                    isExactCopy = false
                    break
                }
            }
        }

        if isExactCopy && !re.setTemplates.isEmpty {
            re.setTemplates.removeAll()
        }
    }
}

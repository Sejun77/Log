import Foundation

/// Read-only summary of which routines reference a given `Exercise`.
///
/// Built once from a live `[Routine]` snapshot (typically a sorted `@Query`)
/// and a target `exerciseID`. Pure value type — no SwiftData fetches, no
/// mutation — so it is safe to compute outside the SwiftUI `body` and unit
/// testable in isolation.
///
/// Counting rules (Exercise Detail "Used in Routines" polish):
///  - Counts **unique routines**, not slots. A routine that references the
///    exercise in two slots is one `Entry` with `slotCount == 2`.
///  - Scans `Routine.blocks` only. `RoutineVariant.blocks` are intentionally
///    ignored: variants are seeded empty at bootstrap and the routine editor
///    operates exclusively on `Routine.blocks`, matching the delete-impact
///    and Routines-tab summary logic.
///  - Matches by `RoutineExercise.exercise?.id == exerciseID`. A `nil`
///    (unlinked / deleted) exercise reference never matches and is skipped.
///  - Entries are ordered by `(Routine.order, Routine.name)` — the same order
///    the Routines tab shows.
///
/// **Alternative Exercises (Build 10 C1).** A slot's prepared alternatives
/// reference an `Exercise` by id just as the slot itself does, and until this
/// slice they were invisible here — an exercise used *only* as a prepared
/// alternative reported "Used in 0 routines" and its delete confirmation said
/// nothing about the prepared work it was about to destroy.
///
/// So the scan now also reads each slot's `prescription.slotAlternatives` and
/// counts matches by `SlotAlternative.exerciseID`. The two kinds of usage are
/// counted **separately** (`slotCount` vs `alternativeCount`) and never summed
/// into one number, because they have different consequences on delete: a
/// direct slot is removed from the routine, an alternative is removed from a
/// slot that itself survives.
///
/// Reading `slotAlternatives` is a decode of an additive `Data?` column and
/// inherits the whole `SlotAlternatives` tolerance contract — a nil, empty, or
/// corrupt column reads as `[]`. A routine whose alternatives payload was
/// hand-edited into nonsense therefore counts zero alternatives rather than
/// failing the scan, so this helper cannot be made to throw or crash by stored
/// data. Disabled alternatives (`isEnabled == false`) **are** counted: they are
/// still prepared work and deleting the exercise still destroys them.
struct ExerciseRoutineUsage {
    struct Entry: Equatable {
        let routineID: UUID
        let routineName: String
        /// Number of `RoutineExercise` slots in this routine that reference
        /// the target exercise directly. May be `0` for a routine that only
        /// references the exercise as a prepared alternative.
        let slotCount: Int
        /// Number of prepared alternatives in this routine that reference the
        /// target exercise, across every slot. May be `0`.
        let alternativeCount: Int

        /// Detail suffix shown after the routine name, e.g. `"· 2 slots"`,
        /// `"· 3 alternatives"`, `"· 2 slots · 3 alternatives"`.
        ///
        /// `nil` for normal single direct usage so the row shows the bare name
        /// — `"· 1 slot"` is never rendered on its own, which is the rule this
        /// suffix had before alternatives existed and the reason the slot part
        /// is still suppressed at exactly one.
        ///
        /// Alternatives are always named when present, at any count: unlike a
        /// second slot, a prepared alternative is not visible anywhere else on
        /// this screen, and it is the thing the delete confirmation is about to
        /// warn the user they will lose.
        var slotSuffix: String? {
            var parts: [String] = []
            if slotCount > 1 {
                parts.append(String(localized: "\(slotCount) slots"))
            }
            if alternativeCount == 1 {
                parts.append(String(localized: "\(alternativeCount) alternative"))
            } else if alternativeCount > 1 {
                parts.append(
                    String(localized: "\(alternativeCount) alternatives"))
            }
            guard !parts.isEmpty else { return nil }
            return "· " + parts.joined(separator: " · ")
        }
    }

    /// One entry per routine that references the exercise at least once —
    /// directly, as a prepared alternative, or both — ordered by
    /// `(Routine.order, Routine.name)`.
    let entries: [Entry]

    init(routines: [Routine], exerciseID: UUID) {
        let ordered = routines.sorted {
            ($0.order, $0.name) < ($1.order, $1.name)
        }

        var built: [Entry] = []
        for routine in ordered {
            var slots = 0
            var alternatives = 0
            for block in routine.blocks {
                for slot in block.exercises {
                    if slot.exercise?.id == exerciseID { slots += 1 }
                    // Tolerant by construction — see the type comment. A slot
                    // with no prescription, or one whose column is nil / empty
                    // / unreadable, contributes zero.
                    alternatives += slot.prescription?.slotAlternatives
                        .filter { $0.exerciseID == exerciseID }.count ?? 0
                }
            }
            if slots > 0 || alternatives > 0 {
                built.append(
                    Entry(
                        routineID: routine.id,
                        routineName: routine.name,
                        slotCount: slots,
                        alternativeCount: alternatives
                    )
                )
            }
        }
        self.entries = built
    }

    /// Number of unique routines referencing the exercise in any way.
    var routineCount: Int { entries.count }

    /// Total direct `RoutineExercise` slots across every routine.
    var slotCount: Int { entries.reduce(0) { $0 + $1.slotCount } }

    /// Total prepared alternatives referencing the exercise, across every
    /// routine and slot.
    var alternativeCount: Int {
        entries.reduce(0) { $0 + $1.alternativeCount }
    }

    /// Whether the exercise is referenced anywhere — the gate for the Exercise
    /// Detail empty state. True for an exercise used *only* as a prepared
    /// alternative, which is the case this slice exists to stop misreporting.
    var isUsed: Bool { !entries.isEmpty }

    /// Whether any routine uses the exercise as a direct slot.
    var hasDirectUsage: Bool { slotCount > 0 }

    /// Pluralized count line.
    ///
    ///  - no usage → `"Used in 0 routines"` (unchanged)
    ///  - direct only → `"Used in 2 routines"` (unchanged)
    ///  - alternatives only → `"Used as 3 alternatives"`. Deliberately **not**
    ///    "Used in 1 routine · 3 alternatives": the exercise is not part of any
    ///    routine's plan, and leading with a routine count would overstate it.
    ///  - both → `"Used in 2 routines · 3 alternatives"`
    var summary: String {
        if !hasDirectUsage && alternativeCount > 0 {
            return alternativeCount == 1
                ? String(localized: "Used as \(alternativeCount) alternative")
                : String(localized: "Used as \(alternativeCount) alternatives")
        }

        let routines =
            routineCount == 1
            ? String(localized: "Used in \(routineCount) routine")
            : String(localized: "Used in \(routineCount) routines")

        guard alternativeCount > 0 else { return routines }

        let alternatives =
            alternativeCount == 1
            ? String(localized: "\(alternativeCount) alternative")
            : String(localized: "\(alternativeCount) alternatives")
        return "\(routines) · \(alternatives)"
    }
}

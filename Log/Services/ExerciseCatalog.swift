import Foundation

/// Value type for a built-in exercise definition. Carries only the fields the
/// seed pass needs — `id` is generated at insert time, `notes` is left nil
/// because we don't ship opinionated copy with the catalogue, and `isCustom`
/// is implicit (the seeder always writes `false`). Equipment/body-part strings
/// are expected to match the canonical option lists in `ExerciseDetailView`
/// (`canonicalBodyParts` / `canonicalEquipment`) so seeded rows surface as
/// already-selected values in the pickers rather than as legacy/custom rows.
struct ExerciseSeed {
    let name: String
    let bodyPart: String?
    let equipmentType: String?
    let setupDefaults: String?
    let isTimeBased: Bool

    init(
        name: String,
        bodyPart: String? = nil,
        equipmentType: String? = nil,
        setupDefaults: String? = nil,
        isTimeBased: Bool = false
    ) {
        self.name = name
        self.bodyPart = bodyPart
        self.equipmentType = equipmentType
        self.setupDefaults = setupDefaults
        self.isTimeBased = isTimeBased
    }
}

/// Built-in exercise catalogue, versioned so future additions can re-trigger
/// the seed pass via `ExerciseSeedService.seedIfNeeded`. The version is the
/// only field that gates re-seeding — bump it any time `v1` (or its successor)
/// gains new entries; the per-name dedupe in the service ensures already-
/// present names are never duplicated.
enum ExerciseCatalog {
    /// Bump when adding a new versioned list (e.g. introduce `v2` and route
    /// `seedIfNeeded` against it). The seed-version key persisted in
    /// UserDefaults is compared against this constant.
    static let currentVersion: Int = 1

    /// Initial 25-entry starter set covering every canonical body part with
    /// common gym setups. Two time-based entries (Plank, Treadmill Run)
    /// exercise `isTimeBased = true` so the seeded catalogue covers both
    /// prescription modes the rest of the app supports.
    static let v1: [ExerciseSeed] = [
        ExerciseSeed(name: "Barbell Bench Press", bodyPart: "Chest", equipmentType: "Barbell"),
        ExerciseSeed(name: "Incline Dumbbell Press", bodyPart: "Chest", equipmentType: "Dumbbell"),
        ExerciseSeed(name: "Cable Fly", bodyPart: "Chest", equipmentType: "Cable"),
        ExerciseSeed(name: "Pull-Up", bodyPart: "Back", equipmentType: "Bodyweight"),
        ExerciseSeed(name: "Barbell Row", bodyPart: "Back", equipmentType: "Barbell"),
        ExerciseSeed(name: "Lat Pulldown", bodyPart: "Back", equipmentType: "Cable"),
        ExerciseSeed(name: "Seated Cable Row", bodyPart: "Back", equipmentType: "Cable"),
        ExerciseSeed(name: "Overhead Press", bodyPart: "Shoulders", equipmentType: "Barbell"),
        ExerciseSeed(name: "Dumbbell Lateral Raise", bodyPart: "Shoulders", equipmentType: "Dumbbell"),
        ExerciseSeed(name: "Face Pull", bodyPart: "Shoulders", equipmentType: "Cable"),
        ExerciseSeed(name: "Barbell Curl", bodyPart: "Biceps", equipmentType: "Barbell"),
        ExerciseSeed(name: "Dumbbell Curl", bodyPart: "Biceps", equipmentType: "Dumbbell"),
        ExerciseSeed(name: "Triceps Pushdown", bodyPart: "Triceps", equipmentType: "Cable"),
        ExerciseSeed(name: "Skull Crusher", bodyPart: "Triceps", equipmentType: "EZ Bar"),
        ExerciseSeed(name: "Back Squat", bodyPart: "Quads", equipmentType: "Barbell"),
        ExerciseSeed(name: "Front Squat", bodyPart: "Quads", equipmentType: "Barbell"),
        ExerciseSeed(name: "Leg Press", bodyPart: "Quads", equipmentType: "Machine"),
        ExerciseSeed(name: "Romanian Deadlift", bodyPart: "Hamstrings", equipmentType: "Barbell"),
        ExerciseSeed(name: "Leg Curl", bodyPart: "Hamstrings", equipmentType: "Machine"),
        ExerciseSeed(name: "Hip Thrust", bodyPart: "Glutes", equipmentType: "Barbell"),
        ExerciseSeed(name: "Standing Calf Raise", bodyPart: "Calves", equipmentType: "Machine"),
        ExerciseSeed(name: "Conventional Deadlift", bodyPart: "Back", equipmentType: "Barbell"),
        ExerciseSeed(name: "Plank", bodyPart: "Core", equipmentType: "Bodyweight", isTimeBased: true),
        ExerciseSeed(name: "Hanging Leg Raise", bodyPart: "Core", equipmentType: "Bodyweight"),
        ExerciseSeed(name: "Treadmill Run", bodyPart: "Cardio", equipmentType: "Machine", isTimeBased: true),
    ]
}

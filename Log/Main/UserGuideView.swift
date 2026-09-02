import SwiftUI

// ======================================================
// MARK: - User Guide (read-only, in-app)
// ======================================================

/// Static, read-only rendering of the tester User Guide. Content mirrors the
/// repo's `USER_GUIDE.md` (English + Korean) and is embedded as native SwiftUI
/// so it never depends on the network or a bundled file at runtime — the
/// simplest, most TestFlight-stable option.
///
/// The guide is intentionally a flat `ScrollView` of typed blocks. To update the
/// text, edit the `englishGuide` / `koreanGuide` arrays below to match
/// `USER_GUIDE.md`; there is no parsing or shared state to keep in sync.
/// Which of the two guides is on screen.
///
/// A pure value type with a pure default rule, so "a Korean phone opens the
/// Korean guide" is a unit test rather than something only a re-launched
/// simulator can answer.
enum UserGuideLanguage: String, CaseIterable, Identifiable {
    case english
    case korean

    var id: String { rawValue }

    /// The segmented control's label. **Never localized**: a language switcher
    /// names each language in its own language, so a Korean reader can find
    /// 한국어 on an English screen and vice versa. Rendered with
    /// `Text(verbatim:)` for the same reason.
    var pickerLabel: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        }
    }

    /// Which guide to open for a given locale: Korean for a Korean-language
    /// locale, English for everything else.
    ///
    /// Keyed on the **language**, not the region — a Korean speaker with a US
    /// region still reads Korean, and `ko` with no region still resolves. Every
    /// other language falls back to English, which is the only other guide
    /// there is.
    static func `default`(for locale: Locale) -> UserGuideLanguage {
        locale.language.languageCode == .korean ? .korean : .english
    }
}

struct UserGuideView: View {
    /// View-local only, deliberately not persisted: the locale default is right
    /// on essentially every launch, and a stored override would outlive the one
    /// reading session it was meant for. Nothing else in the app stores a
    /// per-screen language either.
    @State private var language: UserGuideLanguage = .default(for: .current)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                Picker("Guide language", selection: $language) {
                    ForEach(UserGuideLanguage.allCases) { language in
                        Text(verbatim: language.pickerLabel).tag(language)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(Self.sections(for: language)) { section in
                    GuideSectionView(section: section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.lg)
        }
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The guide for one language — **one** of the two arrays, never both
    /// concatenated. Both arrays are kept exactly as they were; this only
    /// chooses between them.
    static func sections(for language: UserGuideLanguage) -> [GuideSection] {
        switch language {
        case .english: return englishGuide
        case .korean: return koreanGuide
        }
    }
}

// MARK: - Content model

/// One block of the guide: a heading, an optional intro paragraph, and an
/// optional list. `ordered` picks numbered vs. bulleted rendering.
struct GuideSection: Identifiable {
    let id = UUID()
    let heading: String
    var intro: String? = nil
    var ordered: Bool = false
    var items: [String] = []
    /// A closing paragraph rendered after the list (used where the source has
    /// trailing prose, e.g. the prefill note).
    var outro: String? = nil
}

// MARK: - Section rendering

private struct GuideSectionView: View {
    let section: GuideSection

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(section.heading)
                .font(.dsSection)
                .foregroundStyle(.primary)

            if let intro = section.intro {
                Text(intro)
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.items.isEmpty {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        GuideListRow(
                            marker: section.ordered ? "\(index + 1)." : "•",
                            text: item
                        )
                    }
                }
            }

            if let outro = section.outro {
                Text(outro)
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DSSpacing.xs)
            }
        }
    }
}

private struct GuideListRow: View {
    let marker: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            Text(marker)
                .font(.dsBody)
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .leading)
            Text(text)
                .font(.dsBody)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Guide content (mirrors USER_GUIDE.md)

extension UserGuideView {

    static let englishGuide: [GuideSection] = [
        GuideSection(
            heading: "User Guide"
        ),
        GuideSection(
            heading: "Basic Terms",
            items: [
                "Exercise: one movement, such as Bench Press, Squat, or Dumbbell Row",
                "Routine: a planned workout made of several exercises",
                "Superset: two or more exercises performed back-to-back before resting",
                "Set: one round of an exercise",
                "Reps: how many times you perform the movement in one set",
                "Weight: the load used for the set",
                "Duration: time-based tracking, used instead of reps and weight",
                "RIR/RPE: effort ratings used to describe how hard a set felt",
                "History: completed workouts saved after finishing",
            ]
        ),
        GuideSection(
            heading: "Basic Flow",
            ordered: true,
            items: [
                "Open the app.",
                "Go to Exercises to check or create exercises.",
                "Go to Routines to create or select a workout plan.",
                "Start a workout from a routine.",
                "Log each set as you train.",
                "Finish the workout.",
                "Check History to review what you completed.",
            ]
        ),
        GuideSection(
            heading: "Creating an Exercise",
            ordered: true,
            items: [
                "Open Exercises.",
                "Tap Add Exercise.",
                "Enter the exercise name.",
                "Choose the body part and equipment.",
                "Choose whether the exercise uses reps or duration.",
                "For bodyweight exercises, choose whether bodyweight should count as load.",
                "Add exercise notes or setup notes if needed.",
            ]
        ),
        GuideSection(
            heading: "Organizing Exercises",
            intro: "In the Exercises tab, you can organize the exercise list in different ways:",
            items: [
                "manually",
                "by name",
                "by body part",
                "by equipment",
            ]
        ),
        GuideSection(
            heading: "Creating a Routine",
            ordered: true,
            items: [
                "Open Routines.",
                "Create a new routine.",
                "Add exercises or supersets.",
                "Set the number of sets, rep range, rest time, and warm-up sets.",
                "Set effort level, tempo, techniques, and routine-specific notes as needed.",
            ]
        ),
        GuideSection(
            heading: "Effort Targets",
            intro: "An effort target says how hard a working set should feel, written as RIR or RPE (choose which in Settings). A routine exercise can set targets four ways:",
            items: [
                "None: no effort target is shown for this exercise.",
                "Same Target: one value for every working set.",
                "Progression: a start value and an end value, spread across the sets. Targets move in whole steps, so RIR 2 → 0 over 4 sets shows 2, 2, 1, 0, and RPE 8 → 10 over 4 sets shows 8, 8, 9, 10.",
                "Custom Per Set: type the exact target for each set, such as 2, 1.5, 1, 0.",
            ],
            outro: "If you add sets, the last custom target repeats for the new ones. If you remove sets, the extra targets are dropped. Targets you already set are left as they are.\n\nTargets stay with the plan. They are saved in the routine, shown on the matching set during a workout, still there when you leave a workout and resume it later, used by alternative exercises, copied when you duplicate a routine, and kept when you export or import one."
        ),
        GuideSection(
            heading: "Completing a Workout",
            ordered: true,
            items: [
                "Open a routine.",
                "Tap Start Workout.",
                "Enter reps and weight for each set.",
                "Tap Log after completing a set.",
                "Rest when the timer starts.",
                "Record notes about the session if needed.",
                "Switch exercises, edit the workout plan, edit setup notes, or edit exercise notes if needed.",
                "Tap Finish and confirm to save the workout to History.",
            ],
            outro: "When switching exercises during a workout, the app keeps compatible plan details and may prefill input fields from the new exercise's previous performance, but the workout plan itself remains controlled by the selected switch option."
        ),
        GuideSection(
            heading: "Alternative Exercises",
            intro: "Alternative exercises are replacement exercises you prepare ahead of time and save inside a routine exercise. They help when equipment is busy or unavailable, a movement feels uncomfortable that day, or you simply want a planned backup.\n\nTo prepare one:",
            ordered: true,
            items: [
                "Open a routine.",
                "Open an exercise in the routine.",
                "Tap Alternative Exercises.",
                "Tap Add Alternative and choose the replacement exercise.",
                "Set up its own plan: sets, reps or duration, rest, effort, tempo, warm-ups, techniques, cardio target distance, Cardio Plan, and notes.",
            ],
            outro: "To use one, start a workout from the routine, tap Switch Exercise, then choose an item under Prepared Alternatives. Applying an alternative switches the exercise and applies the plan you prepared for it. If the switch would remove sets you already logged, the app asks you to confirm first, and Cancel leaves the workout exactly as it was.\n\nAn alternative turned Off stays saved in the routine editor but is not offered during a workout. An alternative that matches the exercise you are already doing is not offered either. If its exercise has been deleted, it appears as Exercise unavailable and cannot be applied. Duplicating, exporting, or importing a routine keeps its alternatives."
        ),
        GuideSection(
            heading: "Duration Exercises and Cardio",
            intro: "Some exercises are tracked by time instead of reps, such as a plank hold, a wall sit, or cardio.\n\nTo set a duration or a rest time, tap the field. You can then tap a preset value, or scroll the hour / minute / second wheels.\n\nLimits and behavior:",
            items: [
                "exercise duration can be set up to 6 hours",
                "rest can be set up to 60 minutes",
                "duration exercises do not show reps, weight, or tempo",
                "leaving a field empty means it is not set",
            ],
            outro: "Cardio exercises also let you record details such as distance, calories, heart rate, incline or decline, resistance, and heart-rate zone. In routines, cardio exercises can have a target distance and an optional Cardio Plan. To make your own cardio exercise, open the exercise, turn on Time-based, then turn on Cardio.\n\nA Cardio Plan is only a guide/checklist. Your workout is still saved as one Cardio Set using the duration and Details you log."
        ),
        GuideSection(
            heading: "Rest Timer",
            intro: "After you log a set, the rest timer starts automatically.\n\nIf you close the rest timer overlay while the timer is still running, you can show it again by:",
            items: [
                "briefly opening Notification Center / Lock Screen, then returning to the app",
                "going to the Home Screen, then opening the app again",
            ]
        ),
        GuideSection(
            heading: "Last Performance Prefill",
            intro: "The app can use previous workout data to help fill in future workouts.\n\nYou can control whether a completed workout is used for future prefill:",
            items: [
                "when finishing or saving a workout",
                "later from History",
            ],
            outro: "This is useful if a workout was unusual, such as a deload, recovery day, or incomplete session, and you do not want it to affect future workout suggestions."
        ),
        GuideSection(
            heading: "Checking History",
            intro: "History shows completed workouts.\n\nUse History to review:",
            items: [
                "exercises performed",
                "sets completed",
                "weight and reps",
                "session notes",
                "progress over time per exercise",
            ],
            outro: "The Progression chart plots one point per session for the exercise you choose. A strength exercise offers e1RM, volume, best weight, and reps. A cardio exercise offers distance, duration, pace, calories, and average heart rate instead — e1RM and volume need a weight, so they are not offered.\n\nCardio history shows your logged cardio results and any Cardio Plan that was planned for the session."
        ),
        GuideSection(
            heading: "Settings",
            intro: "Use Settings to adjust app defaults and manage data.\n\nYou can:",
            items: [
                "choose weight unit: lb or kg",
                "choose distance unit for cardio: km or mi",
                "choose effort type: RIR or RPE",
                "set your bodyweight",
                "set default sets, rep ranges, and rest times",
                "import or export exercises",
                "import routines",
                "export workout history",
            ]
        ),
    ]

    static let koreanGuide: [GuideSection] = [
        GuideSection(
            heading: "사용자 가이드"
        ),
        GuideSection(
            heading: "기본 용어",
            items: [
                "운동: 벤치프레스, 스쿼트, 덤벨 로우처럼 하나의 운동 동작",
                "루틴: 여러 운동으로 구성된 운동 계획",
                "슈퍼세트: 두 개 이상의 운동을 쉬지 않고 이어서 수행한 뒤 휴식하는 방식",
                "세트: 운동을 한 번 수행하는 단위",
                "반복 횟수: 한 세트 당 동작 반복 횟수",
                "중량: 해당 세트에서 사용한 무게",
                "시간: 반복 횟수와 중량 대신 시간으로 기록하는 방식",
                "RIR/RPE: 세트가 얼마나 힘들었는지 기록하는 운동 강도 지표",
                "기록: 운동을 완료한 뒤 저장된 운동 기록",
            ]
        ),
        GuideSection(
            heading: "기본 사용 흐름",
            ordered: true,
            items: [
                "앱을 엽니다.",
                "운동 탭에서 운동을 확인하거나 새로 추가합니다.",
                "루틴 탭에서 운동 계획을 만들거나 선택합니다.",
                "루틴에서 운동을 시작합니다.",
                "운동하면서 각 세트를 기록합니다.",
                "운동을 완료합니다.",
                "기록 탭에서 완료한 운동을 확인합니다.",
            ]
        ),
        GuideSection(
            heading: "운동 만들기",
            ordered: true,
            items: [
                "운동 탭을 엽니다.",
                "운동 추가를 누릅니다.",
                "운동 이름을 입력합니다.",
                "부위와 장비를 선택합니다.",
                "반복 횟수로 기록할지, 시간으로 기록할지 선택합니다.",
                "맨몸 운동의 경우 체중을 중량에 포함할지 선택합니다.",
                "필요하면 운동 메모나 세팅 메모를 추가합니다.",
            ]
        ),
        GuideSection(
            heading: "운동 정리하기",
            intro: "운동 탭에서는 운동 목록을 여러 방식으로 정리할 수 있습니다.",
            items: [
                "직접 정렬",
                "이름순 정렬",
                "부위별 정렬",
                "장비별 정렬",
            ]
        ),
        GuideSection(
            heading: "루틴 만들기",
            ordered: true,
            items: [
                "루틴 탭을 엽니다.",
                "새 루틴을 만듭니다.",
                "운동이나 슈퍼세트를 추가합니다.",
                "세트 수, 반복 범위, 휴식 시간, 워밍업 세트를 설정합니다.",
                "필요하면 운동 강도, 템포, 운동 기법, 루틴 전용 메모를 설정합니다.",
            ]
        ),
        GuideSection(
            heading: "운동 강도 목표",
            intro: "운동 강도 목표는 각 작업 세트를 얼마나 힘들게 수행할지 RIR 또는 RPE로 나타냅니다(설정에서 방식을 선택합니다). 루틴의 운동마다 네 가지 방식으로 설정할 수 있습니다.",
            items: [
                "없음: 이 운동에는 강도 목표를 표시하지 않습니다.",
                "동일 목표: 모든 작업 세트에 같은 값을 사용합니다.",
                "프로그레션: 시작 값과 끝 값을 정하면 세트에 걸쳐 나누어 적용됩니다. 정수 단위로 변하므로 4세트에서 RIR 2 → 0은 2, 2, 1, 0으로, RPE 8 → 10은 8, 8, 9, 10으로 표시됩니다.",
                "세트별 지정: 2, 1.5, 1, 0처럼 각 세트의 목표 값을 직접 입력합니다.",
            ],
            outro: "세트를 늘리면 마지막에 지정한 목표가 새 세트에 반복 적용되고, 세트를 줄이면 남는 목표는 삭제됩니다. 이미 지정한 앞쪽 목표는 그대로 유지됩니다.\n\n설정한 목표는 계획과 함께 유지됩니다. 루틴에 저장되고, 운동 중에는 해당 세트에 표시되며, 저장 후 종료와 이어서 하기에서도 복원되고, 대체 운동에도 적용되며, 루틴을 복제하거나 내보내기 / 가져오기를 해도 그대로 유지됩니다."
        ),
        GuideSection(
            heading: "운동 완료하기",
            ordered: true,
            items: [
                "루틴을 엽니다.",
                "운동 시작을 누릅니다.",
                "각 세트의 반복 횟수와 중량을 입력합니다.",
                "세트를 완료한 뒤 기록을 누릅니다.",
                "타이머가 시작되면 휴식합니다.",
                "필요하면 세션 메모를 기록합니다.",
                "필요하면 운동을 교체하거나, 운동 계획을 수정하거나, 세팅 메모 또는 운동 메모를 수정합니다.",
                "완료를 누른 뒤 확인하면 운동이 기록에 저장됩니다.",
            ],
            outro: "운동 중 다른 운동으로 교체할 때, 앱은 호환되는 계획 정보는 유지하고 새 운동의 이전 기록을 입력 칸에 미리 채울 수 있습니다. 하지만 실제 운동 계획은 사용자가 선택한 교체 옵션에 따라 결정됩니다."
        ),
        GuideSection(
            heading: "대체 운동",
            intro: "대체 운동은 미리 준비해서 루틴의 운동 안에 저장해 두는 교체용 운동입니다. 기구가 사용 중이거나 없을 때, 그날 동작이 불편할 때, 또는 미리 대비책을 정해 두고 싶을 때 유용합니다.\n\n준비하는 방법:",
            ordered: true,
            items: [
                "루틴을 엽니다.",
                "루틴 안의 운동을 엽니다.",
                "대체 운동을 누릅니다.",
                "대체 운동 추가를 누르고 교체할 운동을 선택합니다.",
                "해당 운동의 계획을 설정합니다: 세트 수, 반복 횟수 또는 시간, 휴식, 운동 강도, 템포, 워밍업, 운동 기법, 유산소 목표 거리, 유산소 계획, 메모.",
            ],
            outro: "사용하려면 해당 루틴에서 운동을 시작하고, 운동 교체를 누른 뒤, 준비된 대체 운동에서 항목을 선택합니다. 대체 운동을 적용하면 운동이 교체되고 미리 준비해 둔 계획이 함께 적용됩니다. 이미 기록한 세트가 삭제되는 경우에는 앱이 먼저 확인을 요청하며, 취소를 누르면 운동은 그대로 유지됩니다.\n\n끄기로 설정한 대체 운동은 루틴 편집 화면에는 그대로 남지만 운동 중에는 표시되지 않습니다. 지금 하고 있는 운동과 같은 대체 운동도 표시되지 않습니다. 해당 운동이 삭제된 경우에는 사용할 수 없는 운동으로 표시되며 적용할 수 없습니다. 루틴을 복제하거나 내보내기/가져오기를 해도 대체 운동은 그대로 유지됩니다."
        ),
        GuideSection(
            heading: "시간 기반 운동과 유산소 운동",
            intro: "플랭크, 월 싯, 유산소 운동처럼 반복 횟수 대신 시간으로 기록하는 운동이 있습니다.\n\n시간이나 휴식 시간을 설정하려면 해당 항목을 누릅니다. 그 다음 미리 설정된 값을 누르거나, 시간 / 분 / 초 휠을 돌려 설정할 수 있습니다.\n\n제한과 동작 방식:",
            items: [
                "운동 시간은 최대 6시간까지 설정할 수 있습니다.",
                "휴식 시간은 최대 60분까지 설정할 수 있습니다.",
                "시간 기반 운동에서는 반복 횟수, 중량, 템포가 표시되지 않습니다.",
                "값을 비워 두면 설정되지 않은 상태로 처리됩니다.",
            ],
            outro: "유산소 운동에서는 거리, 칼로리, 심박수, 경사 / 내리막, 저항, 심박 존 같은 세부 정보도 기록할 수 있습니다. 루틴에서는 유산소 운동에 목표 거리와 유산소 계획을 설정할 수 있습니다. 직접 유산소 운동을 만들려면 해당 운동을 열고 시간 기반을 켠 다음 유산소를 켜세요.\n\n유산소 계획은 안내용 체크리스트일 뿐입니다. 운동은 기록한 시간과 세부 정보를 바탕으로 유산소 세트 하나로 저장됩니다."
        ),
        GuideSection(
            heading: "휴식 타이머",
            intro: "세트를 기록하면 휴식 타이머가 자동으로 시작됩니다.\n\n타이머가 아직 실행 중일 때 휴식 타이머 화면을 닫은 경우, 다음 방법으로 다시 표시할 수 있습니다.",
            items: [
                "알림 센터 / 잠금 화면을 잠깐 열었다가 앱으로 돌아오기",
                "홈 화면으로 나갔다가 앱을 다시 열기",
            ]
        ),
        GuideSection(
            heading: "이전 기록 자동 입력",
            intro: "앱은 이전 운동 기록을 바탕으로 다음 운동 입력을 더 쉽게 할 수 있습니다.\n\n완료한 운동을 이후 자동 입력에 사용할지 선택할 수 있습니다.",
            items: [
                "운동을 완료하거나 저장할 때 설정할 수 있습니다.",
                "나중에 기록 탭에서도 변경할 수 있습니다.",
            ],
            outro: "이 기능은 디로드, 회복 운동, 미완성 운동처럼 평소 기록으로 사용하고 싶지 않은 운동을 제외할 때 유용합니다."
        ),
        GuideSection(
            heading: "기록 확인하기",
            intro: "기록 탭에서는 완료한 운동을 확인할 수 있습니다.\n\n기록에서 확인할 수 있는 내용:",
            items: [
                "수행한 운동",
                "완료한 세트",
                "중량과 반복 횟수",
                "세션 메모",
                "운동별 진행 변화",
            ],
            outro: "진행 그래프는 선택한 운동에 대해 세션마다 한 점씩 표시합니다. 근력 운동에서는 e1RM, 볼륨, 최고 중량, 반복 횟수를 볼 수 있습니다. 유산소 운동에서는 대신 거리, 시간, 페이스, 칼로리, 평균 심박수를 볼 수 있습니다. e1RM과 볼륨은 중량이 있어야 계산할 수 있어 표시되지 않습니다.\n\n유산소 기록에는 기록한 유산소 결과와 그 세션에 계획했던 유산소 계획이 표시됩니다."
        ),
        GuideSection(
            heading: "설정",
            intro: "설정에서는 앱 기본값과 데이터를 관리할 수 있습니다.\n\n설정할 수 있는 내용:",
            items: [
                "중량 단위 선택: lb 또는 kg",
                "유산소 거리 단위 선택: km 또는 mi",
                "운동 강도 방식 선택: RIR 또는 RPE",
                "체중 설정",
                "기본 세트 수, 반복 범위, 휴식 시간 설정",
                "운동 가져오기 / 내보내기",
                "루틴 가져오기",
                "운동 기록 내보내기",
            ]
        ),
    ]
}

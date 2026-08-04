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
struct UserGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                ForEach(Self.englishGuide) { section in
                    GuideSectionView(section: section)
                }

                Divider()
                    .padding(.vertical, DSSpacing.sm)

                ForEach(Self.koreanGuide) { section in
                    GuideSectionView(section: section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.lg)
        }
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
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
            heading: "Duration Exercises and Cardio",
            intro: "Some exercises are tracked by time instead of reps, such as a plank hold, a wall sit, or cardio.\n\nTo set a duration or a rest time, tap the field. You can then tap a preset value, or scroll the hour / minute / second wheels.\n\nLimits and behavior:",
            items: [
                "exercise duration can be set up to 6 hours",
                "rest can be set up to 60 minutes",
                "duration exercises do not show reps, weight, or tempo",
                "leaving a field empty means it is not set",
            ],
            outro: "To track an exercise as cardio, open it in Exercises, turn on Time-based, then turn on Cardio.\n\nDuring a workout, a cardio set still logs with duration alone. Tap Details on the set row to also record distance, average heart rate, heart-rate zone, calories, incline or decline, and resistance. Every one of these is optional, and pace and speed are worked out for you once a distance and a duration are entered. Enter the details before tapping Log — to change them afterwards, tap Undo and log the set again.\n\nIn a routine, a cardio slot can also carry a target distance. Open the slot's Prescription section and enter it in km or mi — the unit you choose is saved with the target. A cardio slot starts at one set with no rest, and does not show warm-up steps, techniques, tempo, or the effort target, because those describe reps and weight.\n\nWhen you start the workout, the target distance fills in the distance field on the cardio set row. Change it freely: what gets logged is the distance you actually covered, and your edit is kept if you Save & Exit and come back.\n\nCardio exercises are grouped under the Cardio body part. The app includes Walking, Treadmill Run, Treadmill Walk, Stationary Bike, Elliptical, Stair Climber, and Rowing Machine as duration-based exercises, and you can add your own the same way."
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
            ]
        ),
        GuideSection(
            heading: "Settings",
            intro: "Use Settings to adjust app defaults and manage data.\n\nYou can:",
            items: [
                "choose weight unit: lb or kg",
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
                "운동을 종료합니다.",
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
                "종료를 누른 뒤 확인하면 운동이 기록에 저장됩니다.",
            ],
            outro: "운동 중 다른 운동으로 교체할 때, 앱은 호환되는 계획 정보는 유지하고 새 운동의 이전 기록을 입력 칸에 미리 채울 수 있습니다. 하지만 실제 운동 계획은 사용자가 선택한 교체 옵션에 따라 결정됩니다."
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
            outro: "운동을 유산소로 기록하려면 운동 탭에서 해당 운동을 열고 시간 기반을 켠 다음 유산소를 켜세요.\n\n운동 중에도 유산소 세트는 시간만으로 기록할 수 있습니다. 세트 행의 세부 정보를 누르면 거리, 평균 심박수, 심박 존, 칼로리, 경사 / 내리막, 저항도 함께 기록할 수 있습니다. 모두 선택 사항이며, 거리와 시간을 입력하면 페이스와 속도는 자동으로 계산됩니다. 세부 정보는 기록을 누르기 전에 입력하세요. 기록한 뒤에 값을 바꾸려면 취소를 누르고 세트를 다시 기록하면 됩니다.\n\n루틴에서는 유산소 슬롯에 목표 거리를 설정할 수도 있습니다. 슬롯의 처방 섹션을 열고 km 또는 mi로 입력하세요. 선택한 단위는 목표와 함께 저장됩니다. 유산소 슬롯은 1세트, 휴식 없음으로 시작하며 워밍업 단계, 테크닉, 템포, 강도 목표는 표시되지 않습니다. 이 항목들은 반복 횟수와 중량을 기준으로 하기 때문입니다.\n\n운동을 시작하면 목표 거리가 유산소 세트 행의 거리 칸에 채워집니다. 자유롭게 바꿀 수 있으며, 기록되는 값은 실제로 수행한 거리입니다. 저장 후 나가기를 했다가 돌아와도 수정한 값은 유지됩니다.\n\n유산소 운동은 유산소 부위로 묶여 있습니다. 앱에는 걷기, 트레드밀 러닝, 트레드밀 걷기, 실내 자전거, 일립티컬, 스텝밀, 로잉 머신이 시간 기반 운동으로 포함되어 있으며, 같은 방식으로 직접 추가할 수도 있습니다."
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
                "운동을 종료하거나 저장할 때 설정할 수 있습니다.",
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
            ]
        ),
        GuideSection(
            heading: "설정",
            intro: "설정에서는 앱 기본값과 데이터를 관리할 수 있습니다.\n\n설정할 수 있는 내용:",
            items: [
                "중량 단위 선택: lb 또는 kg",
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

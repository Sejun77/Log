# Entry #12 — TestFlight Beta Testing, Korean Support & External Feedback

> **Draft.** This entry is a template for the TestFlight beta phase. It is filled
> in as the beta happens. Unresolved areas use `[TBD]` placeholders — no results
> are recorded until they actually happen. Testers have **not** completed testing
> yet.

---

## Phase Overview

Entry #11 was about whether the app works for **my own** workouts. The answer
was yes: the full workout loop was validated on a real device, and the automated
test suite passed (916 tests, 0 failures as of Entry #11).

Entry #12 asks a different question:

> Can **other people** understand and use the app?

This phase is about external feedback from a small group of friends and family
through TestFlight. It is **not** about a public App Store release.

**Status:** planned / just beginning. TestFlight testing has not started yet.

---

## Why TestFlight

Up to now, the app has only run on my own iPhone, installed directly from Xcode.
That is fine for personal development, but:

- a free developer build needs reinstalling roughly weekly, which is bad for
  other people
- I can't watch every tester use the app, so I need it in their hands on their
  own phones
- installing from Xcode is not realistic for friends and family

TestFlight solves this: testers install through a normal-feeling flow, keep the
build for the testing period, and can use the app on their own schedule during
real training.

The point is to find usability issues I can't see myself, because I already know
how the app is "supposed" to work.

---

## Korean Support for Family Testing

Some family members are more comfortable in Korean than English. To make their
testing genuinely useful, **Korean UI support was added** so they can use the app
in their own language.

This matters because:

- feedback is only useful if the tester actually understands the screen
- translation problems (confusing wording, clipped text) are their own class of
  usability bug worth catching early
- it widens who can meaningfully test the app

Committed as: `feat(i18n): add Korean beta UI support`.

Open question for this phase: are any Korean translations confusing or clipped
in real use? `[TBD]`

---

## TestFlight Setup

- Build prepared for TestFlight: **Build 9 — uploaded**
- Build number / version tested: **1.0 (9)**
- Internal vs. external testing group: `[TBD]`
- Beta notes sent to testers: `[TBD]`
- Date invites sent: `[TBD]`

Build 9 carries the cardio system, Alternative Exercises end-to-end, Custom Per
Set RIR/RPE effort targets, the improved automatic RIR/RPE progression, the
destructive confirmation before removing logged sets, and the updated
guide/tester docs.

**Build 10 work has started.** It opens with a safety/UX fix to Alternative
Exercises deletion handling (C1), followed by a Korean terminology and naming
pass (C2), an active-workout layout polish (C3) and an Alternative Exercises
discoverability pass (C4), a User Guide language default (C5) and an
effort-target clarity pass (C6), planned effort targets in History (C7), the
Calculus showcase hidden from Release (C8), a stability / data-integrity fix to
prepared Alternative Exercises (C9), a manual-test polish bundle (C10) and a
nested-editor persistence fix (C11) — see the Build 10 entries under *Fixes
Made* below. C1–C8 are UX polish or visibility improvements, not Build 9
blockers. **C9 is not polish**: it fixes a reproduced crash and a silent
orphan-row leak in Alternative Exercises authoring, and Build 9 carries both —
the crash needs a prepared alternative's *first* warm-up step to trigger, so it
is reachable but not on a common path. **C10 is mixed**: five findings from one
manual pass, four of them wording and layout, one a real active-workout bug (a
rest timer that outlived the set that started it). **C11 is data loss**: work
authored inside a prepared alternative could vanish on the way out of the
screen. Build 9 carries it, and so did C9 — the crash fix made the edit
possible, not durable.

---

## Tester Groups

| Group              | Who                         | Focus                              | Status  |
| ------------------ | --------------------------- | ---------------------------------- | ------- |
| Lifting friends    | Friends who train regularly | Real workout use                   | `[TBD]` |
| Family (Korean UI) | Family, Korean-comfortable  | Korean usability                   | `[TBD]` |
| Casual testers     | People who don't lift much  | Understandable without gym context | `[TBD]` |

Number of testers invited: `[TBD]`
Number who installed: `[TBD]`
Number who completed a workout: `[TBD]`

---

## Testing Tasks

The checklist testers are asked to walk through (full version in
`docs/TESTFLIGHT_FEEDBACK_PLAN.md`):

- Install the app through TestFlight
- Open the app
- Inspect or create an exercise
- Inspect or create a routine
- Start a workout
- Log some sets
- Use the rest timer
- Try Save & Exit, then Resume
- Finish the workout
- Check History
- Check the progress charts
- _(optional)_ Switch an exercise during a workout
- _(optional)_ Log a cardio exercise (duration-based), with the details in notes
- _(optional)_ Try the Korean UI
- _(optional)_ Try an uneven superset, if comfortable
- _(optional)_ Prepare an alternative exercise on a routine exercise, then apply
  it mid-workout from Switch Exercise → Prepared Alternatives
- _(optional)_ Set an effort target on a routine exercise — Same Target,
  Progression, or Custom Per Set — and check the per-set targets during the
  workout
- _(Build 10)_ Open an exercise that is used **only** as an Alternative
  Exercise, confirm it does not read as unused, then delete it and confirm the
  warning mentions prepared alternatives and the alternative is gone from the
  routine afterwards
- _(Build 10, Korean UI)_ Open a routine block and confirm the set rows are in
  Korean, then compare the **End** and **Finish** dialogs during a workout and
  confirm they ask different questions
- _(Build 10)_ Start a workout and confirm the set rows are the first thing on
  the screen — say whether logging feels quicker to reach than it did in Build 9
- _(Build 10)_ On a routine exercise that has prepared alternatives, check that
  the routine row and the Start Workout screen both say how many there are
  before you start, and that the Switch Exercise row says so during the workout
- _(Build 10)_ Open the in-app User Guide and confirm it opens in your phone's
  language, with a switch at the top for the other one — you should not have to
  scroll through a guide you cannot read
- _(Build 10)_ On a routine exercise, tap the info button under the effort mode
  picker and say whether the four modes are explained clearly enough to choose
  between them
- _(Build 10)_ Finish a workout on an exercise that has an effort target, then
  open it in History and confirm the planned effort is shown — and that it still
  shows the old value after you change the routine's target
- _(Build 10)_ Open Settings and confirm there is no "Showcase" or "Calculus
  Analytics" row — and that everything else you used before is still there

---

## Feedback Form Questions

The questions asked after testing:

- Was it clear how to start a workout?
- Was it clear how to log a set?
- Did the rest timer make sense?
- Was Save & Exit / Resume understandable?
- Was History useful?
- Were the progress charts useful or confusing?
- If using Korean, were any translations confusing or clipped?
- What was most useful?
- What was most confusing?
- What would stop you from using this regularly?
- Did anything feel broken or unreliable?

---

## Feedback Log

Severity:

- **P0** crash, data loss, or cannot finish core flow
- **P1** major confusion or broken flow
- **P2** annoying but avoidable issue
- **P3** polish or feature request

### 2026-07-10 — Peer/family tester + developer validation

- **Group:** Friends & Family Beta
- **Severity:** P0
- **Feedback:** The app crashed when opening routines or adding the first exercise to a blank routine. Organizer showed a SwiftData `graph_keyPathToString` crash.
- **Status:** Fixed. Removed a fragile SwiftData predicate in the routine startability path and added regression tests.

### 2026-07-13 — Peer/family tester + developer validation

- **Group:** Friends & Family Beta
- **Severity:** P0
- **Feedback:** The app crashed when deleting or removing an exercise from a routine. Organizer showed the same SwiftData key-path translation crash.
- **Status:** Fixed. Removed a fragile `RoutineBlock.id` predicate from the deletion path and made deletion tombstone-safe.

### 2026-07-13 — Peer/family tester + manual review

- **Group:** Friends & Family Beta
- **Severity:** P1
- **Feedback:** The final workout step could finish immediately if the user accidentally tapped Next too many times.
- **Status:** Fixed. Added a confirmation dialog before finishing workouts.

### 2026-07-13 — Peer/family tester + manual review

- **Group:** Friends & Family Beta
- **Severity:** P2
- **Feedback:** Newly added warm-up sets sometimes did not appear until leaving and reopening the warm-up editor.
- **Status:** Fixed. Reassigned the warm-up steps array so SwiftUI observes the insertion immediately.

### 2026-07-15 — Peer/family tester usability feedback

- **Group:** Friends & Family Beta
- **Severity:** P2
- **Feedback:** A tester requested a user guide because the app was simple, but not fully intuitive for someone unfamiliar with training apps or workout terminology.
- **Status:** Fixed. Added `docs/USER_GUIDE.md` and an in-app User Guide under Settings → Help → User Guide.

### 2026-07-15 — Peer/family tester usability feedback

- **Group:** Friends & Family Beta
- **Severity:** P2
- **Feedback:** Setup notes are useful during workouts, but they could not be edited from the active workout screen like exercise notes.
- **Status:** Fixed. Added an "Edit Setup Notes" flow to the active workout's Equipment & Setup section, using the same focused-sheet pattern as exercise notes. Edits save to the exercise for future sessions and also update the current session's snapshot, so this workout's History shows the corrected setup notes. Previously completed workouts stay frozen.

### 2026-07-15 — Peer/family tester + manual review

- **Group:** Friends & Family Beta
- **Severity:** P1
- **Feedback:** The Finish Workout confirmation sometimes required a second tap before the workout actually finished.
- **Status:** Fixed. Made the confirmation action reliable so one tap finishes the workout exactly once, while keeping Cancel and the apply-changes options unchanged.

### 2026-07-30 — Peer/family tester + developer reproduction

- **Group:** Friends & Family Beta
- **Severity:** P1
- **Feedback:** Switching an exercise during an active workout produced an inconsistent plan, especially between duration-based and normal exercises. Switching a duration exercise for a normal one could leave **mixed duration/reps prescription state** — a reps/weight exercise still showing duration fields. Choosing "Keep Current Plan" also made the **set count inconsistent** (2 sets became 3). And leaving the workout and coming back showed that **the two resume paths restored different plans**: the routine's Start screen showed the original set count again but still rendered duration fields, while Resume Workout showed something else.
- **Status:** Fixed. "Keep Current Plan" and "Reset Plan" now resolve through **one compatibility adapter**, so duration and normal exercises no longer leave mixed prescription state. Incompatible tempo, Tempo Override, warm-ups, techniques, and routine-specific notes are handled safely — preserved where they remain valid, cleared or adapted where they do not. **All resume paths now restore the same active session plan.** Switching may still prefill the input fields from the switched-in exercise's previous performance, but that is draft-only and never changes the workout plan.

### 2026-08-02 — Peer/family tester usability feedback

- **Group:** Friends & Family Beta
- **Severity:** P2
- **Feedback:** Duration and rest-period inputs were too limited. The duration maximum was about 10 minutes, which is too low for long duration exercises or cardio, and the steppers moved in fixed 15-second increments, so reaching 30+ minutes would have taken an unreasonable number of taps.
- **Status:** Fixed. Exercise duration now goes up to 6 hours and rest up to 60 minutes, and both are entered with a preset strip plus hour/minute/second wheels instead of a stepper.

### 2026-08-02 — Peer/family tester feature request

- **Group:** Friends & Family Beta
- **Severity:** P2
- **Feedback:** A tester asked for cardio support, which the app had no obvious answer for.
- **Status:** Fixed for the beta, in the same slice as the duration/rest limits above (lightweight cardio depends on usable long-duration input). Cardio can be logged as a duration-based exercise. For now, details like distance, speed, incline, resistance, or heart-rate zone can be written in notes. In Korean: 유산소 운동은 시간 기반 운동으로 기록할 수 있습니다. 현재는 거리, 속도, 경사, 저항 단계, 심박 구간 같은 세부 정보는 메모에 기록할 수 있습니다. Structured cardio metrics are deferred (see Deferred Feedback).

### TBD — Peer/family tester

- **Group:** Friends & Family Beta
- **Severity:** TBD
- **Feedback:** TBD
- **Status:** TBD

Peer/family testing has started, and the entries above reflect issues found through tester use, developer reproduction, crash reports, and manual validation.

---

## Fixes Made From Feedback / TestFlight Validation

These fixes came from Friends & Family Beta feedback, TestFlight crash reports, developer reproduction, and manual validation.

- Removed a fragile SwiftData predicate from the routine startability path after a TestFlight crash occurred when opening routines or adding the first exercise to a blank routine.
- Removed a second fragile SwiftData predicate from the routine deletion path after deleting or removing an exercise from a routine caused another TestFlight crash.
- Hardened routine deletion so empty routines, empty blocks, deleted exercises, and stale SwiftData relationship objects are handled safely.
- Added a confirmation dialog before finishing a workout so accidental repeated taps on Next cannot immediately end the workout.
- Fixed warm-up set insertion so newly added warm-up steps appear immediately without leaving and reopening the editor.
- Added a tester-facing user guide in both GitHub documentation and inside the app under Settings → Help → User Guide.
- Added setup-notes editing to the active workout screen (same focused-sheet pattern as exercise notes) so wrong or missing setup cues can be corrected while training. Edits write to the exercise definition for future sessions and to the current session's snapshot so this workout's History records the corrected notes; templates and previously completed History are untouched.
- Made the Finish Workout confirmation reliable: the dialog records the chosen finish option and runs the finish once after the dialog's dismissal transaction commits, instead of racing the navigation dismissal inside the button action. No change to the confirm-before-finish safety behavior, the Cancel path, or the apply-changes options.
- Fixed mid-workout exercise switching between duration-based and normal exercises. Both "Keep Current Plan" and "Reset Plan" now resolve through a single compatibility adapter, so a switch can never leave mixed duration + reps/weight state. Keep preserves set count, rest, and RIR/RPE across a tracking-type change (previously the set count silently fell back to the app default — the reported 2 → 3 bug) and adapts everything the new exercise type can't express; Reset rebuilds from the app's default prescription source for the new type. Warm-ups and techniques survive only within the same tracking type, kept techniques are re-checked against the existing conflict rules, and the routine-specific note no longer follows the user to a different exercise. Routine templates are still never mutated silently.
- Made all active-workout entry points restore the same session plan. Walking into a routine and tapping Start while a workout is running now pushes the same live plan the Resume banner pushes, instead of rebuilding it from the routine template — the rebuild is reserved for the cold-restart case it was written for, and now sources a switched slot from the session snapshot rather than the template.
- Cleaned up tempo for duration-based exercises: hidden in the routine prescription editor and the in-workout Edit Plan sheet, dropped from the plan summary, cleared when a slot flips to duration, and suppressed at read time so stale saved values (including on old History rows) never render. Tempo behavior for normal exercises is unchanged, and stored History values are not rewritten.
- Made the Tempo Override technique incompatible with duration-based exercises, matching the prescription tempo field. It can no longer be added to a duration slot; a stale one (imported routine, or a slot switched to duration later) is removed when the prescription editor opens and suppressed everywhere it would otherwise render — routine technique list and count, active-workout set chips, and the orphan-technique summary row. Techniques are also filtered when the session plan is captured, so nothing incompatible reaches a workout or the History snapshot frozen from it. Tempo Override is unchanged for normal exercises, and the pairwise technique conflict rules are untouched.
- Kept last-performance prefill on exercise switching, as **draft-only** behavior. Switching to a new exercise clears the replaced exercise's stale suggestions for that slot, then loads the switched-in exercise's own latest performance and uses it to prefill the editable reps/weight (or duration) input fields. It runs only after the chosen plan option has already been adapted to the new exercise type, and it writes nothing but draft text — the plan, prescription snapshot, set count, rest, RIR/RPE, tempo, warm-ups, techniques, prescription notes, routine template, and History are all decided elsewhere and unaffected. If the new exercise has no history the slot falls back to its prescription defaults.
- Raised the duration and rest ceilings and replaced their steppers. Every seconds-valued editor previously capped at 600s (routine prescription duration/rest, in-workout Edit Plan) or 300s (Settings rest defaults, warm-up step rest, superset round rest), stepping 15s at a time. Exercise duration now allows up to 6 hours and rest up to 60 minutes, and both are entered through a shared row offering one-tap presets plus hour/minute/second wheels. Storage is unchanged — still `Int` seconds — and one shared normalizer clamps every write, so no editor can produce a negative or out-of-range value. The active workout's free-text duration field parses through the same normalizer and echoes the compact form ("45m") next to the raw seconds so a long cardio entry is readable before it is logged. Short holds like Plank, Hollow Hold, and Wall Sit are unaffected, and duration slots still hide reps/weight, tempo, and Tempo Override.
- Added lightweight cardio support without a cardio data model. Cardio already existed as a canonical body part with the Korean translation 유산소; the built-in catalogue now seeds Walking, Treadmill Walk, Stationary Bike, Elliptical, Stair Climber, and Rowing Machine alongside the existing Treadmill Run, all duration-based. The catalogue version was bumped so existing installs pick the new names up, and the per-name dedupe means nothing is duplicated or overwritten. Distance, speed, incline, resistance / machine level, and heart-rate zone go in exercise or setup notes for now.
- Added regression tests for routine startability, routine deletion, finish confirmation behavior, warm-up step insertion, and exercise-switch compatibility / resume consistency / draft-only prefill.
- Added **Alternative Exercises**, built after the cardio system and on top of the exercise-switch work above. A routine exercise can now store prepared backup/replacement exercises, each carrying its own plan — sets, reps or duration, rest, effort, tempo, warm-ups, techniques, cardio target distance, Cardio Plan, and notes. The routine editor authors them; a workout started from that routine offers them mid-session under Switch Exercise → **Prepared Alternatives**, and applying one switches the exercise *and* applies the prescription prepared for it rather than adapting the replaced exercise's plan. The existing destructive confirmation still runs first when the switch would remove already-logged sets, and Cancel leaves the session untouched. Alternatives are frozen into the session at start, so editing the routine mid-workout cannot change what the active session offers, and they survive Save & Exit → Resume. Duplicating a routine copies them (with fresh alternative ids and shared exercise references), and routine transfer export/import carries them, resolving each alternative's exercise by name exactly as a slot's own exercise reference is resolved. Routine templates are still never mutated silently, and a routine that uses no alternatives sees no new screen and exports byte-identically to before.
- **Redesigned RIR/RPE effort targets**, built after the Build 8 prep and the Alternative Exercises work above, and scoped to the **next build (Build 9)**. Automatic **Progression** no longer lands on awkward half-step targets by default: endpoints are exact, interior sets round to whole numbers in the direction the metric means "easier", and the ramp stays monotonic. RIR 2 → 0 over 4 sets now resolves to **2, 2, 1, 0**, and RPE 8 → 10 over 4 sets resolves to **8, 8, 9, 10**, instead of the half-step values the old nearest-0.5 interpolation produced. Alongside it, a third mode — **Custom Per Set** — lets a user type the exact target for every set, half steps included, such as **2, 1.5, 1, 0**; custom values are stored verbatim and are never rounded. The list is stored as a comma-separated column, fitted to the set count on both write and read (extra sets repeat the last authored target, removed sets truncate, earlier targets are never touched), and rejected whole rather than element-wise if a hand-edited document is malformed, so a bad entry can never shift a later set's target onto the wrong set. Custom targets preserve through routine editing, the active workout, Save & Exit → Resume, Alternative Exercises, routine duplication, and routine transfer export/import. Switching between modes seeds sensible values rather than discarding them, and the None / Same Target / Progression behavior that already shipped is unchanged for slots that do not opt into Custom Per Set.
- Stopped the host app from requesting **notification authorization during XCTest-hosted runs**. The app already skipped the request under UI tests via the `--ui-testing` launch argument, but `LogTests` does not pass that argument, so the host app could raise a system permission dialog while XCTest was still establishing its connection to the runner — an occasional bootstrap flake that failed the run before any test executed. The launch gate now also checks `XCTestConfigurationFilePath` in the process environment, which XCTest sets only in a test-hosting process. Production launch behavior is unchanged: on device, TestFlight, App Store, or a normal Xcode Run the variable is absent and authorization is still requested exactly once per launch. UI test behavior is unchanged, and the in-workout authorization requests are untouched.

- **Build 10 C1 — made exercise deletion account for prepared Alternative Exercises.** The first Build 10 fix, and a safety/UX one: `ExerciseRoutineUsage` counted only direct routine slots, so an exercise referenced *solely* as a prepared alternative reported the misleading **"Used in 0 routines"** on Exercise Detail — directly above a Delete button that would strand that prepared work. Deleting it removed nothing from the alternatives, leaving dangling references that resurfaced mid-workout as disabled `Exercise unavailable` rows in routines the user had no way to repair. Exercise usage now counts prepared alternatives alongside direct slots, kept as **separate** counts that are never summed (a routine referencing the exercise both ways is still counted once): Exercise Detail now reads `Used as 3 alternatives` when there is no direct usage, `Used in 2 routines · 3 alternatives` when there is both, and no longer offers the "add this exercise to a routine" empty state to an exercise several routines are relying on. The delete confirmation now names the prepared alternatives and their count. Deleting an exercise **prunes** the matching alternatives rather than leaving them dangling — the user chose to delete it from the library and the confirmation now says the prepared work goes with it — while non-matching alternatives keep their ids, their prescriptions, and a dense order, and removing a slot's last alternative clears the column to nil so "had them and lost them" persists identically to "never had any". A nil, empty, or corrupt alternatives payload matches nothing and is left byte-identical rather than rewritten. Disabled alternatives are counted and pruned like any other — they are still prepared work. No schema change, no active-workout switch behavior change, no effort-target logic change.

- **Build 10 C2 — fixed Korean terminology and a raw-enum leak in the routine editor.** Display text only; nothing behaves differently. Four things the app said wrong, plus a guide error. The **End workout?** and **Finish this workout?** dialogs shared one Korean title — `운동을 종료할까요?` — so the exit path and the save-to-History path asked the identical question; they now read `운동을 중단할까요?` and `운동을 완료할까요?`, the latter matching the `완료` button inside it. Routine block detail rendered `SetTemplate.kindRaw.capitalized`, the *persisted English raw value*, so a Korean routine listed its sets as `Working` / `Warmup` / `Dropset`; both call sites now use the localized `SetKind` label the rest of the app already had, with raw values and persistence untouched. The routine editor row and the cardio plan editor's title said **Structured Cardio** while the active workout, History and the guide said **Cardio Plan** — both now say Cardio Plan / 유산소 계획 (the Alternative Exercises summary chip keeps the old key deliberately, as renaming it buys the user nothing). The Techniques row read `운동 기법        3 테크닉`, two Korean words for one thing; the count now reuses the row's own name as `운동 기법 %1$lld개`. And the Korean guide told users to tap **종료** — the *exit* button — to save a workout to History; the finish steps now say **완료**, and the only 종료 left is `저장 후 종료`, the save-for-later exit. `docs/USER_GUIDE.md` was updated on main to match, since the in-app guide mirrors it by hand. No schema, persistence, lifecycle, cardio, alternatives, transfer or History change.

- **Build 10 C3 — put the Sets section first on the active workout screen.** UX polish, layout order only; nothing behaves differently. The set rows were the **ninth** section in the list, under Session Notes, the future-prefill toggle, Exercise Notes, Switch Exercise, the Plan card, Equipment & Setup, warm-ups and the cardio checklist — so logging a normal working set meant scrolling past read-once admin content on every exercise, on every phone. Sets is now first, followed by the plan-shaped sections a user reads *while* logging (Plan, Warmup, the Cardio Plan checklist), then Equipment & Setup, then the read-once half (Switch Exercise, Exercise Notes, the prefill toggle, Session Notes). The header above the list did not move. No section was removed, renamed or collapsed behind a disclosure group, and no label or accessibility identifier changed; the list's own modifiers — inset-grouped style, scroll-to-dismiss-keyboard, the bottom Back / Next-Finish safe-area bar and its keyboard withdrawal, and the keyboard dismiss accessory — are untouched. Verified as a pure permutation by diffing the multiset of non-blank lines against the parent commit: seven comment lines removed, eleven added, every code line byte-identical and merely relocated. That check caught a real defect en route — the first pass swallowed the cardio checklist's call along with the comment above it, which would have compiled clean, passed the whole suite, and silently dropped the checklist from cardio workouts. No schema, persistence, lifecycle, rest timer, switch, alternatives, effort-target, cardio-calculation, History or transfer change.

- **Build 10 C4 — made prepared Alternative Exercises visible before you need them.** UX / discoverability polish, display only; nothing behaves differently. Alternative Exercises shipped complete in Build 9 and then said nothing about itself: a slot's prepared alternatives were authored deep inside the routine slot and invisible on the routine row, the Start Workout screen and the active workout, so a user could not confirm the prepared work had survived routine editing, duplication or import without starting a workout and tapping Switch Exercise. The count now appears on all three. **Routine editor rows** append it to the summary that already states the plan — `3 × 8–12 · 90s rest · RIR 2 · 2 alternatives` — via a new count on `BlockPrescriptionSummary`; superset rows are exempt, since a block-level count would not say which exercise owns it. **Start Workout** listed only exercise names and now renders that same summary type, so a plan is worded identically on the screen you author it and the screen you confirm it; the start logic is untouched. **The Switch Exercise row** shows a count when the slot has offers, taken from the exact array the sheet is built from, so the badge can never promise a row the sheet will not show — and a slot with nothing to offer shows no badge and still opens the picker directly, as before. **M13** is fixed alongside: the sheet is titled `Switch Exercise` rather than the name of the exercise being replaced, which moved into a two-line section header (`Prepared Alternatives` over `Replacing Bench Press`). The **count rule** is "what tapping Switch Exercise will offer you": disabled alternatives are excluded — the user asked for them not to be offered, so counting them would advertise something the sheet will not honor — while a deleted exercise's alternative still counts, because the sheet still shows that row, named and disabled. The authoring row inside the slot still counts every alternative, disabled included. One new localized key (`Replacing %@` → `%@ 대체 중`); the counts and both titles reuse keys the app already ships. No schema, persistence, payload-format, authoring, switch, destructive-confirmation, deletion, effort-target, cardio-calculation, History, transfer, duplication, lifecycle, set-logging or rest-timer change.

- **Build 10 C5 — the in-app User Guide now opens in the device's language.** UX / onboarding polish, presentation only; neither guide's content changed. The guide rendered the full English guide, a divider, and then the full Korean guide — both, always, in that order — so a Korean tester scrolled past a guide they could not read to reach theirs, and an English tester ended every visit on a long Korean appendix. It is the first screen a new tester opens, which made it the worst place in the app for a scroll tax. It now shows **one** guide, chosen by the device language (Korean on a Korean phone, English otherwise), with a small **English / 한국어** segmented switch at the top for anyone who wants the other. The default rule is a pure `UserGuideLanguage.default(for:)` keyed on the **language, not the region** — a Korean speaker with a US region still gets Korean, a bare `ko` resolves, and every other language falls back to English, the only other guide there is; taking a `Locale` argument rather than reading `Locale.current` is what makes it unit-testable. Both guide arrays are intact and still held to matching section and item counts by the existing parity tests, which matters more now that a reader can flip between them on one screen. The selection is view state and is **not persisted**: the locale default is right on essentially every launch, and remembering an override past the session that prompted it would be a small permanent way to be wrong. The two switch titles are deliberately **not** translated — a language switcher names each language in its own language — so the only new key is the one nobody sees: `Guide language` → `가이드 언어`, the picker's VoiceOver label. `docs/USER_GUIDE.md` was not touched; this changes presentation, not content. No schema, persistence, lifecycle, set-logging, rest-timer, switch, alternatives, effort-target, cardio, History, transfer or duplication change.

- **Build 10 C6 — explained the effort targets, and stopped hiding saved ones.** UX / clarity polish covering five audit findings on one feature; wording, helper text and summary formatting only. The **mode picker offered four modes and defined none of them**, so an info button under it now lists all four — None, Same Target, Progression, Custom Per Set — one sentence each, in Korean using the picker's own translations; the in-app guide and `docs/USER_GUIDE.md` had described *three* ways since before Custom Per Set shipped and now describe four, with `None` added as the first. Setting **Autoregulation to None looked like deletion**: the effort controls are hidden, reasonably, but a slot with authored targets showed nothing at all, so a read-only line now says the targets are saved and names the setting that brings them back — shown only when something is actually saved, never editable, and it writes nothing. The **in-session copy said "not available yet"** for a progression that is deliberately frozen at session start; it now says the targets are fixed for this session, and the two superseded strings were deleted from the catalog rather than left stale. A **ten-set custom list printed all ten values** into a one-line row and pushed the segments before it off the end; summaries now show four values then an ellipsis (`RIR 3/3/2/2…`), counted against the list fitted to the set count. And the editor's live preview joined per-set values with `" · "` — the separator that divides whole summary segments — so `Set targets: 2 · 1 · 0` read as three segments rather than one list; the rule is now `/` inside a value list and `" · "` between segments, matching the block subtitle and the alternative summary. All of it is display: `resolve`, the per-set labels and the stored comma-separated list are untouched, pinned by a test asserting they are byte-for-byte unchanged after a summary is taken. No schema, migrations, stored effort fields, `EffortMode` raw values, custom-target persistence, effort resolution, lifecycle, set-logging, rest-timer, switch, alternatives, deletion, cardio, History-schema, transfer or duplication change.

- **Build 10 C7 — History now shows the planned effort target a workout was started with.** A History / effort-target visibility improvement, display only. Build 9 shipped Custom Per Set targets and they vanished the moment a workout ended: `PlannedPrescriptionSnapshot` had carried the frozen effort fields since the slice that added them, with **no reader**, so a user could author a per-set ramp, train it, and find no trace of it afterwards — the feature was effectively write-only. Each History item now carries a one-line **Planned effort** row, between Equipment & Setup and the Cardio Plan block and above the logged sets, laid out exactly like the Equipment row and added to both the single-exercise and superset section shapes. The value is read **only** from `item.plannedPrescriptionSnapshot`, through a new pure helper — never the live routine, the live exercise, or the routine list — so editing your programming tomorrow cannot rewrite what last week's workout says it planned; that is pinned by tests against real model rows, for a single target and for a custom list. All formatting is delegated to the same resolver the routine editor and active workout use, so `RIR 2`, `RIR 2 → 0` and `RIR 2/1.5/1/0` render identically to everywhere else and the C6 four-value elision (`RIR 3/3/2/2…`) arrived for free; both metrics work, including the paired fallback that lets a target authored in RIR read for a user now on RPE, and legacy snapshots with no explicit mode still derive a single target. Every "nothing to say" case renders **no row at all** rather than an empty one: no snapshot, mode None, missing values, a corrupt custom list, or autoregulation switched off. Cardio is not special-cased — a cardio slot's snapshot carries no effort values, so it renders nothing through the ordinary path. The label is **Planned effort / 계획 강도** and says nothing about achievement: no `SetLog` holds a logged RIR/RPE, and a test asserts the Korean never implies one. **H5(b) was deliberately not implemented** — no logged-effort field, no planned-vs-actual comparison, no `SetLog` change. No schema, migrations, `SetLog` / `WorkoutItem` / snapshot fields, stored effort values, `EffortMode` raw values, active-workout logging or effort controls, lifecycle, rest timer, switch, alternatives, deletion, cardio calculations, transfer payload or duplication change.

- **Build 10 C8 — hid the Calculus showcase from Release and TestFlight builds.** Settings / TestFlight polish, visibility only. Settings offered a **Showcase → Calculus Analytics** row unconditionally: an AP Calculus AB demo that analyses in-memory sample data and touches nothing a user owns. It was written as a development exercise, and it has been sitting in the Settings screen of a build sent to people who came to log workouts — in English only, so a Korean tester met an untranslated section about coursework. It is now behind `#if DEBUG`, still available locally and absent from anything a tester installs. The gate wraps **both** the call site and the `showcaseSection` definition, which is what makes it load-bearing rather than cosmetic: gating only the call would work today and quietly stop working the first time someone re-added a reference, whereas with the definition gated too an ungated call **fails the Release build** instead of shipping. The rule itself lives in one small pure helper taking the build configuration as an argument — the only way to test it at all, since a test bundle is built in the same configuration as its host app and a Debug run can never observe Release behavior directly. Not a runtime flag: no `UserDefaults`, nothing togglable, no hidden gesture. `Localizable.xcstrings` was **not** touched — the three showcase keys have no Korean and no test requires them to, so translating a Debug-only demo would be work with no user. `AnalyticsView`, `StrengthAnalytics` and `SampleWorkoutData` are unchanged and still build and test in every configuration: this removes the way *in*, not the showcase. No schema, migrations, workout, routine, active-workout, History, cardio, Alternative Exercises, effort-target, localization, docs, project-settings, signing, bundle ID, team, marketing-version or build-number change.

- **Build 10 C9 — made prepared Alternative Exercises write into their own store.** A stability and data-integrity fix, and the first Build 10 item that is not polish: manual testing reproduced a **crash**. The alternative detail editor reuses the real routine prescription editors — `PrescriptionFields`, `WarmupSchemeEditor`, `TechniquePlanEditor` — by binding them to a **scratch** slot that lives in `AlternativeDraftStore`'s own throwaway in-memory container, and injects that container's context into the section's environment. That injection does not reach the editors the section **pushes**, so both wrote into the app's context instead, against a prescription that belongs somewhere else. One mistake, two different failures. `SlotPrescription.warmupScheme` is **to-one**, and relating a to-one across containers is a SwiftData `fatalError` — adding the first warm-up step to a prepared alternative killed the app on the main thread (`EXC_BREAKPOINT` in the `warmupScheme` setter), which is exactly the reported crash. `techniquePlans` is **to-many**, and the same cross-container relate is accepted *silently* — so techniques never crashed on add; they were saved into the **user's store** as orphan rows owned by no cascade and reachable from no screen, and `ModelContext.delete` on a draft-owned plan was a no-op until the draft had saved, after which it raised `NSInvalidArgumentException`. Both editors now resolve the write context from **the model being edited** (`prescription.modelContext ?? environment`), through two small helpers — `WarmupSchemeAuthoring` and `TechniquePlanAuthoring` — which also carry the create / insert / relate sequences so those paths are testable without a UI harness. For every routine slot the resolved context *is* the environment's, so ordinary warm-up and technique editing is unchanged; for a scratch slot it is the draft container, so nothing an alternative editor creates can reach the user's database. **No orphan sweep was added:** any `TechniquePlan` rows a Build 9 install already leaked are inert — unreachable from any screen, with no effect on payloads, workouts or History — and cleaning them up can be decided separately. No schema, migrations, `SlotAlternative` payload format, public Alternative Exercises behavior, routine-editor behavior outside the context fix, active-workout, switch, effort-target, cardio, History, transfer/import/export payload, duplication, localization, docs, project-settings, signing, bundle ID, team, marketing-version or build-number change.

- **Build 10 C10 — the manual-test polish bundle.** Five findings from one pass through the app on device, fixed together: four are wording or layout, one is a real bug. **The rest timer outlived the set that started it.** Three undo paths had drifted apart — the reps/weight row stopped the rest *unconditionally* (so going back to correct an older set killed the countdown running after a newer one), while the duration / cardio row and the warm-up row never stopped it *at all*, under a comment claiming the first behavior. Unlog the set that began the rest and the countdown, its scheduled notification and its Live Activity all kept running for a set that no longer existed. The timer had no way to know better: it is slot-scoped, and `AppState` persists only `activeRestSlotID`, never which set triggered it. Rest starts now record their origin set, and all five start sites — working reps/weight, duration/cardio, warm-up, and the two dropset paths, where a drop's rest belongs to its **parent** working set — carry it. One pure rule decides the rest: clear only when the unlogged set *is* the origin; after a cold resume, where the rehydrated rest knows only its slot, clear only when that slot has no logged sets left at all. Clearing goes through the existing path, so the notification and Live Activity state go with it. Rest *start* behavior and every duration calculation are untouched. **Warm-up now sits above Sets.** C3 moved the set rows from ninth to first; a warm-up is performed *before* the first working set, so listing it after the rows it precedes asked the user to scroll up to do the thing they do first. The order is now Plan, Equipment & Setup, Warmup, Cardio Plan checklist, Sets — everything above the set rows plan-shaped and short — with the whole admin half (Switch Exercise, Exercise Notes, the prefill toggle, Session Notes) still below, Session Notes last. Verified as a pure permutation: zero code lines added or removed against the parent commit, comments only. **History's planned-effort row wrapped onto two lines.** The value was never the cause — the C6 four-value elision bounds it — the label was: "Planned effort" needs about 88pt at the row's 12pt caption size and sat in an 80pt column. The column is now 100pt, shared with the Equipment row so the two stay aligned, with a one-line limit and a scale-factor backstop for large type. The copy is unchanged in both languages: `계획 강도` stays, and nothing about the row implies a measured result. **"Finish (this workout only)" appeared even when it was the only option.** With no pending swaps and no dirty session plan the dialog offers one action plus Cancel, and the qualifier answered a question the user was never asked — there is no other workout, and nothing else the button could apply. Alone it now reads **Finish / 완료**; as soon as an apply option shares the dialog the qualifier earns its place back and every multi-option dialog keeps the wording it shipped with. Label selection only: the options offered, their order, the apply-back flags and what finishing does are all unchanged, and no new key was needed. **The Korean Back button said `등`.** The active workout's bottom bar rendered its Back label through the bare `Back` key — which is also the canonical **body part**, seeded on Pull-Up, Barbell Row, Lat Pulldown, Seated Cable Row and Conventional Deadlift — so the navigation control read the anatomical back, next to a correctly labelled `다음`. The button now has its own key, translating to **`이전`**, chosen over `뒤로` because it pairs with `다음` as an ordinal step through the workout. English is unchanged, and the body part's own `Back` → `등` entry is untouched — one added key, nothing repointed. No schema, migrations, model fields, Alternative Exercises payload format, scratch-editor architecture, exercise-deletion behavior, exercise-switch behavior, effort-target resolution, cardio calculations, History data model, transfer/import/export payload, routine duplication, project-settings, signing, bundle ID, team, marketing-version or build-number change.

- **Build 10 C11 — prepared-alternative edits now survive leaving the screen, and a warm-up row is tappable across its whole card.** A stability / persistence fix, found by manual testing straight after C9 — and a genuine data-loss bug rather than polish. **The commit was inferred rather than called.** `SlotAlternativeDetailEditor` edits a **scratch** slot in `AlternativeDraftStore`'s own in-memory container and writes the result back into the `SlotAlternative` payload; that write-back happened because the editor read `store.payload()` inside its `body` and let `.onChange` notice the value had moved. But the warm-up and technique editors are **pushed on top of that view**, so a step added in one mutates the scratch graph while the view owning the commit is off-screen. Its body re-evaluates only if the user comes back through it — pop one level and the edit is saved, switch tabs or pop straight to the routine list and the body never runs again, the commit never fires, and the draft container is deallocated with the edit still inside. That is precisely the "sometimes saved, sometimes not" in the report, and `TechniqueParamEditView` — a further level down — was the most exposed of all. The commit is now a **call**: a new `AlternativeDraftCommit` holds the write-back rule, both nested editors take an `onGraphChange` hook fired after *every* mutation (add, edit, delete, reorder, and each of the parameter screen's field saves), `SlotPrescriptionSection` forwards it, and the detail editor commits the moment the graph changes. The existing value observer stays — it still covers everything edited on that screen — with an idempotent `onDisappear` commit as a backstop. The scratch-editor architecture is **kept**; only its lifecycle became explicit. Routine editing is unchanged by construction: a routine slot's prescription *is* the stored model, so its editors pass no hook and nothing is committed anywhere. **The second half is a tap target.** Editing an existing warm-up step required hitting the *text*: the row's `.buttonStyle(.plain)` opts out of the promotion a `List` gives a default-styled button — which is what keeps the row looking like a row — so the button's hit area was exactly its label, and the label hugs its content, leaving the row's insets and the padding up to the list's 44pt minimum height dead. `.contentShape(Rectangle())` was applied **outside** the button, where it shapes the cell for the list's own hit-testing and never reaches the gesture. Both modifiers now sit inside, on the label, which also spans the full row width and minimum height — no visual change, and swipe-to-delete and drag reordering are untouched. Techniques were never affected: their rows are `NavigationLink`s, which a list makes fully tappable. No schema, migrations, `SlotAlternative` payload format, public Alternative Exercises semantics, scratch-editor architecture, active-workout switch behavior, exercise-deletion behavior, effort-target logic, cardio calculations, History data model, transfer/import/export payload, routine duplication, localization, project-settings, signing, bundle ID, team, marketing-version or build-number change.

Current validation status:

- Routine startability crash fix: tested with regression coverage.
- Routine deletion crash fix: tested with regression coverage.
- Finish confirmation: tested with pure navigation helper tests and manual checklist.
- Finish confirmation reliability fix: tested with dialog option-routing and single-fire consumption tests; manual one-tap re-check on device completed.
- Warm-up rendering fix: tested with warm-up insertion tests.
- Prepared-alternative scratch-context fix (Build 10 C9): tested with new warm-up and technique scratch-context suites; manual device re-check still pending.
- Manual-test polish bundle (Build 10 C10): rest-origin, finish-label and Korean navigation copy are covered by pure tests; the section reorder and the History row layout are display-only and want the device pass.
- Nested-editor persistence fix (Build 10 C11): the commit and refresh rules are covered by a new suite whose first test asserts the data loss itself; the warm-up tap target is a hit-testing change and wants the device pass.
- User Guide: added to GitHub documentation and inside the app.
- Active-workout setup notes editing: tested with display-resolution helper tests, SwiftData snapshot-propagation tests (current-session update, cancel no-op, past-History freeze, future-session pickup), and Korean localization regression coverage.
- Exercise-switch compatibility: tested with 22 value-level adapter tests covering Keep/Reset across duration → normal, normal → duration, and same-type switches.
- Resume consistency: tested with 15 SwiftData tests covering plan-source routing, cold-restart rebuild from session snapshots, session-plan persistence, switched-session History, the frozen-History invariant, and a switch-with-prefill case proving the restored plan follows the switch rather than the switched-in exercise's history.
- Tempo / Tempo Override cleanup: tested so duration exercises do not keep prescription tempo or Tempo Override, while non-duration technique behavior and the pairwise conflict rules remain unchanged.
- Switch-time draft prefill: tested so switching prefills reps/weight (or duration) input fields from the switched-in exercise's own latest history, clears the replaced exercise's stale suggestions first, falls back to prescription defaults when the new exercise has no history, and leaves the plan and prescription snapshot byte-identical.
- Duration/rest limits: tested with bound, clamp, negative, empty, and parse cases at both ceilings, plus 30+ minute cardio durations and the existing short-hold values.
- Beta cardio: tested so the seeded cardio exercises are all duration-based, the Cardio body part stays canonical, and it localizes to 유산소.
- User guide sync: tested so the English and Korean guides stay structurally aligned and both carry the cardio-in-notes wording that `docs/USER_GUIDE.md` uses.
- Alternative Exercises: tested at every hop — the payload codec and its tolerance rules, slot persistence, routine-editor authoring, the session freeze (including that editing the routine mid-workout cannot change the active session), the offer rules, the switch adapter applying the prepared prescription, duplication with fresh ids, and transfer export/import round-trips including warm-ups, techniques, a Cardio Plan and older documents that predate the feature.
- Alternative Exercises Korean coverage: tested so the authoring screen, the Prepared Alternatives sheet, the switch confirmation, and the summary flags all have Korean translations, and the English keys still render unchanged.
- Custom / progression effort targets: tested at every hop — the per-set list
  codec and its whole-list rejection rule, resizing against a changed set count,
  the whole-number progression ramp (including the RIR 2 → 0 → 2, 2, 1, 0 and
  RPE 8 → 10 → 8, 8, 9, 10 cases), mode transitions, slot persistence, the
  active-workout targets, Save & Exit → Resume, alternative exercises carrying
  custom targets, duplication, and transfer export/import round-trips.
- Alternative-exercise usage and deletion (Build 10 C1): tested at both halves —
  usage counting for direct-only, alternative-only, and both-ways references,
  disabled alternatives still counted, the empty-state gate, and a corrupt
  payload counting zero rather than failing the scan; then the delete
  confirmation wording for each of the three shapes (unused, direct-only,
  alternatives present), pruning across every routine and slot, non-matching
  alternatives surviving with ids and prescriptions intact, dense reordering of
  survivors, the last alternative clearing the column to nil, no dangling
  reference left behind, a corrupt column left untouched, and the pre-existing
  direct-slot deletion rules (superset block deleted whole, normal block slots
  unlinked and renumbered) still holding. Korean coverage added for the new
  usage and delete-warning strings, including placeholder retention.
- Manual switch/restart/History re-check on device: completed.
- Manual custom-effort regression on device: **pending.**
- Manual Build 10 C1 re-check on device: **pending** — the automated coverage
  walks the full delete-an-alternative-only-exercise scenario, but the dialog
  copy has not been read on a real screen at Korean string lengths.
- Manual Build 10 C2 re-check on device: **pending** — the tests assert the
  compiled Korean strings, but the block-detail rows, the two workout dialogs,
  the cardio row and the Techniques row have not been seen on a Korean screen.
- Manual Build 10 C11 re-check on device: **pending** — and the one whose whole
  point is a route a test cannot take. The sequence to walk is the reported one:
  add a warm-up step inside a prepared alternative, go **back to the routine and
  switch tabs** rather than popping one level, return to the same alternative,
  and confirm the step is there; then the same for a technique. The tap target
  is the other half: tap the empty background of a warm-up row, in a normal
  routine exercise and in a prepared alternative, and confirm the edit sheet
  opens — then check swipe-to-delete and drag reordering still behave.
- Manual Build 10 C10 re-check on device: **pending** — and the widest of the
  Build 10 items, because four of its five findings are things only a screen can
  settle: that Warmup reads naturally above Sets and the set rows are still
  quick to reach, that the planned-effort row holds one line at normal width,
  that the finish dialog says plainly **Finish / 완료** with nothing pending and
  keeps the qualifier when an apply option appears, and that the Korean bottom
  bar reads **이전 / 다음** while a body part elsewhere still reads **등**. The
  rest-timer fix wants the full loop: log a set, watch rest start, unlog it,
  confirm the countdown *and* its notification stop, then log again.
- Manual Build 10 C9 re-check on device: **pending** — the automated coverage
  proves the crash path and the leak are gone at the model layer, but the two
  things only a device can confirm are that the added warm-up step and technique
  appear in the alternative editor immediately, and that they are still there
  after leaving, reopening, and applying the alternative mid-workout.
- Manual Build 10 C8 re-check on device: **pending** — the gate is a
  compile-time one, so what a device pass adds is the two things a build cannot
  report: that the showcase is genuinely absent from a Release install, and that
  **no other Settings row** disappeared with it.
- Manual Build 10 C7 re-check on device: **pending** — the freeze behavior is
  unit-tested against real model rows, so what wants a real screen is the
  quieter half: that an exercise with no effort target and a cardio item both
  stay visually clean, and that the Korean label reads as *planned* rather than
  achieved.
- Manual Build 10 C6 re-check on device: **pending** — two items: the info
  button's placement under the mode picker is the one layout judgment call in
  the slice (a Picker owns its row's tap, so the glyph could not go in its
  label), and the autoreg-off saved-targets row is unit-tested as a rule but has
  never been seen in the real editor.
- Manual Build 10 C5 re-check on device: **pending** — the tests pin the
  language rule but not the wiring of `Locale.current` into the view's state, so
  what needs a real device is launching in each language and seeing the right
  guide open, plus the segmented picker's look on a small screen (both titles
  are short, so this is a check rather than a worry).
- Manual Build 10 C4 re-check on device: **pending** — and one item comes
  first: the routine row's subtitle is a single line in caption, so a maximal
  cardio row (`3 × 45s · 5.0 km · 120s rest · RPE 8 → 10 · 3 alternatives`) may
  truncate on a small phone, and truncation eats the tail — which is the new
  count. Needs a small-device pass; swapping the full word for a compact `2 alt`
  is a one-line change if it reads badly.
- Manual Build 10 C3 re-check on device: **pending** — the reorder is a pure
  view-tree permutation and builds clean either way, so what needs a real screen
  is first-focus keyboard behavior with Sets at the top and the bottom
  Back / Next-Finish bar on a small device.
- Korean terminology and set-kind labels (Build 10 C2): 6 tests added to
  `KoreanLocalizationTests` — the End and Finish dialog titles distinct and each
  exact, English keys unchanged, set-kind row labels localized and never a
  capitalized raw enum value, a `SetKind.allCases` guard so a new case forces
  the key list to be updated, the Cardio Plan row name in both languages, and
  the technique count reusing 운동 기법 with its placeholder intact — plus 2 in
  `UserGuideContentTests` pinning the Korean finish step to 완료.
- Active workout section order (Build 10 C3): no tests added or changed — no
  test asserts section order, and the UI target is a launch/navigation smoke
  test. The reorder was verified by diffing the multiset of non-blank lines
  against the parent commit: comment lines only, every code line relocated
  unchanged.
- Alternative Exercises discoverability (Build 10 C4): 9 tests added to
  `BlockPrescriptionSummaryTests` (count present and absent, singular vs
  plural, disabled excluded, all-disabled reads as none, the count is the last
  segment, a corrupt payload counts zero, supersets exempt, the value-in
  initializer, and `map` for the Start Workout screen), 3 to
  `PreparedAlternativeSwitchTests` (the badge count equals the offer count, an
  unavailable alternative still counts, no offers means no badge) and 4 to
  `KoreanLocalizationTests` (the new and reused keys localize, English
  unchanged, placeholders retained with both plural forms agreeing, and the
  sheet's title differs from its subtitle). No existing test was weakened or
  changed: the new `alternatives:` parameter defaults to zero, so every prior
  expectation stands as written.
- User Guide language default (Build 10 C5): 6 tests added to
  `UserGuideContentTests` (Korean locales default to the Korean guide, including
  a bare `ko` and a Korean language with a non-Korean region; non-Korean locales
  default to English; each language renders exactly one guide, with an explicit
  check that the section count is *not* the sum of both; the selector offers
  exactly two languages; both labels are stable) and 1 to
  `KoreanLocalizationTests` (the picker's accessibility label in both bundles).
  No existing test was weakened — the structural-parity tests read the guide
  arrays directly and still hold both to matching shape.
- Effort-target clarity (Build 10 C6): 15 tests added to
  `EffortTargetResolverTests` (a custom summary elides after four values and not
  at four or fewer, elision follows the set count, and — the one that matters —
  elision changes neither the stored list nor `resolve` nor the per-set labels;
  separators consistent; saved-target presence in every shape, absent when
  empty, an unusable custom list not counted, presence independent of the stored
  mode), 3 to `UserGuideContentTests` (all four modes in both languages, the
  intro's count matches the list under it, "three ways" never returns) and 5 to
  `KoreanLocalizationTests` (the new keys localize, English unchanged, the
  explanation names all four modes using the picker's own Korean, the superseded
  "not available yet" keys are gone, the saved-targets row names both halves).
  One existing test was **updated, not weakened**: the effort key list named the
  two superseded strings and failed on the first run; those entries now name the
  replacement copy, and a new test pins the old keys' absence.
- History planned effort (Build 10 C7): new `HistoryPlannedEffortTests` (20),
  in three parts — wording over pure snapshot field values (every mode, both
  metrics, the paired-metric fallback, legacy snapshots); the no-row cases (five
  corrupt-list shapes, autoregulation off, modes with no values, a zero set
  count); and **freshness over real model rows**, where editing the routine
  after the workout must not change what History says, for both a single target
  and a custom list, plus a check that rendering an elided summary leaves the
  stored list byte-for-byte intact. 2 added to `KoreanLocalizationTests` (the
  label localizes, and never implies a logged result). No existing test was
  modified.
- Calculus showcase gate (Build 10 C8): new `SettingsShowcaseVisibilityTests`
  (4) — visible in Debug, hidden in Release, visibility depending on nothing but
  its argument, and the compiled constant agreeing with the configuration the
  suite runs in, so an inverted `#if` fails in CI rather than surfacing as a
  showcase row on TestFlight. The showcase's own suites
  (`StrengthAnalyticsTests`, `SampleWorkoutDataTests`) are untouched and still
  pass: the slice removes the way *in*, not the showcase. No existing test was
  modified.
- Prepared-alternative scratch context (Build 10 C9): new
  `AlternativeWarmupScratchTests` (14) and `AlternativeTechniqueScratchTests`
  (17), both passing the **app's** context as the fallback — the wrong-store
  context the environment used to hand the pushed editors — so each one fails
  loudly if the resolution regresses. Between them they cover adding, editing,
  deleting, reordering, committing, reopening and applying warm-ups and
  techniques inside a prepared alternative, that nothing reaches the app store,
  that the parent routine slot is never mutated, and that normal routine warm-up
  and technique editing still writes to the app context exactly as before. Both
  were checked against the pre-fix code: the warm-up suite crashes the runner
  with the shipped fatal error, and 9 of the technique suite's tests fail. No
  existing test was modified.
- Manual-test polish bundle (Build 10 C10): new `ActiveWorkoutRestOriginTests`
  (9) pinning the one rest-clearing rule so a fourth undo path cannot invent a
  fourth answer — origin unlogged clears; an older set, another slot, and the
  warm-up/working-set index split all keep; a drop is owned by its parent set;
  and the cold-resume branch clears only on a slot with nothing logged left. 4
  added to `ActiveWorkoutFinishConfirmTests` (sole option reads `Finish`, the
  qualifier returns across all three multi-option shapes, apply labels are
  unconditional, and the option set and routing are unchanged), 3 to
  `KoreanLocalizationTests` (the navigation key is `이전` and not `등`, English
  is still "Back", `다음` unchanged, and the body part still translates to `등`),
  and 2 to `HistoryPlannedEffortTests` (every summary shape is one short line
  with no embedded break; the label keeps both "planned" and "effort"). No
  existing test was modified or weakened. The section reorder has **no** unit
  test: the sections are heterogeneous `ViewBuilder` calls and driving them from
  a list would restructure a view whose keyboard and safe-area behavior is
  documented as fragile, so the evidence is the pure-permutation diff plus the
  device pass.
- Nested-editor persistence (Build 10 C11): new
  `AlternativeNestedEditorCommitTests` (14). The first test is a **negative
  control** — a nested edit that is never committed is lost when the draft store
  is released, which is the reported data loss asserted directly, so the suite
  fails loudly if the hook is ever removed. The rest cover the fix: warm-up and
  technique committed through the hook, both surviving leave-and-reopen (checked
  in the stored payload *and* in the scratch graph a reopened nested editor
  reads), edit-and-delete across two visits, both carried into the session plan
  by the switch adapter, the parent routine slot never mutated, siblings
  untouched including a disabled one and a noted one, the commit targeting the
  alternative actually being edited, a deleted alternative never resurrected by
  a stale editor, a no-draft commit writing metadata only, the commit being
  idempotent, and normal routine editing needing no commit at all. No existing
  test was modified or weakened. The warm-up tap target has **no** unit test:
  hit-testing is not reachable without a UI harness, so the row carries a stable
  accessibility identifier for when one exists, and the evidence is the device
  pass.
- Latest test suite result: **full scheme passes: 2,452 tests, 0 failures** —
  2,450 unit tests plus 2 UI tests (Build 10 C11 run). Debug build succeeds and
  Release build succeeds.

---

## Planned Fixes From Feedback

- None currently. The setup-notes editing request was implemented, and the cardio
  request is answered for the beta by duration-based cardio logging (see Fixes
  above). Structured cardio metrics are tracked under Deferred Feedback.

---

## Deferred Feedback

Feedback that is real but intentionally not addressed in this phase, such as P2/P3 polish, larger redesigns, or out-of-scope ideas.

- **Structured cardio metrics.** The cardio request is answered for the beta by
  duration-based logging plus notes. Dedicated fields are deferred:
  - distance
  - pace
  - calories
  - heart-rate zone
  - incline
  - resistance / machine level

A proper cardio system is designed in `docs/CARDIO_SYSTEM_DESIGN.md` (design
only — no implementation yet).

Full cardio tracking is **deferred, not forgotten**. Each of those metrics needs
its own model field, its own unit handling (km vs. mi, min/km vs. min/mi), its
own History and analytics treatment, and a migration — that is a phase of its
own, not a beta patch. Logging cardio as duration + notes keeps the data
capturable now without freezing a schema that a proper cardio phase would want
to change.

> **Resolved since this entry was written — the cardio phase shipped.** Every
> metric listed above now has a dedicated field, plus HR zone, and the phase went
> further than the deferral anticipated: Settings-only distance units, cardio
> routine targets, exercise-switch compatibility, previous-performance prefill,
> CSV and routine-transfer support, a catalogue v3 seed with a one-time assisted
> migration prompt, cardio History charts, and structured cardio **planned
> segments** — a routine-authored plan that shows as a Cardio Plan checklist
> during the workout and in History afterwards. Slices 1–12E, recorded in
> `docs/CARDIO_SYSTEM_DESIGN.md` and `docs/STRUCTURED_CARDIO_DESIGN.md`.
>
> The prediction that it needed "a phase of its own, not a beta patch" held. So
> did the schema caution: every column landed additive and nil-defaulted, with no
> `SchemaMigrationPlan` written.
>
> **Still deferred (Slice 12F):** repeat/interval authoring UI, per-segment
> actual logging and the analytics, charts and export that depend on it,
> automatic or live segment progression, and every GPS / HealthKit / Apple Watch
> non-goal. A cardio bout is still logged as **one aggregate set**.
>
> The historical text above is left as written — it records what testers were
> told at the time.

---

## What I Learned

Reflections from running the beta.

- TestFlight exposed SwiftData issues that did not reproduce reliably in the simulator or normal debug builds.
- Release/TestFlight builds can fail differently from local debug builds, especially around SwiftData predicates and model identity.
- Crash reports from Organizer were essential because they showed the real failing frame: `PersistentModel.graph_keyPathToString(keypath:)`.
- Regression tests are important after every crash fix so the same class of bug does not return.
- Beta readiness is not only about adding features; it also means preventing accidental destructive actions, such as finishing a workout unintentionally.
- SwiftUI relationship updates can fail to render immediately if a SwiftData relationship array is mutated in place, so some relationship updates need whole-array reassignment.
- Tester feedback can reveal documentation and usability gaps that are easy for the developer to miss.
- Active workout state needs one clear source of truth; otherwise different resume paths can appear to restore different versions of the same workout.
- Compatibility rules should be explicit when switching between different exercise types, because preserving everything can create invalid mixed state.
- An input's **range** and its **control** are one decision. Raising a limit without replacing the stepper would have made 6-hour durations technically possible and practically unusable.
- A feature request can often be answered with the primitives already in the app. Cardio did not need a cardio model to become usable in the beta; it needed duration input that was not capped at ten minutes.

Themes to continue watching as peer/family testing expands:

- whether the core flow is understandable without me explaining it
- whether the rest timer and Save & Exit / Resume make sense to new users
- whether progress charts help or confuse
- whether Korean wording holds up in real use
- whether routine editing feels stable after the TestFlight crash fixes
- whether setup notes and exercise notes are easy to understand during active workouts

---

## Phase Result

`[TBD]`

This section will be written once the beta phase has more complete feedback. It should honestly state what the feedback showed, what was fixed, and what was deferred — without claiming a public App Store release. The goal of this phase is external feedback, not distribution.

**As of now:** Friends & Family Beta testing has started. Crash, usability, documentation, active-workout consistency, and exercise-switching issues have already been fixed, and the exercise-switching fix has passed both the automated test suite and manual device validation. Beta testing is still ongoing, so the phase result stays open until more tester feedback comes in.

**Build 8:** prepared and archived for TestFlight with the cardio system and
Alternative Exercises as its headline items. No upload is recorded in this
repository.

**Build 9:** **uploaded to TestFlight** — the cardio system, Alternative
Exercises end-to-end, Custom Per Set RIR/RPE effort targets, the improved
automatic RIR/RPE progression, the destructive confirmation before removing
logged sets, and the updated guide/tester docs.

**Build 10:** started. It opens with **C1**, a safety/UX fix to Alternative
Exercises deletion handling: exercise usage now includes prepared alternatives,
so an exercise used only as an alternative no longer reports the misleading
"Used in 0 routines"; the delete confirmation now warns that prepared
alternatives will be removed; and deleting an exercise prunes those
alternatives instead of leaving dangling unavailable rows behind. **C2** follows
it with a Korean terminology pass, display text only: the End and Finish
workout dialogs no longer share one Korean title, routine block detail stops
showing raw English set kinds (`Working` / `Warmup` / `Dropset`) in Korean, the
routine editor and its plan editor now call the cardio plan **Cardio Plan** like
the rest of the app, the Techniques count stops mixing 운동 기법 and 테크닉, and
the Korean guide now says to tap **완료** — not 종료 — to save a workout to
History. **C3** is an active-workout layout polish: the Sets section now comes
first on the exercise screen instead of ninth, so logging no longer sits below
session notes, the prefill toggle, exercise notes, Switch Exercise, the Plan
card, Equipment & Setup, warm-ups and the cardio checklist. **C4** makes
prepared Alternative Exercises visible before a workout starts: the routine row
and the Start Workout screen now say how many enabled alternatives a slot has,
the active workout's Switch Exercise row carries the same count, and the switch
sheet is titled by its action with the replaced exercise moved to a subtitle.
**C5** makes the in-app User Guide open in the device's language — one guide
rather than English and Korean stacked back to back — with an English / 한국어
switch for the other. **C6** is an effort-target clarity pass: the routine
editor now explains all four effort modes, the guide documents `None` as the
fourth, turning autoregulation off no longer makes saved targets look deleted,
the in-session copy states the rule instead of reading like an unfinished
feature, and a long custom per-set summary stops at four values with an
ellipsis. **C7** makes the effort targets visible again after a workout ends:
History now shows the planned effort each exercise was started with, read from
the frozen session snapshot so editing the routine later cannot rewrite it.
**C8** takes the AP Calculus AB showcase out of Settings for Release and
TestFlight builds, keeping it for local development. Six are UX polish, C7 is a
visibility improvement and C8 is a TestFlight-facing cleanup. Nothing here
blocks Build 9, which stays in testers' hands.

**Build 9 — next build scope:** the redesigned RIR/RPE effort targets, which
landed after Build 8 was prepared: whole-step automatic Progression and the new
**Custom Per Set** mode. Both are implemented and test-covered. Build 9 has
**not** been uploaded. Remaining work is the manual custom-effort regression
pass on device (still pending) and the build prep itself.

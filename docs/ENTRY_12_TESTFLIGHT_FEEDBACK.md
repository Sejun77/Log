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

- Build prepared for TestFlight: `[TBD]`
- Build number / version tested: `[TBD]`
- Internal vs. external testing group: `[TBD]`
- Beta notes sent to testers: `[TBD]`
- Date invites sent: `[TBD]`

TestFlight setup is planned; details filled in once the build is up.

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
`TESTFLIGHT_FEEDBACK_PLAN.md`):

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
- **Status:** Fixed. Added `USER_GUIDE.md` and an in-app User Guide under Settings → Help → User Guide.

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

Current validation status:

- Routine startability crash fix: tested with regression coverage.
- Routine deletion crash fix: tested with regression coverage.
- Finish confirmation: tested with pure navigation helper tests and manual checklist.
- Finish confirmation reliability fix: tested with dialog option-routing and single-fire consumption tests; manual one-tap re-check on device completed.
- Warm-up rendering fix: tested with warm-up insertion tests.
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
- Manual switch/restart/History re-check on device: completed.
- Latest full test suite result: full scheme passes with **2,185 tests, 0
  failures** — 2,183 unit tests plus 2 UI tests. Debug build succeeds and
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

**Next build scope:** the cardio system and Alternative Exercises are both
implemented and test-covered in the working tree, and are the headline items for
the next TestFlight build. That build has **not** been uploaded yet — remaining
work is the final manual regression pass on device and the build prep itself.

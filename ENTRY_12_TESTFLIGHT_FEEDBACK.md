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
- _(optional)_ Try the Korean UI
- _(optional)_ Try an uneven superset, if comfortable

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

Feedback is recorded here (and in `TESTFLIGHT_FEEDBACK_PLAN.md`) as it arrives.

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
- **Status:** Fixed. The confirm button ran the finish (ending in a navigation dismissal) synchronously inside the dialog's own dismissal transaction, so the dismissal could be dropped when a same-frame re-render (e.g. the per-second rest-timer tick) landed. The dialog now only records the chosen finish option; the finish runs once on the next main-actor turn, after the dialog teardown commits. One confirmation tap reliably finishes, exactly once; Cancel and the apply-changes options are unchanged.

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
- Added regression tests for routine startability, routine deletion, finish confirmation behavior, and warm-up step insertion.

Current validation status:

- Routine startability crash fix: tested with regression coverage.
- Routine deletion crash fix: tested with regression coverage.
- Finish confirmation: tested with pure navigation helper tests and manual checklist.
- Finish confirmation reliability fix: tested with dialog option-routing and single-fire consumption tests; manual one-tap re-check on device pending.
- Warm-up rendering fix: tested with warm-up insertion tests.
- User Guide: added to GitHub documentation and inside the app.
- Active-workout setup notes editing: tested with display-resolution helper tests, SwiftData snapshot-propagation tests (current-session update, cancel no-op, past-History freeze, future-session pickup), and Korean localization regression coverage.
- Latest full test suite result: 976 tests, 0 failures.

---

## Planned Fixes From Feedback

- None currently. The setup-notes editing request was implemented (see Fixes above).

---

## Deferred Feedback

Feedback that is real but intentionally not addressed in this phase, such as P2/P3 polish, larger redesigns, or out-of-scope ideas.

- `[TBD]`

No peer/family feedback has been deferred yet.

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

**As of now:** Friends & Family Beta testing has started. Several crash, usability, and documentation issues have already been fixed, but the beta phase is still ongoing.

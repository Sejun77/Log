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
Severity: **P0** crash/data loss/can't finish · **P1** major confusion/broken
flow · **P2** annoying but avoidable · **P3** polish/feature request.

| Date       | Tester                            | Group                     | Severity | Feedback                                                                                                                                       | Status                                                                                                  |
| ---------- | --------------------------------- | ------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| 2026-07-10 | Developer / TestFlight validation | Internal pre-peer testing | P0       | App crashed when opening routines or adding the first exercise to a blank routine. Organizer showed a SwiftData `graph_keyPathToString` crash. | Fixed. Removed fragile SwiftData predicate in routine startability path and added regression tests.     |
| 2026-07-13 | Developer / TestFlight validation | Internal pre-peer testing | P0       | App crashed when deleting/removing an exercise from a routine. Organizer showed the same SwiftData key-path translation crash.                 | Fixed. Removed fragile `RoutineBlock.id` predicate from deletion path and made deletion tombstone-safe. |
| 2026-07-13 | Developer / manual testing        | Internal pre-peer testing | P1       | Final workout step could finish immediately if the user accidentally tapped Next too many times.                                               | Fixed. Added confirmation dialog before finishing workouts.                                             |
| 2026-07-13 | Developer / manual testing        | Internal pre-peer testing | P2       | Newly added warm-up sets sometimes did not appear until leaving and reopening the warm-up editor.                                              | Fixed. Reassigned warm-up steps array so SwiftUI observes the insertion immediately.                    |
| [TBD]      | Peer/family tester                | Friends & Family Beta     | [TBD]    | [TBD]                                                                                                                                          | [TBD]                                                                                                   |

Peer/family feedback has not been fully collected yet. The entries above came from early TestFlight validation and manual beta-readiness testing before expanding the tester group.

---

## Fixes Made From Feedback / TestFlight Validation

These fixes came from early TestFlight validation, crash reports, and manual beta-readiness testing.

- Removed a fragile SwiftData predicate from the routine startability path after a TestFlight-only crash occurred when opening routines or adding the first exercise to a blank routine.
- Removed a second fragile SwiftData predicate from the routine deletion path after deleting an exercise from a routine caused another TestFlight crash.
- Hardened routine deletion so empty routines, empty blocks, deleted exercises, and stale SwiftData relationship objects are handled safely.
- Added a confirmation dialog before finishing a workout so accidental repeated taps on Next cannot immediately end the workout.
- Fixed warm-up set insertion so newly added warm-up steps appear immediately without leaving and reopening the editor.
- Added regression tests for routine startability, routine deletion, finish confirmation behavior, and warm-up step insertion.

Current validation status:

- Routine startability crash fix: tested with regression coverage.
- Routine deletion crash fix: tested with regression coverage.
- Finish confirmation: tested with pure navigation helper tests and manual checklist.
- Warm-up rendering fix: tested with warm-up insertion tests.
- Latest full test suite result: 955 tests, 0 failures.

---

## Deferred Feedback

Feedback that is real but intentionally not addressed in this phase (P2/P3,
larger redesigns, or out of scope).

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

Likely themes to watch as peer/family testing expands:

- whether the core flow is understandable without me explaining it
- whether the rest timer and Save & Exit / Resume make sense to new users
- whether progress charts help or confuse
- whether Korean wording holds up in real use
- whether routine editing feels stable after the TestFlight crash fixes

---

## Phase Result

`[TBD]`

This section is written once the beta has actually happened. It should honestly
state what the feedback showed, what was fixed, and what was deferred — without
claiming a public App Store release. The goal of this phase is external
feedback, not distribution.

**As of now:** planned only. Testers have not completed testing yet.

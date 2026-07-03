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

| Group | Who | Focus | Status |
|-------|-----|-------|--------|
| Lifting friends | Friends who train regularly | Real workout use | `[TBD]` |
| Family (Korean UI) | Family, Korean-comfortable | Korean usability | `[TBD]` |
| Casual testers | People who don't lift much | Understandable without gym context | `[TBD]` |

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
- *(optional)* Switch an exercise during a workout
- *(optional)* Try the Korean UI
- *(optional)* Try an uneven superset, if comfortable

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

| Date | Tester | Group | Severity | Feedback | Status |
|------|--------|-------|----------|----------|--------|
| [TBD] | [TBD] | [TBD] | [TBD] | [TBD] | [TBD] |

No feedback recorded yet — testing has not started.

---

## Fixes Made From Feedback

Fixes that came directly out of beta feedback go here.

- `[TBD]`

No fixes yet — no feedback has been collected.

---

## Deferred Feedback

Feedback that is real but intentionally not addressed in this phase (P2/P3,
larger redesigns, or out of scope).

- `[TBD]`

---

## What I Learned

Reflections from running the beta.

- `[TBD]`

Likely themes to watch (to confirm or reject with real data):

- whether the core flow is understandable without me explaining it
- whether the rest timer and Save & Exit / Resume make sense to new users
- whether progress charts help or confuse
- whether Korean wording holds up in real use

---

## Phase Result

`[TBD]`

This section is written once the beta has actually happened. It should honestly
state what the feedback showed, what was fixed, and what was deferred — without
claiming a public App Store release. The goal of this phase is external
feedback, not distribution.

**As of now:** planned only. Testers have not completed testing yet.

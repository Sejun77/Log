# TestFlight Feedback Plan

This is a practical plan for the first small TestFlight beta of **Log**.

It exists to make the beta easy to run: what to send testers, what to ask them
to try, what questions to ask, and where to write down what comes back.

**Status:** planned. TestFlight testing has not started yet.

---

## Goal

Find out whether other people — not just me — can understand and use the app.

Entry #11 proved the app works for my own workouts. This beta is about a
different question: can a friend or family member install the app, start a
workout, log sets, and understand what is happening, without me sitting next
to them?

The goal is **practical feedback**, not a public release.

---

## Scope

In scope:

- a small, invited group of friends and family
- installing through TestFlight
- the everyday workout flow (start → log → rest → finish → review)
- basic Korean UI usability for family testers

Out of scope:

- public App Store release
- large-scale or open testing
- marketing, ratings, or reviews
- promising fixes on any timeline

This is a personal/internal milestone and a portfolio project.

---

## Tester Groups

Small and informal. Rough groups:

| Group | Who | Focus |
|-------|-----|-------|
| Lifting friends | Friends who train regularly | Real workout use, whether the flow matches how they actually train |
| Family (Korean UI) | Family members more comfortable in Korean | Whether the app makes sense in Korean, clipped/confusing translations |
| Casual testers | People who don't lift much | Whether the app is understandable without gym context |

A tester can belong to more than one group.

---

## Tester Instructions

Send something short like this with the TestFlight invite:

> Thanks for helping test Log, my personal gym-logging app.
>
> 1. Install TestFlight from the App Store if you don't have it.
> 2. Tap the invite link and install Log through TestFlight.
> 3. Open the app and try running through one workout — create or pick an
>    exercise, build a small routine, start a workout, log a few sets, use the
>    rest timer, then finish it and look at your History.
> 4. Don't worry about breaking anything. This is test data on your own phone.
> 5. Tell me anything that felt confusing, annoying, or broken — even small
>    things. "I didn't know what this button did" is very useful.
>
> This is a personal project, not a finished App Store app, so rough edges are
> expected. Honest feedback is the whole point.

For Korean-speaking testers, add: *"The app is available in Korean — feel free
to test in Korean and tell me if any wording is confusing or cut off."*

---

## Testing Tasks

A simple checklist testers can walk through. Required tasks first, optional at
the end.

- [ ] Install the app through TestFlight
- [ ] Open the app
- [ ] Inspect or create an exercise
- [ ] Inspect or create a routine
- [ ] Start a workout
- [ ] Log some sets
- [ ] Use the rest timer
- [ ] Try Save & Exit, then Resume
- [ ] Finish the workout
- [ ] Check History
- [ ] Check the progress charts
- [ ] *(optional)* Switch an exercise during a workout
- [ ] *(optional)* Log a cardio exercise (duration-based), with the details in notes
- [ ] *(optional)* Try the Korean UI
- [ ] *(optional)* Try an uneven superset (different set counts per exercise), if comfortable

---

## Feedback Questions

Ask these after testing. Keep it conversational — a message or short call is
fine.

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

## Severity Scale

Use this to rank feedback when logging it.

| Level | Meaning |
|-------|---------|
| **P0** | Crash, data loss, or cannot finish a workout |
| **P1** | Major confusion or a broken main flow |
| **P2** | Annoying but avoidable issue |
| **P3** | Polish or feature request |

---

## Feedback Log

Fill this in as feedback arrives.

| Date | Tester | Group | Severity | What happened / feedback | Status |
|------|--------|-------|----------|--------------------------|--------|
| 2026-07-15 | Peer/family tester | Friends & Family Beta | P2 | Setup notes are useful during workouts, but could not be edited from the active workout screen like exercise notes. | fixed |
| 2026-07-15 | Peer/family tester | Friends & Family Beta | P1 | The Finish Workout confirmation sometimes required a second tap before the workout actually finished. | fixed |
| 2026-07-30 | Peer/family tester | Friends & Family Beta | P1 | Switching an exercise mid-workout gave an inconsistent plan between duration-based and normal exercises: switching could leave mixed duration/reps prescription state (duration fields on a reps/weight exercise), the set count was inconsistent after switching ("Keep Current Plan" changed 2 → 3), and the two resume paths restored different plans. Fixed: "Keep Current Plan" and "Reset Plan" now use one compatibility adapter so neither leaves mixed prescription state; incompatible tempo, Tempo Override, warm-ups, techniques, and prescription notes are handled safely; and all resume paths restore the same active session plan. Switching may still prefill input fields from the new exercise's previous performance, but that is draft-only and does not change the workout plan. | fixed |
| 2026-08-02 | Peer/family tester | Friends & Family Beta | P2 | Duration and rest inputs were too limited: duration maxed out around 10 minutes, which is too low for long duration exercises or cardio, and the 15-second steppers would have taken far too many taps to reach 30+ minutes. Fixed: exercise duration now goes up to 6 hours and rest up to 60 minutes, both entered with one-tap presets plus hour/minute/second wheels instead of a stepper. Values are stored as seconds as before, and every write is clamped so negative or out-of-range values cannot be entered. | fixed |
| 2026-08-02 | Peer/family tester | Friends & Family Beta | P2 | Asked for cardio support. Fixed in the same slice as the duration/rest limits above, because lightweight cardio depends on usable long-duration input: cardio can be logged as a duration-based exercise, and the built-in catalogue now seeds Walking, Treadmill Walk, Stationary Bike, Elliptical, Stair Climber, and Rowing Machine as duration-based exercises under the existing Cardio body part (Korean: 유산소). For now, details like distance, speed, incline, resistance, or heart-rate zone can be written in notes. Structured cardio metrics (distance, pace, calories, heart-rate zone, incline, resistance / machine level) are deferred, not forgotten. | fixed |
| [TBD] | [TBD] | [TBD] | [TBD] | [TBD] | [TBD] |

Status values: `new`, `investigating`, `fixed`, `deferred`, `won't fix`.

---

## Known Limitations

Testers should know this going in:

- Public App Store readiness is **not** claimed.
- TestFlight feedback phase is **planned / just beginning** — not completed.
- UI polish may continue during and after this beta.
- Broader distribution is deferred until this small beta is useful and settled.
- Korean translations are new and may need refinement.
- Cardio is supported as duration-based logging only. Details like distance,
  speed, incline, resistance, or heart-rate zone go in notes; there are no
  dedicated cardio fields yet.

---

## What Not to Test / What Not to Overfocus On

To keep feedback useful:

- Don't stress-test for crashes on purpose — just use it normally.
- Don't overfocus on visual polish (spacing, colors, fonts). Some polish is
  intentionally still in progress.
- Don't worry about missing "big" features — this is a focused personal app,
  not a full commercial product.
- Don't test on data you care about keeping; treat everything as test data.
- Don't compare it feature-for-feature to large commercial gym apps.

The most valuable feedback is about **understanding and everyday use**: could
you figure out what to do, and did the core flow work?

---

## Next Steps

1. Prepare a TestFlight build and internal notes.
2. Invite the first small group of testers.
3. Share tester instructions and the testing checklist.
4. Collect feedback into the Feedback Log above.
5. Triage feedback by severity (P0–P3).
6. Fix clear P0/P1 issues; defer P2/P3 as appropriate.
7. Record outcomes in `ENTRY_12_TESTFLIGHT_FEEDBACK.md`.

TestFlight testing is planned but has not started yet.

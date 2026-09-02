# Entry #12 — Beta Feedback, Cardio System & TestFlight Preparation

> **DRAFT — not final.** A few fixes/features are still planned before the
> TestFlight upload. Numbers, scope, and build status in this entry are accurate
> as of the last verified run and will be updated before publishing. See
> **Final Pre-TestFlight Polish** near the end for what is still open.
>
> _Numbering note:_ the repo already uses `docs/ENTRY_12_TESTFLIGHT_FEEDBACK.md` for
> the beta feedback log. If the public devlog numbering is separate, this stays
> #12; otherwise renumber before publishing.

**Date Range:** 2026-06-24 → 2026-08-12 _(end date to be updated if more work lands before upload)_

Entry #11 ended with the app working for **my** workouts — the full loop, start to
History, validated on a real device. This entry is about a different question:

> Can other people install this, use it, and understand what they're looking at?

That question turned out to be less about features and more about everything
around them. The bulk of this stretch went into fixing what early testers hit,
making the everyday flow harder to get wrong, writing a guide for people who
don't already know how the app works, and translating it for family who'd rather
use it in Korean. Cardio — the one genuinely large new feature — came at the end,
and only after a smaller version of it had been in testers' hands long enough to
show what it actually needed.

The phase ends with the test suite repaired and passing, a manual regression
done, and **build 9 uploaded to TestFlight**. Build 10 work has since started;
its first fix is recorded at the end of this entry.

---

## 1. Beta Feedback & Stability

The first weeks were driven almost entirely by what testers ran into. Two of
these were crashes that never reproduced in normal development builds — they only
showed up on other people's phones, which is precisely the argument for getting
it onto other people's phones.

- **Fixed a crash when opening a routine or adding the first exercise to an empty
  routine.** This one hit testers immediately, on the most basic thing you can do
  in the app.
- **Fixed a second crash when deleting or removing an exercise from a routine.**
  Routine deletion was then hardened so empty routines, empty blocks, and
  already-deleted exercises are all handled safely.
- **Added a confirmation before finishing a workout.** Tapping Next one time too
  many at the end of a session used to end the workout instantly. Later, the
  confirmation itself was made reliable so a single tap finishes the workout
  exactly once.
- **Added setup-notes editing during an active workout.** Setup notes were useful
  mid-session but read-only; now they can be corrected on the spot. The correction
  saves for future sessions and for this workout's History — previously completed
  workouts stay frozen.
- **Fixed warm-up sets not appearing** until you left and reopened the warm-up
  editor.
- **Removed unused background capabilities** and added a privacy note ahead of
  beta distribution.

Every one of these came from a tester, a crash report, or a reproduction of
something a tester described. They're logged with severity and outcome in
`docs/ENTRY_12_TESTFLIGHT_FEEDBACK.md`.

---

## 2. Routine & Active Workout Polish

Alongside the crash fixes, the everyday flow got quieter and more predictable.

- **Exercise switching mid-workout was made consistent.** Switching between a
  time-based exercise and a normal one could previously leave a mixed plan on
  screen — duration fields on a reps-and-weight exercise — and could silently
  change the set count. Both "Keep Current Plan" and "Reset Plan" now produce a
  valid plan for the new exercise, keeping what still applies and clearing what
  doesn't.
- **Save & Exit and Resume now restore the same workout.** The two ways back into
  a running session used to disagree about what the plan was. There's now one
  answer.
- **Switching prefills the input fields** from the new exercise's own last
  performance — but only the fields you're about to type into. It never changes
  the workout plan.
- **Tidied up settings that don't apply to time-based exercises,** so options
  meant for reps-and-weight work no longer show up where they can't do anything.
- **Warm-ups, plan edits, and rest behavior** were cleaned up as part of the same
  pass, including a stale rest timer that could keep counting for an exercise you
  had just replaced.
- **Simplified labels and helper text** in several places, so screens explain
  themselves instead of relying on tooltips.

---

## 3. Duration Exercises & Cardio Foundation

Cardio didn't start as a cardio system. It started as a tester asking for cardio,
and the honest first answer being: the app can almost do this already.

- **Duration and rest limits were raised** — up to 6 hours for an exercise and 60
  minutes for rest. The previous ceiling was around 10 minutes, which is fine for
  a plank and useless for a run.
- **The input control was replaced along with the limit.** One-tap presets plus
  hour / minute / second wheels, instead of a stepper that moved 15 seconds at a
  time. Raising a cap without fixing the control would have made long durations
  technically possible and practically unusable.
- **Cardio became loggable right away** as a time-based exercise, with the
  built-in list seeding common cardio machines. Details like distance and incline
  went into notes for that first beta build.
- **Then cardio was separated from generic duration exercises.** Notes aren't
  queryable — you can't chart weekly distance or compare two 5k runs from a text
  field. So cardio became its own kind of exercise, with its own fields, designed
  in `docs/CARDIO_SYSTEM_DESIGN.md` before any of it was built.

The short version: the beta answer shipped in days and kept people training; the
proper answer shipped a few weeks later, informed by the beta one.

---

## 4. Cardio Logging

- **Dedicated cardio exercises.** An exercise can be marked Time-based, then
  Cardio. Common ones ship built in. If you used an earlier build, the app offers
  **once** to convert the cardio exercises you already have — declining changes
  nothing.
- **A Details section** for distance, duration, calories, heart rate, incline or
  decline, resistance / machine level, and heart-rate zone. Pace and speed are
  worked out from what you enter.
- **Distance unit in Settings.** Pick km or mi once and the whole app follows it.
- **History summaries.** A cardio bout shows a readable summary line rather than
  an empty set row.
- **Cardio progress charts.** Distance, duration, pace, calories, and average
  heart rate, instead of the strength series that need a weight.
- **Previous-performance prefill.** A cardio set starts from what you *chose* last
  time (distance, incline, resistance), never from last session's *results* (heart
  rate, zone, calories).
- **Cardio slots in routines** can carry a target distance, and start as a single
  effort with no rest.

A cardio bout is recorded as **one aggregate Cardio Set** — one row holding the
duration and the Details you entered. Everything downstream reads that one row.

---

## 5. Structured Cardio Plans

The last piece lets a routine describe the *shape* of a cardio session, not just
its length. The distinction that matters:

> **Cardio Plan = what you intended. Cardio Set = what you actually did.**

- A cardio routine slot can carry an ordered plan of segments — **Warm-up**,
  **Work**, **Recovery**, **Cool-down** — each with its own optional targets. This
  turns "30 min treadmill" into "5 easy / 20 at 1% / 5 easy."
- **During the workout the plan appears as a checklist** next to the set entry, so
  you can see what's next and tick segments off.
- **Ticks survive Save & Exit and Resume.** Leave mid-session, come back, and your
  place is still there.
- **Ticks are never saved to History.** They're progress markers, not
  measurements — the app shouldn't imply it observed something it didn't.
- **History shows the planned Cardio Plan** the workout was started with, next to
  the logged result.
- **Routine transfer preserves plans.** Exported routines carry their segments,
  and routine files from older builds still import.
- **The logged result is still one Cardio Set.** Segments are not logged
  individually.

Stated plainly because it's a real limitation: since logging is aggregate, an
interval session charts as one average pace, which understates the hard efforts.
That's a known trade-off for this build, not an oversight.

---

## 6. User Guide, Korean UI & Tester Instructions

A tester said the app was simple but not obvious if you don't already know gym
terminology. That was fair.

- **A user guide was written and put inside the app,** under Settings → Help →
  User Guide, covering the basics through History, the rest timer, prefill, and
  cardio.
- **Korean UI support** was added so family members can test in the language
  they're comfortable in — including body parts, Settings text, and help text.
  Feedback is only useful if the tester understood the screen.
- **The guide was simplified before testing.** The cardio section in particular
  was cut back to what a tester actually needs, with internal vocabulary removed
  and the logged row named plainly as a **Cardio Set**.
- **Tester instructions were updated** so cardio and structured cardio are part of
  the optional walkthrough, with known gaps listed so nobody reports a deliberate
  deferral as a bug.
- **Testers are asked to check** routines, logging, cardio, History, the Korean UI
  (including any wording that reads oddly or gets cut off), any step that felt
  confusing, and anything that looked like missing data.

---

## 7. Testing & Validation

_Counts are from the latest verification run, after the Build 10 C3 fix._

- **The UI test target was restored.** `LogUITests` had gone missing from the
  project and the scheme pointed at stale references, so the full scheme couldn't
  run end to end.
- **A stale UI test was replaced with a launch/navigation smoke test.** The old
  one was pinned to UI that no longer exists; the replacement checks that the app
  launches and its main screens are reachable — the thing a UI test can actually
  catch reliably.
- **Full scheme passes: 2,323 tests, 0 failures** — 2,321 unit tests plus 2 UI
  tests.
- **Debug build succeeds.**
- **Release build succeeds.**
- **Manual regression completed** on device: routines, logging, exercise
  switching, cardio Details, the Cardio Plan checklist through Save & Exit and
  Resume, History, the charts, and timer behavior across backgrounding and
  reopening.
- **Build 9 uploaded to TestFlight.** Build 10 work has started — see *Build 10*
  below.

The cardio work landed additively — new fields are optional and start empty — so
existing workouts, routines, and history weren't rewritten and no data migration
was needed.

---

## 8. Deferred / Not Included Yet

Deferred means decided, not forgotten.

- **Repeat authoring UI for Cardio Plans.** No editor yet for `5 × (1 min hard /
  2 min easy)`; a plan is an ordered list of segments.
- **Segment-level actual results.** Segments are targets you tick, not things the
  app records individually.
- **Segment-level analytics and charts.** Nothing to chart until per-segment
  results exist.
- **GPS / route tracking.** Not planned.
- **Apple Watch / HealthKit.** Not planned.
- **Automatic cardio tracking** of any kind — no sensors, no live progression, no
  timer driving the session. Every number is one you enter.
- **Workout-history CSV import.** History export works; importing history is not
  planned.

---

## Final Pre-TestFlight Polish

Done:

- Removed a stale "Rest after" preview label that could appear from legacy
  routine data before starting a workout.
- Fixed a background/foreground timer issue where a duration countdown could
  reopen as a Rest overlay instead of catching up as duration.
- Added a confirmation before switching exercises when the switch would remove
  already logged sets.

TODO:

- Add remaining fixes completed before upload
- Update final test count if it changes

---

## Build 10 — First Fix

Build 9 is on TestFlight. Build 10 opens not with a feature but with a
safety/UX fix to how deleting an exercise interacts with **Alternative
Exercises** — the thing Build 9 shipped and the thing that made this reachable.

Exercise usage was only ever counted from direct routine slots. Alternatives
live inside a slot's prescription, so an exercise used *only* as a prepared
alternative reported **"Used in 0 routines"** — on the same screen as the Delete
button, immediately above it. Delete it and nothing cleaned up the alternatives
pointing at it; they resurfaced mid-workout as disabled `Exercise unavailable`
rows, in routines with no way to repair them.

- **Exercise usage now includes prepared alternatives.** Direct slots and
  alternatives are counted separately and never summed, so a routine that uses
  an exercise both ways is still one routine. Exercise Detail reads `Used as 3
  alternatives` when there is no direct usage, and `Used in 2 routines · 3
  alternatives` when there is both.
- **The "Used in 0 routines" case is fixed**, along with the "add this exercise
  to a routine" empty state that used to appear underneath it.
- **The delete confirmation now warns about prepared alternatives** and names
  the count.
- **Deleting an exercise prunes the matching alternatives** instead of leaving
  dangling unavailable rows. Non-matching alternatives are preserved untouched,
  and a slot that loses its last one goes back to storing nothing at all.

The pruning is a deliberate reversal of a design-doc decision, and worth being
straight about: the original design rejected sweeping up alternatives whose
exercise was deleted, on the grounds that silently destroying prepared work is
worse than showing a dead row. That reasoning holds for a *silent* sweep. This
is not one — it happens only at the moment the user deletes the exercise, and
only after a confirmation that says the prepared alternatives go with it. The
disabled `Exercise unavailable` row still exists for the case it was really
written for: a workout already in progress, whose frozen session plan still
names an exercise deleted mid-session.

No schema change, no active-workout switch behavior change, no effort-target
logic change.

---

## Build 10 — Saying the Right Thing in Korean

The second Build 10 slice is smaller and entirely about words. Nothing in the
app behaves differently afterwards; four things it *said* were wrong.

- **End and Finish asked the same question.** Both dialogs were titled
  `운동을 종료할까요?` in Korean — the one that exits a workout and the one that
  completes it and saves it to History. They now read `운동을 중단할까요?` and
  `운동을 완료할까요?`, and the finish dialog agrees with the `완료` button
  inside it.
- **Routine block detail leaked the database into the UI.** It rendered
  `kindRaw.capitalized` — the persisted English raw value — so a Korean routine
  listed its sets as `Working`, `Warmup`, `Dropset`. It now uses the localized
  label the rest of the app already had.
- **The cardio plan had two names.** The routine editor said *Structured
  Cardio*; the active workout, History and the guide said *Cardio Plan*. The
  editor row and the screen it pushes now say Cardio Plan too.
- **The Techniques row argued with itself**, reading `운동 기법        3 테크닉`.
  The count now reuses the row's own name.

And a guide error worth its own line: the Korean guide told users to tap **종료**
to save a workout to History. 종료 is the *exit* button. Someone following the
guide literally would have been told to leave the workout at the exact moment
they meant to finish it. The finish steps now say **완료**, and the only 종료
left in the guide is `저장 후 종료` — the save-for-later exit, which is what the
word should have been reserved for from the start.

That last one is the useful reminder in this slice. The translation was not
missing and not clipped; it was fluent, confident, and pointed at the wrong
button. Nothing but reading the Korean UI as a Korean user would catch it, which
is exactly what the tester round is for.

---

## Build 10 — Putting the Sets Where the Hands Are

The third Build 10 slice moves one section and changes nothing else.

The active workout screen listed nine sections, and the set rows were **ninth**.
Above them: session notes, the future-prefill toggle, exercise notes, Switch
Exercise, the Plan card, Equipment & Setup, warm-ups, the cardio checklist. All
of it either read once at the start or never — and all of it between the user
and the reps field they come back to every couple of minutes, on every exercise,
on every phone.

Sets is now first. Then the plan-shaped things a user reads *while* logging —
Plan, Warmup, the Cardio Plan checklist — then Equipment & Setup, and then the
read-once half: Switch Exercise, Exercise Notes, the prefill toggle, Session
Notes. No section was removed, renamed, collapsed behind a disclosure, or given
a new label; the header above the list did not move.

It is worth being precise about how little this changed, because a 4,800-line
view is exactly where a "simple reorder" quietly loses something. Comparing the
multiset of non-blank lines against the previous commit: seven comment lines
removed, eleven added, and every single line of code byte-identical and merely
relocated. That check earned its keep immediately — the first pass rewrote the
cardio checklist's comment and swallowed the call underneath it. It would have
compiled clean, passed all 2,323 tests, and silently dropped the checklist from
every cardio workout, because nothing in the suite asserts that a section is on
screen. A build succeeding is not the same as the screen being right.

---

## Next Steps

- Continue Build 10 from the UX audit backlog.
- Re-run the full test suite and the release build before the next upload.
- Get Build 9 feedback from the small friends-and-family group during real
  training.
- Collect feedback, especially on confusing steps and on Korean wording.
- Fix confusing UI and translation problems **before** adding major new features —
  the point of this build is to learn what other people don't understand, and
  piling on more surface area first would defeat it.

The through-line of this entry is that "ready for other people" was mostly not a
feature problem. It was crashes that only appear on someone else's phone, a
confirmation before an irreversible tap, a guide for someone who doesn't know the
vocabulary, and a translation. Cardio is the headline, but it's the last thing
that happened, not the reason the app got testable.

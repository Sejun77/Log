# TestFlight Feedback Plan

This is a practical plan for the first small TestFlight beta of **Log**.

It exists to make the beta easy to run: what to send testers, what to ask them
to try, what questions to ask, and where to write down what comes back.

**Status:** planned. TestFlight testing has not started yet.

**Build for this round:** Build 9, the next tester round after Build 8. Build 8
was prepared and archived with the cardio system and Alternative Exercises;
Build 9 adds the redesigned RIR/RPE effort targets, including **Custom Per Set**.
Build 9 has not been uploaded — this plan is what the round runs on once it is.

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
> If anything is unclear, there's a short user guide in the app under
> Settings → Help → User Guide.
>
> This is a personal project, not a finished App Store app, so rough edges are
> expected. Honest feedback is the whole point.

The same guide is `docs/USER_GUIDE.md` in this repository, on GitHub at
`https://github.com/Sejun77/Log/blob/main/docs/USER_GUIDE.md` (English +
한국어), if a tester would rather read it before installing.

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
- [ ] *(optional)* Log a cardio exercise — duration, then open **Details** to add
      distance, heart rate, calories, incline, or resistance
- [ ] *(optional)* Set a distance target on a cardio routine slot, and check the
      distance unit (km / mi) in Settings
- [ ] *(optional)* Build a **Structured Cardio** plan on a cardio slot (warm-up /
      work / cool-down), tick it off during the workout, then look for the
      **Cardio Plan** section in History afterwards
- [ ] *(optional)* Try the Korean UI
- [ ] *(optional)* Try an uneven superset (different set counts per exercise), if comfortable

### Alternative Exercises

New since the last tester round: a routine exercise can hold prepared
replacement exercises,
each with its own plan, offered when you switch exercises mid-workout.

- [ ] Open or create a routine
- [ ] Open an exercise in the routine
- [ ] Tap **Alternative Exercises**
- [ ] Tap **Add Alternative** and pick a replacement exercise
- [ ] Edit its plan — sets, reps, rest, warm-ups, techniques, target distance,
      Cardio Plan, or notes
- [ ] Start a workout from that routine
- [ ] Tap **Switch Exercise** and confirm **Prepared Alternatives** appears
- [ ] Apply the prepared alternative, and check the exercise *and* its plan
      update correctly
- [ ] Log a set, then try switching again
- [ ] Confirm the app warns you before removing logged sets
- [ ] Tap **Cancel** once, and confirm the logged set is still there
- [ ] Try again, confirm the switch, and check it works as expected
- [ ] *(optional)* Try a cardio alternative
- [ ] Duplicate the routine and confirm the alternatives came with it
- [ ] Export the routine, import it back, and confirm the alternatives survived

What to report:

- missing or incorrect alternatives
- confusing **Prepared Alternatives** wording
- sets disappearing when you did not expect it
- problems with the switch confirmation
- cardio alternative issues
- clipped Korean text, awkward Korean wording, or English text still showing
  while the phone is set to Korean

### Effort Targets

New in this round: automatic RIR/RPE progression was cleaned up so it stops
producing awkward half-step targets, and a routine exercise can now carry an
exact target for every set.

- [ ] Open a routine and open an exercise in it
- [ ] Try **Same Target** — one RIR/RPE value used by every working set
- [ ] Try **Progression** with RIR 2 → 0 over 4 sets, and confirm the sets show
      **2, 2, 1, 0**
- [ ] Try **Progression** with RPE 8 → 10 over 4 sets, and confirm the sets show
      **8, 8, 9, 10**
- [ ] Try **Custom Per Set** and enter exact targets such as **2, 1.5, 1, 0**
- [ ] Leave the routine, reopen it, and confirm the custom targets are still
      there
- [ ] Start a workout from that routine and confirm each set shows the target you
      set
- [ ] Save & Exit, then Resume, and confirm the targets are still correct
- [ ] Give an alternative exercise its own custom effort targets, apply it
      mid-workout, and confirm its targets are used
- [ ] Duplicate the routine, then export and import it, and confirm the custom
      targets survive both

What to report:

- RIR/RPE targets that look awkward or wrong for the sets
- custom effort targets not saving
- targets in the active workout not matching the targets set in the routine
- custom targets on an Alternative Exercise not applying when you switch to it
- Korean wording issues on the effort target labels (동일 목표 / 프로그레션 /
  세트별 지정) — confusing, clipped, or still in English

### Deleting an Exercise Used as an Alternative (Build 10)

New in Build 10: the Exercises tab now knows when an exercise is used as a
prepared alternative, and says so before you delete it.

- [ ] In **Exercises**, open an exercise that is used **only** as an Alternative
      Exercise (not added to any routine directly)
- [ ] Confirm it does **not** appear unused — it should say it is used as an
      alternative, not "Used in 0 routines"
- [ ] Try deleting it
- [ ] Confirm the delete warning mentions **prepared alternatives**
- [ ] Confirm the deletion goes through
- [ ] Reopen the routine that had it as an alternative
- [ ] Confirm the alternative is gone, with no leftover "Exercise unavailable"
      row
- [ ] Confirm any *other* alternatives on that slot are still there and unchanged
- [ ] Confirm the routine itself still works — open it and start a workout

What to report:

- an exercise still reading as unused when a routine relies on it as an
  alternative
- a delete warning that does not mention prepared alternatives
- other alternatives disappearing when only one should have
- a leftover "Exercise unavailable" row after the delete
- anything about the routine that looks broken afterwards
- clipped or awkward Korean wording in the usage line or the delete warning

---

### Korean Wording After the Build 10 Terminology Fix (Build 10)

Korean UI only. Set the phone to Korean first. Nothing here changes what the app
does — it is a read-the-screen pass on wording that was wrong in Build 9.

- [ ] Open a routine block and check the set rows — they should read
      `메인 세트` / `워밍업 세트` / `드롭 세트`, never `Working`, `Warmup` or
      `Dropset`
- [ ] Start a workout, tap the **End** path and read the dialog title
      (`운동을 중단할까요?`)
- [ ] Cancel, then tap **Finish** and read that dialog title
      (`운동을 완료할까요?`) — the two must ask different questions
- [ ] Open a cardio routine slot and confirm the plan row says `유산소 계획`,
      and that the screen it opens has the same name
- [ ] Open a slot with techniques and confirm the row does not mix 운동 기법 and
      테크닉
- [ ] Open the in-app Korean guide and confirm the finish step says to tap
      **완료** to save the workout to History

What to report:

- any English word left in a Korean screen, especially in a set row
- the End and Finish dialogs reading the same, or either one naming the wrong
  action
- 유산소 계획 and 유산소 구성 both appearing for the same thing
- guide steps that name a button that is not on the screen
- any of this wording clipped or wrapped badly at Korean string lengths

---

### Reaching the Set Rows (Build 10)

Changed in Build 10: on the active workout screen the **Sets** rows now come
first, instead of below session notes, the prefill toggle, exercise notes,
Switch Exercise, the plan card, setup, warm-ups and the cardio checklist.
Nothing else about logging changed — this is only about how far you scroll.

- [ ] Start a normal workout and confirm the set rows are visible without
      scrolling
- [ ] Log a working set and confirm the rest timer behaves as it always has
- [ ] Confirm everything you used before is still there, further down: the plan,
      warm-ups, setup, Switch Exercise, exercise notes, the prefill toggle and
      session notes
- [ ] Start a cardio workout with a Cardio Plan and confirm the checklist is
      still easy to find
- [ ] Tap into a notes or setup field and confirm the keyboard and the bottom
      Back / Next buttons behave normally

What to report:

- still having to scroll to reach the set rows, and on which phone
- anything that used to be on this screen that you can no longer find
- the keyboard covering a field, or the bottom Back / Next bar overlapping
  anything
- whether logging actually feels quicker than it did in Build 9

---

### Seeing Prepared Alternatives Before You Start (Build 10)

New in Build 10: a routine exercise that has prepared alternatives now says so
before the workout, instead of only when you tap Switch Exercise mid-set.
Nothing about how alternatives work has changed — this is only about where the
count is shown.

- [ ] Prepare two alternatives on a routine exercise, and turn a third one off
- [ ] In the routine, confirm the row says **2 alternatives** — the one you
      turned off is deliberately not counted
- [ ] Confirm an exercise with no alternatives says nothing extra
- [ ] Open **Start Workout** and confirm the count is visible there too, before
      you start
- [ ] Start the workout and confirm the **Switch Exercise** row shows the count
- [ ] Tap Switch Exercise and confirm the sheet is titled **Switch Exercise**,
      with the exercise you are replacing named under the header
- [ ] Apply a prepared alternative and confirm it behaves exactly as it did in
      Build 9
- [ ] On a small phone, check a long routine row (a cardio exercise with a
      distance target, rest and an effort range) and say whether the count at
      the end is cut off

What to report:

- a count that does not match the alternatives you prepared
- the alternative you turned off being counted
- the count cut off at the end of a routine row, and on which phone
- the switch sheet title or subtitle reading oddly, in either language
- anything different about applying an alternative compared with Build 9

---

### Warm-ups and Techniques Inside an Alternative (Build 10)

Fixed in Build 10: on Build 9, adding a warm-up step to a prepared alternative
crashed the app. Adding a technique did not crash but quietly left a stray row
behind. Both are fixed, and nothing about how alternatives work has changed —
this check is only to confirm the editing itself is now solid.

- [ ] Open a routine exercise's **Alternative Exercises** and open a prepared one
- [ ] Add a **warm-up** step, and confirm the app does not crash
- [ ] Confirm the step appears straight away, without leaving the screen
- [ ] Add a **technique**, then edit it, then delete it
- [ ] Leave the alternative editor, reopen it, and confirm what you kept is
      still there
- [ ] Start a workout from that routine and apply the prepared alternative
- [ ] Confirm the warm-up and technique you authored are the ones the workout
      shows
- [ ] Log a set and confirm the rest timer still behaves normally
- [ ] Check that a **normal** routine exercise's warm-ups and techniques still
      work exactly as before

What to report:

- any crash, and what you had just tapped
- a warm-up step or technique that does not appear until you leave and come back
- anything you saved in an alternative that is missing when you reopen it
- a warm-up or technique that does not carry into the workout after applying the
  alternative
- anything different about editing warm-ups or techniques on a normal routine
  exercise

---

### The Active Workout Screen, After the Polish Pass (Build 10)

Changed in Build 10, from a round of manual testing: **Warmup** now sits above
the set rows, the rest timer stops when you unlog the set that started it, the
finish button reads plainly **Finish / 완료** when there is nothing else to
apply, and the Korean bottom bar says **이전** instead of **등**.

- [ ] Start a workout from a routine whose first exercise has warm-up steps
- [ ] Confirm **Warmup** appears **above** Sets, and that the set rows are still
      quick to reach without a long scroll
- [ ] Confirm **Session Notes** is still near the bottom
- [ ] Log a set and confirm the rest timer starts as it always did
- [ ] Unlog that same set, and confirm the rest timer stops
- [ ] Log another set and confirm rest starts normally again
- [ ] *(optional)* While resting after set 3, go back and correct set 1 —
      the rest should **keep running**
- [ ] Finish a workout where you changed nothing, and confirm the button says
      just **Finish** / **완료**
- [ ] Finish a workout where you switched an exercise or edited the plan, and
      confirm the longer "Finish + …" options still appear
- [ ] Open **History** for a workout that had an effort target, and confirm
      **Planned effort** fits on one line
- [ ] In Korean, confirm the bottom bar reads **이전** and **다음**
- [ ] In Korean, open an exercise whose body part is Back and confirm it still
      reads **등**

What to report:

- a rest timer that keeps running after you unlog a set, or one that stops when
  you did not expect it to
- a rest notification that still arrives after you unlogged the set
- Warmup or Sets in an order that feels wrong while training
- the planned-effort row still wrapping onto two lines, and on which phone
- **이전** or **다음** reading oddly, or **등** appearing anywhere it means
  navigation
- the finish button saying more or less than the situation calls for

---

### Opening the User Guide (Build 10)

Changed in Build 10: the in-app guide opens in your phone's language instead of
showing the English guide with the Korean one underneath it. Nothing either
guide says has changed — only which one you land on.

- [ ] Open **Settings → Help → User Guide** and confirm it opens in your
      phone's language
- [ ] Confirm you do **not** have to scroll through a second full guide in the
      other language
- [ ] Tap the other language at the top and confirm the guide switches
- [ ] Leave the guide, reopen it, and confirm it opens in your phone's language
      again (the switch is per visit, on purpose)
- [ ] On a small phone, confirm the **English / 한국어** switch is not cramped

What to report:

- the guide opening in the wrong language for your phone
- the switch not changing the guide, or landing you mid-page
- a section that exists in one language but not the other
- the switch looking cramped or clipped, and on which phone

---

### Effort Targets, Explained (Build 10)

Changed in Build 10: the routine editor now explains what the four effort
modes do, saved targets no longer disappear when autoregulation is off, and a
long per-set target list no longer runs off the end of a row. How targets
themselves work has not changed.

- [ ] On a routine exercise, tap the info button under the effort mode picker
      and read the four modes — say whether you could choose between them from
      that alone
- [ ] Set **Custom Per Set** with 4 targets and confirm the summary shows all
      four
- [ ] Add more sets so there are more than 4 targets, and confirm the summary
      ends in `…` rather than running long
- [ ] Confirm each set row still shows its own full target during the workout
- [ ] In **Settings**, set Autoregulation to **None**, reopen the exercise, and
      confirm it says the targets are saved rather than showing nothing
- [ ] Turn RIR or RPE back on and confirm the targets are exactly as you left
      them
- [ ] During a workout, open **Edit Plan** on a progression or per-set exercise
      and confirm it says the targets are fixed for this session
- [ ] Open the User Guide's effort section and confirm it lists four modes

What to report:

- a mode you still cannot tell apart from the others after reading the info
- targets that look lost after turning autoregulation off, or different after
  turning it back on
- a set row showing a truncated or wrong target (the summary may shorten, the
  rows must not)
- any effort text clipped on a routine row, and on which phone
- awkward Korean in any of the new explanations

---

### Seeing Your Planned Effort in History (Build 10)

New in Build 10: after a workout is finished, History shows the effort target
that exercise was planned with. It is what you **aimed for**, not what the app
measured — nothing records your actual RIR or RPE per set.

- [ ] Set an effort target on a routine exercise, finish a workout with it, and
      open that workout in **History**
- [ ] Confirm a **Planned effort** line appears for that exercise
- [ ] Now change the routine's effort target, reopen the **same old** workout,
      and confirm History still shows the original value
- [ ] Try it with a progression (RIR 2 → 0) and with per-set targets
      (2, 1.5, 1, 0) and confirm both read correctly
- [ ] With more than 4 per-set targets, confirm the line ends in `…` rather
      than running long
- [ ] Confirm an exercise with **no** effort target shows no planned-effort line
      at all
- [ ] Confirm a cardio exercise's History still reads cleanly
- [ ] In Korean, confirm 계획 강도 reads as something you planned, not something
      you achieved

What to report:

- History showing a different target than the workout was started with,
  especially after you edit the routine
- a planned-effort line on an exercise you never set a target for
- wording in either language that sounds like the app recorded your actual
  effort
- the line cut off or crowding the rows below it, and on which phone

---

### Settings, After the Showcase Was Removed (Build 10)

Removed in Build 10: the **Showcase / Calculus Analytics** row in Settings. It
was a development demo that had no business in a build you installed, and it is
gone from tester builds. Nothing else in Settings changed.

- [ ] Open **Settings** and confirm there is no "Showcase" or "Calculus
      Analytics" row
- [ ] Confirm Units, Bodyweight, Autoregulation, Defaults, Data and Help are all
      still present and still work
- [ ] In Korean, confirm Settings has no leftover English-only section

What to report:

- a "Showcase" or "Calculus Analytics" row still appearing
- any Settings row that used to be there and now is not
- any remaining English text on the Korean Settings screen

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
- Cardio ~~is supported as duration-based logging only~~ **now has dedicated
  fields** (see below); the "details go in notes" limitation above applied to the
  first beta build only.

### Cardio, as it stands

What testers can use:

- **Dedicated cardio exercises** — Time-based + Cardio, with Walking, Treadmill
  Run/Walk, Stationary Bike, Elliptical, Stair Climber and Rowing Machine seeded.
  If you used an earlier build, the app offers **once** to convert the cardio
  exercises you already have; declining changes nothing.
- **Logging** — duration, plus optional distance, average heart rate, heart-rate
  zone, calories, incline/decline and resistance under **Details**. Pace and
  speed are derived as you type.
- **Distance unit** — chosen once in Settings (km / mi) and used everywhere.
  Changing it re-reads every existing number; nothing stored changes.
- **Routine targets** — a cardio slot can carry a target distance, and starts at
  one set with no rest.
- **Prefill** — a cardio set starts from what you did last time (distance,
  incline, resistance), never from that session's *results* (heart rate, zone,
  calories).
- **History** — a per-bout summary line, plus distance / duration / pace /
  calories / average-heart-rate series in the Progression chart.
- **Structured cardio** — a cardio slot can carry a planned segment list
  (warm-up / work / recovery / cool-down). It shows as a **Cardio Plan**
  checklist during the workout, the ticks survive Save & Exit, and completed
  History shows the plan the workout was started with.
- **Routine transfer** — exported/imported routines keep their structured
  segments; routine files from older builds still import.

Known deferrals — please don't report these as bugs:

- **Repeat / interval authoring** (`5 × (1 min hard / 2 min easy)`) has no editor
  yet. A plan is an ordered list of segments.
- **Per-segment results.** The checklist is a plan you tick, not a log: ticks are
  not saved to History, and a bout is recorded as **one cardio set**. So an
  interval session charts as one average pace.
- **No GPS, route maps, HealthKit, Apple Watch, or automatic tracking** of any
  kind. Every number is one you enter.
- **No segment-level charts, analytics, or CSV columns** — the exports and charts
  are per-bout.

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

1. Prepare the Build 9 TestFlight build and internal notes.
2. Invite the first small group of testers.
3. Share tester instructions and the testing checklist.
4. Collect feedback into the Feedback Log above.
5. Triage feedback by severity (P0–P3).
6. Fix clear P0/P1 issues; defer P2/P3 as appropriate.
7. Record outcomes in `docs/ENTRY_12_TESTFLIGHT_FEEDBACK.md`.

TestFlight testing is planned but has not started yet.

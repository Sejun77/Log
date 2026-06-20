# Entry #11 Workout Testing Notes

This file is the detailed, real-device workout testing record for Entry #11.
It exists so the high-level status in `ENTRY_11_DESIGN_RELEASE_PLAN.md` stays
focused on release planning, while the full per-workout test evidence (friction,
bugs, and follow-ups captured while it was fresh) lives here.

---

## Purpose

Capture the raw notes from actual workouts run on a physical iPhone during the
Entry #11 release-readiness phase. These notes drive the polish slices and
document what was — and was not — exercised end-to-end on device. The design
release plan links here instead of carrying the long logs inline.

---

## Test Summary

- **Workout tests completed:** 3
- **Device used:** iPhone 13 Pro (consistent across all three tests)
- **Major result:** The full workout loop (start → prefill → log sets →
  keyboard/input → rest timer → Save & Exit / Resume → Finish → History) was
  exercised end-to-end on a real device across all three sessions.
- **Major follow-up issues:**
  - Weight / rep field switching is not smooth on the first instance and feels
    somewhat random (seen in Test 1, recurred in Test 3).
  - Setup Notes do not update when switching exercises (Test 2); want proper
    refresh of exercise info on switch, plus prefill from history when available.

---

## Workout Test 1

- Date: 6/14/2026
- Routine: Lower A + Upper A (Recovery)
- Device: iPhone 13 Pro
- Tested:
  - [x] start workout
  - [x] prefill
  - [x] log sets
  - [x] keyboard/input
  - [x] rest timer
  - [x] Save & Exit / Resume
  - [x] Finish → History
- What felt good: All green except what's specified below
- Issues / friction: Not switching smoothly across weight / rep fields on the first instance, somewhat random
- Follow-up: N/A

---

## Workout Test 2

- Date: 6/16/2026
- Routine: Lower B
- Device: iPhone 13 Pro
- Tested:
  - [x] start workout
  - [x] prefill
  - [x] log sets
  - [x] keyboard/input
  - [x] rest timer
  - [x] Save & Exit / Resume
  - [x] Finish → History
- What felt good: All green except what's specified below
- Issues / friction: Setup Notes not updating when switching exercise
- Follow-up: Proper update across exercise info when switching, also prefill from history if available

---

## Workout Test 3

- Date: 6/17/2026
- Routine: Upper B
- Device: iPhone 13 Pro
- Tested:
  - [x] start workout
  - [x] prefill
  - [x] log sets
  - [x] keyboard/input
  - [x] rest timer
  - [x] Save & Exit / Resume
  - [x] Finish → History
- What felt good: All green except what's specified below
- Issues / friction: Same issue as test 1
- Follow-up: N/A

---

## Consolidated Follow-Up

### Bugs

- **Weight / rep field switching not smooth on first instance** (Test 1, recurred
  in Test 3). Behavior feels somewhat random. Needs a confirmed reproduction
  (which field was focused, warm vs. cold start) before a fix is attempted.

### Design friction

- ✅ **RESOLVED — Setup Notes do not update when switching exercises** (Test 2).
  Fixed and **shipped on main** as the *Active Workout switch-exercise
  consistency* pass (`fix(active-workout): refresh switched exercise info and
  prefill`). Equipment & Setup now resolves from the session-start snapshot for
  non-swapped exercises and the live switched-in exercise for swapped ones; the
  same pass also fixed the blank Switch Exercise sheet, switched-in prefill,
  Bodyweight ↔ Barbell weight-field visibility, and stale Bodyweight dropset
  suppression. Validated: build succeeded, **875 tests / 0 failures** (16 in the
  new `SwitchExerciseConsistencyTests`), manual device testing confirmed.

### Active Workout hierarchy concerns

- The exercise-info refresh on switch is now **resolved** (see above). The
  remaining open item on this surface is the keyboard/input field switching
  friction (still unresolved — see Bugs). It remains an input for the deferred,
  higher-risk Active Workout visual-hierarchy / redesign work; confirm and
  reproduce on device before changing layout or behavior.
- Follow-up wishlist from Test 2: prefill exercise info from history when
  available.

### Release-readiness notes

- Real-device workout testing is **complete**: all three tests were real-device,
  end-to-end passes covering start workout, prefill, logging, keyboard/input,
  rest timer, Save & Exit / Resume, and Finish → History. Of the two usability
  follow-ups surfaced, the Setup Notes / switch-exercise refresh is now
  **resolved and shipped**; the field-switching friction remains monitor-only
  pending a deterministic reproduction. Neither was a flow-completion gap.

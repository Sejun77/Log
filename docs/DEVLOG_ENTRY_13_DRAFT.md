# Entry #13

**Working title:** Real-Workout Testing & Continued Refinement

**Date Range:** 2026-11-01 → ongoing

This entry begins after Entry #12's frozen 2026-10-15 cutoff.

Detailed findings live in `docs/ENTRY_13_TESTING_LOG.md`.

---

## Session Notes & Keyboard Interaction

**Status:** Open — investigating

**Source:** Personal real-workout testing

Observed facts only; no cause has been established.

Observed on a real iPhone during an actual workout:

1. Entering an existing Session Note can take about 1–2 seconds before the field
   becomes editable.
2. Once focused, typing itself is smooth.
3. Tapping the app's checkmark / Done control can cause a transient visual
   rendering glitch where part of the note briefly becomes dark / incorrectly
   rendered before settling normally.
4. The rendering glitch:
   - occurs even with a one-character note
   - occurs in fresh and resumed workouts
   - does not corrupt the saved text
   - does not occur when the keyboard is dismissed another way
   - has been observed on a real device
   - has **not** reproduced in Simulator so far
5. Keyboard / scrolling behavior is a separate reproducible symptom:
   - occurs on both real device and Simulator
   - tapping a field does not always scroll enough to keep the selected input
     line fully visible above the keyboard
   - after dismissing the keyboard, the active-workout page does not reliably
     return to the expected bottom position

It is not yet known whether these share one cause:

- focus-entry delay
- checkmark rendering glitch
- keyboard scrolling/restoration

This issue is not connected to the earlier caret/word-selection investigation
from Entry #12. That investigation concerned a different symptom and reproduced
independently outside Log.

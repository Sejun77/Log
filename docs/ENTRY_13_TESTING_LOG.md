# Entry #13 — Testing Log

This log holds findings for Entry #13, which begins on 2026-11-01. Findings are
kept distinct by source:

- **Personal real-workout findings**: what my own training sessions turn up.
- **Developer reproduction / investigation**: follow-up done to reproduce or
  narrow down a finding.
- **Peer / TestFlight re-test feedback**: what testers report later.

Details not recorded are marked _not recorded_ rather than guessed.

---

## Issue 1 — Session Notes & Keyboard Interaction

**Status:** Open — investigating

**Source:** Personal real-workout testing

Observed facts only; no cause has been established. It is not yet known whether
symptoms A, B and C share one cause.

This issue is being tracked separately from the earlier caret/word-selection investigation from Entry #12. That investigation concerned a different symptom and reproduced independently outside Log; no connection between the two has been established.

### Reproduction Matrix

| Symptom                                     | Real device | Simulator             |
| ------------------------------------------- | ----------- | --------------------- |
| A. Focus acquisition delay                  | Observed    | _Not recorded_        |
| B. Checkmark commit rendering glitch        | Observed    | Not reproduced so far |
| C. Keyboard visibility / scroll restoration | Reproduces  | Reproduces            |

### A. Focus acquisition delay

**Status:** Open — investigating

**Observed on a real iPhone during an actual workout:**

- Entering an existing Session Note can take about 1–2 seconds before the field
  becomes editable.
- Once focused, typing itself is smooth.

### B. Checkmark commit rendering glitch

**Status:** Open — investigating

**Observed:** Tapping the app's checkmark / Done control can cause a transient
visual rendering glitch where part of the note briefly becomes dark / incorrectly
rendered before settling normally.

| Condition                      | Result                |
| ------------------------------ | --------------------- |
| One-character note             | Occurs                |
| Fresh workout                  | Occurs                |
| Resumed workout                | Occurs                |
| Saved text                     | Not corrupted         |
| Keyboard dismissed another way | Does not occur        |
| Real device                    | Observed              |
| Simulator                      | Not reproduced so far |

### C. Keyboard visibility / scroll restoration

**Status:** Open — investigating

**Observed on both real device and Simulator:**

- Tapping a field does not always scroll enough to keep the selected input line
  fully visible above the keyboard.
- After dismissing the keyboard, the active-workout page does not reliably return
  to the expected bottom position.

**Expected behavior:**

- When a text input becomes focused, the screen should scroll enough that the
  active input line is fully visible above the keyboard.
- When the keyboard is dismissed, the active-workout screen should settle back to
  its normal expected position rather than remain stranded at an arbitrary
  keyboard-adjusted offset.

### Developer Reproduction / Investigation

_None recorded yet, beyond the Simulator results in the matrix above._

### Peer / TestFlight Re-test Feedback

_None recorded yet._

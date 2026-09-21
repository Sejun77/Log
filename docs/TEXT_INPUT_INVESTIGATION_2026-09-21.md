# Text Input Investigation — 2026-09-21

> **Do not restart this investigation at the Log level without new evidence.**
> The behavior was reproduced in independent stock SwiftUI and UIKit apps on
> two physical devices. No Log-specific cause was found and no Log-specific
> fix is warranted. If you revisit it, start from the independent UIKit
> reproduction — not from `ActiveWorkoutView`.

Branch used: `fix/text-selection-and-field-focus` (cleaned back to its starting
HEAD; nothing from this investigation was committed).

---

## Original symptoms

**Session Notes**
- typing-performance complaints
- the caret could not reliably be placed inside a word
- word selection / double-tap behaved inconsistently
- an earlier trailing blank-space problem on long notes

**Active workout reps / weight**
- switching between fields became unreliable near the keyboard
- bottom fields could end up covered by the keyboard

---

## Previously validated fixes that remain

All of these were merged **before** this investigation and must not be
reverted:

- `TextDraftController` / local draft isolation (`Log/UI/TextDraft.swift`)
- removal of per-keystroke `ActiveWorkoutView` / global-guard publication work
- Session Notes committed at persistence boundaries — focus loss, Save & Exit,
  Finish, and lifecycle transitions
- exercise-name local draft
- the long Session Notes blank-space / layout fix

This investigation ended with the working tree byte-identical to HEAD, so none
of the above was touched.

---

## Hypotheses tested and falsified

None of these resolved the device behavior. Each is recorded at the strength it
was actually measured — several were only ever assumptions.

| Hypothesis | Outcome |
|---|---|
| `UIScrollView.delaysContentTouches` | changed; did not resolve |
| `safeAreaInset` bottom-panel reservation | changed; did not resolve |
| `FocusState` identity collision | investigated; not the cause |
| generic `List` touch interception | did not explain the behavior |
| `DraftNotesField` specifically | reproduced without it |
| `TextField(axis: .vertical)` specifically | reproduced with a plain one |
| `TextEditor` as an assumed fix | assumed, never validated; reproduced too |
| TextKit 2 specifically | TextKit 1 reproduced identically |
| the diagnostic gesture observer as the cause | reproduced with the observer fully off |
| spell-check / autocorrection as root cause | assumed, never proven |

---

## Device measurements worth keeping

From the tested iPhone layout, before the investigation moved above Log:

- the keyboard top sat around **y = 488**
- a low field could be focused *before* the keyboard presented, remain behind
  the keyboard afterwards, and only later be scrolled upward by SwiftUI
  (observed: `contentOffset.y` 386.7 → 574.7, focused field 676..710 → 397..431)
- switching to the sibling reps/weight field in the same row could still fail
  **after** that automatic scroll had made the row visible

The diagnostic harnesses that produced these numbers were temporary,
uncommitted investigation code and were removed because no production fix was
validated.

---

## Isolation results

This is the part that matters.

**1. Log root-level isolation.** A debug-only root was rendered in place of the
normal app hierarchy — no model container in use, no `\.font` environment
override, no tint, no `TabView`, no `NavigationStack`, no overlays, no `List`.
The PURE layer, containing only stock SwiftUI controls, **still reproduced** the
caret behavior. The layer ladder above it was therefore never needed.

**2. Independent fresh SwiftUI app** (no Log code, no SwiftData):

| Control | Result |
|---|---|
| single-line `TextField` | reproduced |
| `TextField(axis: .vertical)` | reproduced |
| `TextEditor` | reproduced |

Reproduced both when launched from Xcode and when launched from the Home
Screen.

**3. Independent UIKit app** (no SwiftUI at all, no custom gestures, no
delegates touching selection):

| Control | Result |
|---|---|
| plain `UITextField` | reproduced |
| `UITextView(usingTextLayoutManager: true)` — TextKit 2 | reproduced |
| `UITextView(usingTextLayoutManager: false)` — TextKit 1 | reproduced |

**4. Physical devices**

- iPhone, iOS 26.6.2 — reproduced
- iPad, iPadOS 26.6.2 — reproduced
- an iPad TestFlight build of Log also reproduced the core behavior
- the secondary selection UI differed between iPhone and iPad; the underlying
  caret-placement behavior did not

**Observed behavior, consistently across all of the above:** a single tap could
not reliably place the caret between characters inside a word; it snapped to
the word start or end, or selected the whole word. "No Replacements Found"
could appear. Double-tap selection was inconsistent. Other apps already
installed on the same devices behaved normally.

---

## Current conclusion

> The caret/word-selection behavior was reproduced in completely independent
> stock SwiftUI and UIKit applications on two physical devices running 26.6.2.
> No Log-specific production cause or fix was established. The issue therefore
> should not currently be worked around in Log without new evidence.

Deliberately **not** claimed: that this is an Apple bug, a TextKit bug, a
Natural Selection bug, or gated on the SDK an app links against. None of those
were tested and none should be repeated as findings.

---

## Repository state at close

- `fix/text-selection-and-field-focus` cleaned back to its starting HEAD
- working tree clean; no production change came out of this investigation
- all temporary diagnostics, labs, and isolation harnesses removed
- the UIKit reproduction lives **outside** the Log repo at
  `~/Developer/CaretUIKitScratch/`

---

## Future guidance

**Do not restart the same Log-level investigation unless new evidence appears.**
If you do revisit it, start from the independent UIKit reproduction, not from
`ActiveWorkoutView`.

Comparisons that could be worth making, in rough order of cost:

- a different OS generation on the same hardware
- a different SDK / Xcode generation building the same reproduction
- a minimal Apple Feedback reproduction

None of these are required for current Log development.

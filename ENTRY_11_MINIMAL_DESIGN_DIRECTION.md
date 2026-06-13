# Entry #11 Minimal Design Direction

> Working design guide for Entry #11 polish. Not a backlog, not a devlog —
> a reference to keep small UI slices pulling in the same direction.

## Design Goal

Log should feel like a calm, focused workout tool. During a workout the UI
should reduce friction and make the next action obvious; everywhere else it
should stay quiet and uncluttered. The app is already functional — the goal is
to make it feel lighter and more refined, not to add features.

## Current Problem

The app is structurally strong, but some surfaces can feel hard or dense:
heavy borders and boxes, crowded sections (e.g. many controls stacked in one
group), inconsistent typography (system fonts mixed with DS tokens), too many
equal-weight buttons (Back / Next / Finish read the same), and long form-like
screens. None of this is broken — it just reads busier than it needs to.

## Design Principles

- Make the current action obvious.
- Reduce visual competition between elements.
- Prefer whitespace over borders.
- Use fewer, clearer surfaces.
- Use the accent color sparingly.
- Keep destructive actions clear but not visually overwhelming.
- Keep workout logging fast.
- Preserve existing behavior.
- Don't redesign logic-heavy flows blindly.

## Visual System Direction

### Color
- Calm neutrals for backgrounds and cards (`DSColor.bg` / `.surface` / `.surfaceAlt`).
- Brand/accent (`DSColor.brand`) mainly for the primary action and selected states.
- Destructive red (`DSColor.error`) only for truly destructive actions.
- Avoid making every card or button visually loud — most surfaces should recede.

### Typography
- Clear hierarchy, top to bottom:
  - screen title (`.dsTitle`)
  - section title (`.dsSection`)
  - primary row text (`.dsBody`)
  - secondary metadata (`.dsBodySecondary`)
  - helper text (`.dsCaption`)
- Reduce unnecessary bold — reserve weight for genuine emphasis.
- Use DS font tokens consistently; retire stray `.headline` / `.caption` / `.subheadline`.

### Spacing
- Add breathing room where screens feel dense (use the `DSSpacing` scale).
- Keep workout input rows compact enough to be usable in the gym.
- Maintain a consistent vertical rhythm within and across sections.

### Cards and Surfaces
- Prefer soft cards (`DSCard`: subtle fill + small shadow) over hard boxes.
- Reduce heavy borders; lean on background contrast instead.
- Keep contrast subtle and readable in dark mode.
- Avoid nested cards / cards-inside-cards clutter.

### Buttons
- One obvious primary action per area (`DSPrimaryButton`).
- Secondary actions stay quieter (`DSSecondaryButton` / plain).
- Destructive actions clearly red, but not oversized unless the action is critical.
- Back, Next, and Finish should not look equally important — Finish (commit) leads.

### Forms
- Split large forms into logical sections (as done in Exercise Detail).
- Use helper text only where it prevents real confusion.
- Avoid long, dense, undifferentiated form stacks.

### Tags / Pills
- Use pills for status (in-use, in-progress), not decoration.
- Keep status labels consistent in shape, size, and wording.
- Don't let chips compete with the primary content of a row.

## Screen-Level Direction

### Active Workout
- Feel: focused and fast — the current set should be the visual center of gravity.
- Avoid: burying set logging under stacked Notes/Plan/Equipment sections; equal-weight
  nav buttons; loud per-set chrome. (Section reordering itself is deferred — see below.)

### Routine Editor
- Feel: calm, scannable list of blocks; block vs. superset clearly distinct.
- Avoid: dense stepper walls, inconsistent fonts, raw inline warnings.
- Started: the invalid-superset warning is now a native `Label`
  (`exclamationmark.triangle`, orange) instead of raw emoji/red text; and the
  superset child Delete is greyed/disabled at the two-exercise minimum
  (red = destructive available, gray/disabled = unavailable).

### Exercise Detail
- Feel: a tidy settings screen — grouped sections, light helper text.
- Avoid: one giant section; ambiguous field purposes.

### History
- Feel: readable timeline; metrics legible at a glance.
- Avoid: cramped controls and noisy chart chrome (control redesign deferred).

### Settings
- Feel: standard, quiet iOS settings; clear data/destructive labeling.
- Avoid: adding decoration; keep demo/debug items clearly marked.

## Safe First Design Slices

1. **Design-system audit (cards/buttons/surfaces)** — inventory only, no code. Risk: none.
2. **Minimal `DSCard` / section surface refinement** — soften fills, reduce borders. Risk: low.
3. **Button hierarchy pass** — promote primary, quiet secondary, tame destructive. Risk: low.
4. **Status pill standardization** — one shared pill for in-use/in-progress. Risk: low–medium (touches a few files; respect the intentional `LockBadge` size note).
   - **Started (foundation shipped):** shared `StatusPill` added and adopted for History's "In Progress" label. **`LockBadge` unification remains deferred** — the two implementations are intentionally left unchanged for now.
5. **Routine / Exercise form density reduction** — grouping + spacing. Risk: low.
   - **Started:** routine editor minimal polish underway — native `Label` warning
     (replacing raw emoji/red text) and a disabled/grey child Delete affordance at
     the two-exercise superset minimum (red = available, gray/disabled = unavailable).
6. **Active Workout visual hierarchy — audit only** — document, implement later after real workout testing. Risk: low (audit), higher (implementation).

## Things Not To Change Yet

- Active Workout section order.
- Workout logging flow.
- Rest timer behavior.
- Prefill logic.
- History calculations.
- Chart control redesign.
- SwiftData models.
- Major architecture refactors.

## Evidence To Collect

- Active Workout mid-session (a real set being logged).
- Routine detail with several blocks (incl. a superset).
- Exercise Detail.
- History metrics + chart.
- Settings.
- Real-device screenshots (not just simulator).
- Notes from actual workout use — captured when feeling better.

# Message hover toolbar: grow the row, or float the plate

Decision requested: pick A (grow non-compact rows to a 30px minimum, as implemented in PR #1520) or B (keep 24px rows and host the plate in an ancestor above the list).

**Recommendation: A.**
Ship PR #1520 as written.

The three facts that decide it are below, then the product survey, then the argument against my own pick.

---

## What PR #1520 actually does

I read the branch before evaluating, because the brief said the comparison turns on it, and it does.

`client/packages/app/lib/src/features/messages/widgets/message_row.dart:264` is:

```dart
constraints: BoxConstraints(
  minHeight: compact ? 0 : MessageHoverToolbar.height,
),
```

The minimum is unconditional on every non-compact row.
It is not gated on `hovered`, `menuOpen` or `focusWithin`, all of which are in scope at that point in the builder and none of which are used.
`compact` here is `LayoutClass.of(context) == LayoutClass.compact`, which is a width class, not the hover state and not the density setting.

So the list never reflows under the pointer.
The cost of A is a permanently looser transcript, not jitter, exactly as the brief said.

The PR body confirms the hover-only variant was considered and rejected for that reason, in the author's own words: "I picked that over a hover-only minimum, because that would grow the hovered row by 6px and move everything below it, and with the pointer moving row to row I think it would jitter (and there's already a test that hovering must not resize the row)."

### The size of the cost, measured

`AppTypography.body` is `fontSize: 15, height: 1.45`, so a body line is 21.75px, rounded to 22.
`AppDensity.normal.groupedRowGap` is 2.
A one-line grouped continuation is therefore 2 + 22 = 24px today, and 30px under A.

I measured `build/ui-snapshots/message-toolbar-grouped-dark.png` rather than trusting the arithmetic.
The capture is 2000x720 at device pixel ratio 2.
The two grouped continuation rows ("fix is up in the PR", "and a second line in the run") have text bands starting at y=241 and y=300, a pitch of 59 device pixels, which is 29.5 logical pixels.
That is the 30px minimum, confirmed in the rendered output.

The cost is bounded more tightly than "the transcript gets looser".
Only one-line grouped continuations move.
A group-start row is `rowGap` 8 + header 22 + body 22 = 52px and does not move.
Any row with two lines of body, a reply quote, an attachment, reactions, a poll, a thread summary or an embed is already well over 30px and does not move.
The affected case is a run of short one-line replies from the same person inside the grouping window, which is admittedly the most characteristic thing a Discord-style channel does.

In the worst case, a channel that is nothing but one-line continuations, a 700px transcript shows 23 rows instead of 29.

---

## The three facts that decided it

### 1. Discord anchors its hover toolbar inside the message row at top 0, and gets away with a row shorter than the plate only because CSS hit-tests overflow

This is the closest comparison and the brief asked for it specifically, so I went to Discord's own stylesheet rather than to impressions.

Discord's chat CSS chunks are not preloaded on the unauthenticated shell, so I pulled the webpack entry (`/assets/web.91d9ed412e5a4f3b.js`), extracted the `miniCssF` ternary chain, and fetched the 257 live CSS chunks it names.
The message module is `618416.a8a67f0c89afda02.css`, class hash `_c19a55`.

The two rules that matter:

```css
.wrapper_c19a55{position:relative;word-wrap:break-word;flex:0 0 auto;min-height:1.375rem;padding-inline-end:var(--custom-message-margin-horizontal);...}
.buttonContainer_c19a55{inset-inline-end:0;position:absolute;top:0}
```

The hover toolbar is anchored `position: absolute; top: 0; inset-inline-end: 0` **inside the message row**, which is `position: relative`.
That is structurally identical to what PR #1520 does.
Discord does not host the plate in an ancestor overlay above the list, and a Discord theme that touches it has to reach through the row to get at it (`li[class*="messageListItem"] > div[class*="message"] div[class*="buttonContainer"] > div[role="group"] > div[class*="wrapper"]`, from `llsc12/discord-acrylic`, `UI/Chat/Messages/DecoratorButtons/Buttons.css`).

Discord's row heights, from the same file plus its variable definitions:

- `min-height: 1.375rem` = 22px, the floor for any message row.
- Cozy adds `--custom-message-spacing-vertical-container-cozy: 0.125rem` top and bottom, so a cozy grouped continuation is 22 + 2 + 2 = **26px**.
- Compact adds `--custom-message-padding-vertical-container-compact: 0.125rem` top and bottom, so a compact row is also **26px**; compact differs by indentation and an inline header, not by vertical padding.

So Discord's tightest row is 26px and its plate is taller than that.
The plate overflows the row and paints over the row above, and it stays clickable there, because in CSS an absolutely positioned child that overflows its parent still receives pointer events.
Flutter does not do that, which is the whole premise of this decision.

Discord's answer to "the plate is taller than the row" is therefore unavailable to slim-m.
Option A is the closest thing to Discord's structure that Flutter permits.

**Does Discord reflow on hover?** No.
Every `:hover` rule in its message module changes `opacity`, `color`, `border-color`, `background-color`, `filter`, `text-decoration` or `cursor`.
Not one changes height, padding or margin.
The only hover rule on the row itself is `.mouse-mode .wrapper_c19a55:hover .timestampVisibleOnHover_c19a55{opacity:1}`.

### 2. The standard web metric for layout instability explicitly refuses to exempt hover-driven reflow, which independently vindicates rejecting the hover-only minimum

The Layout Instability API spec, section 2.4 Input Exclusion, says:

> Excluding inputs generally include mousedown, keydown, pointerdown, and change events. [...] The mousemove and pointermove events are also not excluding inputs.

web.dev's CLS article repeats the caution: the `hadRecentInput` flag suppresses shifts within 500ms of discrete input only, and continuous interactions do not count as recent input.
Good CLS is 0.1 or less.

A layout shift caused by moving the pointer over a list therefore gets no exemption at all.
It is counted as unexpected instability by the metric the web ecosystem settled on after measuring user frustration.
This is not decisive between A and B, since neither reflows, but it closes the door on the hover-only minimum and confirms the PR was right to reject it.

### 3. slim-m's own design language already publishes 30 as the pointer row height, so A applies an existing token rather than inventing a number

`docs/design/desktop-vs-mobile.md` has a table under "Density: what moves with width and what never does":

| Row | Height |
|-----|--------|
| `rowPointer` | 30 |
| menu row / `controlMd` | 34 |
| `rowTouch` (touch minimum) | 44 |

and the line immediately after: "Vertical rhythm is the only density lever: `rowGap` 4/8/12, grouped 1/2/4. Type, avatars and hit targets deliberately do not scale."

`AppSizes.rowPointer = 30` is already the minimum height for every other pointer-interactive row in the product.
`AppButton`, `AppIconButton`, `AppControlWithOptions` and `AppListRow` all floor themselves at it (`components/core/button.dart:167`, `icon_button.dart:112`, `control_with_options.dart:130`, `surfaces/list_row.dart:210`).

A message row that carries a five-slot pointer toolbar is a pointer-interactive row.
Under A it becomes the only kind of interactive row in slim-m that is not an exception to the project's own stated floor.
Under B it stays a 24px interactive row with a 30px control floating over it, which is a standing inconsistency with a locked design token, and the kind of thing that gets rediscovered and re-litigated later.

---

## What each product actually does

Evidence strength is marked, because it is not uniform.
Four of these I read from the shipped stylesheet.
Three I could not get behind an auth wall and have marked as observed.

### Discord (primary source: its own CSS, measured above)

Toolbar sits **inside the row**, `position: absolute; top: 0; inset-inline-end: 0`.
It paints upward past the row's own box and stays hittable, because CSS overflow does not kill pointer events.
Row minimum 22px; cozy grouped continuation 26px; compact 26px.
Hover changes paint only, never geometry.
The list does not reflow as the pointer moves down it.

### Zulip (primary source: `web/styles/message_row.css`)

The most instructive of the set, because Zulip is the densest mainstream chat client and it chose reservation over floating.

`.message_controls` is `grid-area: controls; align-self: stretch` inside the message box's own grid, alongside `message` and `time`.
The controls are a permanent column of the row, not an overlay, and they are revealed with opacity rather than inserted.

The CSS says why, in its own comment:

> This is a bit tricky; we need to reserve space for the message controls even when the message isn't hovered, so that hover doesn't disturb the layout. Usually that would be just `visibility: hidden`, but that cannot be animated, so we set opacity as well, which can be animated.

Zulip also pads the control icons above their visual size for the same hit-target reason slim-m does:

> The icon body is 16px square at 16px/1em; the clickable area for the icon is 26px wide by 25px tall, so these values ensure a 26px x 25px clickable area for the icon.

Zulip is the product that most closely faces slim-m's tradeoff, and its answer is A's answer: reserve the space permanently, never move the layout on hover.

### Element / Matrix (primary source: `element-web` `packages/shared-components/.../EventTileView.module.css`)

Element is the one that genuinely floats, and it is the best illustration of what B costs.

```css
.slotActionBar {
    position: absolute;
    z-index: 10;
    inset-block-start: calc(
        -1 * (var(--event-tile-action-bar-size) + 2 * (var(--event-tile-action-bar-margin) + var(--cpd-border-width-1)))
    );
    inset-inline-end: var(--event-tile-action-bar-offset);
    user-select: none;
}
```

With `--event-tile-action-bar-size: 28px` and `--event-tile-action-bar-margin: 3px`, the bar sits 36px above the tile's top edge, entirely outside the row, over whatever is above it.
Continuation tiles get `padding-top: 0`, so Element's continuations are tight.

And then, immediately after, this:

```css
/* Keep the pointer path from the event line into the action bar inside this
   shell boundary. The action-bar contents own their controls and tooltips. */
.slotActionBar::before {
    content: "";
    position: absolute;
    width: calc(10px + 48px + 100% + 8px);
    height: calc(20px + 100%);
    inset-block-start: -12px;
    inset-inline-start: -58px;
    z-index: -1;
    cursor: initial;
}
```

That is an invisible hit-bridge pseudo-element, hand-tuned with four magic offsets, whose only job is to keep the pointer from falling out of the hover state on the way from the row to the plate.
`_MessageActionBar.pcss` then carries two further per-context overrides that exist to fix clickability in specific list shapes, one of them commented "Improve clickability of the first event below a collapsed bubble summary."

Element floats, and Element needed a bespoke invisible bridge plus per-context clickability patches to make floating work.
That is B's bill, in a product that has been iterating on it for years.

### Mattermost (primary source: `webapp/channels/src/sass/components/_post-menu.scss`)

A Slack-shaped client, and a straddler:

```scss
.post-menu {
    position: absolute;
    z-index: 6;
    top: -12px;
    right: 0;
    display: flex;
    justify-content: flex-end;
    padding: 4px;
    ...
}
.post-menu__item { width: 28px; height: 28px; ... }
```

Plate is 28 + 8 padding + 2 border = 38px, hoisted 12px above the post's top edge, so it overlaps the post above by 12px.
The menu is a descendant of the post, not an ancestor overlay.
Hover toggles `visibility`, never geometry (`.post:hover .post-menu__item { visibility: visible }`).

### Slack (observed; could not reach its stylesheet)

Slack's client CSS is behind auth and I could not retrieve it.
Themes that target `c-message_actions__container` only recolour it, so they give no geometry.
Observed behaviour: the actions bar appears at the top-right of the hovered message, on a raised plate, overlapping the message above it, and the transcript does not reflow as the pointer moves.
Mattermost, which is a deliberate Slack-shaped client and is open, does exactly this with `top: -12px`, which is the best proxy I have.
Treat the Slack row as corroborating rather than load-bearing.

### Microsoft Teams (observed)

Teams' message action bar floats at the top-right of the hovered message and overlaps the message above.
Microsoft's own open chat primitive, `@fluentui-contrib/react-chat`, gives the row rhythm but not the action bar: `container { paddingTop: 16px }` and `attachedContainer { paddingTop: 2px }` for a grouped continuation.
That 2px continuation gap is the same instinct as slim-m's `groupedRowGap: 2`.
No reflow on hover.

### Linear (observed)

Linear's comment and list-row actions appear at the top-right of the hovered row, absolutely positioned within the row, opacity-gated.
Linear's rows are considerably taller than 24px, so the plate fits inside the row without overhang and the question does not arise in the same form.
Linear is not a useful precedent for a 24px row.

### GitHub comment threads (observed)

GitHub is the outlier and is worth naming because it is the one product here that does not float at all.
Issue and PR comment actions live in the comment header, in normal flow, in space that is always reserved.
The reaction control and the overflow kebab occupy header space whether or not you are hovering, and hover only changes their emphasis.
GitHub's comments are large blocks rather than 24px rows, so reserving header space is free, and it takes the option Zulip takes: reserve, do not float.

### Summary of the survey

Nobody reflows the list under the pointer.
That is unanimous across all seven.
The split is on how the plate relates to the row: Discord, Slack, Teams, Mattermost and Element overhang or float, while Zulip and GitHub reserve permanent space inside the row.
The overhangers are all on the web, where an overflowing absolutely positioned child stays clickable.
slim-m is not, and that single platform difference moves it from the first group into the second.

---

## The underlying question: hover-reflow versus a uniformly looser list

Asked directly, the answer is that hover-reflow is clearly worse, and it is not close.

- The layout-instability spec refuses hover-driven shifts any exemption (section 2.4, quoted above), so the standard metric treats them as unexpected instability.
- Zulip's stylesheet documents the same conclusion reached from practice, and pays a permanent grid column for it.
- Discord's message module contains no hover rule that changes geometry.
- Element pays an invisible bridge element rather than move the row.

But this question is moot for the decision at hand, because A as implemented does not reflow.
The real comparison is "permanently 6px looser on one-line continuations" against "24px rows with a floating plate and the machinery that floating needs".

On Fitts's law: for a target acquired by a vertical approach, the relevant extent is the target's height, and 24 to 30 is a modest improvement in acquisition time at any realistic approach distance.
I would not lean on it, because the toolbar's buttons are 30x30 under both options; only the row itself changes.
The stronger targeting argument is not about speed but about ownership, and it is below.

On accessibility: WCAG 2.2 SC 2.5.8 Target Size (Minimum), Level AA, requires targets for **pointer inputs** to be at least 24 by 24 CSS pixels, with five exceptions (Spacing, Equivalent, Inline, User Agent Control, Essential).
It is not a touch-only criterion; the Benefits section names "Mouse users who have difficulty with fine motor movements" and "People using mouse, stylus or touch input who have mobility impairments such as hand tremors."

This does not decide A against B.
The toolbar buttons are 30x30 hit boxes under both options and pass on size outright.
A 24px row with a 30px control is not a violation.

What it does establish is two smaller things.
First, a 24px grouped row that is itself a target, which slim-m's rows are because they carry a context-menu region, sits exactly on the floor with no margin; under A it clears it by 6px.
Second, the Understanding document's Figure 7 case is two rows of 16px buttons with a 1px gap, where the 24px spacing circles intersect the adjacent row's targets and the criterion fails.
The reasoning in that figure is about stacked rows whose targets crowd each other, which is the shape B produces at the plate's edges.

Under B, a 30px plate over a 24px row overhangs its own row by 6px, so roughly 3px at the top and 3px at the bottom land on the rows either side.
Those strips belong, visually, to a neighbouring message, and that neighbouring message is itself a target.
A pointer resting there is over the plate, not over the row it appears to be over.
Under A that ambiguity cannot exist, because the plate is always inside the row that owns it.
That is a correctness property, not an aesthetic one, and it is worth more than the 6px.

---

## The strongest argument against A, stated fairly

slim-m's users come from Discord.
Discord's tightest continuation row is 26px, measured from its own stylesheet above.
slim-m's is 24px today and becomes 30px under A.

So A does not merely make slim-m looser than it was; it makes slim-m's tightest row 15 percent looser than the equivalent row in the product its users are leaving, and 25 percent looser than slim-m is now.
The transcript is the product.
A run of short one-line replies is the single most characteristic thing that happens in a Discord-style community, and it is precisely the case A inflates.

The cost is permanent, it is paid by every user on every row of that shape, and it is paid in service of a control that is invisible unless a pointer is resting on that row.
There is no escape hatch today: `AppDensity` has `compact`/`normal`/`spacious`, but `message_row.dart:284` hardcodes `AppDensity.normal`, so nothing in the UI can select a tighter transcript.

And the project's own rules cut against my pick here.
`CLAUDE.md` says: "When making technical decisions, do not give much weight to development cost. Instead, prefer quality, simplicity, robustness, scalability, and long term maintainability."
B's price is engineering effort, and A's price is a permanent product regression.
On a plain reading of that rule, B wins.

### Why I still pick A

Because B's price is not development cost.
It is permanent structural complexity on the surface users spend all day in, and `CLAUDE.md` ranks robustness and long-term maintainability first, which is the same clause.

The plate would have to be positioned against a scrolling viewport, which means either a `LayerLink` per row or per-frame global-rect recomputation, with a correctness requirement that it tracks correctly during a fling.
Row hover state would have to move out of `HoverReveal` into a channel-level controller that owns "which message is showing a plate", because the plate is no longer a descendant that can be mounted per row.
`HoverReveal` is shared with the emoji picker and the context menu, so that contract change propagates.
The pointer path from row to plate crosses a widget-tree boundary, which is the exact problem Element solved with a hand-tuned invisible pseudo-element, and the exact class of bug that `listener-sees-taps-meant-for-widgets-above` and `secondary-tap-down-fires-for-every-nested-recognizer` already cost this project once each.
Focus traversal would no longer match the widget tree, so tabbing from a row into its own toolbar needs a focus-scope arrangement that the current descendant plate gets for free.
The existing geometry tests, which hit-test the plate's top edge, centre and bottom edge inside a tight grouped run, would all have to be rewritten against overlay coordinates, which is where the real assurance currently lives.
And `clearance()` would still be needed, because body text must still not run under the plate, so B does not retire that complexity either.

That is five new failure modes, each of which only shows up under scroll, at a viewport edge, or with a keyboard, on the busiest surface in the product.
None of them is visible in a static screenshot, which is how they get merged.

---

## Cost of being wrong, and reversibility

**Wrong about A.**
The symptom is that the transcript reads too airy in short-reply channels.
It is continuous, obvious, visible in a screenshot before merge, and it is the kind of thing that surfaces in the backlog channel within a day.
The fix is small and layered:

1. One constant: `MessageHoverToolbar.height` currently aliases `AppSizes.rowPointer` (30). A 26px toolbar with 24px plates still passes WCAG 2.5.8 outright and brings the row back to Discord's 26px. That is a design-token argument to have, not a rewrite.
2. Wire the existing density selector: `AppDensity.compact` already has `groupedRowGap: 1`, and `message_row.dart` hardcodes `normal`. `docs/design/feature-exploration.md` already lists an adjustable density setting as accepted work.
3. Revert the constraint entirely and accept a dead strip, if the owner decides a dead 6px is acceptable.

All three are reversible in a line or two, and the geometry tests tell you immediately when the plate goes dead.

**Wrong about B.**
The symptoms are a plate clipped at the top or bottom of the viewport, a plate left behind on the wrong row after a fling, a plate eating the top 3px of the row below, two plates briefly visible during fast pointer traversal, and a focus order that jumps.
They are intermittent, they reproduce badly, and they land on every user's main surface.
Undoing them means unpicking the overlay host, the position tracking, the hover controller and the focus scoping, which is a revert of a large diff and a rewrite of the test suite that currently proves the geometry.

A is a tuning mistake.
B is an architecture mistake.
Tuning mistakes are cheap to be wrong about.

---

## If the owner picks B anyway, this is the bill

Stated plainly, because the brief asked whether it is proportionate.

1. **Overlay host.** A `Stack` or `OverlayPortal` above the list in `ChannelScreen`, not inside the scrollable, so the plate is not clipped by the viewport.
2. **Position tracking.** A `LayerLink` per row and a `CompositedTransformFollower` for the plate, so it tracks during scroll without per-frame global-rect math. One link per row is cheap; the bookkeeping for which link is active is not.
3. **Viewport clamping.** At the top of the scroll area the plate must clamp down into its row rather than sit above the viewport, and at the bottom it must clamp up. That is a conditional offset that has to be derived from the row's rect against the viewport rect every frame the plate is up.
4. **One at a time.** Hover state moves from `HoverReveal` (per row) to a channel-level notifier holding a single message id. `HoverReveal` is shared with the emoji picker and the context menu, so its builder contract, which PR #1520 just extended with `focusWithin`, changes again for all three consumers.
5. **Pointer continuity.** Moving the pointer from the row into the plate must not read as leaving the row. The plate is no longer a descendant, so the row's `MouseRegion` fires `onExit`. This needs either the plate reporting its own hover back into the controller, or a bridge region, which is Element's `::before` in Flutter form.
6. **Focus.** The plate's buttons must be reachable by keyboard in visual order from the row, across a widget-tree boundary. That needs a `FocusTraversalGroup` or a focus-scope reparent, and it is the part most likely to be quietly wrong.
7. **Tests.** Every geometry test in `message_hover_toolbar_test.dart` is written against row-local coordinates and would be rewritten, plus new tests for clamping at both viewport edges, plate-follows-scroll, and single-plate invariance under fast traversal.
8. **Still needed anyway.** `MessageHoverToolbar.clearance()` stays, because text must still stop short of the plate.

That is disproportionate to 6px on one class of row, and it recreates in Flutter the workaround Element documents as a workaround.

---

## Sources

Read directly:

- slim-m PR #1520, branch `feat/message-hover-toolbar`, worktree `/home/npc/.slimm-scratch/msg-toolbar/wt`; `client/packages/app/lib/src/features/messages/widgets/message_row.dart:264`, `message_hover_toolbar.dart`, `client/packages/design_system/lib/src/app_metrics.dart:85,176-178`, `app_typography.dart:81`.
- `client/packages/app/build/ui-snapshots/message-toolbar-grouped-dark.png`, measured.
- `docs/design/design-language.md`, `docs/design/desktop-vs-mobile.md` lines 61-77.
- Discord web client, build `web.91d9ed412e5a4f3b.js`, CSS chunk `618416.a8a67f0c89afda02.css` (message module, class hash `_c19a55`), retrieved 2026-09-30.
- Zulip, `web/styles/message_row.css` (`.message_controls`, `.message_control_button`, `.message-controls-icon`).
- Element Web, `packages/shared-components/src/room/timeline/event-tile/EventTileView/EventTileView.module.css` and `.../actions/ActionBarView/ActionBarView.module.css`, plus `apps/web/res/css/views/messages/_MessageActionBar.pcss`.
- Mattermost, `webapp/channels/src/sass/components/_post-menu.scss` and `_post.scss`.
- Fluent UI contrib, `packages/react-chat/src/components/ChatMessage/ChatMessage.styles.ts`.
- `llsc12/discord-acrylic`, `UI/Chat/Messages/DecoratorButtons/Buttons.css`, for Discord's DOM nesting.

Specs:

- [WCAG 2.2 SC 2.5.8 Target Size (Minimum)](https://www.w3.org/TR/WCAG22/#target-size-minimum) and its [Understanding document](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html).
- [WCAG 2.2 SC 2.5.5 Target Size (Enhanced)](https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html).
- [Layout Instability API, section 2.4 Input Exclusion](https://wicg.github.io/layout-instability/).
- [web.dev, Cumulative Layout Shift](https://web.dev/articles/cls).

Observed rather than read: Slack, Microsoft Teams, Linear, GitHub comment threads.
Their client stylesheets are behind auth or not published, and the theme CSS that targets them only recolours.

# Desktop vs Mobile: how to build a responsive UI component

TLDR for anyone adding UI.
The full spec is the "Desktop vs Mobile" design doc; this is the short, actionable version kept in the repo so the rules travel with the code.
Its sibling `design-language.md` owns the visual tokens (color, type, spacing, motion); this file owns layout and which surface to use.

## The one rule

Layout responds to **window width, never to platform**.
A narrow desktop window and a phone render identically.
`Platform.isAndroid` / `Platform.isIOS` / `defaultTargetPlatform` must never decide layout or which surface to show.
One widget, a width-checked shell.
Platform checks are only ever for capability (push, tray, file pickers), never for shape.

## Three laws

1. Width decides, and it is re-checked live on resize (panes slide, they do not pop).
2. Pointer rows are 30-38dp; touch rows are >= 44dp.
   A control whose drawn size is the design (an avatar) pads its hit area with `AppTouchHitArea` instead of growing.
   An ancestor only passes a press down while it contains it, so the padding needs a parent with room, and a control that cannot get that room (the 22dp author name) is not a finger target at touch density.
   `phone_touch_targets_test.dart` hit-tests the area around each control rather than reading the size of its icon.
3. Every hover affordance has a named long-press equivalent. A desktop-only action is a review defect.

## The three widths

- **compact** `< 600` - one pane, drill-down with a back action. `kCompactWidth` in `design_system/.../app_metrics.dart` is the single source (shared with hit targets so the two cannot drift).
- **medium** `600-1000` - adds the channel rail. Thresholds in `app/.../routing/breakpoints.dart`.
- **expanded** `>= 1000` - adds the member pane.

A resize crossing a threshold animates at 180ms.
On compact: back is `compact_channel_app_bar`, the rail becomes `channel_rail_drawer`, and the member list is an end drawer (`compact_drawer_scaffold.dart`) opened from the channel header or an edge swipe, not a drill-in route.

## Which surface? Answer in order, stop at the first yes

1. **Actions on a thing the user just pointed at** (a message, a channel row, a canvas object) -> **context menu**. `AppMenu` via `context_menu_region.dart`, reached by right-click / kebab / long-press, anchored at the pointer. All three converge on one menu body.
2. **Picking one value for a control that stays on screen** (status, share quality, a role) -> **dropdown**: the same `AppMenu` body anchored to the control with the selected row marked. For 2-4 short options use a segmented row instead.
3. **Info about a thing plus its actions** (a member, an edit history, a pinned list) -> **popover / sheet**: an anchored popover on a pointer, a bottom sheet on touch. `showAppSheet` decides.
4. **A short task with a submit** (create channel, compose a poll, crop an avatar, confirm a destructive act) -> **`showAppSheet`**: a bottom sheet under 600, a centered dialog (max 460) above it. Never a raw `AlertDialog` or hand-rolled `showDialog`.
5. **A place with its own nav or list you return to** (settings, admin, member management) -> **`modalPage` route**: fullscreen on a phone, a floating ~860x720 panel on desktop. Sections inside are `SettingsPanes`, never their own dialogs.
6. **Status the user did not ask for** (offline, retrying, a degraded call) -> **banner**: it pushes content, never overlays it. Amber is transient; red attaches to what failed. Snackbars/toasts are for confirmations only, never for errors.
7. **An unsolicited, time-limited prompt that demands a decision** (an incoming call, an invite that expires) -> **full-focus overlay**: painted above the routed tree and above every dialog and sheet, never in flow - a status banner pushes content because there is nothing to decide, but this vanishes on its own timeout unless answered, so it must be seen. On desktop it also raises and focuses the window, so it reaches the user even minimized or behind another app. Below `kCompactWidth` it is a full-screen takeover, the same shape a phone's own incoming-call screen already uses; at or above it, a floating card that leaves the rest of the window usable. Escape (or its on-screen equivalent) resolves it to a less intrusive state, the same "no keyboard trap" rule every other surface here follows.
8. **Content the user chose to watch, once they leave where it lives** (a screen share or camera from a call in another channel) -> **floating mini-player**: a draggable, corner-snapping card over the routed pane only, never over the composer, the keyboard, a status banner, or the page's own primary action (so not on a voice channel's page, which offers the switch), sized by width and never by platform. It carries video only; an audio-only call stays with the strip and the rail summary (rule 6). On desktop the same feed can be popped out into its own OS window, whose controls size by that window's own width; on Android the OS picture-in-picture window is the same content once the app is backgrounded, and shows the feed alone; it needs no layout rule because it has no chrome. See `docs/decisions/0040-call-mini-player-and-pop-out.md`.

Write the rule number (1-8) in the PR description.
If none fits, the design question comes back to the spec before code is written.

## Never-rules

- Never a modal just to show a menu (use the anchored menu).
- Never a menu with more than ~8 rows (that is a sheet or a pane).
- Never a dropdown for 2-3 options (use a segmented row).
- Never nested modals (use an inline expander or a second step).
- Never a floating anchored surface under a thumb; never a sheet on desktop.
- Never a tooltip as the only carrier of information; never a tooltip on touch.
- Never a keyboard shortcut as the only path to a command.
- **Never a toast for an error.** Errors persist as an `AppErrorState` attached to what failed; a `check-error-surface.py` gate enforces this.

## Tie-breaker

- Dismisses on outside-click and loses nothing -> menu / popover.
- Dismissing would discard input -> a `showAppSheet` task with an explicit cancel.
- The user comes back to it -> a routed `modalPage`.

## Density: what moves with width and what never does

Tokens never change with width.
Colors, radii, the type scale and the spacing grid are identical at every width.
If a compact screen seems to need a new color or radius, the design is wrong, not the token set.

Only heights, hit targets and input font size move:

| Row | Height |
|-----|--------|
| `rowPointer` | 30 |
| menu row / `controlMd` | 34 |
| `rowTouch` (touch minimum) | 44 |
| touch menu / input | 48 |

The composer is h40 / font 14 on desktop (keyboard hints allowed) and h48 / font 16 on compact (font 16 blocks iOS auto-zoom; the send button is always visible).
Vertical rhythm is the only density lever: `rowGap` 4/8/12, grouped 1/2/4. Type, avatars and hit targets deliberately do not scale.

## The translation table

Every desktop affordance must state its compact equivalent, or it is not done.

| Desktop has | Compact must have | Never |
|-------------|-------------------|-------|
| hover reveal (kebab, action cluster) | long-press -> action sheet, same items | an action that silently vanishes |
| context menu / popover / modal | bottom sheet, handle, 44px rows | a floating anchored surface under a thumb |
| tooltip with a shortcut | a visible label, or nothing | tooltips on touch |
| keyboard shortcut (Cmd-K, R, E) | a reachable on-screen path to the same command | the shortcut as the only path |
| member pane | an end drawer from the right edge (header button or edge swipe), closed by selecting a member or tapping the scrim | a second routed screen for a list the channel stays behind |
| pins | `pinned_messages_sheet`, a bottom sheet (rule 3) | a drawer that traps scroll |
| inline edit-in-place | the same, composer expanded to fit | a separate edit screen |
| drag to reorder (click and hold lifts, a line shows the landing place) | a still hold opens the options, a hold then a move lifts, same drop rules | a permanent grip, or reorder hidden behind an edit mode |
| full-focus overlay (floating card) | full-screen takeover, same two actions | a desktop-only accept/decline pair |

## The review question

For any UI change, ask: **resize the window across 600 - what appears, what converts, what dies?**
Anything that dies is the bug.

Reference widgets that already do this right, whose shape new UI should follow: `command_palette`, `channel_rail_drawer`, `compact_channel_app_bar`, `context_menu_region`, `showAppSheet`, `modal_page`.

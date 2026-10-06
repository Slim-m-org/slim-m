# Visual Identity and Design Language

Scope: color, typography, spacing, iconography, motion, and how they compile into Flutter design tokens.

Wording (one verb per action, one name per thing) is in [`wording.md`](wording.md).

> **Status, 2026-07-26.** This is the original proposal. Where it disagrees with
> `client/packages/design_system/lib/src/app_tokens.dart`, **the code is
> correct** - values were tuned to pass the WCAG contrast gate, and the
> 2026-07-26 identity review changed several more.
>
> Superseded by [`../decisions/0004-visual-identity-review.md`](../decisions/0004-visual-identity-review.md)
> on these points specifically:
>
> - The accent is three tokens now (`accent`, `accentFill` with `accentOn`,
>   `accentSoft`), not one. One value cannot be both legible as text and
>   brand-true as a fill.
> - `surface.sunken` exists, below base, for the rails.
> - True black's hairline is `#2C3238`, not `#23282D`.
> - Radius is `6 / 10 / 16 / full`. The 4dp step is gone: it is
>   indistinguishable from 6 under a hairline.
> - The type scale drops subheading 17, leaving 11 / 12 / 14 / 15 / 20 / 24.
> - Code syntax, canvas object and focus-ring token families were missing and
>   now exist.
> - The accent **hue** is a glacier cyan, not the teal below, decided 2026-07-27.
>   The reason is not the collision the review named, which was measured and did
>   not hold; it is that teal desaturates to near-grey under deuteranopia.
>
> The direction, the reasoning and the rejected alternatives below all still
> stand. Read this for why, and the decision record for what.
This builds on the token pipeline already decided in `flutter-client.md` (a compiled token file wired through a `ThemeExtension`, with light, dark, and true-black variants) and defines the values that fill it.

## Direction

Verdict: a neutral-first interface with one restrained accent, not a brand-color-saturated one.
Discord's identity is "blurple everywhere"; Slack leans on an equally loud aubergine sidebar.
slim-m reads the opposite way, a quiet gray-slate surface where color appears only where it carries meaning, never as decoration.
This is also more durable: trend-driven UI (glassmorphism, gradient-mesh, neumorphism) ages in two to three years, while a neutral-plus-one-accent system in the lineage of Linear, GitHub, and VS Code has stayed legible for a decade.
Rejected: a broad signature brand color, the Discord/Slack pattern, since it contradicts "understated" and "distinct."
Risk: restraint can drift into blandness, mitigated by confining the accent to a fixed set of semantic roles rather than per-screen judgment.

## Color System

Neutrals are a cool slate scale, authored in OKLCH for perceptually even lightness steps, exported to sRGB hex for the Dart token file.
The accent is a muted teal, far in hue from Discord's blurple, Slack's aubergine, and Teams' blue, so no screenshot reads as a competitor's app.

| Role | Light | Dark | True black |
|---|---|---|---|
| surface.base | #F7F8F9 | #17191C | #000000 |
| surface.raised | #FFFFFF | #1F2226 | #121316 |
| border.subtle | #E1E4E8 | #2B2F34 | #232427 |
| text.primary | #1B1E22 | #ECEDEF | #ECEDEF |
| text.secondary | #5B6169 | #A7AEB6 | #A7AEB6 |
| accent.default | #1B6F91 | #58B4D8 | #40B6D9 |

The accent moved from the teal this table originally carried (#2B8A83 / #4FBDB4) to glacier cyan on 2026-07-27.
The reasoning, including that the review's own stated argument for the move turned out to be wrong when measured, is in [decisions/0004-visual-identity-review.md](../decisions/0004-visual-identity-review.md).
The Design Brief Prompt further down still quotes the teal, deliberately: it is a verbatim record of what was asked for, not a statement of what is.

Status dots keep the conventional traffic-light palette (green online, amber away, red do-not-disturb, gray offline), since that convention is load-bearing for recognition; each also carries a distinct shape so state never depends on color alone.
A person is drawn one way everywhere: `UserAvatar` for the picture and its dot, at one of the `AppAvatarSize` steps, with the state from `presenceForProvider`.
A person nothing has been reported about yet draws no dot at all, because a grey ring would claim offline.
The signed-in user is never unknown to themself: an unreported self reads online.
Dots start at the 24px step; a smaller avatar carries none, so two initials never sit under one.
Canvas participant cursors get their own categorical set, spaced away from the accent and status hues.
Rejected: deriving dark mode by inverting light-mode lightness, which produces harsh surfaces; every dark value above is hand-tuned instead.
Risk: a two-tone system limits how much "brand" marketing pages can carry, mitigated by letting the website use the accent more freely, since the token system governs the product, not every asset.
Every foreground/background pair is checked against WCAG 2.1 AA (4.5:1 body text, 3:1 large text and icons) at authoring time.

## Typography

Primary typeface: IBM Plex Sans (variable font), with IBM Plex Mono for code, logs, and diagnostics.
Chosen over the more common Inter because it has real character instead of reading as the default choice of every SaaS dashboard, and its open, technical origin fits a self-hosted, developer-adjacent product; one variable-weight file also keeps the weight axis to a single bundled asset, a small win against the client's binary-size budget.

| Token | Size | Weight | Line height |
|---|---|---|---|
| type.micro | 11sp | 400 | 1.3 |
| type.caption | 12sp | 400/500 | 1.35 |
| type.ui | 14sp | 400/500 | 1.3 |
| type.body | 15sp | 400 | 1.45 |
| type.subheading | 17sp | 500 | 1.3 |
| type.heading | 20sp | 600 | 1.25 |
| type.title | 24sp | 600 | 1.2 |

Roles are named for the app's own vocabulary, not Flutter's default `TextTheme` slots, which do not map cleanly onto a chat app.
Weight is capped at 600, bold 700 is unused; numeric contexts use tabular figures so digits do not jitter.
Text respects OS text-scale up to 130 percent, verified by golden tests already planned in `flutter-client.md`.
Rejected: a separate display/headline face layered on top, a decorative flourish "understated" argues against.
Risk: Plex can render slightly heavier than Inter on Linux fontconfig at small sizes, mitigated by testing on the Fedora GNOME environment already named as the primary Linux target.

## Spacing, Radius, and Elevation

Spacing is a 4dp base grid (4, 8, 12, 16, 20, 24, 32, 40, 48, 64), named by value, matching the 4dp/8dp convention most Flutter contributors already know even though the visual style is not Material.
Three vertical insets deliberately sit off that grid, named in `AppRhythm`: 10 above a heading in a side pane, 14 above a divider band in the transcript, 6 below either.
A heading wants more air above it than below, so that it reads as belonging to what follows, and the grid's nearest pair - 12 above, 8 below - is both too loose and too even to say that.
The rail, the member pane and the transcript each arrived at the same answer independently, which is what made it a rhythm worth naming rather than drift worth re-gridding.
Nothing else is allowed off the grid: a value used at a single site stays a named constant in the file that owns it, where what it aligns to can be named too.
Radius is four steps: 4 (chips), 6 (buttons, inputs), 10 (cards, panels, modals), 16 (floating canvas windows), plus full for avatars and pills.
Elevation is border-first: a 1px hairline is the default separator, and only three soft, low-opacity shadow tokens exist (`AppShadows.menu`, `float` and `canvasTile`), reserved for surfaces that must visually float (menus, canvas windows, modals) or rest above the plane (live canvas tiles, toasts, the call mini-player).
This is performance and identity together: blurred shadows and backdrop blur cost more to composite than a hairline border, which matters on the lightweight self-host and older-device targets, and reads calmer than Discord's shadowed panels.
Message layout is flat and grouped (avatar, name, timestamp, stacked lines), not chat-bubble style, matching the brief's instruction that layout should "resemble the familiarity of Discord or Slack," where bubbles read as consumer messaging instead.
Risk: border-only separation can feel flat on dense screens, mitigated by pairing borders with a sunken background step for the few screens that need a third depth cue.
The computed contrast ratios that motivated true black's brighter hairline above (`#23282D` at 1.41:1 against `#000000`, raised to `#2C3238` at 1.62:1) come from [design-language-review.md](design-language-review.md)'s finding 1, which measured all six border/surface pairs across the three themes and found every one below the 3:1 WCAG 1.4.11 threshold for a UI component boundary.
Decision 0004's 2026-10-01 addendum resolves it: separators stay hairlines, while the edge of an input uses `borderStrong` at 3:1 or better (cards stay hairlines).

## Iconography

Base set: Lucide Icons (owner decision), an open, ISC-licensed, actively maintained line-icon library that covers the generic UI icons a community project keeps needing without commissioning new artwork per feature.
The interface never uses emoji as chrome (owner decision); emoji appear only as user-chosen message content such as reactions.
Custom icons are reserved for surfaces where distinctiveness matters: the app mark and the Voice Canvas toolbar (pen, sticky note, shape, window).
Sizes are tokenized at 16, 20, 24 (default), 32dp, 1.5px stroke at the 24dp reference; active state is conveyed by weight and the accent as well as never by color alone.
Rejected: Material Icons, which would read as an unstyled default Flutter app; emoji as UI chrome, which is inconsistent across platforms and off-brand for an understated product; a full custom icon set, an ongoing maintenance liability outweighing the distinctiveness it buys.
Risk: Lucide's language will drift slightly from the custom toolbar icons, mitigated by matching stroke width and corner logic across both.

## Motion

Tokens: `duration.fast` 100ms (press, hover), `duration.base` 180ms (panel and route transitions), `duration.slow` 280ms (modal entrances), with one standard ease-out curve for entrances and its accelerate counterpart for exits.
Nothing in the chrome runs longer than 280ms, and nothing is decorative motion with no functional purpose.
The Voice Canvas is one exception: direct-manipulation gestures (drag, pan, zoom, pinch) run with zero added easing, tracking input 1:1 every frame, since eased motion under a live cursor feels laggy and works against the drag targets already set in `voice-canvas.md`; easing is reserved for system-initiated moves.
All non-essential motion respects the OS "reduce motion" setting, collapsing to instant state changes.
Rejected: backdrop-blur "frosted glass" overlays, a look several competitors are adopting, both for render cost on lower-end GPUs and because avoiding it serves differentiation.
Risk: near-zero-motion chrome can read as lifeless; the Voice Canvas is the intentional counterweight, allowed more energetic motion since it is the feature meant to feel alive.

## Flutter Design Tokens

The pipeline is already decided in `flutter-client.md`; this report adds the schema, a two-layer model of primitives (`color.slate.100`, `space.16`) that only the `design_system` package references, and semantic tokens (`color.surface.base`, `color.accent.default`, `type.body`) that widgets actually consume.
This indirection means a future rebrand or palette refinement, plausible since the project name is still undecided, changes a handful of primitive values rather than rewriting widget code.
Recommendation: one consolidated `AppTokens` extension holding nested value objects (`AppColors`, `AppTypography`, `AppSpacing`, `AppRadii`, `AppMotion`), so a widget does one lookup instead of five.
Rejected: raw hex or numeric literals anywhere outside the generated file, already the rule in `flutter-client.md`, repeated here because it keeps this system honest over years of contributions.
Risk: one large generated class can look intimidating to a contributor, mitigated by it being generated, never hand-edited, and enforced by the CI drift check `flutter-client.md` already specifies.

## Two Notes on the Brief

The brief lists "Accessibility" as a single unqualified bullet with no concrete bar, unlike the rest of the brief, which is specific everywhere else.
I am treating this as a gap to close, not defer, and setting WCAG 2.1 AA as the explicit target: 4.5:1 body contrast, 3:1 for large text and icons, full reduce-motion support, status by shape as well as color, minimum 44 to 48dp touch targets.
Separately, "understated" sits in mild tension with the Voice Canvas brief, which wants an "AR glasses, arrange anything in space" feeling.
I resolve this by scoping restraint to the app chrome and treating the canvas as the deliberate exception zone, since a uniformly muted palette applied there too would undercut the feature the brief calls the product's defining one.

## Design Brief Prompt (ready to submit to a design tool)

```
Design a desktop-and-mobile UI for "slim-m," an open-source, self-hostable,
Discord/Slack-style group chat and voice app. Sidebar-based navigation
(servers/spaces, channel list, member list), a flat grouped message list
(avatar, name, timestamp, stacked text - no chat bubbles), and a signature
"Voice Canvas": an infinite collaborative whiteboard active during voice
calls, with movable camera bubbles, screen-share tiles, and freeform
drawing, in the spirit of Figma or a shared AR workspace.

Style: understated, clean, calm, functional, built to look good in five
years, not two. Neutral-first: cool slate-gray surfaces, restrained use
of a single teal accent, no purple/blurple, no heavy shadows, no
glassmorphism or blur, no gradients as decoration.

Palette:
- Light: background #F7F8F9, surface #FFFFFF, border #E1E4E8,
  text #1B1E22 / #5B6169, accent #2B8A83.
- Dark: background #17191C, surface #1F2226, border #2B2F34,
  text #ECEDEF / #A7AEB6, accent #4FBDB4.
- Status: green online, amber away, red do-not-disturb, gray offline,
  each with a distinct shape, not color alone.

Typography: IBM Plex Sans, weights 400/500/600 only, never bold 700.
Type scale from 11sp to 24sp. Message body at 15sp.

Spacing: 4dp grid (4/8/12/16/20/24/32/40/48/64). Radius: 4/6/10/16 plus
full for avatars and pills. Elevation via 1px hairline borders, not
drop shadows, except three subtle shadows for menus, floating windows and resting tiles.

Icons: consistent 1.5px stroke outline set (Phosphor-style), 20-24dp,
bold weight for active state instead of color-only changes.

Motion: fast (100ms) micro-feedback, base (180ms) panel transitions,
nothing over 280ms in the chrome. Exception: the Voice Canvas may use
richer, more energetic color and motion, since it is the signature
feature.

Avoid: Discord's saturated purple-blue brand color, Slack's aubergine
sidebar, chat-bubble message styling, glassmorphism/frosted blur,
neumorphism, gradient-mesh backgrounds, and any generic default
Material look.

Deliver: light and dark mode screens for (1) sidebar + channel list +
message view, (2) an active voice call with the Voice Canvas open and
two floating camera bubbles plus a screen share tile, (3) settings,
(4) a first-run/empty state.
```

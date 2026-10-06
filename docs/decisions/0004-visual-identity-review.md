# 0004 - Visual identity review

Date: 2026-07-26.
Status: accepted.
The one decision it left open, the accent hue, was settled on 2026-07-27 in the section below, which also records why its stated reason did not survive measurement.

Owner decision 8 said a real designer review had to happen before the token
palette was locked, because the accent is a from-scratch brand choice and the
tokens are load-bearing across every screen.
This is that review.
It drew the v1 shell across eleven screens (text channel, canvas, light and true
black, command palette, compact, voice strip, settings, onboarding, accent
options, components, app mark) rather than assessing a swatch grid, which is why
most of what follows is specific rather than directional.

## Confirmed, no change

- **Cool slate neutrals.** Hold up under a dense evening of real chat.
- **Border-first elevation.** Called the strongest decision in the system, and
  the reason the canvas can float six objects without the screen turning to
  soup.
- **IBM Plex Sans with Plex Mono, capped at 600.** The pairing carries more of
  the personality than the accent does; mono on timestamps, code, channel names
  and keycaps is worth leaning on harder.
- **Flat grouped messages, the 4dp grid, no backdrop blur.** No notes.
- **Comfortable density at 15sp / 1.45.** Reads well, but the message column
  needs a cap near 760px or wide monitors hurt.

## Changed, and why

### The accent could not be one token

A value legible **as text** and a value recognisable **as a fill** are different
colours. Forcing one token through both jobs is why light `#1E7F77` and dark
`#4FBDB4` passed contrast and still did not read as the same brand: the light
one is a duller colour, not a darker version of the same one.

Split into `accent` (contrast-bound, for text and icons), `accentFill`
(brand-true, always paired with `accentOn`), and `accentSoft` (a ~12% tint that
does most of the actual accent work). The contrast gate now checks honest pairs
instead of one value against two different requirements.

### True black needed a brighter hairline

In dark mode a border is a hint, because fill difference already separates
surfaces. On `#000000` the border **is** the entire elevation system, and
`#23282D` against black is 1.41:1, which disappears at exactly the low OLED
brightness true black exists for.

Raised to `#2C3238`. That is 1.62:1, better but still far from the 3:1 that WCAG
1.4.11 asks of a UI component boundary, and reaching 3:1 would need roughly
`#5A5A5A`, which is a visible grey rule rather than a hairline. So the value
moved and the underlying question did not: **is a separator hairline a UI
component under 1.4.11, or an incidental boundary that is exempt?** Until that is
answered the gate reports border ratios instead of asserting them, with the
reasoning written next to the test rather than left as a silent omission.

### Two scales had one step too many

Radius 4 and 6 are indistinguishable under a 1px hairline. Collapsed to
`6 / 10 / 16 / full`.

Type subheading 17 never appears next to body 15 without also differing in
weight and colour, so it earned nothing. Six steps (11 / 12 / 14 / 15 / 20 / 24)
covered every screen drawn.

Fewer tokens is fewer judgement calls per contributor, which is the point of
having a system at all.

### Three token families were missing

They would have been invented under pressure, inconsistently, by whoever hit
them first:

- **Code syntax**, five roles (keyword, string, number, comment, punctuation)
  and per theme, because the same string colour cannot clear 4.5:1 on both
  `#FFFFFF` and `#000000`. Fifteen values, all now gated. A fenced block is
  exactly the surface that quietly ends up the one inaccessible thing in an
  otherwise AA product.
- **Canvas objects**, deliberately warmer and more saturated than the chrome,
  plus a closed set of six categorical cursor hues for remote participants that
  must not reuse status or accent hues.
- **A focus ring**, its own token rather than the accent border already used for
  active and selected states. If focus and selection look the same, a keyboard
  user cannot tell where they are.

### One more surface

`surface.sunken`, a step below base, for the rails. Six surfaces were not enough
to draw the shell without the panes bleeding together.

Adding it immediately paid for itself by exposing a real defect: the light accent
cleared base at 4.53:1 but only reached 4.26:1 on sunken, and the rails carry
accent (active channel marker, unread badge). Corrected to `#1D7A72`.

## The accent hue: decided, glacier cyan

**Decided 2026-07-27: option B, glacier cyan.**
The anchors are the ones the review named, `#58B4D8` dark and `#1B6F91` light, taken verbatim.

The review's argument for moving was this.

> The shipped teal collides with the online-status green. At 9 to 10px, `#4FBDB4`
> and a conventional online green sit two rows apart in the member list and read as
> one colour to a deuteranope. The redundant-cue rule means the dots survive, but
> the accent stops meaning "interactive" the moment presence uses a neighbouring
> hue.

That argument is wrong, and it was measured to be wrong before the change was made.
The right answer came out anyway, which is the only reason this section records a decision rather than a reversal.

### What was measured

The shell was rendered at 1400x880 with the real fonts and a seeded session, the same harness described in `CLAUDE.md`, and the accent and the online green were taken out of that render and put through a Vienot-Brettel-Mollon LMS simulation of dichromatic vision, rather than argued about on a hue wheel.

Under simulated deuteranopia the two colours move **apart**, not together.
CIEDE2000 between the accent and the online green goes from 20.2 to 29.3.
The simulation is a per-pixel colour transform, so it says nothing on its own about acuity at 9 to 10px; what it does say is that the mechanism the review named is not there to be helped by size either way.

What does happen is worse in a quieter way.
Teal loses about 74% of its chroma under that simulation, CIE LCh C* falling from 33.7 to 8.8, which is close enough to neutral that the accent stops reading as a colour at all.
For a deuteranope the accent does not become confusable with the presence green; it becomes a grey that carries no signal, so every one of the seven accent roles below loses the hue half of its cue and is left with only its shape.
Glacier cyan keeps effectively all of its chroma through the same simulation, C* 31.3 to 31.5, so the accent still reads as a colour.

One factual correction to the review while this is being written down.
It says the accent and the online green sit "two rows apart" in the member list.
They do not: they are on the same rows.
Nick and Priya each carry an online dot and an accent role badge, so the two colours sit side by side within one row rather than two rows apart.
The proximity is therefore worse than the review said and the confusability is not there anyway, which is a fair summary of the whole finding.

### The options, as drawn

Three options were drawn against the same probe (accent beside a status dot, a
role badge, a mention, a filled button, a poll bar):

| Option | Dark / light | Hue | Verdict |
|---|---|---|---|
| A, muted teal | `#4FBDB4` / `#1D7A72` | 178 | Was shipped. Not the collision the review claimed, but it desaturates to near-grey under deuteranopia. |
| B, glacier cyan | `#58B4D8` / `#1B6F91` | 202 | **Adopted.** 24 degrees further from green, clears amber, red and grey, reads cooler and more technical. Teams' blue is an indigo at 265, so no collision there either. |
| C, copper | `#C98F63` / `#8F5A2E` | 48 | Strongest identity, but moves the collision rather than solving it: copper then sits beside the away amber. Only viable if away loses amber or becomes shape-only. |

The argument for B is that the accent is the cheap thing to move and the
traffic-light status convention is the expensive thing. Everything drawn works
unchanged with B, because it is one primitive value, which is what the two-layer
token model promised.

A fourth option was named and not recommended: no chromatic accent at all, with
colour reserved entirely for status and canvas content. Maximum longevity and
zero collisions, but it leaves the app icon with no brand colour and gives new
users nothing to learn "this is clickable" from.

### What actually changed in the code

The review expected this to be "one primitive value", and it was close to that but not quite.
The accent is five tokens per theme, not one, and three themes carry it, so it is fifteen values.

Only two of them were decided: the anchors above.
The other thirteen were derived by taking the teal family's own OKLCh offset from its own anchor, per theme and per role, and applying the same offset to the new anchor.
So `accentOn` keeps its lightness delta and its chroma ratio and only rotates hue, `accentSoft` keeps the lightness and saturation relationship it already had, `accentRing` keeps its alpha byte over the new fill, and `trueBlack`'s accent is the same brighter, more saturated step off `dark` that the teal family made.
The point of doing it that way is that nothing was re-judged by eye, so this is a hue move and not a redesign smuggled in behind one.

The resulting values, all of which clear the existing contrast gate:

| Role | Light | Dark | True black |
|---|---|---|---|
| accent, accentFill, focusRing | `#1B6F91` | `#58B4D8` | `#40B6D9` |
| accentOn | `#FFFFFF` | `#070E12` | `#030E12` |
| accentSoft | `#D8E7F0` | `#1D2B33` | `#12262D` |
| accentRing | `0x381B6F91` | `0x4058B4D8` | `0x3D40B6D9` |

Light improves against the surface it was tightest on: accent-as-text on `surface.sunken` goes from 4.55:1 to 4.97:1.
Dark and true black each give up a little headroom on `surface.base`, 7.78:1 to 7.49:1 and 9.27:1 to 8.91:1, both far above the 4.5:1 the gate asks for.
`focusRing` is still the same value as `accentFill` in every theme, as `app_tokens.dart` requires.
Note that no test asserts that equality: `surfaces_test.dart` checks a focus ring is drawn in whatever colour it is handed, so a divergence would pass today.

No goldens need regenerating, contrary to what the review estimated.
The reference images have never been generated at all, and `matchesGoldenFile` sits behind a `SLIMM_GOLDENS` environment flag, so nothing compares against them; see the golden note in `CLAUDE.md`.

## The seven accent roles, closed

The hue is settled now, but it was never the point: the accent's value is that it is rare.
The failure mode is not a wrong hue, it is the sixteenth contributor adding an accent border to a card because it looked plain.
The list:

1. Active channel (2px marker plus soft tint)
2. Unread badge
3. Mentions of you
4. The live-voice glyph
5. The unread divider
6. Your own poll vote
7. The member-pane toggle when open

All of them mean "this concerns you". Nothing decorative. Treat this as closed.

## Layout: nothing needs reopening

The standing worry was whether the Spaces / Focus / Deck concepts were parked too
early. The framing was wrong rather than the decision:

- **Focus is not an alternative shell.** It is the compact breakpoint plus a
  command palette, and both are already shipping. The compact and palette screens
  are Concept 02 in everything but name.
- **Deck is not a layout either.** It is a landing pane, and can live where the
  channel list points when nothing is selected. Additive later, no rewrite.
- **Only Spaces was a genuine fork**, and betting the shell on spatial navigation
  for heads-down text was the right call to decline.

So what was parked was two additive features, not two roads not taken.

## Canvas: "window" is a behaviour, not an object kind

This settles the contradiction in `voice-canvas.md`, which listed `window` as a
fourth content kind in the schema comment and then said two paragraphs later that
it was not a kind at all.

The second reading is right. Drag, resize and bring-to-front are a contract that
images, GIFs, camera bubbles and screen-share tiles all satisfy; a distinct
window object would be a frame with nothing in it.

Consequence: **the tool dock has three tools, not four** - pen, note, shape.
Paste is a gesture, not a tool. A tool must be selected before touch draws, so
every slot added is another mode to be wrong about.

~~**Stale as written, found 2026-08-05.**
What Phase 6 actually built is pen, eraser and select (Move) - not pen, note and shape - and this section's own "three tools" count was never checked against the shipped bar.
Erase and select are not in this list at all, and neither is a distinct object kind for either.
The review's "three, not four" was about content kinds becoming tools, which this document never revisits now that note and shape objects are landing (a concurrent change was adding them as this correction was written).
Whoever lands note and shape should re-open this section rather than trust its old count, and should decide whether erase and select are additional tools this document simply never named, or a different axis - edit actions on existing content - that a "content kinds become tools" framing was never meant to cover.~~

**Closed, 2026-08-05: note and shape are built, and the axis question above is answered.**
Pen, note and shape are the three placement tools this section always meant: each drops a new object where a pointer taps, and the tool dock reads exactly as this section originally specified.
Erase and select are the other axis the note above asked about - they act on an object already there (erase it, or move/resize/reorder it), never place a new one, so they were never a fourth and fifth placement choice this section needed to count.
A shape is one of `CanvasShapeKind` (rectangle, ellipse, line, arrow), picked from the overflow menu while the shape tool is active; a note holds text entered once through a sheet before anything is sent, since this canvas has no in-place edit for any kind.
Colour for both is fixed per kind (`AppCanvasColors.note`, `.shape`), not user-chosen, the same closed-role treatment the seven accent roles above already establish.

## Smaller things worth keeping

- **Presence is shape-first**: circle online, triangle away, barred square do not
  disturb, ring offline, struck ring appearing offline. Still distinct
  desaturated, which is worth a golden test.
- **Density changes vertical rhythm only.** Type sizes, avatar sizes and the
  gutter are identical across compact, comfortable and spacious, which is what
  stops three densities becoming three designs.
- **Non-human authors get a square avatar**, mono body, and an always-visible
  tag that is never colour-coded, so the cue survives a screenshot.
- **Operators become chips once parsed.** Typed text stays plain mono; a valid
  operator commits to an accent-soft chip, which is free validation feedback.
- **The command palette uses a flat scrim, not blur.** Cheap to composite and
  keeps the dismissed state legible.
- **The voice strip lives in the rail, not over the content**, so collapsing the
  canvas costs no message space and survives navigating to another channel. You
  are in a call, not in a screen.
- **The speaking ring pulses**, and it is the one looping animation in the
  chrome itself (the typing dots and the screen-share loading shape loop too,
  as content that reports progress). Under reduce-motion it becomes a static ring plus a bar glyph, so
  speaking is still conveyed twice.
- **Disabled controls say why.** The share-audio row keeps its space and explains
  itself on sessions that cannot capture, because silently hiding a
  platform-limited control is how a self-hoster concludes a feature is broken
  rather than unavailable.
- **Fingerprint confirmation gets a colour strip** derived from the same hash,
  taken from the canvas cursor palette so it never collides with status colours.
  Four swatches are far easier to compare over a phone call than 32 hex
  characters; keep the hex as the real check.
- **Say the awkward thing early.** "No email on this account, ask an admin for a
  reset code" belongs on the create-account screen, not in a settings page nobody
  reads.
- **Selection handles must stop scaling with the world below about 25% zoom**, or
  they become untappable on a phone.

## App mark and the name

Three marks were drawn from the geometry the UI already uses, with no letterforms
so the name stays free. The recommended one, **Offset**, is an empty frame with a
solid object pushed out of it, using the 16 and 10 radii verbatim.

The review also offered it as a *name*: short, spatial, meaningful in both drawing
and typesetting, and apt for a product whose defining feature is arranging objects
in space. `offset.chat` works and "an Offset server" reads naturally. Weaker
alternatives named: Plane, Commons.

Owner decision 9 still stands - the name is chosen before 1.0, in Phase 9. This
is input to that, not a decision.

Wordmark, when there is a name: Plex Mono 500, lowercase, letter-spaced +0.04em,
mark to the left at cap height. Do not commission a drawn logotype first.

## When a canvas object earns `AppShadows.float`, and whether a stroke is selectable (2026-08-05)

Two things this review left as open questions for a later reviewer to settle: `AppShadows.float`'s own doc comment names a menu and "a dragged canvas object" as the only two things allowed a shadow, but nothing on the canvas ever used it; and `CanvasOpsController.beginSelect` only ever hit-tested an image, so a stroke could never be selected, moved or reordered.
Both are decided and built now.
Read this before touching `StrokePainter.elevationShadow`, `CanvasDocument.elevatedObjectId`, or `beginSelect`'s stroke fallback.

**The shadow keys off active manipulation, not selection, and that is a narrower reading than "selected" would have been.**
`CanvasDocument.elevatedObjectId` names the one object this client's own pointer is currently dragging or resizing - set in `beginSelect`'s drag and resize branches, cleared at the top of `endSelect` before the commit request even lands - and `StrokePainter` draws the shadow only for whichever image that names.
Selection (the outline and, for an image, its resize handles) is `selectedObjectId`, a separate and much longer-lived notifier that stays set for as long as the Move tool holds a selection, including between one drag and the next.
The two were kept distinct deliberately: this project's own border-first elevation is described elsewhere in this document as "the reason the canvas can float six objects without the screen turning to soup," and a shadow that persisted for the whole time an object merely sat selected would be exactly that soup on a canvas with several selected-but-idle objects - normal once several people are working on one board.
A shadow only for the literal seconds an object is off the plane keeps the exception rare, which is what makes it read as an exception at all.

**A camera bubble gets the opposite answer, unconditionally, because it is a different kind of object.**
It is never draggable yet, so "only while dragged" would mean never; and unlike an image or a stroke, it is never part of the document plane in the first place - `CanvasPresenceLayer`'s own doc already describes it as a widget layer stacked over the surface, never painted into it.
`CanvasPresenceBubble` now carries `AppShadows.float` unconditionally, and `AppRadii.window` - a token whose own doc comment already reserved it for "floating canvas objects" and which nothing had used until this change - in place of the plain `AppRadii.card` it borrowed before.

**Rendered and checked against real pixels, not decided on paper, and it surfaced a real theme gap.**
A throwaway `PictureRecorder`-driven render (per this file's own testing convention, and the technique this repo's history already uses) showed the shadow reading clearly on the light theme, faintly on dark, and essentially not at all on true black - `AppShadows.float`'s `0x85000000` composited against `surface.base`'s near-identical near-black leaves nothing to see.
That is not a defect in this change: the selection outline and resize handles are `accentFill`, a token the contrast gate already holds to 4.5:1 against every surface in every theme, and they are what a person actually depends on to see what is picked up - confirmed in the same renders, where the outline stayed sharp on true black with no shadow visible at all.
The shadow is genuinely atmospheric "extra energy" the design language grants the canvas, layered on top of a cue that already carries the whole weight on its own, the same "never one channel alone" shape this project's presence indicators and reaction chips already follow.
Recorded here rather than "fixed": the fix would be a second, lighter shadow variant for dark surfaces, which the task that produced this section explicitly ruled out ("do not invent a second shadow"), and a literal reading of the existing token was the more disciplined choice over reaching around that constraint.

**A stroke can now be selected, but only for reorder - never a drag.**
`beginSelect` falls back to a path hit test once the tap misses every image, and accepts the result only when it is not itself an image (a stray tolerance match near a box `hitTestImageAt` already tested and rejected must not be re-admitted through a looser check).
A selected stroke sets `selectedObjectId` exactly the way an image does, so `bringToFront`/`sendToBack` and the overflow menu's "Bring to front"/"Send to back" items work on it with no further change anywhere - both were already generic over any object kind, and the only thing stopping a stroke from reaching them was that nothing had ever selected one.
It never sets `elevatedObjectId` and never starts a `_drag`: a freehand mark has no box a person expects to relocate the way a placed image's is, and `SelectionPainter` already draws no handles for a non-image kind, so a selected stroke reads as "here, and reorderable" with nothing suggesting it can be picked up and moved.
This is the real answer to the moderation case the task named directly: a drawing an image now covers can be brought back above it by tapping whatever part of the stroke still pokes out past the image's own box (an image's hit test is its box, a stroke's is its own path, so the exposed part of the line is reachable even though the covered part is not) and choosing "Bring to front."
A stroke entirely enclosed inside an image's box has no exposed tap target at all; the residual workaround is to select and send the image to the back first, which is a real but rare two-step cost, named here rather than solved, since closing it fully would need a z-order-aware hit test this change did not build.

### Addendum 2026-10-01: the hairline question is answered

A separator hairline is incidental and stays `borderSubtle`.
The edge of a control a person has to find is a UI component under WCAG 1.4.11 and meets 3:1.
Text inputs (`AppInput` and the theme's `InputDecorationTheme`) now draw their edge in `borderStrong`.
Cards are containers, not controls, so `AppCard` keeps the hairline: a 3:1 card edge around 3:1 inputs read as a box in a box in settings.
Dividers, card header rules, chips and menu separators keep the hairline too.
`borderStrong` on light was darkened from `#898E93` to `#858A8F` because the old value reached only 2.92:1 on `surfaceSunken`.
It now measures 3.08 to 3.48 in light, 3.41 to 4.04 in dark and 4.16 to 4.48 on true black, and `component_boundary_contrast_test.dart` computes this from the tokens.

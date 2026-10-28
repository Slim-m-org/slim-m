<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0096 - Viewers draw on a shared screen, shown by a click-through overlay on the sharer's real screen

Status: accepted (Linux built and checked in a nested KWin; Windows written and compiled for syntax only)
Date: 2026-10-28

## The ask

The owner, 2026-10-14: "as a person sharing my screen, if my friends are viewing my screen from the canvas if they draw on it maybe you can overlay it to the screen im currently showing it on, so they can put a sticky note on it or a funny meme, or circle something that disappears in a few seconds just to point something out to me".
Decisions on 2026-10-26: plan the overlay first, opt-in and off by default.
Decision on 2026-10-28: build it in v120 for Linux and Windows.

## Decision

- The overlay is off by default and per user: "Let viewers draw on my screen", in Voice settings under "Sharing and preview" and in the share options menu while sharing.
  It only exists on a desktop that can host it; elsewhere the control is absent, never disabled.
- It is up only while all of these hold: the setting is on, a whole screen is being shared, and the desktop can host it.
  A window share never opens it (see "What it covers").
- Viewers get a small pen, circle and note pill on a screen tile, and only while that sharer's consent is live.
- Marks are ephemeral and never stored.
  They are relayed to the sharer, painted on the sharer's real screen, and fade out a few seconds later.
- A sharer always sees "Viewers can draw on your screen" with a Turn off button in the call stage while it is up, and the share options menu shows the toggle checked.
  Turning it off closes the window at once and withdraws consent.

## A native window, not a second Flutter view

The overlay is a small native window owned by the desktop runner and driven over a method channel (`slimm/screen_overlay`: `support`, `show`, `draw`, `hide`).
The runner only paints primitives (strokes, ellipses, notes) in coordinates normalised to the monitor.
Everything that decides what a frame contains lives in Dart: the fade, the opt-in gate, the coordinate mapping.

Why not Flutter's own windowing (decision 0040) or a helper process:

- A transparent, click-through, layer-shell Flutter view needs the experimental windowing flag on Linux and has no equivalent on Windows, so it could not be shared.
- A helper process adds a second binary to every package (rpm, deb, tarball, flatpak, the Windows installer) and an IPC channel for a window that draws three shapes.
- The native window needs no second engine, no texture sharing and no windowing flag.

## Windows

A layered, topmost, click-through popup:

- Extended styles `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`, style `WS_POPUP`, sized to the shared monitor.
  `WM_NCHITTEST` answers `HTTRANSPARENT` and `WM_MOUSEACTIVATE` answers `MA_NOACTIVATE`, so it never takes a click or focus.
- It is drawn with GDI+ into a premultiplied 32-bit bitmap and handed to `UpdateLayeredWindow` with per-pixel alpha.
- It is excluded from capture with `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`, which needs Windows 10 version 2004 (build 19041).
  Where the call is refused, or the build is older, the overlay is reported unsupported and never shown: an overlay that lands in the share is worse than none.
- A game in exclusive fullscreen covers it; borderless windowed does not.
- Written to compile but not run here: there is no Windows machine on the dev box.
  The code was syntax-checked with mingw-w64 against the real GDI+ and Flutter wrapper headers.
  Which monitor "Screen N" means is the least certain part and needs a real multi-monitor check.

## Linux

The same native window, made with GTK, and the way it stays on top differs by session:

- **Wayland with wlr-layer-shell** (KDE Plasma, wlroots compositors such as sway and Hyprland).
  The window is a layer-shell surface on the overlay layer, anchored to all four edges of the shared monitor, with no exclusive zone and keyboard interactivity off.
  The input region is empty, so every pointer and touch event falls through.
  gtk-layer-shell is loaded with `dlopen` at the moment the overlay is first asked for, so it is a soft dependency: nothing changes for anyone who never turns the setting on, and the rpm lists it as a recommended package.
  Loading it after GTK worked in a nested KWin 6.7 (checked with `WAYLAND_DEBUG`: overlay layer, keyboard interactivity 0, anchor 15, empty input region).
- **Wayland without layer-shell** (GNOME, which does not implement it, or any desktop without gtk-layer-shell installed).
  There is no supported way for a plain client to sit above other windows or to be click-through and positioned, so the overlay is reported unsupported and the setting does not appear.
  A fullscreen window with "keep above" was rejected: it takes the compositor's fullscreen handling, can be covered by the next window focused, and would turn a pointing aid into something that interrupts what is being shared.
- **X11 with a compositor.**
  A `GTK_WINDOW_POPUP` (override-redirect) window with an RGBA visual, "keep above", moved to the monitor's origin, with an empty input shape.
  Without a compositor a transparent window paints black, so that case is unsupported.
  Not run here: this box is Wayland only.

Linux cannot exclude the overlay from capture.
Wayland screen capture goes through the portal and PipeWire, which captures the whole output; there is no per-window exclusion for a monitor share.
X11 capture reads the root window, which includes every window.
The cost is small and bounded: a mark appears in the shared video a moment after it appears on the sharer's own screen, so viewers see it twice, once from their own pen and once baked into the video.
Windows shows no such copy because of the exclusion above.

## What it covers

Whole-screen shares only in this version, and the overlay covers the monitor being shared.
A window share would need the window's rectangle and to follow it as it moves and resizes, which neither the portal nor libwebrtc's window capturer reports back to us; so a window share never opens the overlay, and viewers are never told they may draw.

Which monitor is shared:

- Windows: the capturer's own "Screen N" label, taken as the Nth monitor in enumeration order, because the app's own source picker chose it.
- Linux Wayland: the portal's picker makes the choice and never says which monitor.
  The size of the first captured frame picks the monitor whose shape matches best, and the primary monitor breaks a tie.
  On a layout of identical monitors this can choose the wrong one; that limit is accepted and documented rather than hidden.

## Coordinates

A mark is stored as 0 to 1 across the shared screen, never in tile or world units.
A tile letterboxes the video (`VideoViewFit.contain`), so the screen fills only part of the tile when their shapes differ.
The sharer's consent frame carries the screen's width over its height, and a viewer maps through the fitted content rectangle, so a mark does not drift toward the bars.
A point on the bars clamps to the screen edge.

## Relay

One new ephemeral socket frame, `canvas.screen_annotation` (and `.updated` back), through the canvas relay.
Nothing is persisted and there is no migration.

- Kinds: `consent`, `stroke` (a delta of x/y pairs, at most 24 pairs a frame), `shape` (an ellipse, `[x0, y0, x1, y1]`), `note` (`[x, y]` plus up to 80 characters).
- Gated like ink: canvas access and not timed out.
  Charged by wire size against the stroke-preview budget, so a drawing viewer cannot flood a call.
  Any coordinate outside 0 to 1, a malformed id, or an unknown kind drops the frame silently.
- A consent frame is only relayed when its sender is the sharer it speaks for.
  The sharer repeats consent every 5 seconds while the overlay is up and a viewer believes it for 15, so a sharer who vanishes stops being believed and a missed frame can only remove the pen, never grant it.
- The server cannot know whether the sharer opted in, and does not try.
  The gate that matters is the sharer's own client, which paints nothing unless the setting is on, a screen is shared, and the mark is over its own screen in the call it is in.
  The overlay lives on that machine, so that is where the decision is kept.

## Privacy

- Only the sharer's own screen, only while they share it, only a mark a call member drew.
  A mark from someone the sharer has blocked is dropped before it is painted, on the sharer's overlay and on a viewer's tile alike.
- Off by default, per user, and the setting survives a restart but the overlay never starts without a live share.
- The notice and the one-click off are always visible in the call stage while it is up.
  The share options menu carries the same toggle for anyone not on the call page.
- Nothing a viewer draws is stored on the server or the sharer's disk.
- The overlay cannot take input, so it cannot be used to click something on the sharer's machine.
- Excluded from the share on Windows; on Linux it is in the share, as above.

## Fade

A finished stroke or circle holds 4 seconds, then fades over 1.5.
A note holds 8 seconds, since it is read, then fades over the same 1.5.
A mark whose last frame never arrives counts as finished 2 seconds after its last frame.
At most 48 marks are alive and a stroke stops growing at 1200 points, so a stuck or hostile sender is bounded.
The overlay repaints about 30 times a second only while a mark is alive and goes idle (no timer) afterwards.

## Surface rules

This follows `docs/design/desktop-vs-mobile.md` rule 2 for the share options toggle (a value on a control that stays on screen) and rule 6 for the notice, which pushes content in the call stage and never overlays it.
The tile's pen, circle and note pill is part of the tile's own controls, so it is sized by width: hidden on a tile narrower than 220 logical pixels.

## Not done

- Window shares.
- A viewer's marks while the viewer is not on the canvas (the pen is a canvas tile control).
- Packaging gtk-layer-shell in the tarball and the flatpak; the rpm recommends it.
- macOS, web, Android and iOS, by decision.
- A real Windows run, an X11 run, a real GNOME run, and a real multi-monitor run.

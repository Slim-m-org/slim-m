<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0096 - Viewers draw on a shared screen, shown by a click-through overlay on the sharer's real screen

Status: accepted (Linux built and checked in a nested KWin; Windows written and compiled for syntax only)
Date: 2026-10-28

## The ask

The owner, 2026-10-14: "as a person sharing my screen, if my friends are viewing my screen from the canvas if they draw on it maybe you can overlay it to the screen im currently showing it on, so they can put a sticky note on it or a funny meme, or circle something that disappears in a few seconds just to point something out to me".
Decisions on 2026-10-26: plan the overlay first, opt-in and off by default.
Decision on 2026-10-28: build it in v120 for Linux and Windows.

## Decision

- The overlay is off by default and per user: "Viewers draw on my screen", in Voice settings under "Sharing and preview" and in the share options menu while sharing.
  The overlay window only exists on a desktop that can host it; the setting itself is offered everywhere (see "In-app preview and window shares").
- It is up only while all of these hold: the setting is on, a whole screen is being shared, and the desktop can host it.
  A window share never opens the overlay window (see "What it covers"), though viewers may still draw on it.
- Viewers draw with the board's own tools on the canvas and a small pen, circle and note pill on the call stage, and only while that sharer's consent is live.
- Marks are ephemeral and never stored.
  They are relayed to the sharer, painted on the sharer's real screen, and fade out a few seconds later.
- When it comes up the sharer gets a short "Viewers can draw on your screen." toast, and the share options menu shows the toggle checked (no persistent banner, see Privacy).
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
  The size of the first captured frame narrows the choice to the monitors whose shape matches.
  Wayland reports no primary monitor, so a tie cannot be broken honestly: the overlay opens on every monitor that matches, and on every monitor when the size is unknown.
  This replaced a primary-monitor tie-break that always chose the first monitor, so on two identical monitors a share of the second one drew on the first (2026-11-02, nested KWin with two outputs).
  A mark may therefore also appear on a monitor that is not shared; that is shown rather than silently missing.

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
- There is no banner while the overlay is up (owner decision, 2026-11-02).
  A short info toast says viewers can draw when it opens, and the share menu keeps the toggle.
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

This follows `docs/design/desktop-vs-mobile.md` rule 2 for the share options toggle (a value on a control that stays on screen) and rule 6 for the status line, which was a banner and is now one info toast.
The tile's pen, circle and note pill is part of the tile's own controls, so it is sized by width: hidden on a tile narrower than 220 logical pixels.

## Call overlay (2026-11-04)

The same native window also lists who is in the call, like Discord's overlay.
Owner, 2026-11-04: "validate the overlay setup, maybe it would be nice to do like discord where she show the people in call and voice activty top left or whatever position just to give me a second source of it working".

- Its own setting, "Call overlay", off by default, with a corner choice (top left by default) shown once it is on.
  Like the drawing overlay it is absent, never disabled, where the desktop cannot host it.
- It shows whenever you are in a call and, on Linux, hides while you share a whole screen.
  Linux cannot keep a window out of the capture, and the owner does not want the panel in his stream.
  Windows excludes the panel from capture, so it stays up during a share.
  A window share leaves it up, since the share does not include it.
- One row per person: you first, then the call's own order so rows do not jump, at most 8 rows and then "+N more".
  Each row has a 24px round avatar, the name, and a struck-through microphone or headphones when muted or deafened.
  While they talk the avatar gets a 2px accent ring, and nothing otherwise.
  It is always the dark tokens with a hairline border and the 10 radius, so it reads over any background.
  Owner, 2026-11-07, looking at the first version (a grey dot per name): "clean up overlay? keybinds?".
  He chose avatars with mute icons, a toggle keybind, and a smaller, fainter panel, and added "show voice activity rings also, kindve just want to align with discord for this but simple".
  So rows are 28px tall with 11px text and 8/6 padding, the surface is 60% opaque and the text 90%.
- Avatars are baked in Dart, once per person and picture: the cached avatar (or the tinted initials disc, as `AppAvatar` draws it) is cropped to a 48px circle and encoded as a PNG.
  A row carries its user `id`, and an `avatar` PNG only the first time that picture is sent.
  The runner decodes it into a cache keyed by user id (cairo on Linux, GDI+ on Windows) and draws that, so a speaking flicker never resends bytes.
  The cache lives as long as the window: Dart forgets what it sent whenever the window is shown or hidden, and the runner empties its cache on `hide`.
  A row with no picture yet is drawn as a plain disc until it arrives, and the picture upgrades from initials to the photo when the bytes land.
- The protocol gains `panel` (rows, corner, monitor index, colours; null clears it) and `appMonitor` (the index of the monitor the app window is on, or -1).
  Dart decides the rows and the colours; the runner only draws, and it repaints only when `panel` is called.
  Dart sends `panel` only when the panel differs from the last one it sent, so a speaking flicker that changes no row costs nothing, and the runner has no timer.
- On Linux the window belongs to one owner at a time.
  The drawing overlay needs a whole-screen share and the panel needs there to be none, so they are never wanted together; the controller hands the window from one to the other.
- On Windows the panel has its own window, so it stays on its chosen monitor while the drawing overlay covers the shared one.
- Monitor: the one the app window is on when the runner can tell (GDK `monitor_at_window` on Linux, `MonitorFromWindow` on Windows), otherwise the primary.
  It is chosen when the panel opens and does not follow the window to another monitor mid-call.
- Overlay screen (2026-11-06): with two or more screens the setting offers Automatic (the rule above) or a named screen.
  Owner, 2026-11-06: "on the call overlay can we have it pick a monitor to display on? might help with the canvas drawing also".
  The pick is stored as the screen's position and size, so a reorder does not move it, and an unplugged pick falls back to Automatic.
  When a share cannot say which screen it is and more than one could match, the drawing overlay uses the picked screen instead of covering them all.
- Keyboard (2026-11-07): "Toggle call overlay", default Ctrl+Shift+O (Cmd on Apple), is one of the remappable call shortcuts and flips "Show call overlay".
  It is bound only where the desktop can host the overlay, so the browser and other platforms keep the key.
  In a call it is also a global hotkey beside mute and deafen, so it works while a game has focus.
- Windows draws the same panel with GDI+ and, like the drawing overlay, is excluded from capture; it is compiled for syntax only.

## In-app preview and window shares (2026-11-04)

Consent no longer waits for the overlay window.
Viewers may draw whenever the setting is on and the sharer is sharing anything, a window included, so a window share, a GNOME sharer, an iPhone sharer and a desktop whose probe says unsupported are all drawable.
The consent frame carries the shape of what is shared: the covered monitor when the overlay is up, otherwise the size of the first captured frame, sent again when it arrives.

The marks viewers draw also show over the sharer's own preview of their share (the local tile on the call stage and the canvas), read-only and on the same fade clock.
That preview is the one place a window share, a GNOME sharer or a phone sees the marks, since only a whole-screen share on a capable desktop gets the overlay window.
It is gated the same way as the overlay: it paints nothing unless the sharer's own consent is live, and a mark from a blocked viewer is dropped before it reaches either.
The toast "Viewers can draw on your screen." now comes with consent, not with the overlay window.

On a whole-screen share with the overlay up, viewers' marks therefore appear on the real screen and in the preview.
That is intended: the preview is what the sharer is looking at when the app is in front.

## Zoom and pan on a watched share (2026-11-04)

A viewer can zoom a remote share with the wheel (ctrl+wheel on the canvas, where a plain wheel moves the board), a trackpad pinch, a two-finger pinch on touch (not on the canvas, where two fingers already move the board), the + / - / 0 keys while the share has focus, then drag to pan.
A small indicator with a reset shows while zoomed.
Double click toggles fit and 200% on the full-screen view; on the stage and canvas tiles a double click still opens full screen, and resets the zoom first when one is active.
It works on the call stage tile, the full-screen view and the canvas tile.

- The percentage is relative to fit, not to the stream's pixels, because a viewer is never told the sender's resolution.
- Zoom is kept as the picture's origin and scale as fractions of the viewport, so it means the same in any tile size.
- A tile's zoom is dropped when its share ends, so the next share starts at fit.
- Marks stay normalised to the video: the annotate layer maps through the content rect after the zoom is applied, so a stroke drawn while zoomed lands where it was aimed, and marks are clipped to the tile.
- A wheel still zooms while a pen is picked.
  Pinch and pan wait until the pen is put down, since the pen's catcher owns the drag.

## The board's own tools on the canvas (2026-11-06)

Owner, 2026-11-06: "why cant i use the normal controls ... if i draw on canvas why doesnt that translate to the stream that i see on the canvas, do we need a seperate dock on a stream to do this?"

- On the canvas a screen tile has no pill of its own.
  While the sharer allows drawing, the board's pen draws on their screen, its shape tool circles, and its note and text tools leave a note, all in the board's pen colour.
- Every board shape lands as a circle, since the relay only carries strokes, circles and notes.
- Where the sharer has not allowed it, the board's tools behave as before and ink the board over the tile.
- The pan and eraser tools leave the screen alone.
- The call stage, which has no board toolbar, keeps the pill.

## Not done

- A window share's own overlay window.
  The in-app preview carries window-share marks.
- A viewer drawing from the full-screen video view; the pen is on the canvas tile and the call stage tile.
- Pinch zoom on a canvas tile; use ctrl+wheel there, or open the share full screen.
- Packaging gtk-layer-shell in the tarball and the flatpak; the rpm recommends it.
- macOS, web, Android and iOS, by decision.
- A real Windows run, an X11 run, a real GNOME run, and a real multi-monitor run.
  The Windows avatar path (the PNG decoded through `SHCreateMemStream` and GDI+) has been read against the API but never built or run.

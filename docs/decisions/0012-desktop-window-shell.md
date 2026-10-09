# 0012 - Desktop window shell

Date: 2026-08-10.
Status: built (#533), with the no-tray quit gap below closed 2026-08-11, the startup-window recommendation superseded 2026-08-27, and the handoff frame-wait regression fixed 2026-08-28 (see the addendum at the end).

Three asks from the owner turn out to be one subject: a Discord-style startup animation into last-known geometry, closing to a tray instead of quitting, and a smaller custom title bar in place of the native one.
All three require the app to own its own window lifecycle instead of the OS owning it, so this record designs that ownership as one shape rather than three features.

Two things the owner has since settled, folded into the design below rather than left as open questions:

**macOS gets its own branch, explicitly.**
His words: "I don't mind aligning by just having an if macos: give them mac styled bar."
Discord itself runs frameless on macOS, draws its own bar content, and keeps the native traffic lights top-left rather than drawing its own close/minimise glyphs; this design matches that split rather than one bar everywhere.

**Close-to-tray is wanted and is achievable, "like Discord."**
macOS: the red button hides the window, the app keeps running in the Dock, clicking the Dock icon restores it - the platform convention and what Discord does.
Windows and Linux: close minimises to a tray entry with a right-click menu.
The real caveat is narrower than "we cannot": GNOME dropped legacy tray icons and needs the AppIndicator extension (the well-known Discord-on-GNOME annoyance); KDE, the owner's own desktop, supports it natively via StatusNotifierItem.
A real runtime fallback is designed below, not "install the extension."

## The constraint that shapes everything else: nothing here can be verified by looking at it

This is the single biggest practical risk in the feature, so it is addressed once, up front, per surface, rather than hand-waved per section.

**What is fully automatable, no display involved.**
Geometry-clamp math (does a saved rectangle intersect a currently-attached display), the close-vs-minimise decision router, provider invalidation and default values, and reduce-motion behaviour are all plain Dart logic, testable exactly the way the rest of this client already is: `flutter test` on `ubuntu-latest`, no window ever raised.
`design_system`'s existing `reduce_motion_test.dart` and `semantics_test.dart` are the direct precedent for the two accessibility claims this record makes (reduce-motion collapse, and screen-reader-reachable custom controls).

**What is automatable but does not exist yet, and is worth building.**
`main-builds.yml`'s `linux-client` job already produces a real release binary; nothing launches it.
Propose a new CI job, on `ubuntu-latest` (a CI runner, not the owner's screen, so no rule is at risk), that starts the built binary under `Xvfb` - a virtual, off-screen X server - and drives it with `wmctrl`/`xdotool` or the same accessibility-tree approach `e2e.yml` already uses for the web build via Chrome DevTools Protocol.
This can assert: the window's title, that it appears within a timeout, that its size after a fresh launch with no saved preference matches the documented default, that a saved-geometry file changes the launched size, and that sending `WM_DELETE_WINDOW` does not terminate the process once close-to-minimise ships.
It cannot assert that the result looks right, that a tray icon rendered, that dragging feels smooth, or anything about KDE, GNOME, Windows, or macOS specifically, since a virtual X11 server is none of those things.

**What can never be automated and needs the owner at the keyboard, named per surface rather than once:**
- Whether the startup animation looks right and times correctly against real init work, not synthetic Xvfb timing.
- Whether the tray icon actually renders and behaves on his real KDE Plasma Wayland session (very likely, per KDE's native SNI support, but "very likely" is not "confirmed" - `docs/os_backlog/linux_backlog.md` already carries this exact caveat for every Linux finding that is not KDE Wayland specifically).
- Whether window drag, resize, edge-snap, and double-click-maximise feel native once the frame is no longer OS-drawn.
- Whether the close button's `setPreventClose` interception actually intercepts the X button on GTK/Wayland - see "what is unsure" below, there is a real, confirmed-adjacent reason to doubt this needs checking rather than trusting the package's own claim.
- Anything about Windows or macOS at all, since neither platform is scaffolded (`docs/os_backlog/windows_backlog.md`, `docs/os_backlog/macos_backlog.md`); every Windows/macOS statement in this record is a design intent to build against once a platform exists, not a tested fact.
- GNOME behaviour specifically, since the owner's own machine is KDE and this project has no GNOME hardware; `linux_backlog.md`'s own "Behaviour on non-KDE, non-Wayland Linux desktops... is unverified" entry applies unchanged here and will keep applying after this ships.

**The rule that follows for any agent, present or future, touching this work:** never run `flutter run -d linux`, never launch the built binary outside the Xvfb CI job above, and never do anything that raises a window on this machine's real display.
The Xvfb path is the substitute for "does it run"; everything else goes on a short list for the owner to actually look at, not something an agent tries to approximate by reasoning about it.

## What already exists, checked against the real code

`client/packages/app/linux/runner/my_application.cc` already does one relevant thing well: it creates the GTK window hidden and only calls `gtk_widget_show` on Flutter's own `first-frame` signal, so there is no flash-of-unstyled-window today, and no OS splash exists at all.
It also sets a hardcoded `gtk_window_set_default_size(window, 1280, 720)` with no geometry persistence, uses `G_APPLICATION_NON_UNIQUE` (no single-instance enforcement, worth flagging: a tray-based app that can be launched a second time while already running in the tray will spawn a second process rather than focusing the first, an easy follow-on paper cut once close-to-tray ships), and renders a GNOME header bar or a plain title bar depending on window-manager detection, with the window title read as `slimm_app` fixed 2026-08-04 to read `slim-m` in both branches (`docs/BACKLOG.md`).

`docs/BACKLOG.md`'s "A frameless window with our own title bar" entry already exists, deliberately deferred rather than declined, and already names the three-platform divergence (macOS traffic lights left, Windows controls right, Linux "depending on the desktop environment") and the cost (drag, snap, double-click-maximise, system menu, keyboard/screen-reader reachability, all reimplemented).
This record is that deferral being picked up.

`shared_preferences` is already a resolved dependency across the whole client, Linux included, so geometry persistence needs no new package.
`AppMotion` and `AppFadeIn` (`client/packages/design_system/lib/src/app_motion.dart`, `app_fade_in.dart`) already implement exactly the "fade in, honour reduce-motion, land at final state with no travel" shape this record needs for the startup animation, with no new token or widget class required.
`AppIcons` has no window-chrome glyphs yet (no minimize/maximize/close entries; the nearest existing icon, `expand`, is `LucideIcons.maximize2300` for an unrelated canvas control) - three new entries are a real, small cost of this work.

`client/packages/app/lib/src/providers/voice_controller.dart`'s `voiceControllerProvider` (a `StateNotifierProvider<VoiceController, VoiceState>` read once in `main.dart`'s `ProviderContainer`, independent of any widget) is the thing whose lifetime matters for "what happens to a live call when the window is hidden," addressed directly below.

`docs/os_backlog/linux_backlog.md`'s confirmed rule - "never enumerate windows on Linux from any call site... only ever request `SourceType.Screen`" - already means Linux screen share is always a full-screen capture, never a capture of the app's own window or any other single window.
That rule turns out to matter directly here: it is the reason the "hidden window still holding a capture" trap the owner is worried about cannot happen on Linux today, addressed below.

## The startup window

**Recommendation: not a second OS window, a themed first frame inside the one real window.**
`my_application.cc` already defers `gtk_widget_show` to Flutter's first paint, so the mechanism to avoid a flash already exists; what is missing is that the first paint is currently the real app UI (or a bare loading spinner), not a small themed state.
Build a small, centered-where-the-platform-allows loading screen (app mark plus a subtle `AppMotion`-governed animation, collapsing to a static mark under reduce-motion the same way `AppFadeIn` already does) as literally the first widget `SlimMApp` builds, shown while `main.dart`'s existing async sequence runs (`restoreSession`, the four preference-controller restores, `syncControllerProvider`/`pushControllerProvider` bring-up), then swap to the real UI and apply the restored window bounds in the same frame.

**Why not a real second top-level window**, considered and rejected: a second GTK top-level is a second taskbar/Alt-Tab entry that appears and then disappears, which is a visible flicker in exactly the surface this feature exists to make smooth.
It also needs its own close/dispose bookkeeping, and on Wayland there is no way to guarantee the "real" window then appears at a specific screen position relative to where the splash sat, since the compositor owns position, not the app - so a two-window handoff cannot deliver the seamless jump-free feeling asked for, while a single window whose content swaps trivially can.

**Cold start, no saved geometry:** the existing default, 1280x720, kept as the fallback rather than invented anew, centered where the platform honours position at all (see below).

**A saved rectangle naming a monitor no longer attached:** this is only a live question on the platforms where an app can set its own position in the first place.
Confirmed by research, not assumed: Wayland was designed from the start to give a client no way to read or set its own absolute window position; `gtk_window_move` is a no-op there, full stop, the compositor decides.
So on Linux under Wayland (the project's own target), "restore to last position" cannot regress into an off-screen window, because position was never something the app controlled to begin with; the whole class of bug is structurally absent on this platform.
On X11, Windows, and macOS, where position is real, restore must validate: before applying a saved rectangle, check it intersects at least one currently attached display's work area (`screen_retriever`'s `getAllDisplays()`, see dependencies below) and fall back to the default centered position if it does not.
Persist size unconditionally everywhere; persist position only where the platform can act on it.

**Maximized and full-screen are not a rectangle:** persist a tri-state (windowed rect, maximized, fullscreen), not only a `Rect`.
Keep the last known windowed rect around even while maximized or fullscreen, the same way a browser does, so returning to windowed state has something real to restore to rather than a synthesized guess.

## Geometry persistence

**Where:** `shared_preferences`, one JSON blob under one key (size, tri-state, and position where applicable), rather than five separate keys - matching the one-value-per-feature shape the existing preference controllers (`display_preferences.dart` and its siblings, already read in `main.dart`) already use.

**When written, and this is a real design decision, not a detail:** never on every resize/move callback.
`window_manager`'s listener exposes both a continuous variant (fires every frame of a drag) and a settled variant (`onWindowResized`/`onWindowMoved`, after the gesture ends); write only on the settled callbacks, and additionally flush once on hide/close, since that is the one moment the process could plausibly be interrupted next.
Named as unsure below: the precise semantics of "settled" versus "continuous" in this package's actual Linux implementation have not been read from its source in this session and should be confirmed before relying on it, rather than assumed from the method names alone.

## Close means minimise, and it is one feature in three local idioms, not three behaviours

Per the owner's own settled answer:

- **macOS:** the red button hides the window (does not literally minimise to the Dock the way a yellow-button minimise does); the app keeps running with its Dock icon present; clicking the Dock icon restores the window. This is both Apple's own convention for a window-owning-but-backgroundable app and literally what Discord does on macOS.
- **Windows and Linux:** close hides the window entirely and shows a tray entry with a right-click menu, the classic Discord-on-Windows behaviour, with the Linux caveat below.

**How somebody actually quits, since X no longer does it anywhere:** the tray menu (Windows/Linux) and the Dock menu (macOS) each need an explicit "Quit slim-m" item, since that affordance's normal home (closing every window) has just been repurposed.
Recommend keeping `Cmd+Q` as a genuine quit on macOS, matching Apple's HIG and user expectation regardless of what the red button now does; whether `Alt+F4`/window-manager-close-shortcuts on Windows and Linux should also genuinely quit, rather than mirror the X button's hide, is named as an owner question below, since making every close-shaped affordance behave identically would quietly remove the "how do I actually quit" path the tray/menu item now has to be the sole home of.

**What happens to a live call and an in-progress screen share when the window hides, since hiding is now the default everywhere.**
`voiceControllerProvider` lives in the `ProviderContainer` created in `main()`, not in any widget's lifecycle, so hiding the window - on any platform, via `window_manager`'s `hide()` or macOS's own window-order-out - does not dispose it, does not pause the isolate, and does not stop the underlying WebRTC capture/encode pipeline, which runs off the OS media stack rather than off Flutter's paint loop.
This is a genuinely different regime from mobile backgrounding: a hidden desktop window is not OS-suspended by default, so no wake-lock or keep-alive plumbing is needed to keep a call alive while hidden; the local camera-preview widget simply stops repainting, with no functional effect, since nobody is looking at the preview while the window is hidden anyway.

Screen share specifically: the confirmed Linux rule already named above - only `SourceType.Screen` is ever requested, never a window - means the captured source is never "this app's own window" on Linux, so hiding slim-m's own window cannot interrupt a Linux screen share; it captures the physical display regardless of what is or is not on top of it.
This is not yet a settled fact on Windows or macOS, where `desktop_sources.dart`'s own doc comment (cited in both OS backlog files) notes those platforms do offer window-level sharing through the app's own picker sheet; a user sharing "this window" specifically, on a platform that ever supports it, would have that share broken by the app hiding its own window, which is a real design gap to close once Windows or macOS actually ship screen share, not something this record can resolve for platforms that do not exist yet.

## The tray, and the honest Linux caveat with a real fallback

**Wayland reality, stated plainly rather than assumed:** absolute window positioning is compositor-owned on Wayland, not something a `setPosition` call reaches; this affects geometry persistence (above), not the tray icon itself, which is a separate protocol (D-Bus, `org.kde.StatusNotifierItem`) with no dependency on Wayland versus X11 at all.

**Tray availability is a real desktop-environment split, confirmed rather than inferred:** KDE Plasma implements `org.kde.StatusNotifierWatcher` natively, so `tray_manager`'s icon should just work on the owner's own machine.
GNOME Shell removed legacy tray-icon support outright (not a Wayland-specific removal; it is gone under GNOME on X11 too) and needs the third-party "AppIndicator and KStatusNotifierItem Support" extension, not installed by default on stock Fedora Workstation GNOME - the exact annoyance Discord-on-GNOME users already hit.

**The fallback, designed rather than borrowed from Discord's "just install the extension":** never guess from `XDG_CURRENT_DESKTOP`/`GDMSESSION` or any other desktop-name environment variable, which is exactly the fragile approach to reject.
Instead, query `org.kde.StatusNotifierWatcher`'s own `IsStatusNotifierHostRegistered` boolean property over D-Bus at the moment the user presses close - not once, cached, at startup, since a host can appear or disappear mid-session (an extension toggled, a panel restarted) and a stale cached answer would be wrong in either direction.
If the watcher service is absent from the bus, or present with the property false, or the query itself errors, treat all three identically: fall back to an ordinary minimise (window still exists, still reachable via Alt-Tab and the window list), never a hide with no way back.
This mirrors the exact mechanism Electron's own issue tracker converged on for the identical problem (`electron/electron#14635`, "Use dbus to query for org.kde.StatusNotifierWatcher"), so this is a known-sound approach, not an invented one.
This check is Linux-only; Windows always has a notification area (an icon can sit behind the overflow chevron, but it is never simply gone) and macOS's Dock is unconditional, so neither platform needs a runtime capability probe the way Linux does.

**Context menu contents, kept conservative since nothing else exists to hang a menu off yet:** Show/Hide slim-m, Quit slim-m, and - only once wired to `voiceControllerProvider`'s actual state - a Mute toggle and an "in a call" indicator while one is active.
Anything richer (status picker, per-channel actions) is a product decision for later, not architecture this record needs to settle.

## The no-tray fallback left no way out, found and fixed 2026-08-11

The fallback above (`minimizeToTaskbar`) was designed, correctly, so a Linux desktop with no `org.kde.StatusNotifierWatcher` never leaves a hidden window with nothing to bring it back.
It missed the other half of the same question: this whole record only ever specified one "Quit slim-m", in the tray menu, and that menu is never rendered at all without a tray host to display it.
On exactly the desktop this fallback exists for - GNOME with no AppIndicator extension, named above as the well-known case - the X button and Alt+F4 both resolve to minimise, forever, and nothing in the running app's own interface could ever end the process.
That is the trap this whole feature exists to avoid, reopened one level up: a window that always stays reachable, attached to a process that can never be asked to quit.

Two independent routes close it now, neither gated on live tray availability at all.
Gating either on the same probe `resolveCloseAction` already uses would only move the identical race that check already has to live with - a host can appear or disappear mid-session - onto a control's own visibility, and a quit control that can vanish out from under a keyboard user mid-navigation is its own bug, not a fix.

**The title bar's own "Window menu"**, an unconditional fourth control beside minimize/maximize/close, opens the identical "Quit slim-m" the tray menu already offers - reachable by mouse, and by keyboard (Tab to it, Enter to open, Tab and Enter to the item, Escape to back out) exactly as every other title bar control already is.

**A global Ctrl+Q**, bound through Flutter's `HardwareKeyboard.addHandler` rather than through the app's own remappable shortcut table (`platform/lib/src/shortcuts.dart`).
That table's one binding site, `home_shell.dart`'s `CallbackShortcuts`, only fires for a focused descendant of the shell, and several screens - settings among them - are separate top-level routes in `router.dart` that unmount the shell entirely, so a binding there would carry the identical hole on exactly the screens a "quit from anywhere" guarantee cannot afford one on.

`scripts/desktop-shell-smoke.sh` structurally takes the no-tray path on every run - fluxbox offers no `StatusNotifierWatcher` at all - which makes it the one CI job already exercising exactly the desktop this gap lived on.
It now drives Ctrl+Q at the end of its run and asserts the process actually exits, closing the loop its own close-request group deliberately left open: that group proves the window stays reachable after a close, never that anything can end it.

## The title bar

**Branch explicitly per platform, per the owner's own answer, rather than one shared bar:** macOS keeps the OS's own traffic lights top-left, at their normal inset, and the bar's own content (app icon, current Space/channel name, search) reflows to start to their right rather than occupying that corner.
Windows and Linux draw the app's own minimize/maximize/close controls top-right, with content reflowing to end before them.
This is one `TitleBar` widget with a `Platform.isMacOS` branch at the one place window-control layout is decided, not three separate widgets, since everything else about the bar (height, drag region, content) is shared.

**Height, proposed rather than measured, and named as such:** a native GNOME GTK header bar runs roughly 46-48 logical pixels; propose 40dp, a clean step on `AppTokens`'s own 4dp spacing grid and a real reduction rather than a cosmetic one.
This number has not been measured against the owner's actual GTK theme and should be checked against a real screenshot before it is treated as final, listed under "what is unsure" below.

**What it carries that the native bar could not:** the current Space or channel name.
`my_application.cc`'s own comment already notes neither of its two native branches reads this, because doing so natively would need a runtime Dart-to-native bridge that does not exist; a Flutter-drawn bar removes that limitation for free, since it is all Dart already.

**Drag, double-click-maximise, resize, snap:** `window_manager`'s `setAsFrameless()` plus `startDragging()` cover drag-to-move, called from a `GestureDetector` spanning the bar's empty region; double-click-to-maximise is a manual `onDoubleTap` calling `maximize()`/`unmaximize()`, since the package does not give this for free once the frame is gone.
Edge-resize and edge-snap (Windows' Aero Snap, GNOME/KDE tiling shortcuts) are expected to keep working only if `startDragging()` issues the platform's native move-request (Wayland's `xdg_toplevel::move`, Win32's own drag-move) rather than repositioning the window frame-by-frame from Dart; this was not confirmed by reading the package's own source in this session and is named as unsure below rather than assumed.

**The system menu a native frame gives for free (right-click title bar, or Alt+Space on Windows) is not rebuilt.**
Named as a deliberate scope cut: real value, real effort, and an edge case few users reach, consistent with `docs/BACKLOG.md`'s own framing of this whole feature as a cost-benefit trade, not a free upgrade.

**Keyboard and screen-reader access:** every control is a real focusable widget with an explicit `Semantics` label, using the existing `AppIcons`/focus-ring token family (design-language.md) rather than a bespoke look; this class of check already has a home in `design_system/lib/src/semantics_test.dart` and should extend to cover the three new controls rather than relying on manually running a screen reader.
High-contrast and reduce-motion both route through tokens that already exist (`AppTokens`'s high-contrast variant, `AppMotion.isReduced`); no new token family is needed, only applying the existing ones to a new widget.

**What this costs, named honestly rather than smoothed over:** giving up the OS-drawn resize cursors at exact frame edges (hand-rolled hit-testing instead), Windows' Aero Snap preview thumbnail (the underlying snap-to-half behaviour may survive per the paragraph above, the animated preview chrome will not), the native system menu (cut above), any window-manager theme integration a user's KDE/GNOME theme would have applied to a native frame (rounded corners, drop shadow matching their theme), replaced instead by this project's own fixed `AppTokens` radius and shadow, which will look identical across every desktop rather than blending into whichever one the user runs - arguably in the spirit of design-language.md's own "understated, consistent" position, but a real, visible difference from what a native-frame user had before, worth the owner seeing before it ships rather than discovering after.

## Dependencies

**Recommended: `window_manager`, `tray_manager`, `screen_retriever`, all three published by the verified `leanflutter.dev` publisher, the same family, actively maintained (`window_manager` 0.5.2 as of this check, 36 days old).**
One publisher rather than three unrelated authors answers the "who wrote this" question dependencies.md always asks once instead of three times.
`window_manager` covers frameless, drag, resize, bounds get/set, minimize/hide/show, and the close-intercept hook; `tray_manager` covers the icon and its context menu on the same underlying D-Bus/Win32/AppKit primitives; `screen_retriever` covers display enumeration for the off-screen-geometry check above.
None bundles a native capturer requiring newly-compiled FFI code the way this project's own screen-share segfault trap (`flutter_soloud`, rejected for the notification-sound slice) did; all three wrap system APIs already present on the target OS - GTK/GDK on Linux, Win32 on Windows, AppKit on macOS, and libayatana-appindicator/StatusNotifierItem for the Linux tray - the same shape `audioplayers`'s GStreamer wrap was already accepted under.

**Rejected: `bitsdojo_window`.**
Solves the same problem `window_manager`'s own `setAsFrameless()`/`startDragging()` already solves; two packages implementing the same "make the window draggable and frameless" job is the same objection this project already applies elsewhere (one `AudioPlayer` instance rather than a pool, one charting `CustomPainter` rather than a charting library).
No reason to carry both.

**Rejected: `system_tray`.**
An older, separately-authored alternative to `tray_manager` with no reason to prefer it once `tray_manager` already shares a publisher and idiom family with the window package chosen above.

**Considered and rejected: writing the window/tray plumbing entirely ourselves.**
This is the inverse of the FFI-versus-system-library scar dependencies.md already records, and worth naming for that reason: unlike that case, `window_manager`/`tray_manager` are not bundling a native capturer that needs compiling, they are thin wrappers over real, already-linked system libraries.
Reimplementing three platform-specific window backends plus a D-Bus tray protocol from scratch, for a problem two actively-maintained single-publisher packages already solve, is not the cheaper path the way a three-bar-chart `CustomPainter` was cheaper than a charting library.

**Write-ourselves is still the right call for one specific, narrow piece: the Linux tray-availability probe.**
Querying `IsStatusNotifierHostRegistered` is one D-Bus property read; pulling in a general-purpose Dart D-Bus package for exactly one boolean is a heavier dependency than the job needs, when GDBus is already linked into this app via GTK/GIO.
This project already has the exact precedent for a small hand-written native channel in this same directory: `client/packages/app/linux/runner/clipboard_image_channel.cc`/`.h`, roughly 90 lines total, bridging one narrow piece of GTK/glib functionality no package covers.
The tray-probe channel should follow that same shape rather than adding a new package for one property read.

**Not needed now, named for completeness:** a macOS Dock-menu bridge (`NSApplication`'s `applicationDockMenu` delegate) has no ready Flutter package and would need a small native Swift bridge, the same shape as the existing iOS `BroadcastBridge`; deferred until macOS is actually scaffolded, since building it now against a platform that does not exist yet cannot be verified by anything.

## What is unsure, named rather than smoothed over

- Whether `window_manager`'s Linux `startDragging()`/resize implementation issues the Wayland/X11 native move-and-resize requests (preserving edge-snap and smooth compositor-driven dragging) or repositions the frame manually from Dart (which would fight the compositor); not confirmed by reading the package's own native source in this session.
- Whether `setPreventClose()` combined with a `WindowListener.onWindowClose` reliably intercepts the GTK close button on Wayland specifically. There is a real, adjacent, confirmed data point to weigh rather than trust the package's claim blindly: a filed issue against this same package (`leanflutter/window_manager#563`) reports its separate `setClosable(false)` API having no effect on Linux at all, which does not prove `setPreventClose` shares the bug but is close enough kin to warrant an explicit real-desktop check before this is relied on for the close-to-tray feature's whole premise.
- Whether `tray_manager`'s icon actually renders and behaves correctly on the owner's specific KDE Plasma Wayland session; very likely given KDE's native SNI support, not yet confirmed.
- The 40dp title-bar height figure is a proposal against an estimated native height, not a measurement; confirm against a real screenshot on the owner's desktop before treating it as final.
- The `IsStatusNotifierHostRegistered` check has a documented timing race (the Watcher service can appear slightly before the Host does); checking synchronously at each close click rather than caching once reduces but does not eliminate this, and it has not been load-tested against a real extension being toggled mid-session.

## What is genuinely the owner's decision, not this record's to pick silently

- Whether `Alt+F4`/the window-manager close shortcut on Windows and Linux should behave like the X button (hide) or like a real quit, since the two platforms differ from each other in convention here and neither answer is obviously correct once "close no longer quits" is the premise.
- The exact tray/Dock menu contents beyond Show/Hide, Mute, and Quit - a status picker, per-call actions, or nothing more - is a product call, not an architectural one.
- Whether the custom title bar ships for Linux alone first, the only platform with a real target today, or waits so all three platforms land together, given "all OS's" was the ask but only one OS exists to build against right now.

## Migration order, safest and most reversible first

1. **Add `window_manager` and `screen_retriever` as dependencies, with zero behaviour change.** A compile-only addition to `docs/dependencies.md` and `pubspec.yaml`, reversible by deleting an import; nothing about how the window looks or closes changes yet.
2. **Geometry persistence: size and maximized state only, still inside the existing native GTK frame.** Read/write via `shared_preferences` on the settled resize/close events, applied on next launch with the off-screen-rectangle fallback. This alone already delivers "launches into last known position and size" for the size half of that ask, with the least risk in this whole record, and is independently useful even if nothing else here ever ships. Verified by the new Xvfb CI smoke test.
3. **The startup animation, still inside the native-decorated window.** Swap the first Flutter frame for the small themed loading state using the existing `AppFadeIn`/`AppMotion`, gated on reduce-motion. Purely additive on top of step 2, no new native plugin beyond what step 2 already added, easy to revert on its own.
4. **Close-to-minimise/hide**, shipped together with its own explicit quit affordance in the same change, never before it: macOS's hide-and-keep-running first (closest to zero new surface, since the Dock icon is already there for free), then Windows-when-scaffolded and Linux behind the tray-availability probe from step 5, so close never hides with no way back before the fallback exists.
5. **The tray icon (`tray_manager`) with the minimal menu and the Linux availability probe (the small hand-written GDBus channel).** The most environment-dependent piece in this record and the one needing the most real-desktop verification from the owner; deliberately sequenced after close-to-hide exists behind a feature flag, so it can be toggled off without losing the hide behaviour on platforms where the tray genuinely works.
6. **The frameless custom title bar, last.** Highest cost (reimplements drag, resize, snap, the system menu), highest platform divergence, and the piece `docs/BACKLOG.md` already named as deliberately deferred rather than declined. Land it only once 1-5 are stable and the owner has confirmed the tray and minimise behaviour actually feel right on his own machine, since a bad frameless bar is far harder to quietly back out of than a bad tray icon - the moment it ships, a contributor owns drag/resize/snap forever, exactly the cost `docs/BACKLOG.md`'s own entry already named.

Steps 1-3 touch nothing about how the window closes or is drawn, so they carry no risk of "vanishing" the app; steps 4-5 change process lifecycle but can fall back to an ordinary quit-on-close by turning off `setPreventClose`; step 6 is the only one that changes what the window structurally looks like and is the hardest of the six to walk back once real users have it.

## Superseded 2026-08-27: the startup window is a real small window after all

This section does not delete "The startup window" above; it records why the "not a second OS window" recommendation there no longer holds, and what shipped in its place.

**The owner reaffirmed the ask this record rejected, with a reason it never weighed.** His words, restated here rather than paraphrased: "discord seems to do it fine without flickering, i eventually want to hold the updating within that splash screen." Earlier in the same thread: "the slim m splash screen on desktop is the size of the normal window, it should be a small window." The original "not a second OS window" section above was reasoned entirely against the *startup-animation* use case: a themed loading state masking `restoreSession` and the preference restores, which is over in well under a second. It never considered a splash that has to host update-check/download/install progress - UI that must exist *before* the main window's first frame (an update might need installing before the app can even start) and, for an install that restarts the process, *outlive* that first frame too. That is a genuinely different requirement, not a re-litigation of the same one, and it is the reason this reversal is a deliberate, owner-authorized change rather than an agent overruling its own prior record.

**Both original objections have real answers, now that the reason for a second window is real update UI rather than a startup flourish:**

- **"A second top-level window is a second taskbar entry that flickers in and out."** A window created with the platform's skip-taskbar hint (`window_manager`'s own `setSkipTaskbar`) never registers a taskbar entry at all, so there is nothing to flicker. This answer applies to a *genuine* second window; see below for why this change does not yet build one.
- **"Wayland gives an app no way to place a second window relative to where the real window will land."** True and unchanged, but it was only ever a problem for a splash that needed *relative* placement. A splash wants to be screen-centred, full stop, and centring an unpositioned small toplevel is exactly what compositors already do by default - the existing cold-start code path (`_applySplashGeometry` below) does not set a position at all, the same `setSize` + `center()` idiom this file already used for the no-saved-geometry cold start.

**What actually shipped is the single-window fallback this same file's task brief named as the honest alternative, not a genuine second top-level window - said plainly, not implied.** Investigated and set aside for this change, not silently skipped:

- `desktop_multi_window` (or any second-window plumbing) is not a dependency of this project today, and adding it means new native runner code. macOS and Windows have no runner scaffolded at all (`docs/os_backlog/`), so a genuine second window could only ever be Linux-only right now, and even there it means teaching `my_application.cc` to create and tear down a second `GtkApplicationWindow`/`FlView` pair, or re-entering the executable through `desktop_multi_window`'s own sub-window convention.
- This file's own rule two sections up - "never run `flutter run -d linux`, never launch the built binary outside the Xvfb CI job, never raise a window on this machine's real display" - means new native multi-window code could not be visually verified in this change beyond static review and the existing Xvfb smoke test, which does not yet drive a second window at all. Landing unverified native window-lifecycle code for a feature this display-sensitive was judged the wrong trade against landing a smaller, fully test-covered change now.
- **What shipped instead:** the one real window starts in a fixed small splash shape - `DesktopWindowShell.applyInitialGeometry` now applies `splashWindowSize` (380x460) and centres it, locks resizing, and (Linux) hides the native title bar, all before the splash's own first frame, rather than applying the final saved geometry the way this record originally specified. Once bootstrap finishes, `DesktopWindowShell.prepareHandoff` hides the window, applies the real saved-or-default geometry (including maximized/fullscreen run state), `main.dart` flips `appReadyProvider` so the real UI replaces the splash content while nothing is on screen, and `DesktopWindowShell.revealAfterHandoff` waits for that real UI to actually paint (`SchedulerBinding.endOfFrame`) before showing the window again.
- **The honest cost of that stand-in, not smoothed over:** because it is one window throughout, there is no second taskbar entry to flicker (the taskbar-entry objection is moot by construction, not because `setSkipTaskbar` was used - it was not needed), and "always-on-top while it lives" is likewise moot with only one window to be above. What it does *not* eliminate is a brief hide/show of that one window at the handoff instant - a different, smaller visual cost than the one this record originally rejected, but not literally zero, and not verified against a real display in this change per the rule above.
- **What this stand-in still cannot do, and a genuine second window eventually will:** it cannot outlive a restart of the main process. An update that needs to install and relaunch the app cannot keep this splash up across that relaunch, because the splash and the main window are the same window in the same process - the literal "outlive the main window's first frame" requirement that motivated this whole reversal is only half satisfied (exists *before*, does not yet *outlive*). Building the part of the update flow that installs-and-restarts will need the genuine second window (or a second process) this section declined to build now, at which point `setSkipTaskbar` and real compositor-centred placement are the concrete answers to carry over from here.

**The status line is wired now, structurally, per the owner's "I eventually want to hold the updating within that splash screen."** `StartupScreen` takes a `status` string and renders it below the wordmark; `main.dart`'s `startupStatusProvider` holds the live value and is updated at each phase boundary in `_runBootstrapSequence` ("Restoring session", "Loading preferences", "Connecting"). The text is deliberately plain today - there is no update-checking work to report yet - but the seam a future update flow needs (a provider the splash already watches, updated from wherever that work runs) is the thing this change adds, so wiring real update text later is copy at the call sites, not new plumbing.

## Addendum 2026-08-28: the handoff frame wait was waiting on a window that could not paint

The "not verified against a real display" caveat two paragraphs above turned out to hide a real bug, not just an unmeasured cost. The owner ran the released 0.61.0 Linux tarball on his own Fedora 44 + KDE Plasma Wayland machine and its stdout showed `desktop: splash handoff frame wait failed: TimeoutException after 0:00:05.000000: Future not completed` on every launch - the reveal path was spending the full five seconds of `revealAfterHandoff`'s own timeout before ever showing the window.

**Confirmed by instrumenting a real launch on the same machine, not assumed.** `_port.hide()` (`window_manager`'s `gtk_widget_hide` on the toplevel) leaves the window genuinely unmapped, and an unmapped GTK toplevel never receives another compositor frame callback - so `SchedulerBinding.instance.endOfFrame`, awaited while still hidden, has nothing to ever resolve from. A temporary diagnostic build that logged timestamps around the wait showed the wait failing after the full bound every time while hidden, then the very same `endOfFrame` resolving in under 100ms the instant `_port.show()` ran afterward. This is not a slow bootstrap tripping a tight timeout; it is a wait with no way to succeed while the window stays hidden, on any host, because there is nothing at the OS level to notify it a frame happened.

**The fix reorders `revealAfterHandoff` to `show()` first and wait second**, rather than raising or lowering the timeout. The wait after `show()` is kept, bounded the same way, purely so a host that stalls for a genuinely different reason still gets logged - nothing downstream awaits this method's completion, so the bound protects a log line rather than gating anything. This does not newly risk the stale-splash-frame flash the original wait-before-show order existed to prevent: because that order's own timeout fallback already called `show()` unconditionally once the wait failed, and the wait failed on every single launch on this platform, the exposure this reorder produces - the window becomes visible still showing the last frame the splash painted, at the geometry `prepareHandoff` already applied while hidden, until the already-pending `appReadyProvider` frame lands a moment later - is the same exposure every 0.61.0 launch already had, five seconds sooner.

Verified directly: building the real Linux release binary and running it on the same KDE Plasma Wayland session with this fix applied no longer prints the timeout warning, and the window reaches its real content with no perceptible delay.

## Addendum, 2026-09-25: the Space menu lives in the rail header on every platform

Design review note 22 moved the Space name, connection dot and Space menu into the frameless title bar and hid `RailHeader` there, to avoid two copies of the same line 40px apart.
The owner then found the menu chevron sitting beside the window quit kebab and the window controls read as window chrome, and its items were the wrong kind of thing to find there.
The rail header now renders on every platform and carries the Space's identity and its menu, the shape Slack and Discord use.
The title bar keeps the Space name and the build version as the window's own title and drops the dot and the menu.
The name appears twice on purpose: once as a window title, once as the Space header, doing different jobs.


## Addendum, 2026-10-08: the handoff waits for the splash to be mapped

The desktop shell smoke job failed once with "no window of the splash size 380x460 appeared in the X event log" while GTK logged "Timed out waiting for OpenGL frame of size 1280x720 (have 380x460)".
The runner shows the window from Flutter's first-frame signal, but the splash floor starts counting at bootstrap, so on a loaded host `prepareHandoff` could hide and resize the window before it was ever mapped.
X then first showed it at the real size, and the splash never reached the screen.
A runner delaying that show by 2.5s or more reproduces the failure every time.
`prepareHandoff` now waits, bounded at 15s, for the runner to report the window mapped (`linux_window_mapped_channel.cc`: the window manager's map-event on X11, the map signal elsewhere) before it hides anything.
The splash floor is measured from that map, not from bootstrap: once the runner reports the window mapped, `prepareHandoff` waits out whatever is left of the floor (the runner reports how long the window has been mapped) before it hides anything.
A splash that mapped early loses nothing, and one that mapped late still gets its full dwell on screen.

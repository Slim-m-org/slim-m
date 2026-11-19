# Window states: what updates when nobody is typing in the app

The desktop window is in one of three states, and each has its own rule.
A window on a second monitor is unfocused, not unseen: it has to stay current without being clicked.

| State | What it is | `appLifecycleProvider` | Frames |
|---|---|---|---|
| Focused | The window has input focus | `resumed` | drawn |
| Unfocused | On screen behind or beside another app | `inactive` | drawn |
| Hidden | Closed to the tray or minimised | `hidden` | none, except on Wayland (below) |

`client/packages/app/lib/src/providers/app_lifecycle.dart` is the one source.
It starts from what the embedder reports and corrects it with the window's own events, because the two disagree at the edges.
Read it through `appFocusedProvider`, `appVisibleProvider`, `isWindowVisible` or `isSeenNow`; do not read `WidgetsBinding.instance.lifecycleState` in new code.
A plain `State` with no `ref` listens through `windowScopeOf(context)`.
A phone maps onto the same three: `inactive` is a pulled shade, `hidden` and `paused` are the background.

## How the state is decided

The embedder's report is the base, and four corrections sit on top of it.

**The app's own hide wins over everything.**
Closing to the tray is the app's own call, so the port keeps the fact (`DesktopWindowPort.hiddenByApp`) from its `hide` until the window is shown again, and reports a `hide` event.
The notifier asks the port each time and remembers nothing: every account has a notifier of its own, and one made after the hide would not have seen the event.
Focus is ignored meanwhile: opening the tray menu on Windows focuses the hidden window, and that must not mark the open channel read or restart the clocks.

**A window event that proves the window is on screen corrects Flutter too.**
Focus, show, and a maximise that ends a minimise move the binding's own lifecycle state, one step at a time, not only the provider.
The scheduler draws no frame while the binding says hidden, so a corrected provider alone would restart the timers and repaint nothing.
A blur the embedder missed is the one correction that stays in the provider: a pop-out window taking focus blurs the main one, and moving the binding would park the whole app's keyboard focus.
That is why new code never reads the binding's raw state to decide "focused"; the few old observers that still do are listed under known gaps.

**A focus event alone does not end a minimise.**
On Windows `window_manager` reports `focus` whenever the window is activated, without checking that it is still minimised.
So when the window was minimised, or Flutter's own state says hidden, the notifier asks the window (`DesktopWindowPort.isMinimized`) before it believes the focus.
A window that says it is still minimised, or cannot answer, stays hidden.
A window already on screen is not asked, so an ordinary click costs nothing.
A focus that was not believed is remembered until the next blur or minimise, so if the restore event lands a moment later the window comes back focused.

**A minimise is only as reliable as the platform.**

| Platform | Closed to the tray | Minimised |
|---|---|---|
| Windows | hidden | hidden; a maximised window reports `maximize`, not `restore`, when it comes back |
| Linux on X11 | hidden | hidden |
| Linux on Wayland | hidden | hidden when the compositor reports the window suspended (KWin does); otherwise it stays `inactive` |

On Wayland a minimise changes no window state: `xdg_toplevel` has no minimised state, so GTK 3 never sets the iconified bit that both `window_manager` and the Flutter embedder read.
A minimised window there only loses focus and reads as `inactive`.

What a compositor can send instead is `xdg_toplevel`'s `suspended` state (xdg-shell version 6): "this surface is not being repainted".
GTK 3 turns it into a visibility event on the window and into nothing else, so the Linux runner listens for that event (`linux_window_suspended_channel.cc`) and the port keeps the fact (`DesktopWindowPort.suspendedByCompositor`).
The notifier asks the port each time, as it does for the tray, and reads a suspended window as `hidden`.

What this covers on KDE, from KWin 6.8's `WindowItem::updateVisibility`: a minimised window, one on another virtual desktop or activity, one behind "show desktop", and every window while the screen is locked or switched off.
A window an effect still shows (the minimise animation, the overview) or that is being rendered off screen is not suspended.
A window merely covered by another one is not suspended on KWin; other compositors may suspend it, which is still a window nobody can see.

This correction is provider only, like a missed blur: Flutter's own state is left alone and frames stay on.
A suspended window therefore pauses what the rule below lets a hidden window pause, but it is not in the frame trap, and a wrong report from a compositor cannot freeze a window that is in fact visible.

Measured with GTK 3.24.52 and KWin 6.8.2 (a GTK 3 window under `kwin_wayland --virtual` in a test VM): minimise sends the event, restore lifts it, and the iconified bit never changes.
A compositor or a GTK build that never sends the state changes nothing: the window stays `inactive`, visible, and keeps updating, which is the safe direction.

An earlier version of this file described a check for frames that were asked for and never drawn.
It was removed: the Flutter 3.47 Linux embedder has no vsync callback, so its frames run off a timer whether or not the compositor shows them, and the check could never trip.

## The rule

**Never pauses, in any state.**
Anything a person would call out of date.
The sync socket and what it writes to the local store.
OS notifications, their sounds, the taskbar flash and the badge counts.
Incoming and outgoing rings.
The call itself: audio, the roster the call holds, mute, deafen and speaking state.
The tray menu and the call overlay, which are drawn outside the window.
The call heartbeat and the call restore record.

**May pause when unfocused.**
Only motion and media that exist for their own sake, and work that needs the person at the keyboard.
Animated images (`AnimationGate` freezes them on their current frame; a still image always loads).
Fetching the moving original of a gif.
Your own camera and screen preview, behind the "Pause video in the background" setting.
The microphone test meter in settings.
Marking a channel read and telling the server which channel is being read: an unfocused window is seen, but not necessarily read.
Relaying your own canvas cursor.

**May pause only when hidden.**
Everything that is information but costs something to keep fresh.
The once-a-second clocks (`SecondClock`): the call timer, elapsed times, countdowns.
Roster polling for calls you are not in (`voice_roster.dart`).
Level meters (`level_display.dart`) and the speaking ring's pulse.
Receiving other members' video, behind the same setting.
An inline video and a playing module scene.
A scene's `sweep` timeline is the exception, and deliberately so: it is decoration over an end state that is already correct, so like an animated image it only plays in a focused window and otherwise shows its end state.
Whatever pauses here must catch up the moment the window is shown: refetch or repaint on the change to visible, never on the next tick.

## The frame trap

A hidden window draws no frames, and Riverpod 2 only recomputes a derived provider on a frame.
A `Provider` that watches another provider is derived.
So `ref.listen` on a derived provider, or a `Provider<void>` that does its work in its body, hears nothing while the window is hidden, and fires once when it comes back.
Code that must run while hidden listens to a synchronous source instead:

- a `StateNotifierProvider`, `StateProvider` or `NotifierProvider` itself, or a `.select` of one (`voiceFlagsAtOnce`, `voiceParticipantsAtOnce`, `appFocusedProvider`, `appVisibleProvider`);
- a stream (`liveEventsProvider`) or a `ChangeNotifier` (`onAccountsChanged` for the account host);
- for a value built from several sources, a listener on each source that recomputes with `ref.read` (`onVideoPauseChanged`, `listenLevelDisplayed`).

Inside such a listener, read the same synchronous selections.
A derived provider of the notifier that just changed can still hold its old value there, because listeners run before dependents are marked.

Reading is not the problem, only being told is.
`ref.read` of a derived provider refreshes it first, so a value pulled when it is needed is current in any state.
What goes stale is a side effect that waits to be told: closing a socket, unsubscribing video, cancelling a feed.

Anything that waits for "the next frame" is in the same trap, not only `ref.listen`.
`addPostFrameCallback` never runs in a hidden window, so `AccountHost` closes a removed account's container on a zero timer when `SchedulerBinding.framesEnabled` is false.
The one exception is a container whose widgets are still mounted, the account that was on screen: a widget that reads a closed container from a timer throws, so that container waits for the frame that unmounts them.
Its session is already gone by then, so its socket is too.

A lifecycle change is the commonest case: the state turns `hidden` after frames have already stopped, so "pause this when hidden" written against a derived provider only works if a frame happens to be left over.

Widgets are not affected the same way.
A widget cannot repaint without a frame anyway, and it rebuilds from current state on the first frame after the window returns.

## Testing it

`test/support/window_lifecycle.dart` has the helpers.
`hideTestWindow(tester)` hides the window the way the embedder does and drains the frame that was already asked for; after it, `tester.pump()` draws nothing, so assert after `tester.idle()`.
`unfocusTestWindow(tester)` leaves frames on.
`windowIn(state)` with `windowLifecycle(...)` overrides the provider for a test that only cares about the app's own view of the state.
Mount the container in an `UncontrolledProviderScope` for a hidden-window test: a bare `ProviderContainer` refreshes derived providers on a timer and hides the bug.
Assert on the side effect (what the fake session, source or server saw), or on values a listener collected.
Reading the provider under test refreshes it and makes a late clean-up look prompt.
`SchedulerBinding.framesEnabled` is only true once a widget is mounted, so a test about frames coming back needs `testWidgets` and a `pumpWidget`.

## What follows the window with no frame

These were late in a hidden window and now listen to synchronous sources.

- The server identity re-check (`server_identity_recheck.dart`, decision 0036) asks again the moment the sync is live, and `serverIdentityMismatchedProvider` is a selection of the check, so the sync stands down at once on a changed key.
- `activity_publisher.dart` follows the caller's visibility through `onOwnVisibilityChanged`, so "appear offline" from the tray stops the feeds.
- The end of a call clears the stopped shares, the dismissed mini-player, the stamp pictures and the iOS "a call holds the audio" note through `voiceChannelAtOnce`.
- The popped-out feed set reaches the video interest through `onPopOutLiveFeedsChanged`, so a feed popped out while the main window is hidden is subscribed.

## Known gaps

None loses data; each is late by however long the window stays hidden.

- `share_watch.dart` forgets choices about people who stopped sharing on a frame, on purpose: a dropped connection reports an empty roster and then the failed state as two events, and the frame is what lets them be seen together.
- `activity_publisher.dart`: a feed's availability (`ActivityFeed.available`) can be any listenable, and the stored visibility arrives through `effectiveMeProvider`, whose own refetch waits for a frame.
- `popout_host.dart` closes the window of a share that stopped on a frame; with the main window hidden the pop-out keeps its last picture until then.
- A profile banner that changes while the window is unfocused keeps the old image until focus (`profile_banner.dart`, a gapless image under `AnimationGate`).
- `push_controller.dart` and `spotify_link.dart` still read the binding's raw state. Both ask it on a phone, where there are no window events to disagree with it.
- These still observe the binding directly, so they miss a blur only the window reported (a pop-out taking focus) and a suspended Wayland window:
  `video_playback_controls.dart` leaves its bar up, `channel_draft_saver.dart` saves the draft when typing pauses instead of at once, and what `composer_context_menu.dart`, `app_lock_controller.dart` and `web_update_watch.dart` do with it only matters on a phone or in a browser.
  None of them holds anything open; the push-to-talk hold, which did, now follows `appFocusedProvider`.

Not yet checked on a real desktop:

- Windows: the tray menu on a window closed to the tray, and Win+D twice on a maximised window in a call (the call timer must keep running without a click).
- Windows: whether a minimised window is ever activated at all (closing the foreground window and Win+D are the likely ways). The focus check above is written from `window_manager`'s source, not from a reproduction.
- KDE Wayland: the suspended state on the owner's own session, in the real app. The measurement above used a bare GTK 3 window under a virtual KWin.

Riverpod 3 refreshes providers on a timer when no frame comes, which closes the whole class; until that upgrade, new background work follows the rule above.

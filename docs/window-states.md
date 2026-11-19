# Window states: what updates when nobody is typing in the app

The desktop window is in one of three states, and each has its own rule.
A window on a second monitor is unfocused, not unseen: it has to stay current without being clicked.

| State | What it is | `appLifecycleProvider` | Frames |
|---|---|---|---|
| Focused | The window has input focus | `resumed` | drawn |
| Unfocused | On screen behind or beside another app | `inactive` | drawn |
| Hidden | Closed to the tray or minimised | `hidden` | none |

`client/packages/app/lib/src/providers/app_lifecycle.dart` is the one source.
It starts from what the embedder reports and corrects it with the window's own events, because the two disagree at the edges.
Read it through `appFocusedProvider`, `appVisibleProvider`, `isWindowVisible` or `isSeenNow`; do not read `WidgetsBinding.instance.lifecycleState` in new code.
A phone maps onto the same three: `inactive` is a pulled shade, `hidden` and `paused` are the background.

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

A lifecycle change is the commonest case: the state turns `hidden` after frames have already stopped, so "pause this when hidden" written against a derived provider only works if a frame happens to be left over.

Widgets are not affected the same way.
A widget cannot repaint without a frame anyway, and it rebuilds from current state on the first frame after the window returns.

## Testing it

`test/support/window_lifecycle.dart` has the helpers.
`hideTestWindow(tester)` hides the window the way the embedder does and drains the frame that was already asked for; after it, `tester.pump()` draws nothing, so assert after `tester.idle()`.
`unfocusTestWindow(tester)` leaves frames on.
`windowIn(state)` with `windowLifecycle(...)` overrides the provider for a test that only cares about the app's own view of the state.
Mount the container in an `UncontrolledProviderScope` for a hidden-window test: a bare `ProviderContainer` refreshes derived providers on a timer and hides the bug.

## Known gaps

These still listen through derived providers and only catch up when the window is shown.
None loses data; each is late by however long the window stays hidden.

- The server identity re-check after a reconnect (`server_identity_recheck.dart`, decision 0036): the version probe and the mismatch are both derived, so a hidden window keeps its session on a server whose key changed until it is shown.
- `activity_publisher.dart`: a change of presence visibility or of a feed's availability.
- Clean-up on leaving a call in `stamp_images.dart`, `voice_playback.dart`, `share_watch.dart` and `call_mini_player.dart`.
- Pop-out video windows (`popOutLiveFeedsProvider`): a share that stops while the main window is hidden.

Riverpod 3 refreshes providers on a timer when no frame comes, which closes the whole class; until that upgrade, new background work follows the rule above.

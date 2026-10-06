# 0057 - iOS declares audio and voip, and constructs the PushKit registrar

Status: accepted, 2026-10-05. Amended 2026-10-05: `voip` is back, with the registrar wired (issue 230).

## The problem

`Runner/Info.plist` declared `voip` and `remote-notification`.
`VoipPushRegistrar` (`Runner/VoipCallHandler.swift`) was never constructed, so no PushKit registry existed and no VoIP push could arrive (issue 230).
Apple rejects a binary that declares `voip` without using it (guideline 2.5.4), so the declaration was dropped until the path was real.

## Decision

`UIBackgroundModes` is `audio`, `remote-notification` and `voip`.
`audio` is the honest mode for a call that records and plays audio in the background.
`voip` is declared because `AppDelegate` now constructs `VoipPushRegistrar` during `didFinishLaunching`, which is the only way a VoIP push can wake a killed app.
Calls the UI joins are still reported to CallKit by `VoiceCallReporter.swift`, which keeps its own `CXProvider`.

This reverses the earlier note that avoided `audio` (`docs/research/appstore.md`).
That note feared `audio` used only to keep a silent call alive.
Here the app has live microphone capture and playback for the whole call.

## How the path works

1. `AppDelegate.startVoipRegistration` builds the registrar at launch and caches the PushKit token.
   Dart reads it with `getVoipToken` on the existing push channel and receives later or rotated tokens as `onVoipToken`.
2. `PushController` sends it as `voip_push_token` in `PUT /push`, and registers again when a token lands after the first registration.
3. On a DM ring the server seals the envelope to the device's VoIP token (`push/call_ring.rs`, `TokenSlot::Voip`) and skips an iOS device that has none.
4. The relay sends kind `call` to the `<bundle>.voip` topic with push type `voip` and high priority.
   No separate flag is needed: the kind already selects the topic.
5. Swift reports every VoIP push to CallKit before PushKit's completion runs.
   The envelope is sealed to a key Swift does not hold, so the call shows as "Incoming call" and is ended as unanswered after the 30 second ring timeout.

## The invariant

A VoIP push that is not reported to CallKit gets the app terminated and its VoIP privilege revoked.
Two layers guard it:

- `VoipCallHandlerTests` (the `ios unit tests (callkit invariant)` job) drives `handlePush` and `handle` against a fake provider: well formed, empty, garbage, refused and wrong-typed pushes all report before completing or complete without waiting.
- `scripts/lib/test_ios_voip_invariant.py` reads the Swift source with comments and strings stripped: no early exit precedes the report, the PushKit callback only calls the handler, there is one registry, `AppDelegate` constructs the registrar before launch returns, and `voip` is declared exactly while it does.

## Not verified without a device

Real APNs delivery to the `.voip` topic and the phone ringing from a killed app (confirmed on a device: CallKit shows "Incoming call").
Still to confirm on a device: that answering joins the call without a second accept, that no in-app ring shows beside CallKit, and that an answer on a cold launch finds the DM.
Issue 230 stays open until a device confirms each.

## Answering (amended 2026-10-05)

The push is sealed, so Swift knows neither the channel nor the ring id.
It reports `ringing`, `answered` and `ended` for the CallKit call to Dart on the `callkit_incoming` channel, held until Dart takes them (a cold launch can answer before Dart exists).
`DmCallRingController` joins the two sources: CallKit ringing hides the in-app ring, and an answer joins the DM named by the websocket `call.ringing` frame, whichever arrives first.
Accepting from either surface first fetches the DM over REST if the local store lacks it, since a route to an unloaded channel renders "not found or no access".

# 0057 - iOS declares the audio background mode, not voip

Status: accepted, 2026-10-05.

## The problem

`Runner/Info.plist` declared `voip` and `remote-notification`.
`VoipPushRegistrar` (`Runner/VoipCallHandler.swift`) is never constructed, so no PushKit registry exists and no VoIP push can arrive (issue 230).
Apple rejects a binary that declares `voip` without using it (guideline 2.5.4), and the declaration was the only thing the dormant path still did.

## Decision

`UIBackgroundModes` is now `audio` and `remote-notification`.
`audio` is the honest mode: a call records and plays audio while the app is in the background.
Calls the UI joins are still reported to CallKit by `VoiceCallReporter.swift`, which is unchanged.
PushKit is not wired blind, because it cannot be tested without a device, and a VoIP push that is not reported to CallKit gets the app terminated and its VoIP push privilege revoked.

This reverses the earlier note that avoided `audio` (`docs/research/appstore.md`).
That note feared `audio` used only to keep a silent call alive.
Here the app has live microphone capture and playback for the whole call.

## Left in place

`VoipPushRegistrar`, `VoipCallHandlerTests` and the `ios unit tests (callkit invariant)` job stay as they are.
Nothing server-side or client-side relied on `voip`: the Dart client always sends a null `voip_push_token`, and the server only stores one if given.
Issue 230 stays open for the work below.

## Bringing voip back

1. Construct `VoipPushRegistrar` in `AppDelegate` and add `voip` to `UIBackgroundModes` in the same change.
2. Register the PushKit token with the server through the existing `voip_push_token` field.
3. Make the relay send call pushes to the `<bundle>.voip` APNs topic with the `voip` push type.
4. Test on a device that every VoIP push is reported to CallKit before the handler returns.

# How other projects keep a chosen audio device across reopens

Written 2026-10-18 after a report that the microphone had to be reselected on 0.112.
Sources were read from each repository's default branch on that date; line references name functions rather than numbers because the files move.

## What was compared

- livekit client-sdk-js: `Room.ts` (`handleDeviceChange`, `selectDefaultDevices`), `LocalTrack.ts` (`restart`, `setDeviceId`).
- livekit components-js: `persistent-storage/user-choices.ts` and the `usePersistentUserChoices` hook.
- livekit-examples/meet: the pre-join choices flow in `PageClientImpl.tsx`.
- element-hq/element-call: `state/MediaDevices.ts` (`selectDevice$`, `AudioInput`, `AudioOutput`).
- jitsi lib-jitsi-meet and jitsi-meet: `RTCUtils.js` and `base/devices` (`getDeviceIdByLabel`, `userSelectedMicDeviceId`).

## What they agree on

- The saved preference is a device id that is only ever written by the user.
  A device that goes missing never overwrites it, so it comes back the moment the device does.
  Element Call derives the active device as a pure function of the preference and the current list (`selectDevice$`), so there is no state to get stuck.
  slim-m already keeps the pick and what is in use apart (`_chosenInputId` against `_preferredInputId`).
- A list that looks empty or transitional is not evidence that the device is gone.
  Element Call keeps the preferred id when the browser lists one entry with an empty id (`available.size === 1 && available.has("")`).
- Every reopen passes the pinned id again.
  livekit-js keeps the id in the track's constraints and `restart` reuses them; nothing reopens with "no device" unless the user chose the default.
- "Follow the default" and "pinned" are separate states.
  livekit-js and the components store `default` as its own pseudo id and only follow the OS when that is the active choice.
  slim-m stores null for the default, which is equivalent.
- Device change events trigger a reconcile, not a reselect.
  livekit-js runs `selectDefaultDevices` on `devicechange`: it follows a moved default, and for audio output falls back to the first device when the active one vanished.
  It deliberately does not move a microphone on behalf of the user, because the track ends on its own and a Bluetooth headset blinks.

## Where slim-m differed

- `reconcilePreferences` treated an empty device list as every device being unplugged, so a join or device event on a platform that had not enumerated yet silently moved the capture to the system default.
  Windows lists nothing until audio has been opened, so this was reachable.
  Adopted: an empty list keeps the preference (Element Call's rule).
- The chosen microphone was only re-resolved on device events.
  A headset missing at one open and back before the next stayed on the default until another event arrived.
  Adopted: the pick is reconciled before every unmute that opens the capture.
- The playout device was reset by the native layer on each capture open (see the audio notes in the PR for flutter-webrtc's `GetUserAudio`), which none of the above projects face because browsers keep sinks per element.
  Adopted: reapply the pinned output after every open and every device change.

## Not adopted

- Jitsi stores the label next to the id and falls back to a label match (`getDeviceIdByLabel`) because browser ids rotate between sessions.
  The native ids slim-m uses are endpoint ids and stay stable, so this adds a way to pick the wrong device for no gain.
- livekit-js switches audio output to the first device when the active one disappears.
  slim-m falls back to the system default instead, which is what the person had before choosing, and returns when the device does.

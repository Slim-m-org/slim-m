# Briefing a beta tester

What to tell somebody before they start, and what to ask them afterwards.

`docs/INSTALL.md` covers getting the app onto a device.
This page covers the rest: the things that have never been confirmed on real hardware, so the first tester to touch them is the confirmation.

## Say this before they install

**Invite links are `https://<server>/invite/<code>`.**
Chat apps make them clickable, and the page they open offers to open the app or the web client.
The older `slimm://join?server=...&code=...` form still works, and so does a bare code plus the server address.
See `docs/OPEN-QUESTIONS.md` item 21.

**A link to one message is `slimm://message?...` and works the other way round.**
"Copy message link" on a message produces one, and tapping it opens the app on that message.
It only does anything while signed in, and only when the link names the deployment you are signed into.
A link to somebody else's server is ignored, for the same reason an invite is ignored while signed in: one deployment is one community in v1.

**Voice may not work from outside the host's network** unless the operator has forwarded LiveKit's media ports.
Signalling and text go over 443 and work anywhere; call media does not and cannot.
If calls connect and then carry no audio, or never connect at all, that is the first thing to check - not the tester's device.

**Android calls are unverified.**
`RECORD_AUDIO` was missing from the manifest from the day voice shipped until #231, so no Android call could ever have captured audio.
It is declared now, and no Android device has ever been available here to confirm it.
An Android tester making a call is doing something nobody has done successfully yet.

## The four iOS paths nobody has confirmed

The step-by-step version to hand a tester is `docs/PHONE-TESTER-CHECKLIST.md`.

Each of these is covered only by unit tests against fakes.
There is precedent for taking that seriously: an iOS screen-share fix was recorded as done on 2026-07-29 and a real device later disproved it.

Ask about each one explicitly rather than waiting for a volunteered report - a path that quietly half-works is exactly the kind that nobody thinks to mention.

1. **Screen share surviving.** Start a share from a call. Does it keep going past the first few seconds, or does it raise "Screen Recording has stopped"?
2. **CallKit in the background.** Start a call from inside the app, then background the app. Does the call keep running, and does it appear in the Dynamic Island?
3. **Joining with the camera on.** Turn the camera toggle on in Voice Settings, then join a call. Does video actually start? The capture path has never run here - this box has no webcam.
4. **The lock-screen push preview.** Lock the phone and have somebody send a message. Does the notification name the sender and show the message text, or does it say "New message"?

Number 4 is worth a word of warning, because it fails in a way that looks like success.
Two different things make it fall back to "New message" and they are indistinguishable from the outside: the keychain refusing to hand the extension the push key while the screen is locked, or the sealed box failing to open.
The decryption itself is proven by an XCTest against real server-produced ciphertext.
What is not proven is that a real extension process on a real locked device gets there with a key in hand.

## Capture the answers properly

Treat the first report on any of these as the device confirmation this project has never had, which means it needs to survive being read later:

- device model and OS version
- what they did, in order
- what happened, including the exact wording of any error
- whether it reproduced on a second try

A chat message saying "screen share worked" scrolls away and proves nothing six weeks later.
Put it somewhere durable - the relevant `docs/OPEN-QUESTIONS.md` item is the natural home, since that is what the report closes.

## Do not let anyone "fix" this during beta

`VoipPushRegistrar` is declared and constructed nowhere, so the inbound VoIP push path does not run at all - despite a passing XCTest suite guarding it ([#230](https://github.com/Slim-m-org/slim-m/issues/230)).

That is a deliberate deferral.
Constructing it turns a dormant path into a live one that has to be correct on the very first push, because iOS kills an app that receives a VoIP push and does not report a call synchronously.
The failure mode is the app being terminated on somebody's phone, with no way to test it first.

It looks like dead code somebody forgot. It is not. `docs/OPEN-QUESTIONS.md` item 3 is the full reasoning.

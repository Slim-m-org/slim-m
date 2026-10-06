<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# iOS backlog

See [README.md](README.md) for what "confirmed" and "suspected" mean here and how this differs from `docs/BACKLOG.md` and `docs/OPEN-QUESTIONS.md`.

iOS is one of this project's two primary test targets (`docs/ROADMAP.md`: "Early phases prioritize Linux... and iOS as the primary test targets"), has a real, building, signed CI pipeline reaching TestFlight, and has had more real-device confirmation than any other platform in this project.
It has also had more *reversed* confirmations than any other platform: several fixes were recorded as done on the strength of source-reading or CI passing and were then disproved by a real iPhone.
That pattern is itself worth carrying into how this file is read: a green `client-ios-ci` run or a passing unit test against a fake is evidence of internal consistency, not of behaviour on a phone.

## Confirmed

**A category (`@interface X (Category) ... @end`) on a private Flutter engine class breaks the build at link time, not at runtime, and the failure is silent to every test.**
the pre-trim `CLAUDE.md`, "Image paste on iPhone, confirmed working": a category on `FlutterTextInputView` (resolved only via `NSClassFromString` at runtime, and never exported by the engine at link time) produced `Undefined symbol: _OBJC_CLASS_$_FlutterTextInputView` at the 0.21.2 iOS build, while every Dart test passed and the store build simply never happened.
*The rule to keep, stated in `CLAUDE.md` and worth repeating verbatim*: "never write a category on a class resolved through `NSClassFromString`; graft its methods from a donor class instead, or the next engine-private reference breaks the build the same way." The working fix is `SlimmPasteDonor`, a plain `UIResponder` subclass whose methods are read with `class_getInstanceMethod` and grafted onto the runtime-resolved target with `class_addMethod`.

**Apple's "Allow Paste?" prompt exemption only covers a pasteboard read inside the system's own dispatch of a recognised gesture; a Dart-side callback after the fact does not qualify, and this was verified by tracing the engine, not guessed.**
`CLAUDE.md`: a custom `SystemContextMenu` item's tap round-trips through a method channel into Dart *after* the native tap already dispatched, which is why a custom item was always going to prompt regardless of what it did once tapped.
The working shape instead forces the platform's own standard `IOSSystemContextMenuItemPaste` into Flutter's system-menu item list (`systemContextMenuItemsWithForcedPaste`, `composer_context_menu.dart`), so tapping it dispatches native `paste:` directly with no Dart callback in the middle - confirmed on a real iPhone 2026-08-02, the owner's own words: "paste worked on iphone, i just long pressed in input box and it let me paste this time."
*The rule to keep*: never build a custom system-context-menu item expecting it to be exempt from the paste-consent prompt; only the platform's own standard item, dispatched natively, gets the exemption.

**Withdrawing a working affordance on an unproven claim caused a real, if brief, regression, and the fix is a standing rule with its own regression test.**
`CLAUDE.md`: the "+" sheet's fallback paste row was hidden the moment the edit-menu swizzle reported "installed," on the unverified theory that installing meant the menu item actually worked - it did not (the swizzle installing only proves the Objective-C method exchange succeeded, never that iOS ever asks it anything), and on the owner's own phone the edit menu offered only "Scan Text" while the fallback row was hidden, briefly leaving no way to paste an image at all.
*The rule to keep, and it has a named regression test enforcing it*: `composerClipboardPasteAvailable()` is `hasClipboardImage()` alone, unconditionally, on every mobile platform; `composer_clipboard_paste_test.dart` carries a named guard ("the row still appears when the edit-menu swizzle is confirmed installed") that fails if the gate returns. Never withdraw a working affordance on a claim that something else works, only on evidence that it did.

**iOS screen share was broken by a double-capture collision, and a first "one-flag" fix was recorded as done and then disproved on a real device - the single clearest example in this project of the "recorded done, disproved by hardware" pattern.**
the pre-trim `CLAUDE.md`, "The one-flag iOS screen share fix did not survive a real device": the initial fix (`useiOSBroadcastExtension: true`) was traced through LiveKit 2.8.1's source and reasoned as correct, then failed on a real iPhone with "Screen Recording has stopped due to: Recording interrupted by another application" - because the flag never reached the code path that actually mattered; `BroadcastManager`'s own listener republishes with **no capture options at all** once the extension starts, falling back to a room-level default that was never touched.
The working fix (`BroadcastManager.shouldPublishTrack = false`, a manual deferred publish once `BroadcastBridge.broadcastingChanges` confirms the extension is actually running, then restoring auto-publish only after that) is unit-tested against fakes but **still has never been confirmed on a real device**; see `docs/OPEN-QUESTIONS.md` section 1, still open. Do not treat this as fixed without a fresh device confirmation.

**Screen-share audio (2026-08-13) has no path through this app's Dart capture seam on iOS at all, because iOS screen sharing never runs through that seam in the first place.**
Confirmed two ways: `common/darwin/Classes/FlutterRTCDesktopCapturer.m` (shared with macOS) hardcodes `'audio': false` and an empty `audioTracks` list, unconditionally; and iOS's real screen-share path is `BroadcastManager`'s ReplayKit broadcast extension (see the double-capture entry above), whose own app audio arrives through `RPBroadcastSampleHandler`'s separate audio sample-buffer callbacks - a mechanism nothing in `livekit_client`'s capture-options seam reaches at all.
`client/packages/rtc/lib/src/screen_share_audio.dart`'s `supportsScreenShareAudio` correctly excludes iOS, so the toggle this feature added stays absent rather than present-and-inert.
Real app-audio-in-broadcast on iOS would be native Swift work inside the broadcast extension itself, a materially different and larger piece of work than the toggle this entry documents, and is not scoped or started here.

**The broadcast extension must embed no frameworks, or App Store validation rejects the build outright, with a specific, quotable error.**
`docs/ROADMAP.md`'s Phase 0 status: client 0.6.0 failed at `ios-testflight` with altool error 90206, `"the bundle at Runner.app/PlugIns/BroadcastExtension.appex contains disallowed file 'Frameworks'"`, a regression introduced by the broadcast-extension work landing the same day. Fixed (`949af6b`, "the broadcast extension must embed no frameworks", #92) and confirmed working across several subsequent releases. `hygiene.yml` carries an "ios broadcast extension is wired up" check.

**A cancelled required CI check reads as a failure and can silently skip the TestFlight build while the release still looks perfectly green.**
the pre-trim `CLAUDE.md`, "A release can succeed and still ship no store build": `client-ios-ci` takes roughly 13 minutes on a `macos-latest` runner, and until fixed its concurrency group cancelled the previous commit's in-flight run on every push to `main`; `verify-release-checks` treats a cancelled check as a failure, so client 0.17.0's tag, GitHub release, and changelog were all published correctly while `ios-testflight` was silently skipped by its `needs` gate. Fixed (`cancel-in-progress: false` on `main` for the affected workflows) and confirmed working on client 0.18.0 by reading the individual job conclusions of a release cut immediately after several rapid merges, not by trusting the green summary.
*The rule to keep, restated in `docs/OPEN-QUESTIONS.md` section 13*: a release being green does not mean a release is complete; read the individual job conclusions, especially for the iOS leg, which is the slowest and most cancellation-prone.

**iOS 15.0 is the client's own minimum deployment target, raised specifically in response to a real Apple compliance deadline.**
Confirmed by reading `IPHONEOS_DEPLOYMENT_TARGET = 15.0` across every build configuration in `client/packages/app/ios/Runner.xcodeproj/project.pbxproj`. The owner's own briefing for this task states client 0.29.1 raised it in response to Apple's ITMS-90068 warning, which requires uploads to declare 15.0 or later starting spring 2027; this is recorded here as a compliance constraint to keep in mind before ever lowering the deployment target again.

**Superseded by [decision 0057](../decisions/0057-ios-background-modes.md): the modes are now `audio`, `remote-notification` and `voip`, and `AppDelegate` constructs `VoipPushRegistrar`. The entry below is the earlier reasoning.**

**The `voip` background mode is what grants background execution today, and it is deliberately not `audio`, because `audio` used purely to keep a call alive is a named App Store rejection risk.**
the pre-trim `CLAUDE.md`, "The killed-app ghost was never going to be fixed by a race the sweep always loses": adding `UIBackgroundModes: audio` was considered and rejected, citing `docs/research/appstore.md` and an adversarial review (finding M5) that names `audio`-as-keep-alive as a 2.5.4 rejection risk reviewers reject as a generic keep-alive.
Confirmed by reading `client/packages/app/ios/Runner/Info.plist`: `UIBackgroundModes` contains only `voip`, with an in-file comment explaining PushKit needs it to be woken for a VoIP push at all.
~~**The gap this leaves, confirmed and still open**: a call joined from the app's own UI (not an inbound VoIP push) is never reported to CallKit at all, so it gets none of the background-execution grant CallKit would otherwise provide while holding a reported call - filed as [#212](https://github.com/Slim-m-org/slim-m/issues/212), needing a Dart-to-native call lifecycle bridge that does not exist yet, and explicitly not built here because it also needs real-device verification this environment cannot do.~~

**Built, struck 2026-08-11**, and this is the same claim CLAUDE.md's own sweep struck the same day as one of its two worst - it survived here because two documents carried it and only one was checked.
Issue #212 is closed.
The bridge that "does not exist yet" is `client/packages/platform/lib/src/call_lifecycle_channel.dart` on the Dart side and `client/packages/app/ios/Runner/VoiceCallReporter.swift` on the native side, driven by `providers/voice_call_lifecycle_report.dart`, with tests on both sides; the channel's own doc comment cites the issue by number.
`VoiceCallReporter` deliberately keeps its own `CXProvider`, separate from `VoipPushRegistrar`'s, since that one exists for an inbound push and nothing constructs it (see the next entry).
**Still open, and the reason to keep this entry rather than delete it**: none of it has been confirmed on a real iPhone, so the background-execution grant is reasoned from Apple's own semantics and covered by unit tests only.

**Superseded by [decision 0057](../decisions/0057-ios-background-modes.md): `VoipPushRegistrar` is now constructed at launch; the entry below is the earlier state and the first real push still needs a device.**
**`VoipPushRegistrar` was declared and never constructed - a dormant, dead code path guarded only by a passing test suite that cannot prove it actually runs.**
`docs/OPEN-QUESTIONS.md` section 3 ([#230](https://github.com/Slim-m-org/slim-m/issues/230)): the inbound VoIP push path does not run at all today, and this was deliberately left unfixed rather than wired up autonomously, because "iOS terminates an app that receives a VoIP push and does not report a call synchronously," so the failure mode of wiring it up wrong is the app being killed on the owner's own phone with no local way to test first.

**The iOS Notification Service Extension does not exist, confirmed directly against the current Xcode project.**
Confirmed by reading `client/packages/app/ios/Runner.xcodeproj/project.pbxproj`: exactly three native targets exist (`Runner`, `RunnerTests`, `BroadcastExtension`); there is no notification-service-extension target.
This is the actual Phase 3 deliverable that would replace a generic "New message" banner with real, decrypted content, and it remains unbuilt as of this writing, matching `docs/ROADMAP.md`'s Phase 3 status and the pre-trim `CLAUDE.md`'s notification-sound entry, which separately names "the iOS Notification Service Extension's on-device sound selection" as still open for the same underlying reason (no NSE target).

**A `testWidgets`-style trap exists specifically around `Timer.periodic` and iOS-relevant heartbeat code, and it is worth knowing before touching call-lifecycle tests generally, not iOS-specific but found via iOS-adjacent (CallKit) work.**
the pre-trim `CLAUDE.md`, "The killed-app ghost...": a widget test that creates a `Timer.periodic` (the voice-call heartbeat, relevant to keeping a CallKit-reported call correctly represented) without an intervening `tester.pump()` can hang for a fixed ~57 seconds and then crash the test worker with `Bad state: Cannot close sink while adding stream`, rather than failing cleanly - a flutter_tools-level symptom giving no indication of where to look. The fix is one `await tester.pump()` immediately after the state transition that starts the timer.

**Attempting to fix a masked-test-failure claim by moving heartbeat cleanup into `addTearDown` broke a previously-passing invariant, and the reasoning matters for any future iOS-call-lifecycle test change.**
`CLAUDE.md`: `TestWidgetsFlutterBinding`'s pending-timer check runs immediately after the test body returns, strictly before any `addTearDown` callback executes, so moving cleanup there guarantees the timer is still pending when the check fires - the opposite of the intended fix. Verified directly with a minimal reproduction; the original trailing `controller.leave()` calls were restored.

## Suspected

**Screen share on iOS (the `shouldPublishTrack`-based fix) has never been confirmed on a real device**, despite being reasoned correctly against LiveKit's own source and covered by unit tests against fakes.
`docs/OPEN-QUESTIONS.md` section 1, still open as of this writing: "Start a share from a call and confirm it survives past the first few seconds rather than raising 'Screen Recording has stopped'." Given this project's own history of exactly this kind of claim failing on real hardware (see the confirmed entry above), treat this as unverified rather than fixed until a device confirms it.

**CallKit background execution for a UI-initiated call (issue #212) has never been confirmed on a real device, because it has not been built at all yet.** `docs/OPEN-QUESTIONS.md` section 1.

**The camera pre-toggle has never run on any hardware, because this development environment has no webcam.** `docs/OPEN-QUESTIONS.md` section 1: "This box has no webcam, so the capture path itself has never run." This is distinct from, and upstream of, the camera-background-blur gap - camera capture itself, blur or not, is unverified on iOS hardware.

**The `.ambient` audio-session category for notification chimes has never been proven not to interrupt a real, live call on a real device.**
the pre-trim `CLAUDE.md`, "The seven sounds finally play": the choice of `AudioContextIOS(category: .ambient)` (explicitly without `mixWithOthers`, since the category already implies it, confirmed by reading `AudioContextIOS`'s own asserts) is reasoned from Apple's documented category semantics and `audioplayers`' source, described in that same entry as carrying "the same evidentiary bar the rest of this client's untested-on-device surfaces carry" - i.e., explicitly not proven on hardware.

**`VoipPushRegistrar` construction, if and when it is wired up, is a first-push-must-work situation with no safe local rehearsal.** `docs/OPEN-QUESTIONS.md` section 3, restated here because it shapes how that work should be approached whenever it is picked up: the first real confirmation will necessarily be a live push to the owner's own device, since iOS terminates an app that fails to report a call synchronously on a VoIP push.

**Android's clipboard image paste path has no iOS-equivalent risk, but the reverse is untested: whether the iOS long-press paste fix has any interaction with the composer's other context-menu items (Scan Text, Look Up, etc.) has not been specifically checked beyond confirming Paste itself now appears and works.**
Inferred from the absence of any test or note covering this interaction; `composer_clipboard_paste_test.dart` and the confirmed device pass both focus on Paste's own presence and behaviour, not on whether forcing it into the system menu list altered any other item's behaviour.

# slimm_test_support

Shared test fakes for the client packages.
It is a dev dependency only; nothing under `lib/` of a shipped package imports it.

It is a package of its own, not a `test/support/` folder, because the `api` package tests and the `app` package tests both need it and `api` cannot depend on `app`.
The part that needs Riverpod and the app's providers stays in `client/packages/app/test/support/fake_api.dart`.

## What is here

- `testApi(handler)` builds a `SlimmApi` on an `http` `MockClient` handler with signed-in credentials, for tests that want to stub one route by hand.
- `fakeTokens`, `fakeSession()` and `fakeBaseUrl` are the canned credentials and address.
- `jsonHttpResponse(body, [status])` is a JSON `http.Response`.
- `pollUntil(condition)` waits in real time for the thing itself and throws a `TimeoutException` with a reason if it never happens.
  Reach for it instead of a guessed `Future.delayed`, or a hand-rolled deadline loop that gives up silently.

## In the app package

`client/packages/app/test/support/fake_api.dart` adds:

- `mockApiOverride(handler)` overrides `apiProvider` with a handler-backed api on the app's session.
- `pumpInApp(tester, child, overrides: [...])` mounts a widget under a fresh `ProviderContainer` and the light theme, and returns the container.

The controller fakes live next to it: `fake_sync.dart` (`NoopSyncController`, `StubSyncController`, `LiveSyncController`), `fake_blocks.dart`, `fake_voice.dart` (`FakeVoiceController`) and `features/voice/voice_controller_harness.dart`.
Reach for these before writing a local subclass.
A voice session double extends `dead_voice_session.dart`'s `DeadVoiceSession` and scripts only what differs, so a new `VoiceSession` member is added in one place.

A handler passed to `mockApiOverride` or `testApi` should end in a fallback only for requests the test is not about.
A fallback of `200 []` hides a renamed route, so assert that the request the test is about was made.

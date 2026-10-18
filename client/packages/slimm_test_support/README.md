# slimm_test_support

Shared test fakes for the client packages.
It is a dev dependency only; nothing under `lib/` of a shipped package imports it.

It is a package of its own, not a `test/support/` folder, because the `api` package tests and the `app` package tests both need it and `api` cannot depend on `app`.
The part that needs Riverpod and the app's providers stays in `client/packages/app/test/support/fake_api.dart`.

## What is here

- `FakeSlimmServer` answers by method and path.
  `respond('GET', '/channels', [...])` serves a JSON fixture, `on('DELETE', '/channels/:id', handler)` computes a reply from the request, and the newest route wins.
  A request no route answers is recorded in `unmatched` and gets a 404, so a test can assert nothing unexpected was called.
  `server.api()` returns a `SlimmApi` backed by it, and `requestsTo(method, path)` returns what it received.
- `testApi(handler)` builds a `SlimmApi` on an `http` `MockClient` handler with signed-in credentials, for tests that want to stub one route by hand.
- `fakeTokens`, `fakeSession()` and `fakeBaseUrl` are the canned credentials and address.
- `jsonHttpResponse(body, [status])` is a JSON `http.Response`.

## In the app package

`client/packages/app/test/support/fake_api.dart` adds:

- `mockApiOverride(handler)` overrides `apiProvider` with a handler-backed api on the app's session.
- `fakeServerOverride(server)` overrides `apiProvider` with a `FakeSlimmServer`.
- `pumpInApp(tester, child, overrides: [...])` mounts a widget under a fresh `ProviderContainer` and the light theme, and returns the container.

The controller fakes live next to it: `fake_sync.dart` (`NoopSyncController`, `StubSyncController`, `LiveSyncController`), `fake_blocks.dart`, and `features/voice/voice_controller_harness.dart`.
Reach for these before writing a local subclass.

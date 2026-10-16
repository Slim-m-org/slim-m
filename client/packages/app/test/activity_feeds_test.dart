// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The privacy rules hold for every feed, not just the first one: a feed
/// that is off is never opened, hidden suppresses all of them, and the
/// first feed in priority order wins.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/activity_feeds.dart';
import 'package:slimm_app/src/providers/activity_publisher.dart';
import 'package:slimm_app/src/providers/activity_sharing_settings.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _keyA = 'test.feed.a';
const _keyB = 'test.feed.b';

class _FakeFeed {
  _FakeFeed(this.key, this.kind) {
    feed = ActivityFeed(
      label: key,
      description: key,
      enabled: activitySwitchProvider(key),
      via: key,
      available: Provider<bool>((ref) => available),
      open: (ref) {
        opens++;
        final controller = StreamController<api.PresenceActivity?>(sync: true);
        _controller = controller;
        return controller.stream;
      },
    );
  }

  final String key;
  final api.ActivityKind kind;
  bool available = true;
  int opens = 0;
  late final ActivityFeed feed;
  StreamController<api.PresenceActivity?>? _controller;

  bool get isOpen => _controller?.hasListener ?? false;

  void report(String? title) => _controller?.add(
    title == null ? null : api.PresenceActivity(kind: kind, title: title),
  );
}

class _Harness {
  _Harness(this.a, this.b) {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        activityFeedsProvider.overrideWithValue([a.feed, b.feed]),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              // The stored visibility is read from /me; it is not an activity call.
              if (request.url.path == '/me') {
                return http.Response(
                  '{"id":"self","username":"self","display_name":"Self",'
                  '"created_at":0,"permissions":0,'
                  '"presence_visibility":"online"}',
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              calls.add(
                '${request.method} ${request.url.path}'
                '${request.body.isEmpty ? '' : ' ${request.body}'}',
              );
              return http.Response('', 204);
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
  }

  final _FakeFeed a;
  final _FakeFeed b;
  final events = StreamController<api.ServerEvent>.broadcast(sync: true);
  final calls = <String>[];
  late final ProviderContainer container;

  Future<void> start({bool a = false, bool b = false}) async {
    SharedPreferences.setMockInitialValues({
      if (a) _keyA: true,
      if (b) _keyB: true,
    });
    container.read(activityPublisherProvider);
    await container.read(preferencesProvider.future);
    await settle();
    // Sharing waits for /me to say the visibility.
    for (var i = 0; i < 20; i++) {
      if (container.read(ownVisibilityProvider) != null) break;
      await settle();
    }
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void hide() {
    container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.hidden;
  }

  Future<void> dispose() async {
    container.dispose();
    await events.close();
  }
}

String _type(String call) =>
    (jsonDecode(call.substring(call.indexOf('{'))) as Map)['type'] as String;

void main() {
  late _FakeFeed a;
  late _FakeFeed b;
  late _Harness h;

  setUp(() {
    a = _FakeFeed(_keyA, api.ActivityKind.listening);
    b = _FakeFeed(_keyB, api.ActivityKind.playing);
    h = _Harness(a, b);
  });
  tearDown(() => h.dispose());

  test('every feed is off by default and none is opened', () async {
    await h.start();
    expect(h.container.read(activitySwitchProvider(_keyA)), isFalse);
    expect(h.container.read(activitySwitchProvider(_keyB)), isFalse);
    expect([a.opens, b.opens], [0, 0]);
    expect(h.calls, isEmpty);
  });

  test('a disabled feed emits nothing while its neighbour is on', () async {
    await h.start(b: true);
    expect([a.opens, b.opens], [0, 1]);
    a.report('Song');
    b.report('Game');
    await h.settle();
    expect(h.calls.single, startsWith('PUT /presence/activity'));
    expect(_type(h.calls.single), 'playing');
  });

  test('the first feed in priority order wins, the next takes over', () async {
    await h.start(a: true, b: true);
    b.report('Game');
    a.report('Song');
    await h.settle();
    expect(_type(h.calls.last), 'listening');

    a.report(null);
    await h.settle();
    expect(_type(h.calls.last), 'playing');

    b.report(null);
    await h.settle();
    expect(h.calls.last, 'DELETE /presence/activity');
  });

  test('hidden sends nothing and opens no feed, then clears', () async {
    await h.start(a: true, b: true);
    a.report('Song');
    await h.settle();
    expect(h.calls, hasLength(1));

    h.hide();
    await h.settle();
    expect(h.calls.last, 'DELETE /presence/activity');
    expect([a.isOpen, b.isOpen], [false, false]);
    final sent = h.calls.length;
    a.report('Secret');
    b.report('Secret game');
    await h.settle();
    expect(h.calls, hasLength(sent));
  });

  test('a feed the device cannot run is never opened', () async {
    a.available = false;
    await h.start(a: true);
    expect(a.opens, 0);
    expect(h.container.read(availableActivityFeedsProvider), [b.feed]);
  });

  test('settings can show exactly what was accepted by the server', () async {
    await h.start(a: true);
    expect(h.container.read(sharedActivityProvider), isNull);
    a.report('Song');
    await h.settle();
    expect(h.container.read(sharedActivityProvider)?.title, 'Song');

    await h.container
        .read(activitySwitchProvider(_keyA).notifier)
        .setEnabled(false);
    await h.settle();
    expect(h.container.read(sharedActivityProvider), isNull);
  });
}

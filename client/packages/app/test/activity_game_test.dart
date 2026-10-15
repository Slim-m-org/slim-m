// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Game detection through the real feed list: its own switch, off by
/// default, nothing read or sent until on, nothing while hidden, text capped,
/// and the allowlist readable in Settings (decision 0044).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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
import 'package:slimm_app/src/widgets/activity_sharing_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _FakeGames implements GameSource {
  StreamController<RunningGame?>? _controller;
  int listens = 0;

  @override
  Stream<RunningGame?> watch() {
    listens++;
    final controller = StreamController<RunningGame?>(sync: true);
    _controller = controller;
    return controller.stream;
  }

  bool get open => _controller?.hasListener ?? false;

  void run(String? name) =>
      _controller?.add(name == null ? null : RunningGame(name));
}

class _Harness {
  _Harness(this.games, {NowPlayingSource? music}) {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        nowPlayingSourceProvider.overrideWithValue(music),
        gameSourceProvider.overrideWithValue(games),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              // The stored visibility is read from /me; it is not an activity call.
              if (request.url.path == '/me') {
                return http.Response(
                  '{"id":"self","username":"self","display_name":"Self",'
                  '"created_at":0,"permissions":0}',
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

  final _FakeGames? games;
  final calls = <String>[];
  late final ProviderContainer container;

  Future<void> start({Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    container.read(activityPublisherProvider);
    await container.read(preferencesProvider.future);
    await container.read(meProvider.future);
    await settle();
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);
}

Map<String, dynamic> _body(String call) =>
    jsonDecode(call.substring(call.indexOf('{'))) as Map<String, dynamic>;

void main() {
  test('game detection is off by default and reads no process', () async {
    final games = _FakeGames();
    final h = _Harness(games);
    addTearDown(h.container.dispose);
    await h.start();

    expect(h.container.read(shareGameProvider), isFalse);
    games.run('Terraria');
    await h.settle();
    expect(games.listens, 0);
    expect(h.calls, isEmpty);
  });

  test('the listening switch never turns game detection on', () async {
    final games = _FakeGames();
    final h = _Harness(games);
    addTearDown(h.container.dispose);
    await h.start(prefs: {shareListeningKey: true});
    expect(games.listens, 0);
  });

  test('a running game is sent as playing, and quitting clears it', () async {
    final games = _FakeGames();
    final h = _Harness(games);
    addTearDown(h.container.dispose);
    await h.start(prefs: {shareGameKey: true});

    games.run('Terraria');
    await h.settle();
    expect(h.calls.single, startsWith('PUT /presence/activity'));
    expect(_body(h.calls.single), {'type': 'playing', 'title': 'Terraria'});

    games.run(null);
    await h.settle();
    expect(h.calls.last, 'DELETE /presence/activity');
  });

  test('turning the switch off stops reading and clears', () async {
    final games = _FakeGames();
    final h = _Harness(games);
    addTearDown(h.container.dispose);
    await h.start(prefs: {shareGameKey: true});
    games.run('Terraria');
    await h.settle();

    await h.container.read(shareGameProvider.notifier).setEnabled(false);
    await h.settle();
    expect(games.open, isFalse);
    expect(h.calls.last, 'DELETE /presence/activity');
  });

  test('hidden sends nothing and stops reading', () async {
    final games = _FakeGames();
    final h = _Harness(games);
    addTearDown(h.container.dispose);
    await h.start(prefs: {shareGameKey: true});
    h.container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.hidden;
    await h.settle();

    games.run('Terraria');
    await h.settle();
    expect(h.calls, isEmpty);
    expect(games.open, isFalse);
  });

  test('a long game name is cut to the server cap', () async {
    final games = _FakeGames();
    final h = _Harness(games);
    addTearDown(h.container.dispose);
    await h.start(prefs: {shareGameKey: true});

    games.run('g' * 500);
    await h.settle();
    expect((_body(h.calls.single)['title'] as String).runes.length, 128);
  });

  test('a platform with no game source never sends anything', () async {
    final h = _Harness(null);
    addTearDown(h.container.dispose);
    await h.start(prefs: {shareGameKey: true});
    expect(h.calls, isEmpty);
    expect(h.container.read(availableActivityFeedsProvider), isEmpty);
  });

  testWidgets('settings offers the switch, the list and what is shared', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          nowPlayingSourceProvider.overrideWithValue(null),
          gameSourceProvider.overrideWithValue(_FakeGames()),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: ActivitySharingSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final feeds = ProviderContainer().read(activityFeedsProvider);
    final game = feeds.firstWhere((f) => f.enabled == shareGameProvider);
    final listening = feeds.firstWhere(
      (f) => f.enabled == shareListeningProvider,
    );
    expect(find.text(game.label), findsOneWidget);
    expect(find.text(listening.label), findsNothing);
    expect(find.text('Sharing right now: nothing'), findsOneWidget);
    expect(find.textContaining('Counter-Strike 2'), findsNothing);

    await tester.tap(find.textContaining('listed games'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Counter-Strike 2'), findsOneWidget);
  });
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A value the server refuses will be refused again, so the publisher passes
/// over that feed until it reads something different and shares the next feed
/// instead of retrying the same activity for good.
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
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Music implements NowPlayingSource {
  StreamController<NowPlaying?>? controller;

  @override
  Stream<NowPlaying?> watch() =>
      (controller = StreamController<NowPlaying?>(sync: true)).stream;
}

class _Games implements GameSource {
  StreamController<RunningGame?>? controller;

  @override
  Stream<RunningGame?> watch() =>
      (controller = StreamController<RunningGame?>(sync: true)).stream;
}

/// A publisher over a server that refuses any activity titled `refused`, with
/// 500 for any titled `broken`, and answers everything else.
class _Rig {
  final music = _Music();
  final games = _Games();
  final puts = <String>[];
  late final ProviderContainer container;

  Future<void> start() async {
    SharedPreferences.setMockInitialValues({
      shareListeningKey: true,
      shareGameKey: true,
    });
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
            httpClient: MockClient(_answer),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    container.read(activityPublisherProvider);
    await container.read(preferencesProvider.future);
    await settle();
  }

  Future<http.Response> _answer(http.Request request) async {
    if (request.url.path == '/me') return http.Response('{}', 404);
    if (request.method != 'PUT') return http.Response('', 204);
    final title = (jsonDecode(request.body) as Map<String, dynamic>)['title'];
    puts.add('$title');
    if (title == 'refused') {
      return http.Response(
        '{"error":"no"}',
        400,
        headers: {'content-type': 'application/json'},
      );
    }
    if (title == 'broken') return http.Response('boom', 500);
    return http.Response('', 204);
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void listen(String title) => music.controller!.add(NowPlaying(title: title));

  void play(String name) => games.controller!.add(RunningGame(name));

  String? get shared => container.read(sharedActivityProvider)?.title;

  Future<void> dispose() async => container.dispose();
}

void main() {
  late _Rig rig;

  setUp(() async {
    rig = _Rig();
    await rig.start();
    addTearDown(rig.dispose);
  });

  test('a refused track lets the game be shared instead', () async {
    rig.play('Terraria');
    await rig.settle();
    rig.listen('fine');
    await rig.settle();
    expect(rig.shared, 'fine');

    rig.listen('refused');
    await rig.settle();

    expect(rig.shared, 'Terraria', reason: 'not the old track, not nothing');
  });

  test('a refused track is asked for once, not retried', () async {
    rig.play('Terraria');
    await rig.settle();
    rig.listen('refused');
    await rig.settle();
    rig.play('Terraria 2');
    await rig.settle();

    expect(rig.puts.where((title) => title == 'refused'), hasLength(1));
  });

  test('a different track from the same feed is tried again', () async {
    rig.play('Terraria');
    await rig.settle();
    rig.listen('refused');
    await rig.settle();
    rig.listen('fine');
    await rig.settle();

    expect(rig.shared, 'fine');
  });

  test(
    'a track that comes back after another one is asked for again',
    () async {
      rig.listen('refused');
      await rig.settle();
      rig.listen('fine');
      await rig.settle();
      rig.listen('refused');
      await rig.settle();

      expect(rig.puts.where((title) => title == 'refused'), hasLength(2));
    },
  );

  test('a refusal with nothing else to share leaves nothing shared', () async {
    rig.listen('refused');
    await rig.settle();

    expect(rig.shared, isNull);
    expect(rig.puts, ['refused']);
  });

  test(
    'a server error is not a refusal: the same track is tried again',
    () async {
      rig.listen('broken');
      await rig.settle();
      rig.play('Terraria');
      await rig.settle();
      rig.play('Terraria 2');
      await rig.settle();

      expect(
        rig.puts.where((title) => title == 'broken'),
        hasLength(greaterThan(1)),
      );
    },
  );
}

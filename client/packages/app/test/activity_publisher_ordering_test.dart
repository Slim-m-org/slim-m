// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Activity pushes are one at a time and the newest reading wins, so a slow
/// older request cannot land last and leave the server on a stale value.
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
  late final StreamController<NowPlaying?> controller;

  @override
  Stream<NowPlaying?> watch() =>
      (controller = StreamController<NowPlaying?>(sync: true)).stream;
}

/// Every PUT parks on its own gate, so a test decides the order they finish.
class _Rig {
  final music = _Music();
  final events = <String>[];
  final gates = <Completer<void>>[];
  late final ProviderContainer container;

  Future<void> start() async {
    SharedPreferences.setMockInitialValues({shareListeningKey: true});
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        nowPlayingSourceProvider.overrideWithValue(music),
        gameSourceProvider.overrideWithValue(null),
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
    events.add('start $title');
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    events.add('done $title');
    return http.Response('', 204);
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void listen(String title) => music.controller.add(NowPlaying(title: title));
}

void main() {
  late _Rig rig;

  setUp(() async {
    rig = _Rig();
    await rig.start();
    addTearDown(rig.container.dispose);
  });

  test('a second track waits for the first request to finish', () async {
    rig.listen('A');
    await rig.settle();
    rig.listen('B');
    await rig.settle();
    expect(rig.events, ['start A'], reason: 'B must not overlap A');

    rig.gates[0].complete();
    await rig.settle();
    await rig.settle();
    expect(rig.events, ['start A', 'done A', 'start B']);

    rig.gates[1].complete();
    await rig.settle();
    expect(rig.events.last, 'done B');
    expect(rig.container.read(sharedActivityProvider)?.title, 'B');
  });

  test(
    'readings that arrive while one is in flight collapse to the newest',
    () async {
      rig.listen('A');
      await rig.settle();
      rig.listen('B');
      rig.listen('C');
      await rig.settle();

      rig.gates[0].complete();
      await rig.settle();
      await rig.settle();
      rig.gates[1].complete();
      await rig.settle();

      expect(rig.events, ['start A', 'done A', 'start C', 'done C']);
    },
  );
}

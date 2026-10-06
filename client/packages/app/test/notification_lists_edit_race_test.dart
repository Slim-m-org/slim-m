// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A block or an override changed while the first fetch of its list is still
/// in flight. The edit used to invalidate the whole answer, so every other
/// entry stayed unloaded for the session; the edit is now laid over the answer
/// instead, which keeps it from being undone by a response sent before it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(String body) =>
    http.Response(body, 200, headers: {'content-type': 'application/json'});

/// The GETs wait on [gate]; any other request answers at once, or with a 500
/// while [failWrites] is set.
class _Server {
  final gate = Completer<void>();
  bool failWrites = false;

  Future<http.Response> handle(http.Request request) async {
    if (request.method != 'GET') {
      if (failWrites) return http.Response('boom', 500);
      // A mute answers with the override it stored; the rest have no body.
      return request.method == 'PUT'
          ? _json('{"channel_id":"c3","preference":"nothing"}')
          : http.Response('', 204);
    }
    await gate.future;
    if (request.url.path == '/blocks') return _json('["u1","u2"]');
    return _json(
      '[{"channel_id":"c1","preference":"nothing"},'
      '{"channel_id":"c2","preference":"mentions"}]',
    );
  }
}

ProviderContainer _container(_Server server) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(server.handle),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _settleFetch(_Server server) async {
  server.gate.complete();
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

void main() {
  group('channel overrides', () {
    late _Server server;
    late ProviderContainer container;
    ChannelNotificationOverridesController notifier() =>
        container.read(channelNotificationOverridesProvider.notifier);
    ChannelNotificationOverridesState state() =>
        container.read(channelNotificationOverridesProvider);

    setUp(() {
      server = _Server();
      container = _container(server);
    });

    test('a remote override keeps the rest of the answer', () async {
      notifier().applyRemote('c3', api.NotificationPreference.nothing);
      await _settleFetch(server);

      expect(state().settled, isTrue);
      expect(state().isMuted('c3'), isTrue);
      expect(state().isMuted('c1'), isTrue);
      expect(state().overrideFor('c2'), api.NotificationPreference.mentions);
    });

    test('a local mute survives an answer sent before it', () async {
      unawaited(notifier().mute('c3'));
      await _settleFetch(server);

      expect(state().isMuted('c3'), isTrue);
      expect(state().isMuted('c1'), isTrue);
    });

    test('a clear removes an override the answer still lists', () async {
      unawaited(notifier().clear('c1'));
      await _settleFetch(server);

      expect(state().overrideFor('c1'), isNull);
      expect(state().overrideFor('c2'), api.NotificationPreference.mentions);
    });

    test('a mute the server refused is not laid over the answer', () async {
      server.failWrites = true;
      await expectLater(notifier().mute('c3'), throwsA(anything));
      await _settleFetch(server);

      expect(state().overrideFor('c3'), isNull);
      expect(state().isMuted('c1'), isTrue);
    });
  });

  group('the block list', () {
    late _Server server;
    late ProviderContainer container;
    BlocksController notifier() => container.read(blocksProvider.notifier);
    BlocksState state() => container.read(blocksProvider);

    setUp(() {
      server = _Server();
      container = _container(server);
    });

    test('a block keeps the rest of the answer', () async {
      unawaited(notifier().block('u3'));
      await _settleFetch(server);

      expect(state().settled, isTrue);
      expect(state().ids, {'u1', 'u2', 'u3'});
    });

    test('an unblock removes someone the answer still lists', () async {
      unawaited(notifier().unblock('u1'));
      await _settleFetch(server);

      expect(state().ids, {'u2'});
    });

    test('a block the server refused is not laid over the answer', () async {
      server.failWrites = true;
      await expectLater(notifier().block('u3'), throwsA(anything));
      await _settleFetch(server);

      expect(state().ids, {'u1', 'u2'});
    });
  });
}

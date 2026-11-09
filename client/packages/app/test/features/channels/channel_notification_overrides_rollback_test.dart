// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed override change puts back only the channel it was about: another
/// change made while it was in flight, and already accepted, stays.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Server {
  _Server(this.initial);

  final Map<String, String> initial;
  final Map<String, List<Completer<http.Response>>> _writes = {};

  Future<http.Response> handle(http.Request request) {
    if (request.method == 'GET') {
      return Future.value(
        http.Response(
          jsonEncode([
            for (final e in initial.entries)
              {'channel_id': e.key, 'preference': e.value},
          ]),
          200,
        ),
      );
    }
    final key = '${request.method} ${request.url.path.split('/').last}';
    final reply = Completer<http.Response>();
    (_writes[key] ??= []).add(reply);
    return reply.future;
  }

  /// Answers the [nth] request of [method] for [channel] with success.
  void accept(
    String method,
    String channel, {
    int nth = 0,
    String preference = 'nothing',
  }) => _writes['$method $channel']![nth].complete(
    method == 'DELETE'
        ? http.Response('', 204)
        : http.Response(
            jsonEncode({'channel_id': channel, 'preference': preference}),
            200,
          ),
  );

  void refuse(String method, String channel, {int nth = 0}) =>
      _writes['$method $channel']![nth].complete(
        http.Response(jsonEncode({'error': 'no'}), 500),
      );
}

Future<ChannelNotificationOverridesController> _controller(
  _Server server,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  final controller = container.read(
    channelNotificationOverridesProvider.notifier,
  );
  while (!container.read(channelNotificationOverridesProvider).settled) {
    await Future<void>.delayed(Duration.zero);
  }
  return controller;
}

Map<String, api.NotificationPreference> _held(
  ChannelNotificationOverridesController controller,
) => controller.state.byChannel;

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  test('a failed mute leaves a later mute of another channel alone', () async {
    final server = _Server({});
    final controller = await _controller(server);

    final a = controller.mute('A');
    final aFailed = expectLater(a, throwsA(isA<api.ApiException>()));
    final b = controller.mute('B');
    await _pump();
    server.accept('PUT', 'B');
    await b;
    server.refuse('PUT', 'A');
    await aFailed;

    expect(_held(controller), {'B': api.NotificationPreference.nothing});
  });

  test('a failed change puts back what that channel held before', () async {
    final server = _Server({'A': 'mentions'});
    final controller = await _controller(server);

    final a = controller.mute('A');
    final aFailed = expectLater(a, throwsA(isA<api.ApiException>()));
    await _pump();
    server.refuse('PUT', 'A');
    await aFailed;

    expect(_held(controller), {'A': api.NotificationPreference.mentions});
  });

  test(
    'a failed clear leaves a later clear of another channel alone',
    () async {
      final server = _Server({'A': 'nothing', 'B': 'nothing'});
      final controller = await _controller(server);

      final a = controller.clear('A');
      final aFailed = expectLater(a, throwsA(isA<api.ApiException>()));
      final b = controller.clear('B');
      await _pump();
      server.accept('DELETE', 'B');
      await b;
      server.refuse('DELETE', 'A');
      await aFailed;

      expect(_held(controller), {'A': api.NotificationPreference.nothing});
    },
  );

  test('a failure does not undo a newer change to the same channel', () async {
    final server = _Server({});
    final controller = await _controller(server);

    final first = controller.mute('A');
    final firstFailed = expectLater(first, throwsA(isA<api.ApiException>()));
    final second = controller.everything('A');
    await _pump();
    server.refuse('PUT', 'A');
    await firstFailed;

    expect(_held(controller), {'A': api.NotificationPreference.everything});

    server.accept('PUT', 'A', nth: 1, preference: 'everything');
    await second;
    expect(_held(controller), {'A': api.NotificationPreference.everything});
  });
}

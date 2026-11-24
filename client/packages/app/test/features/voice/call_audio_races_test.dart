// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Call audio keeps what the route says and what a frame says when their replies cross.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/call_audio.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

Map<String, dynamic> _session() => {
  'module_id': 'transcript',
  'module_name': 'Transcript',
  'purpose': 'Writes down what is said.',
  'keeps': 'The text, for 30 days.',
  'status': 'on',
  'asked_by': 'asker',
  'included': ['asker'],
  'pending': <String>[],
  'expires_at_ms': DateTime.now().millisecondsSinceEpoch + 60000,
  'full': false,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

ProviderContainer _container(
  StreamController<api.ServerEvent> events,
  Future<http.Response> Function(http.Request) handler,
) {
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      apiProvider.overrideWith((ref) {
        final client = testApi(
          handler,
          session: api.SessionStore(tokens: _tokens),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  late StreamController<api.ServerEvent> events;

  setUp(() {
    events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
  });

  test(
    'a read that a frame overtook still brings startable and transcribable',
    () async {
      final reply = Completer<void>();
      final firstRead = Completer<void>();
      var reads = 0;
      final container = _container(events, (request) async {
        reads++;
        if (reads == 1) {
          firstRead.complete();
          await reply.future;
        }
        return _json({
          'session': null,
          'startable': <Object>[],
          'transcribable': true,
        });
      });
      final sub = container.listen(callAudioProvider('c1'), (_, __) {});
      addTearDown(sub.close);
      await firstRead.future;

      events.add(
        api.VoiceCallAudioChanged(
          channelId: 'c1',
          state: api.CallAudioState.fromJson(_session()),
        ),
      );
      await pumpEventQueue();
      reply.complete();
      await pumpEventQueue();

      expect(sub.read().session, isNotNull);
      expect(sub.read().status.transcribable, isTrue);
    },
  );

  test(
    'a request reply that a frame overtook does not overwrite the frame',
    () async {
      final reply = Completer<void>();
      final container = _container(events, (request) async {
        if (request.method == 'POST') {
          await reply.future;
          return _json({'session': null, 'startable': <Object>[]});
        }
        return _json({'session': null, 'startable': <Object>[]});
      });
      final sub = container.listen(callAudioProvider('c1'), (_, __) {});
      addTearDown(sub.close);
      await pumpEventQueue();

      final asking = container
          .read(callAudioProvider('c1').notifier)
          .request('transcript');
      await pumpEventQueue();
      events.add(
        api.VoiceCallAudioChanged(
          channelId: 'c1',
          state: api.CallAudioState.fromJson(_session()),
        ),
      );
      await pumpEventQueue();
      reply.complete();
      await asking;
      await pumpEventQueue();

      expect(sub.read().session, isNotNull);
      expect(sub.read().busy, isFalse);
    },
  );

  test('a second request while one is in flight sends nothing', () async {
    final reply = Completer<void>();
    var posts = 0;
    final container = _container(events, (request) async {
      if (request.method == 'POST') {
        posts++;
        await reply.future;
      }
      return _json({'session': null, 'startable': <Object>[]});
    });
    final sub = container.listen(callAudioProvider('c1'), (_, __) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    final controller = container.read(callAudioProvider('c1').notifier);

    final first = controller.request('transcript');
    final second = controller.request('transcript');
    await pumpEventQueue();
    reply.complete();
    await Future.wait([first, second]);

    expect(posts, 1);
  });
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `DmCallActivityController` on its own: what each roster answer lights, the
/// retry after a failed lookup, the live-event refetch, and `clear()`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/dm_call_activity.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';

typedef _Roster = http.Response Function(String channelId, int call);

http.Response _roster(List<String> userIds) => http.Response(
  jsonEncode({
    'participants': [
      for (final id in userIds) {'user_id': id, 'display_name': id},
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _status(int code) => http.Response(
  jsonEncode({'error': 'x'}),
  code,
  headers: {'content-type': 'application/json'},
);

class _Fixture {
  _Fixture(this.container, this.events, this.calls);
  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final Map<String, int> calls;

  DmCallActivityController get controller =>
      container.read(dmCallActivityProvider.notifier);
  Map<String, bool> get state => container.read(dmCallActivityProvider);
}

_Fixture _fixture(_Roster answer) {
  final events = StreamController<api.ServerEvent>.broadcast();
  final calls = <String, int>{};
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      liveEventsProvider.overrideWithValue(events.stream),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            final channelId = request.url.pathSegments[1];
            final call = calls[channelId] = (calls[channelId] ?? 0) + 1;
            return answer(channelId, call);
          }),
        ),
      ),
    ],
  );
  addTearDown(() {
    container.dispose();
    events.close();
  });
  return _Fixture(container, events, calls);
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'another participant lights the row and the caller alone does not',
    () async {
      final f = _fixture((id, _) => _roster(id == 'dm-1' ? ['other'] : ['me']));

      f.controller
        ..ensureTracked('dm-1')
        ..ensureTracked('dm-2');
      await _settle();

      expect(f.state, {'dm-1': true, 'dm-2': false});
    },
  );

  test('asking again for a known channel costs no second request', () async {
    final f = _fixture((_, _) => _roster(['other']));

    f.controller.ensureTracked('dm-1');
    await _settle();
    f.controller.ensureTracked('dm-1');
    await _settle();

    expect(f.calls['dm-1'], 1);
  });

  test('a lookup that failed is retried on the next ask', () async {
    final f = _fixture(
      (_, call) => call == 1 ? _status(500) : _roster(['other']),
    );

    f.controller.ensureTracked('dm-1');
    await _settle();
    expect(f.state['dm-1'], isNull, reason: 'the first lookup failed');
    f.controller.ensureTracked('dm-1');
    await _settle();

    expect(f.state['dm-1'], isTrue);
  });

  test('a deployment without voice is asked once and never again', () async {
    final f = _fixture((_, _) => _status(501));

    f.controller.ensureTracked('dm-1');
    await _settle();
    f.controller.ensureTracked('dm-1');
    await _settle();

    expect(f.calls['dm-1'], 1);
  });

  test('a live event refetches a tracked channel and ignores others', () async {
    var other = true;
    final f = _fixture((_, _) => _roster(other ? ['other'] : []));
    f.controller.ensureTracked('dm-1');
    await _settle();
    expect(f.state['dm-1'], isTrue);

    other = false;
    f.events
      ..add(const api.VoiceActivityChanged(channelId: 'dm-1'))
      ..add(const api.VoiceActivityChanged(channelId: 'dm-9'));
    await _settle();

    expect(f.state['dm-1'], isFalse);
    expect(
      f.calls['dm-9'],
      isNull,
      reason: 'never asked about, so not fetched',
    );
  });

  test(
    'clear forgets every state and lets the channel be learned again',
    () async {
      final f = _fixture((_, _) => _roster(['other']));
      f.controller.ensureTracked('dm-1');
      await _settle();

      f.controller.clear();
      expect(f.state, isEmpty);
      f.controller.ensureTracked('dm-1');
      await _settle();

      expect(f.calls['dm-1'], 2);
      expect(f.state['dm-1'], isTrue);
    },
  );
}

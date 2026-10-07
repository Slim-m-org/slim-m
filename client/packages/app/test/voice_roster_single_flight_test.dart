// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Roster polls never overlap, so answers cannot land out of order and a
/// burst of events cannot count as a run of failures.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

class _Request {
  _Request(this.ids);

  final List<String> ids;
  final gate = Completer<void>();
}

class _Rig {
  _Rig() {
    final apiClient = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: api.SessionStore(tokens: _tokens),
      httpClient: MockClient((_) async {
        final request = _Request(List.of(serverIds));
        requests.add(request);
        await request.gate.future;
        if (rateLimited) {
          return http.Response('{"error":"rate limited"}', 429);
        }
        return http.Response(
          jsonEncode({
            'participants': [
              for (final id in request.ids) {'user_id': id, 'display_name': id},
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(apiClient.close);
    container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(apiClient),
        liveEventsProvider.overrideWithValue(events.stream),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
    container.listen(voiceRosterProvider('v1'), (_, _) {});
  }

  final events = StreamController<api.ServerEvent>.broadcast(sync: true);
  final requests = <_Request>[];
  var serverIds = <String>['a'];
  var rateLimited = false;
  late final ProviderContainer container;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  int get inFlight => requests.where((r) => !r.gate.isCompleted).length;
}

void main() {
  test(
    'polls never overlap and the newest answer is the one on screen',
    () async {
      final rig = _Rig();
      await rig.settle();
      rig.serverIds = ['a', 'b'];
      rig.events.add(
        const api.VoiceParticipantJoined(channelId: 'v1', userId: 'b'),
      );
      await rig.settle();
      expect(rig.inFlight, lessThanOrEqualTo(1), reason: 'one poll at a time');

      // Answer the newest outstanding request first, then the rest.
      while (true) {
        final pending = rig.requests.where((r) => !r.gate.isCompleted).toList();
        if (pending.isEmpty) break;
        pending.last.gate.complete();
        await rig.settle();
      }

      final ids = rig.container
          .read(voiceRosterProvider('v1'))
          .value!
          .map((p) => p.userId)
          .toList();
      expect(ids, [
        'a',
        'b',
      ], reason: 'the roster on screen must be the newest');
    },
  );

  test('a burst of rate-limited events is not a persistent failure', () async {
    final rig = _Rig()..rateLimited = true;
    await rig.settle();
    for (var i = 0; i < 3; i++) {
      rig.events.add(const api.VoiceActivityChanged(channelId: 'v1'));
    }
    await rig.settle();
    while (true) {
      final pending = rig.requests.where((r) => !r.gate.isCompleted).toList();
      if (pending.isEmpty) break;
      pending.first.gate.complete();
      await rig.settle();
    }

    expect(
      rig.container.read(voiceRosterProvider('v1')).hasError,
      isFalse,
      reason: 'a single burst is one bad moment; the next poll would succeed',
    );
  });
}

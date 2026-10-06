// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A backlog round that fails while the socket is still attaching must not
/// leave the controller claiming live with the rest of the backlog unfetched.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/sync_harness.dart';
import 'support/sync_live_rig.dart';

/// `/sync` answers `has_more` first, then [secondRound], then a complete page.
FutureOr<http.Response> Function(http.Request) _syncRounds({
  required http.Response Function() secondRound,
  required void Function(int round) onRound,
  required void Function() onComplete,
}) {
  var round = 0;
  return (_) {
    round++;
    onRound(round);
    if (round == 1) {
      return jsonResponse({
        'scopes': [
          {
            'channel_id': 'c1',
            'messages': <dynamic>[],
            'has_more': true,
            'reset': false,
          },
        ],
      });
    }
    if (round == 2) return secondRound();
    onComplete();
    return jsonResponse({
      'scopes': [
        {
          'channel_id': 'c1',
          'messages': [rigMessage('m2', 2, 'the rest of the backlog')],
          'has_more': false,
          'reset': false,
        },
      ],
    });
  };
}

http.Response _serverError() => http.Response(
  '{"error":"boom"}',
  500,
  headers: {'content-type': 'application/json'},
);

http.Response _completePage() => jsonResponse({
  'scopes': [
    {
      'channel_id': 'c1',
      'messages': [rigMessage('m2', 2, 'the rest of the backlog')],
      'has_more': false,
      'reset': false,
    },
  ],
});

void main() {
  test(
    'a failed second backlog round during attach is retried before live',
    () async {
      final ticketGate = Completer<void>();
      var rounds = 0;
      var completeAnswered = false;
      final rig = await SyncLiveRig.build(
        (router) => router
          ..on('POST', '/auth/ws-ticket', (_) async {
            await ticketGate.future;
            return jsonResponse({'ticket': 'tix', 'expires_at': 0});
          })
          ..on(
            'POST',
            '/sync',
            _syncRounds(
              secondRound: _serverError,
              onRound: (r) => rounds = r,
              onComplete: () => completeAnswered = true,
            ),
          ),
        seeded: [rigMessage('m1', 1, 'one')],
      );
      rig.signIn();

      await rig.waitFor(() => rounds >= 2, ms: 2000);
      expect(rounds, 2, reason: 'sanity: the second round ran and failed');
      ticketGate.complete();

      var liveWithGap = false;
      for (var i = 0; i < 320; i++) {
        if (rig.status.name == 'live') {
          liveWithGap = !completeAnswered;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(
        liveWithGap,
        isFalse,
        reason: 'status went live before the backlog was fully fetched',
      );
      expect(completeAnswered, isTrue, reason: 'the backlog is never finished');
    },
  );

  test('control: when the second backlog round succeeds the status goes live '
      'with the backlog complete', () async {
    final ticketGate = Completer<void>();
    var rounds = 0;
    final rig = await SyncLiveRig.build(
      (router) => router
        ..on('POST', '/auth/ws-ticket', (_) async {
          await ticketGate.future;
          return jsonResponse({'ticket': 'tix', 'expires_at': 0});
        })
        ..on(
          'POST',
          '/sync',
          _syncRounds(
            secondRound: _completePage,
            onRound: (r) => rounds = r,
            onComplete: () {},
          ),
        ),
      seeded: [rigMessage('m1', 1, 'one')],
    );
    rig.signIn();

    await rig.waitFor(() => rounds >= 2, ms: 2000);
    ticketGate.complete();
    await rig.waitFor(() => rig.status.name == 'live', ms: 5000);

    expect(rig.status.name, 'live');
    expect((await rig.contents())['m2'], 'the rest of the backlog');
  });
}

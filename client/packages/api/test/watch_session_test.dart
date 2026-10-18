// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The watch session read and its tick frame. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

SlimmApi _client(http.Response Function(http.Request) answer) =>
    testApi((request) async => answer(request),
        session: SessionStore(
          tokens: const TokenPair(
            userId: 'u1',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 4102444800000,
          ),
        ));

const _session = {
  'channel_id': 'c1',
  'bot_user_id': 'b1',
  'item_id': 'item-1',
  'title': 'A Film',
  'duration_ms': 5400000,
  'playing': true,
  'position_ms': 5025000,
  'sampled_at_ms': 1000,
  'epoch': 2,
  'controller_user_id': null,
  'ttl_ms': 30000,
  'server_time_ms': 3500,
};

void main() {
  test('reads the session the route returns', () async {
    late http.Request seen;
    final client = _client((request) {
      seen = request;
      return http.Response(
        jsonEncode(_session),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final session = await client.getWatchSession('c1');
    expect(seen.method, 'GET');
    expect(seen.url.path, '/channels/c1/watch-session');
    expect(session!.title, 'A Film');
    expect(session.positionMs, 5025000);
    expect(session.serverTimeMs - session.sampledAtMs, 2500);
    expect(session.controllerUserId, isNull);
    expect(session.ttlMs, 30000);
  });

  test('a room with nothing playing is null, not an error', () async {
    final client = _client(
      (_) => http.Response(
        jsonEncode({'error': 'no watch session'}),
        404,
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(await client.getWatchSession('c1'), isNull);
  });

  test('parses a watch.tick frame and drops a malformed one', () {
    final tick = ServerEvent.parse(
      jsonEncode({
        'type': 'watch.tick',
        'channel_id': 'c1',
        'bot_user_id': 'b1',
        'ended': true,
        'item_id': 'item-1',
        'playing': false,
        'position_ms': 7000,
        'sampled_at_ms': 1,
        'epoch': 3,
      }),
    );
    expect(tick, isA<WatchTick>());
    tick as WatchTick;
    expect(tick.positionMs, 7000);
    expect(tick.playing, isFalse);
    expect(tick.epoch, 3);
    expect(tick.botUserId, 'b1');
    expect(tick.ended, isTrue);

    final bad = ServerEvent.parse(
      jsonEncode({'type': 'watch.tick', 'channel_id': 'c1'}),
    );
    expect(bad, isNot(isA<WatchTick>()));
  });
}

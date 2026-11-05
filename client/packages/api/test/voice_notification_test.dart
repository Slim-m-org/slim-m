// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `/voice-notifications/channels` and the `voice.notice` frame.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

SlimmApi _api(MockClient client) => SlimmApi(
      baseUrl: _base,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: client,
    );

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

void main() {
  test('listVoiceNotifications parses every entry', () async {
    final api = _api(
      MockClient(
        (_) async => _json([
          {'channel_id': 'c1', 'joins': 'first', 'streams': false},
          {'channel_id': 'c2', 'joins': 'off', 'streams': true},
        ]),
      ),
    );
    addTearDown(api.close);

    final choices = await api.listVoiceNotifications();

    expect(choices.map((c) => c.channelId), ['c1', 'c2']);
    expect(choices[0].joins, VoiceJoinMode.first);
    expect(choices[1].streams, isTrue);
  });

  test('setVoiceNotification sends both choices and reads the answer',
      () async {
    late http.Request seen;
    final api = _api(
      MockClient((request) async {
        seen = request;
        return _json({'channel_id': 'c1', 'joins': 'every', 'streams': true});
      }),
    );
    addTearDown(api.close);

    final saved = await api.setVoiceNotification(
      'c1',
      joins: VoiceJoinMode.every,
      streams: true,
    );

    expect(seen.method, 'PUT');
    expect(seen.url.path, '/voice-notifications/channels/c1');
    expect(jsonDecode(seen.body), {'joins': 'every', 'streams': true});
    expect(saved.joins, VoiceJoinMode.every);
  });

  test('an unknown join mode reads as off', () {
    expect(VoiceJoinMode.parse('someday'), VoiceJoinMode.off);
  });

  test('parses every voice.notice activity', () {
    for (final (wire, activity) in [
      ('call_started', VoiceActivity.callStarted),
      ('joined', VoiceActivity.joined),
      ('streaming', VoiceActivity.streaming),
    ]) {
      final event = ServerEvent.parse(
        jsonEncode({
          'type': 'voice.notice',
          'channel_id': 'c1',
          'actor_id': 'u2',
          'activity': wire,
        }),
      );
      expect(event, isA<VoiceNotice>());
      final notice = event! as VoiceNotice;
      expect(notice.channelId, 'c1');
      expect(notice.actorId, 'u2');
      expect(notice.activity, activity);
    }
  });

  test('a voice.notice with an unknown activity is not an event', () {
    expect(
      ServerEvent.parse(
        jsonEncode({
          'type': 'voice.notice',
          'channel_id': 'c1',
          'actor_id': 'u2',
          'activity': 'dancing',
        }),
      ),
      isNull,
    );
  });
}

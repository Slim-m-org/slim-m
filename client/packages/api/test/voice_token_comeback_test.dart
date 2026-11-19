// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A rejoin nobody asked for says so when it asks for its token, and reads the server's refusal by its code.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

const _token = {
  'url': 'wss://sfu.example.com',
  'room': 'channel-1',
  'token': 'jwt',
  'expires_at': 0,
  'can_publish': true,
};

SlimmApi _api(List<http.Request> seen, {String? refusal}) =>
    testApi((request) async {
      seen.add(request);
      return http.Response(
        refusal ?? jsonEncode(_token),
        refusal == null ? 200 : 409,
        headers: {'content-type': 'application/json'},
      );
    },
        session: SessionStore(
          tokens: const TokenPair(
            userId: 'alice',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ));

void main() {
  test('a join a person asked for is not marked automatic', () async {
    final seen = <http.Request>[];
    await _api(seen).voiceToken('channel-1');
    expect(seen.single.url.queryParameters, isNot(contains('automatic')));
  });

  test('a comeback is marked automatic', () async {
    final seen = <http.Request>[];
    await _api(seen).voiceToken('channel-1', automatic: true);
    expect(seen.single.url.queryParameters['automatic'], 'true');
  });

  test('a refused comeback is read by its code, not its sentence', () async {
    final api = _api(
      [],
      refusal: '{"error":"anything at all","code":"on_call_elsewhere"}',
    );
    await expectLater(
      api.voiceToken('channel-1', automatic: true),
      throwsA(
        isA<ConflictException>()
            .having((e) => e.isOnCallElsewhere, 'isOnCallElsewhere', isTrue),
      ),
    );
  });

  test('a full or locked room is not mistaken for a call elsewhere', () async {
    final api = _api([], refusal: '{"error":"this call is full"}');
    await expectLater(
      api.voiceToken('channel-1'),
      throwsA(
        isA<ConflictException>()
            .having((e) => e.isOnCallElsewhere, 'isOnCallElsewhere', isFalse),
      ),
    );
  });
}

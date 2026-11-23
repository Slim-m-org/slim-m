// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wire for the caller's own call statistics (decision 0113).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

SlimmApi _api(Future<http.Response> Function(http.Request request) handler) =>
    SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

const _body = {
  'since': 1000,
  'calls': 2,
  'talk_ms': 170000,
  'words': 15,
  'characters': 7,
  'words_per_minute': 6.4,
  'fillers': {
    'total': 6,
    'per_100_words': 40.0,
    'phrases': [
      {'phrase': 'um', 'count': 1},
    ],
  },
  'languages': [
    {
      'code': 'en',
      'talk_ms': 140000,
      'share': 0.824,
      'pace': 6.4,
      'unit': 'words'
    },
    {
      'code': 'other',
      'talk_ms': 30000,
      'share': 0.176,
      'pace': null,
      'unit': 'words'
    },
  ],
  'buckets': {
    'size': 'week',
    'items': [
      {'date': '2026-10-19', 'talk_ms': 170000, 'words': 15},
    ],
  },
  'retention_days': 30,
};

void main() {
  test('the stats ask for the caller only and parse every field', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response(
        jsonEncode(_body),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final stats = await api.myCallStats(days: 30, timezone: 'Europe/Berlin');
    expect(seen.url.path, '/me/call-stats');
    expect(seen.url.queryParameters, {'days': '30', 'tz': 'Europe/Berlin'});
    expect((stats.calls, stats.talkMs, stats.words), (2, 170000, 15));
    expect(stats.wordsPerMinute, 6.4);
    expect(stats.fillers!.per100Words, 40.0);
    expect(stats.fillers!.phrases.single.phrase, 'um');
    expect(stats.languages.map((l) => l.code), ['en', 'other']);
    expect(stats.languages.last.pace, isNull);
    expect((stats.weekly, stats.buckets.single.date), (true, '2026-10-19'));
    expect(stats.retentionDays, 30);
    expect(stats.isEmpty, isFalse);
  });

  test('nothing counted parses as empty, with no fillers', () async {
    final api = _api((request) async => http.Response(
          jsonEncode({
            ..._body,
            'since': null,
            'calls': 0,
            'talk_ms': 0,
            'words': 0,
            'characters': 0,
            'words_per_minute': null,
            'fillers': null,
            'languages': <Object>[],
            'buckets': {'size': 'day', 'items': <Object>[]},
            'retention_days': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final stats = await api.myCallStats(transcriptId: 't1');
    expect(stats.isEmpty, isTrue);
    expect(
        (stats.fillers, stats.since, stats.retentionDays), (null, null, null));
  });
}

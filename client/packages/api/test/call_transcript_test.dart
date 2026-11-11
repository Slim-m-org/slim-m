// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wire for call transcripts kept by the server (decision 0113).
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

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

const _settings = {
  'join_policy': 'invite',
  'call_transcription': 'on_request',
  'call_transcript_retention_days': null,
  'call_transcription_available': false,
};

void main() {
  test('a transcript page parses its lines and the cursor', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return _json({
        'id': 't1',
        'channel_id': 'c1',
        'started_at': 100,
        'ended_at': null,
        'mode': 'always',
        'lines': [
          {'seq': 1, 'speaker_id': 'u2', 'at': 120, 'text': 'hello'},
        ],
        'next_after_seq': 1,
      });
    });
    final page = await api.callTranscript('t1', afterSeq: 0, limit: 8);
    expect(seen.url.path, '/voice/transcripts/t1');
    expect(seen.url.queryParameters, {'after_seq': '0', 'limit': '8'});
    expect(page.ongoing, isTrue);
    expect(page.mode, 'always');
    expect(page.lines.single.text, 'hello');
    expect(page.lines.single.speakerId, 'u2');
    expect(page.nextAfterSeq, 1);
  });

  test('deleting a transcript is a DELETE with no body back', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response('', 204);
    });
    await api.deleteCallTranscript('t1');
    expect((seen.method, seen.url.path), ('DELETE', '/voice/transcripts/t1'));
  });

  test('search parses hits and sends the paging cursor', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return _json([
        {
          'transcript_id': 't1',
          'channel_id': 'c1',
          'seq': 4,
          'speaker_id': 'u2',
          'at': 500,
          'text': 'ship it',
          'highlight': '<mark>ship</mark> it',
        },
      ]);
    });
    final hits = await api.searchTranscripts(q: 'ship', before: 900, limit: 5);
    expect(seen.url.path, '/search/transcripts');
    expect(
      seen.url.queryParameters,
      {'q': 'ship', 'before': '900', 'limit': '5'},
    );
    expect(hits.single.seq, 4);
    expect(hits.single.highlight, '<mark>ship</mark> it');
  });

  test('a call carries its transcript id when it has one', () {
    VoiceCall call(Map<String, dynamic> extra) => VoiceCall.fromJson({
          'started_at': 1,
          'ended_at': 2,
          'events': <dynamic>[],
          'canvas': <dynamic>[],
          ...extra,
        });
    expect(call({'transcript_id': 't1'}).transcriptId, 't1');
    expect(call({}).transcriptId, isNull);
  });

  test('settings carry the mode, retention and availability', () {
    final settings = SpaceSettings.fromJson(_settings);
    expect(settings.callTranscription, CallTranscriptionMode.onRequest);
    expect(settings.callTranscriptRetentionDays, isNull);
    expect(settings.callTranscriptionAvailable, isFalse);
  });

  test('an older server reads as off, 30 days and available', () {
    final settings = SpaceSettings.fromJson({'join_policy': 'invite'});
    expect(settings.callTranscription, CallTranscriptionMode.off);
    expect(settings.callTranscriptRetentionDays, 30);
    expect(settings.callTranscriptionAvailable, isTrue);
    expect(CallTranscriptionMode.parse('surprise'), CallTranscriptionMode.off);
  });

  test('the settings PATCH sends the mode and null for keep forever', () async {
    final bodies = <Map<String, dynamic>>[];
    final api = _api((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return _json(_settings);
    });
    await api.setSpaceSettings(
      const SpaceSettingsUpdate(
        callTranscription: CallTranscriptionMode.always,
      ),
    );
    await api.setSpaceSettings(
      const SpaceSettingsUpdate(callTranscriptRetentionDays: 0),
    );
    await api.setSpaceSettings(
      const SpaceSettingsUpdate(callTranscriptRetentionDays: 90),
    );
    expect(bodies[0], {'call_transcription': 'always'});
    expect(bodies[1], {'call_transcript_retention_days': null});
    expect(bodies[2], {'call_transcript_retention_days': 90});
  });

  test('call.transcript_changed parses', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'call.transcript_changed',
        'channel_id': 'c1',
        'transcript_id': 't1',
        'ended': true,
      }),
    );
    expect(event, isA<CallTranscriptChanged>());
    final changed = event as CallTranscriptChanged;
    expect(
      (changed.channelId, changed.transcriptId, changed.ended),
      ('c1', 't1', true),
    );
  });

  test('the notice is due only in always mode and until acknowledged',
      () async {
    final requests = <String>[];
    final api = _api((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.method == 'POST') return http.Response('', 204);
      return _json({'mode': 'always', 'acknowledged': false});
    });
    expect((await api.transcriptionNotice()).due, isTrue);
    await api.ackTranscriptionNotice();
    expect(requests, [
      'GET /voice/transcription-notice',
      'POST /voice/transcription-notice/ack',
    ]);
    const done = TranscriptionNotice(
      mode: CallTranscriptionMode.always,
      acknowledged: true,
    );
    const onRequest = TranscriptionNotice(
      mode: CallTranscriptionMode.onRequest,
      acknowledged: false,
    );
    expect((done.due, onRequest.due), (false, false));
  });
}

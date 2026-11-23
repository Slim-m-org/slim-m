// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wire for marks and notes on a call transcript.
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

const _note = {
  'id': 'm1',
  'transcript_id': 't1',
  'author_id': 'u2',
  'at': 500,
  'line_seq': 3,
  'kind': 'note',
  'text': 'ship it',
  'source': 'voice',
};

void main() {
  test('a mark and a note go out as their kinds and come back parsed',
      () async {
    final bodies = <Object?>[];
    final api = _api((request) async {
      bodies.add(jsonDecode(request.body));
      expect(request.url.path, '/voice/transcripts/t1/marks/m1');
      return _json(_note, 201);
    });
    await api.putCallTranscriptMark('t1', 'm1');
    final kept = await api.putCallTranscriptMark('t1', 'm1', note: 'ship it');
    expect(bodies, [
      {'kind': 'mark'},
      {'kind': 'note', 'text': 'ship it'},
    ]);
    expect((
      kept.kind,
      kept.text,
      kept.lineSeq
    ), (
      TranscriptMarkKind.note,
      'ship it',
      3,
    ));
    expect(kept.spoken, isTrue);
  });

  test('the list reads every mark and delete expects no content', () async {
    final requests = <String>[];
    final api = _api((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.method == 'DELETE') return http.Response('', 204);
      return _json({
        'marks': [
          _note,
          {
            ..._note,
            'id': 'm2',
            'kind': 'mark',
            'text': null,
            'line_seq': null
          },
        ],
      });
    });
    final marks = await api.callTranscriptMarks('t1');
    expect(marks.map((m) => m.id), ['m1', 'm2']);
    expect((marks[1].kind, marks[1].lineSeq), (TranscriptMarkKind.mark, null));
    await api.deleteCallTranscriptMark('t1', 'm2');
    expect(requests, [
      'GET /voice/transcripts/t1/marks',
      'DELETE /voice/transcripts/t1/marks/m2',
    ]);
  });

  test('call.transcript_mark carries a kept mark, or null once removed', () {
    final kept = ServerEvent.parse(
      jsonEncode({
        'type': 'call.transcript_mark',
        'channel_id': 'c1',
        'transcript_id': 't1',
        'mark_id': 'm1',
        'mark': _note,
      }),
    ) as CallTranscriptMarkChanged;
    expect((kept.channelId, kept.markId, kept.mark?.text),
        ('c1', 'm1', 'ship it'));
    final removed = ServerEvent.parse(
      jsonEncode({
        'type': 'call.transcript_mark',
        'channel_id': 'c1',
        'transcript_id': 't1',
        'mark_id': 'm1',
        'mark': null,
      }),
    ) as CallTranscriptMarkChanged;
    expect(removed.mark, isNull);
  });

  test('the notice and the settings carry the voice command switch', () {
    final notice = TranscriptionNotice.fromJson({
      'mode': 'always',
      'acknowledged': false,
      'voice_commands': true,
      'phrase': 'hey orbit',
    });
    expect((notice.voiceCommands, notice.phrase), (true, 'hey orbit'));
    final older = TranscriptionNotice.fromJson({'mode': 'always'});
    expect((older.voiceCommands, older.phrase), (false, 'hey space'));
    final settings = SpaceSettings.fromJson({
      'join_policy': 'invite',
      'voice_commands': true,
      'voice_command_phrase': 'hey orbit',
    });
    expect((
      settings.voiceCommands,
      settings.voiceCommandPhrase
    ), (
      true,
      'hey orbit',
    ));
  });
}

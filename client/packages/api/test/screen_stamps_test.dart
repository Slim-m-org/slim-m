// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stamps on a shared screen (decision 0121): the two calls, the relayed stamp
/// frame, the report kind and its pictures, and the capability a client checks.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Uri get _base => Uri.parse('http://localhost:8080');

SlimmApi _api(Future<http.Response> Function(http.Request) handler) => SlimmApi(
      baseUrl: _base,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'access-1',
          refreshToken: 'refresh-1',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

Map<String, Object?> _report(Map<String, Object?> over) => {
      'id': 'r1',
      'reporter_id': 'sharer',
      'subject_kind': 'screen_stamp',
      'subject_id': 'viewer',
      'channel_id': 'c1',
      'reason': 'not on my desktop',
      'snapshot': null,
      'subject_author_id': 'viewer',
      'created_at': 5,
      ...over,
    };

void main() {
  test('a picture stamp posts exactly one content and expects no body',
      () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response('', 204);
    });
    await api.placeScreenStamp(
      'chan-1',
      id: 's1',
      targetUserId: 'sharer',
      x: 0.42,
      y: 0.31,
      size: 0.12,
      attachmentId: 'ab' * 32,
    );
    expect((seen.method, seen.url.path),
        ('POST', '/channels/chan-1/voice/screen-stamps'));
    expect(jsonDecode(seen.body), {
      'id': 's1',
      'target_user_id': 'sharer',
      'x': 0.42,
      'y': 0.31,
      'size': 0.12,
      'attachment_id': 'ab' * 32,
    });
  });

  test('an emoji stamp sends the emoji and no attachment', () async {
    late Map<String, dynamic> body;
    final api = _api((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('', 204);
    });
    await api.placeScreenStamp('chan-1',
        id: 's2',
        targetUserId: 'sharer',
        x: 0.5,
        y: 0.5,
        size: 0.3,
        emoji: ':wave:');
    expect(body['emoji'], ':wave:');
    expect(body.containsKey('attachment_id'), isFalse);
  });

  test('the received list parses newest first as the server sent it', () async {
    final api = _api((request) async {
      expect(request.url.path, '/voice/screen-stamps/received');
      return http.Response(
        jsonEncode({
          'stamps': [
            {
              'id': 's2',
              'channel_id': 'c1',
              'sender_id': 'viewer',
              'attachment_id': 'cd' * 32,
              'created_at': 9,
              'reported': true,
            },
            {
              'id': 's1',
              'channel_id': 'c1',
              'sender_id': 'viewer',
              'attachment_id': 'ab' * 32,
              'created_at': 8,
              'reported': false,
            },
          ],
        }),
        200,
      );
    });
    final stamps = await api.listReceivedScreenStamps();
    expect(
        stamps.map((s) => (s.id, s.reported)), [('s2', true), ('s1', false)]);
    expect((stamps.last.senderId, stamps.last.attachmentId),
        ('viewer', 'ab' * 32));
  });

  test('a relayed stamp carries its size and its content', () {
    final picture = ServerEvent.parse(jsonEncode({
      'type': 'canvas.screen_annotation.updated',
      'channel_id': 'c1',
      'user_id': 'viewer',
      'target_user_id': 'sharer',
      'kind': 'stamp',
      'annotation_id': 's1',
      'points': [0.42, 0.31],
      'size': 0.12,
      'attachment': 'ab' * 32,
      'animated': true,
      'ended': true,
      'allowed': false,
    })) as CanvasScreenAnnotation;
    expect((picture.kind, picture.size, picture.attachment, picture.animated),
        ('stamp', 0.12, 'ab' * 32, true));
    expect(picture.emoji, isNull);
  });

  test('a stroke from an older server reads no stamp fields', () {
    final stroke = ServerEvent.parse(jsonEncode({
      'type': 'canvas.screen_annotation.updated',
      'channel_id': 'c1',
      'user_id': 'viewer',
      'target_user_id': 'sharer',
      'kind': 'stroke',
      'annotation_id': 'a1',
      'points': [0.1, 0.2],
      'ended': false,
      'allowed': false,
    })) as CanvasScreenAnnotation;
    expect((
      stroke.size,
      stroke.emoji,
      stroke.attachment,
      stroke.animated,
      stroke.stamps
    ), (
      null,
      null,
      null,
      false,
      false
    ));
  });

  test('a screen stamp report keeps its kind and its pictures', () {
    final report = Report.fromJson(_report({
      'picture_ids': ['ab' * 32, 'cd' * 32],
    }));
    expect(report.subjectKind, ReportSubject.screenStamp);
    expect(report.subjectKind.wire, 'screen_stamp');
    expect(report.pictureIds, ['ab' * 32, 'cd' * 32]);
    expect(
        Report.fromJson(_report({'subject_kind': 'user'})).pictureIds, isEmpty);
  });

  test('a resolved screen stamp report reads its pictures in the history', () {
    final entry = ModerationHistoryItem.tryFromJson({
      ..._report({'picture_ids': <String>[]}),
      'kind': 'resolved_report',
      'resolved_at': 6,
      'resolved_by': 'mod',
      'resolution': 'resolved',
    }) as ResolvedReportHistoryEntry;
    expect(entry.subjectKind, ReportSubject.screenStamp);
    expect(entry.pictureIds, isEmpty);
  });

  test('stamps are offered only by a server that lists them', () {
    Version version(List<String>? capabilities) => Version.fromJson({
          'name': 'slim-m',
          'version': '0.112.0',
          'protocol': 1,
          'capabilities': capabilities,
        });
    expect(version(['block', 'report', 'screen_stamps']).supportsScreenStamps,
        isTrue);
    expect(version(['block', 'report']).supportsScreenStamps, isFalse);
    expect(version(null).supportsScreenStamps, isFalse);
  });
}

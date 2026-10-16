// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An upload names its destination channel so a channel overwrite granting
/// Attach Files is honoured; with no channel, nothing extra is sent.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _tokens = TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 0,
);

const _attachment = {
  'id': 'att',
  'filename': 'f.bin',
  'content_type': 'application/octet-stream',
  'size': 3,
};

class _Seen {
  final requests = <http.Request>[];
}

SlimmApi _api(_Seen seen) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(tokens: _tokens),
      httpClient: MockClient.streaming((request, body) async {
        final bytes = await body.toBytes();
        final copy = http.Request(request.method, request.url)
          ..bodyBytes = bytes;
        seen.requests.add(copy);
        final path = request.url.path;
        Object reply;
        int status = 200;
        if (path == '/attachments/uploads' && request.method == 'POST') {
          status = 201;
          reply = {
            'id': 'up',
            'size': 3,
            'offset': 0,
            'part_max_bytes': 64,
            'expires_at': 0,
          };
        } else if (request.method == 'PUT') {
          reply = {
            'id': 'up',
            'size': 3,
            'offset': 3,
            'part_max_bytes': 64,
            'expires_at': 0,
          };
        } else {
          status = 201;
          reply = _attachment;
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(reply))),
          status,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

Future<Attachment> _upload(SlimmApi api,
        {String? channelId, bool big = false}) =>
    api.uploadAttachmentAuto(
      UploadSource(open: () => Stream.value([1, 2, 3])),
      length: 3,
      capabilities: big ? const ['upload_sessions'] : null,
      sessionThreshold: big ? 0 : 1000,
      channelId: channelId,
    );

void main() {
  test('a single-request upload sends channel_id as a query parameter',
      () async {
    final seen = _Seen();
    await _upload(_api(seen), channelId: 'chan-1');
    expect(seen.requests.single.url.queryParameters['channel_id'], 'chan-1');
  });

  test('a resumable upload sends it on create and on complete', () async {
    final seen = _Seen();
    await _upload(_api(seen), channelId: 'chan-1', big: true);
    final create = seen.requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path == '/attachments/uploads',
    );
    expect(jsonDecode(create.body)['channel_id'], 'chan-1');
    final complete = seen.requests.last;
    expect(complete.url.path, '/attachments/uploads/up/complete');
    expect(complete.url.queryParameters['channel_id'], 'chan-1');
  });

  test('with no channel, neither request carries channel_id', () async {
    final single = _Seen();
    await _upload(_api(single));
    expect(single.requests.single.url.queryParameters,
        isNot(contains('channel_id')));

    final resumable = _Seen();
    await _upload(_api(resumable), big: true);
    final create = resumable.requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path == '/attachments/uploads',
    );
    expect(jsonDecode(create.body), isNot(contains('channel_id')));
    expect(resumable.requests.last.url.queryParameters, isEmpty);
  });
}

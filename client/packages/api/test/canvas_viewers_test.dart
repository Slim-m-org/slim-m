// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `GET /presence/canvas-viewers` and its `canvas.viewer.changed` frame.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('canvasViewers reads the batched roster in arrival order', () async {
    Uri? seen;
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'me',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        seen = request.url;
        return http.Response(
          jsonEncode({
            'channels': [
              {
                'channel_id': 'board',
                'viewers': [
                  {'user_id': 'ada', 'since': 10},
                  {'user_id': 'ben', 'since': 20, 'extra': true},
                ],
              },
            ],
            'later_field': 1,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final boards = await api.canvasViewers();

    expect(seen!.path, '/presence/canvas-viewers');
    expect(boards.single.channelId, 'board');
    expect(boards.single.viewers.map((v) => (v.userId, v.since)), [
      ('ada', 10),
      ('ben', 20),
    ]);
  });

  test('parses canvas.viewer.changed and ignores unknown fields', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.viewer.changed',
        'channel_id': 'board',
        'user_id': 'ada',
        'viewing': true,
        'later_field': 'x',
      }),
    );

    final changed = event as CanvasViewerChanged;
    expect((
      changed.channelId,
      changed.userId,
      changed.viewing
    ), (
      'board',
      'ada',
      true,
    ));
  });

  test('a viewer frame missing a field is dropped', () {
    for (final frame in [
      {'type': 'canvas.viewer.changed', 'user_id': 'u', 'viewing': true},
      {'type': 'canvas.viewer.changed', 'channel_id': 'c', 'viewing': true},
      {'type': 'canvas.viewer.changed', 'channel_id': 'c', 'user_id': 'u'},
      {
        'type': 'canvas.viewer.changed',
        'channel_id': 'c',
        'user_id': 'u',
        'viewing': 'yes',
      },
    ]) {
      expect(ServerEvent.parse(jsonEncode(frame)), isNull);
    }
  });
}

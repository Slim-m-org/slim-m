// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note placement is one unretried POST, so a transient failure
/// loses the typed text instead of retrying with the same id.
library;

import 'package:flutter/painting.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_quick_placement.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test('placeNote retries a transient 503 with the same id', () async {
    final ids = <String>[];
    final client = api.SlimmApi(
      baseUrl: Uri.parse('http://test.invalid'),
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        ids.add(body['id'] as String);
        if (ids.length == 1) {
          return http.Response('{"error":"unavailable"}', 503);
        }
        return http.Response(
          jsonEncode({
            'id': body['id'],
            'kind': 'note',
            'z_index': 1,
            'x': 0,
            'y': 0,
            'w': 220,
            'h': 140,
            'props': body['props'],
            'author_id': 'me',
            'seq': 1,
            'created_at': 0,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final errors = <String>[];
    final placement = CanvasQuickPlacement(
      client: client,
      channelId: 'c',
      document: CanvasDocument()..setViewport(const Size(1200, 800)),
      timedOutUntil: () => null,
    );

    final placed = await placement.placeNote(
      Offset.zero,
      'typed note text',
      onError: errors.add,
    );

    expect(errors, isEmpty, reason: 'a single 503 must not surface an error');
    expect(placed, isNotNull, reason: 'the note text was lost, not retried');
    expect(ids.toSet(), hasLength(1));
  });
}

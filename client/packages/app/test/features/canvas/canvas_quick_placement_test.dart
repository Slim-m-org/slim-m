// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasQuickPlacement.placeNote]: the request it actually posts carries
/// [noteBoxFor]'s own box, not the old fixed default - the integration
/// point `canvas_note_sizing_test.dart` cannot see on its own.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_note_sizing.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_quick_placement.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

void main() {
  testWidgets(
    "a placed note's request carries noteBoxFor's own size, not a fixed one",
    (tester) async {
      final requests = <Map<String, dynamic>>[];
      final client = testApi(
        (request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(body);
          return http.Response(
            jsonEncode({
              'id': body['id'],
              'kind': 'note',
              'z_index': 1,
              'x': body['x'],
              'y': body['y'],
              'w': body['w'],
              'h': body['h'],
              'props': body['props'],
              'author_id': 'me',
              'seq': 1,
              'created_at': 0,
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        },
        session: api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      );
      final placement = CanvasQuickPlacement(
        client: client,
        channelId: 'c1',
        document: CanvasDocument(),
        timedOutUntil: () => null,
      );
      final longText = List.filled(40, 'a whole sentence.').join(' ');

      await placement.placeNote(
        Offset.zero,
        longText,
        onError: (_) => fail('must not error'),
      );

      final expected = noteBoxFor(longText);
      expect(requests.single['w'], expected.width);
      expect(requests.single['h'], expected.height);
      expect(
        requests.single['h'],
        greaterThan(140),
        reason: 'the whole point: a long note gets more than the default',
      );
    },
  );

  testWidgets(
    'a timed-out caller hears the freeze named, not a generic refusal',
    (tester) async {
      final client = testApi(
        (request) async => http.Response('{"error":"no"}', 403),
        session: api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      );
      // A little past the exact hour so a later real-clock read cannot truncate this down a bucket.
      final until = DateTime.now()
          .add(const Duration(hours: 2, minutes: 5))
          .millisecondsSinceEpoch;
      final placement = CanvasQuickPlacement(
        client: client,
        channelId: 'c1',
        document: CanvasDocument(),
        timedOutUntil: () => until,
      );

      String? error;
      await placement.placeShape(
        Offset.zero,
        CanvasShapeKind.rectangle,
        onError: (message) => error = message,
      );

      expect(error, contains("You're timed out"));
      expect(error, contains('2h'));
    },
  );
}

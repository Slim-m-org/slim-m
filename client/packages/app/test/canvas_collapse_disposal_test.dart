// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// docs/ROADMAP.md's Phase 6 "collapse-to-strip" deliverable: closing the
/// canvas must not merely hide it, it must unmount and free what it decoded.
///
/// `ConversationPane`'s stage ternary already swaps `CanvasPane` out for a
/// different widget type the moment `canvasOpenProvider` clears, which is
/// what makes this a disposal test rather than a visibility one - there is
/// no `Offstage`/`Visibility` here to almost-fix. What nothing had checked
/// is the thing collapsing is actually *for*: a decoded image bitmap is the
/// expensive resource a bounded cache exists to bound, and hiding the
/// widget while leaving that resident would spend the budget on a pane
/// nobody can see.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart'
    show canvasImageJson, canvasPngFixture, surfaceDocument;
import 'home_shell_harness.dart';

http.Response _jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// Answers exactly one image object on the viewport read and serves its
/// bytes back on the attachment fetch, so hydration has something real to
/// decode rather than racing an empty canvas.
MockClient _imageCanvasClient() => MockClient((request) async {
  final path = request.url.path;
  if (path.endsWith('/me')) {
    return _jsonResponse({
      'id': 'bob',
      'username': 'bob',
      'display_name': 'Bob',
      'created_at': 0,
      'permissions': 0,
    });
  }
  if (path.endsWith('/canvas/objects') && request.method == 'GET') {
    return _jsonResponse({
      'objects': [canvasImageJson('pic')],
      'has_more': false,
      'latest_seq': 1,
    });
  }
  if (path.endsWith('/canvas/ops')) {
    final afterSeq = int.parse(request.url.queryParameters['after_seq'] ?? '0');
    return _jsonResponse({
      'ops': <Object>[],
      'latest_seq': afterSeq,
      'has_more': false,
      'reset': false,
    });
  }
  if (path.startsWith('/attachments/')) {
    return http.Response.bytes(
      canvasPngFixture,
      200,
      headers: {'content-type': 'image/png'},
    );
  }
  if (path.endsWith('/canvas/media-slots')) {
    return _jsonResponse({'slots': <Object>[]});
  }
  if (path.endsWith('/canvas/object-locks')) {
    return _jsonResponse({'object_ids': <Object>[]});
  }
  return _jsonResponse(<Object>[]);
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'closing the canvas disposes the decoded bitmap it was showing, not '
    'just the widget painting it',
    (tester) async {
      final s = setup(httpClient: _imageCanvasClient(), signedIn: true);
      await MessageStore(s.db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);
      s.container.read(canvasOpenProvider.notifier).state = 'c1';

      // A real codec decode needs real asynchrony (canvas_pane_test.dart's own note); pumpAndSettle alone never observes it.
      await tester.runAsync(() async {
        await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      final document = surfaceDocument(tester);
      expect(
        document.paintOrder,
        hasLength(1),
        reason:
            'the fixture placed exactly one image; if hydration never '
            'ran this assertion catches that rather than a null crash below',
      );
      final image = document.strokeIfAlive(document.paintOrder.single)!.image!;
      expect(image.debugDisposed, isFalse);

      s.container.read(canvasOpenProvider.notifier).state = null;
      await tester.pump();

      expect(
        find.byType(CanvasSurface),
        findsNothing,
        reason: 'the pane must be gone, not merely hidden',
      );
      expect(
        image.debugDisposed,
        isTrue,
        reason:
            'the canvas pane disposes its document on unmount, which '
            'frees every decoded bitmap it held - a collapse that left this '
            'resident would spend the 64MB decode budget on a pane nobody '
            'can see',
      );

      await teardown(tester, s.container, s.db);
    },
  );
}

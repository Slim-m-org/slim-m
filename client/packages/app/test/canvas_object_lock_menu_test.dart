// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The object menu's Lock in place and Unlock: who gets them, what a lock
/// disables, and the badge that marks a locked object.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_object_context_menu.dart';
import 'package:slimm_app/src/screens/canvas/canvas_object_locks.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _photo({required String authorId}) => CanvasStrokeInput(
  id: 'photo',
  seq: 1,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 80,
  h: 60,
  points: const [],
  width: 0,
  colorKey: 'shape',
  kind: CanvasObjectKind.shape,
  authorId: authorId,
);

class _Harness {
  _Harness({required String authorId, this.canManage = false}) {
    document.applyPlaced(_photo(authorId: authorId));
    locks = CanvasObjectLocks(
      channelId: 'c1',
      client: api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 4102444800000,
          ),
        ),
        httpClient: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          return http.Response('', 204);
        }),
      ),
    );
  }

  final bool canManage;
  final CanvasDocument document = CanvasDocument();
  late final CanvasObjectLocks locks;
  final List<String> requests = [];
  final List<String> restacked = [];
  final List<String> deleted = [];

  Widget build() => MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 400,
        child: CanvasObjectLocksScope(
          locks: locks,
          child: CanvasObjectContextMenu(
            document: document,
            canManage: canManage,
            selfId: 'me',
            requests: CanvasObjectMenuRequests(),
            tool: CanvasTool.pan,
            onToolChanged: (_) {},
            onBringToFront: restacked.add,
            onSendToBack: restacked.add,
            onDeleteSelected: deleted.add,
            onPasteImageAt: (_) {},
            onAddNoteAt: (_) {},
            onRecenter: () {},
          ),
        ),
      ),
    ),
  );
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('locking your own object sends the lock, badges it, and holds '
      'restack and delete until Unlock', (tester) async {
    final harness = _Harness(authorId: 'me');
    addTearDown(harness.document.dispose);
    await tester.pumpWidget(harness.build());

    await _openMenu(tester);
    await tester.tap(find.text('Lock in place'));
    await tester.pumpAndSettle();
    expect(harness.requests, ['PUT /channels/c1/canvas/objects/photo/lock']);

    final camera = harness.document.camera;
    final badge = tester.getTopLeft(
      find.byKey(const ValueKey('canvas-lock-badge-photo')),
    );
    expect(
      badge.dx,
      closeTo((100 - camera.x) * camera.zoom + AppSpacing.s4, 0.5),
    );
    expect(
      badge.dy,
      closeTo((100 - camera.y) * camera.zoom + AppSpacing.s4, 0.5),
    );

    await _openMenu(tester);
    expect(find.text('Unlock'), findsOneWidget);
    await tester.tap(find.text('Bring to front'));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(harness.restacked, isEmpty);
    expect(harness.deleted, isEmpty);

    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(
      harness.requests.last,
      'DELETE /channels/c1/canvas/objects/photo/lock',
    );
    expect(find.byKey(const ValueKey('canvas-lock-badge-photo')), findsNothing);
  });

  testWidgets('someone else\'s object offers no lock to a plain member', (
    tester,
  ) async {
    final harness = _Harness(authorId: 'someone-else');
    addTearDown(harness.document.dispose);
    await tester.pumpWidget(harness.build());
    await _openMenu(tester);
    // Not theirs to move, so the right-click misses it and opens the empty-space menu.
    expect(find.text('Lock in place'), findsNothing);
    expect(find.text('Paste image'), findsOneWidget);
  });

  testWidgets('a canvas moderator may lock anyone\'s object', (tester) async {
    final harness = _Harness(authorId: 'someone-else', canManage: true);
    addTearDown(harness.document.dispose);
    await tester.pumpWidget(harness.build());
    await _openMenu(tester);
    expect(find.text('Lock in place'), findsOneWidget);
  });
}

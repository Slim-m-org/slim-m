// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real "Paste image" route end to end: the toolbar action, the native
/// clipboard read, the upload, the placement, and - the thing report 2 in
/// the backlog channel asked about - whether the just-pasted image can then
/// be dragged with the Move tool.
///
/// Every other canvas move test places its object directly through the
/// fixture's own `objects` list or a bare `placeCanvasObject` POST, never
/// through `CanvasImagePaste` itself, so this is the one place the actual
/// paste-to-drag path is exercised rather than assumed to behave the same.
///
/// The whole gesture has to run inside `tester.runAsync`: decoding a real
/// PNG through `ui.instantiateImageCodec` is genuine engine work a fake
/// clock never completes, the same reason `canvas_pane_test.dart`'s own
/// hydration tests already need it.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_pane_harness.dart';

const _channel = MethodChannel('top.npcserver.slimm/clipboard_image');

void _mockClipboard(Uint8List bytes) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        switch (call.method) {
          case 'hasImage':
            return true;
          case 'readImage':
            return bytes;
          default:
            return null;
        }
      });
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets(
    'the toolbar Paste image action places a real image, and dragging it '
    'with the Move tool immediately after moves it and posts one move op',
    (tester) async {
      _mockClipboard(canvasPngFixture);
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste image'));
      // A real codec decode needs real asynchrony; pumpAndSettle alone never observes it, the same trap canvas_pane_test.dart's own hydration tests already document.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      expect(fixture.posted, hasLength(1));
      expect(fixture.posted.single['kind'], 'image');
      final pastedId = fixture.posted.single['id'] as String;
      final placedBounds = surfaceDocument(tester).objectBounds(pastedId);
      expect(
        placedBounds,
        isNotNull,
        reason:
            'a paste that placed nothing is not this bug, but is worth '
            'knowing about on its own',
      );

      // A fresh paste already selects itself and switches to Move (see canvas_pane_gestures.dart's `_selectPlaced`), so no tool tap is needed here - dragging its own body is the real next gesture.
      final start = screenFor(
        tester,
        Offset(
          placedBounds!.x + placedBounds.w / 2,
          placedBounds.y + placedBounds.h / 2,
        ),
      );
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(start + const Offset(30, 20));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        fixture.postedOps,
        hasLength(1),
        reason:
            'the drag that follows a fresh paste must move it, not '
            'silently do nothing',
      );
      expect(fixture.postedOps.single['kind'], 'move');
      expect(fixture.postedOps.single['object_id'], pastedId);

      final movedBounds = surfaceDocument(tester).objectBounds(pastedId)!;
      expect(movedBounds.x, placedBounds.x + 30);
      expect(movedBounds.y, placedBounds.y + 20);
    },
  );

  for (final refusal in {
    413: 'That image is too big to upload.',
    507: 'This server has no storage left. Tell an admin.',
  }.entries) {
    testWidgets('a ${refusal.key} on upload says why, not a bare failure', (
      tester,
    ) async {
      _mockClipboard(canvasPngFixture);
      final fixture = CanvasPaneFixture(attachmentUploadStatus: refusal.key);
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste image'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      expect(find.text(refusal.value), findsOneWidget);
      expect(fixture.posted, isEmpty);
    });
  }
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasObjectContextMenu]: what a right-click resolves to (an object's
/// own menu, or the empty-space menu once no object is hit), why a drag
/// past the tap slop never opens either, ownership gating, and the
/// [CanvasObjectMenuRequests] route a screen reader or keyboard reaches the
/// object menu through instead of a mouse.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_context_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _shape(String id, {required String authorId}) =>
    CanvasStrokeInput(
      id: id,
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
  _Harness({
    required this.document,
    required this.requests,
    this.selfId = 'me',
    this.canManage = false,
  });

  final CanvasDocument document;
  final CanvasObjectMenuRequests requests;
  final String? selfId;
  final bool canManage;

  final List<CanvasTool> toolChanges = [];
  final List<String> bringToFront = [];
  final List<String> sendToBack = [];
  final List<String> deleted = [];
  final List<Offset> pastedAt = [];
  final List<Offset> notedAt = [];
  int recentered = 0;

  Widget build() => MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 400,
        child: CanvasObjectContextMenu(
          document: document,
          canManage: canManage,
          selfId: selfId,
          requests: requests,
          tool: CanvasTool.pan,
          onToolChanged: toolChanges.add,
          onBringToFront: bringToFront.add,
          onSendToBack: sendToBack.add,
          onDeleteSelected: deleted.add,
          onPasteImageAt: pastedAt.add,
          onAddNoteAt: notedAt.add,
          onRecenter: () => recentered++,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'a right-click over an object selects it, switches to Move, and offers '
    'the object actions',
    (tester) async {
      final document = CanvasDocument()
        ..applyPlaced(_shape('a', authorId: 'me'));
      addTearDown(document.dispose);
      final harness = _Harness(
        document: document,
        requests: CanvasObjectMenuRequests(),
      );
      await tester.pumpWidget(harness.build());

      await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Bring to front'), findsOneWidget);
      expect(find.text('Send to back'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(document.selectedObjectId.value, 'a');
      expect(harness.toolChanges, [CanvasTool.pan]);
    },
  );

  testWidgets('choosing an item closes the menu and calls the right one', (
    tester,
  ) async {
    final document = CanvasDocument()..applyPlaced(_shape('a', authorId: 'me'));
    addTearDown(document.dispose);
    final harness = _Harness(
      document: document,
      requests: CanvasObjectMenuRequests(),
    );
    await tester.pumpWidget(harness.build());

    await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send to back'));
    await tester.pumpAndSettle();

    expect(harness.sendToBack, ['a']);
    expect(harness.bringToFront, isEmpty);
    expect(harness.deleted, isEmpty);
    expect(
      find.text('Send to back'),
      findsNothing,
      reason: 'picking an item must close the menu',
    );
  });

  testWidgets(
    'right-clicking empty canvas opens the space menu, not the object menu',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final harness = _Harness(
        document: document,
        requests: CanvasObjectMenuRequests(),
      );
      await tester.pumpWidget(harness.build());

      await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Bring to front'), findsNothing);
      expect(find.text('Paste image'), findsOneWidget);
      expect(find.text('Add note'), findsOneWidget);
      expect(find.text('Recenter view'), findsOneWidget);
      expect(document.selectedObjectId.value, isNull);
      expect(harness.toolChanges, isEmpty);
    },
  );

  testWidgets(
    'the space menu never appears alongside the object menu, an object hit '
    'always wins',
    (tester) async {
      final document = CanvasDocument()
        ..applyPlaced(_shape('a', authorId: 'me'));
      addTearDown(document.dispose);
      final harness = _Harness(
        document: document,
        requests: CanvasObjectMenuRequests(),
      );
      await tester.pumpWidget(harness.build());

      await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Bring to front'), findsOneWidget);
      expect(find.text('Paste image'), findsNothing);
      expect(find.text('Add note'), findsNothing);
      expect(find.text('Recenter view'), findsNothing);
    },
  );

  testWidgets(
    'the space menu never offers Clear canvas, even with MANAGE_CANVAS',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final harness = _Harness(
        document: document,
        requests: CanvasObjectMenuRequests(),
        canManage: true,
      );
      await tester.pumpWidget(harness.build());

      await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Clear canvas'), findsNothing);
    },
  );

  testWidgets('picking Paste image in the space menu pastes at the clicked '
      'world point', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final harness = _Harness(
      document: document,
      requests: CanvasObjectMenuRequests(),
    );
    await tester.pumpWidget(harness.build());

    await tester.tapAt(const Offset(120, 140), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste image'));
    await tester.pumpAndSettle();

    expect(harness.pastedAt, [const Offset(120, 140)]);
    expect(harness.notedAt, isEmpty);
    expect(harness.recentered, 0);
    expect(
      find.text('Paste image'),
      findsNothing,
      reason: 'picking an item must close the menu',
    );
  });

  testWidgets('picking Add note in the space menu places a note at the '
      'clicked world point', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final harness = _Harness(
      document: document,
      requests: CanvasObjectMenuRequests(),
    );
    await tester.pumpWidget(harness.build());

    await tester.tapAt(const Offset(150, 90), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add note'));
    await tester.pumpAndSettle();

    expect(harness.notedAt, [const Offset(150, 90)]);
    expect(harness.pastedAt, isEmpty);
  });

  testWidgets('picking Recenter view in the space menu recenters the view', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final harness = _Harness(
      document: document,
      requests: CanvasObjectMenuRequests(),
    );
    await tester.pumpWidget(harness.build());

    await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recenter view'));
    await tester.pumpAndSettle();

    expect(harness.recentered, 1);
    expect(harness.pastedAt, isEmpty);
    expect(harness.notedAt, isEmpty);
  });

  /// The regression this whole feature could most easily reintroduce: a
  /// right-drag pan on empty canvas must stay a pan, never popping the new
  /// space menu behind it - the identical property the object menu's own
  /// drag test already proves for a right-drag over an object.
  testWidgets(
    'a right-button drag past the tap slop over empty canvas never opens '
    'the space menu',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final harness = _Harness(
        document: document,
        requests: CanvasObjectMenuRequests(),
      );
      await tester.pumpWidget(harness.build());

      final gesture = await tester.startGesture(
        const Offset(120, 120),
        buttons: kSecondaryButton,
      );
      await gesture.moveTo(const Offset(120, 220));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Paste image'), findsNothing);
      expect(find.text('Add note'), findsNothing);
      expect(find.text('Recenter view'), findsNothing);
      expect(harness.pastedAt, isEmpty);
      expect(harness.notedAt, isEmpty);
      expect(harness.recentered, 0);
    },
  );

  testWidgets(
    "somebody else's object stays out of reach without MANAGE_CANVAS",
    (tester) async {
      final document = CanvasDocument()
        ..applyPlaced(_shape('a', authorId: 'someone-else'));
      addTearDown(document.dispose);
      final harness = _Harness(
        document: document,
        requests: CanvasObjectMenuRequests(),
        selfId: 'me',
      );
      await tester.pumpWidget(harness.build());

      await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Bring to front'), findsNothing);
      expect(document.selectedObjectId.value, isNull);
    },
  );

  testWidgets('MANAGE_CANVAS reaches an object owned by somebody else', (
    tester,
  ) async {
    final document = CanvasDocument()
      ..applyPlaced(_shape('a', authorId: 'someone-else'));
    addTearDown(document.dispose);
    final harness = _Harness(
      document: document,
      requests: CanvasObjectMenuRequests(),
      selfId: 'me',
      canManage: true,
    );
    await tester.pumpWidget(harness.build());

    await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Bring to front'), findsOneWidget);
    expect(document.selectedObjectId.value, 'a');
  });

  /// The core immunity claim: a right-button press that moves well past the
  /// platform's own tap slop before releasing is a drag, not a click, and
  /// must never open the menu - the property that keeps this widget out of
  /// the way of a right-drag pan built on the same surface, whatever shape
  /// that pan turns out to take.
  testWidgets('a right-button drag past the tap slop never opens the menu', (
    tester,
  ) async {
    final document = CanvasDocument()..applyPlaced(_shape('a', authorId: 'me'));
    addTearDown(document.dispose);
    final harness = _Harness(
      document: document,
      requests: CanvasObjectMenuRequests(),
    );
    await tester.pumpWidget(harness.build());

    final gesture = await tester.startGesture(
      const Offset(120, 120),
      buttons: kSecondaryButton,
    );
    await gesture.moveTo(const Offset(120, 220));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Bring to front'), findsNothing);
    expect(document.selectedObjectId.value, isNull);
    expect(harness.toolChanges, isEmpty);
  });

  /// A movement within the slop still counts as a click - the same leeway
  /// every other tap in this app already gets, not a hair-trigger threshold
  /// invented for this widget alone.
  testWidgets('a tiny wobble within the tap slop still opens the menu', (
    tester,
  ) async {
    final document = CanvasDocument()..applyPlaced(_shape('a', authorId: 'me'));
    addTearDown(document.dispose);
    final harness = _Harness(
      document: document,
      requests: CanvasObjectMenuRequests(),
    );
    await tester.pumpWidget(harness.build());

    final gesture = await tester.startGesture(
      const Offset(120, 120),
      buttons: kSecondaryButton,
    );
    await gesture.moveTo(const Offset(122, 121));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Bring to front'), findsOneWidget);
  });

  testWidgets('a screen-reader or keyboard request opens the same menu with no '
      'pointer position, anchored at the object itself', (tester) async {
    final document = CanvasDocument()..applyPlaced(_shape('a', authorId: 'me'));
    addTearDown(document.dispose);
    final requests = CanvasObjectMenuRequests();
    final harness = _Harness(document: document, requests: requests);
    await tester.pumpWidget(harness.build());

    requests.request('a');
    await tester.pumpAndSettle();

    expect(find.text('Bring to front'), findsOneWidget);
    expect(document.selectedObjectId.value, 'a');
    expect(harness.toolChanges, [CanvasTool.pan]);
  });

  testWidgets('the same request twice in a row reopens the menu both times', (
    tester,
  ) async {
    final document = CanvasDocument()..applyPlaced(_shape('a', authorId: 'me'));
    addTearDown(document.dispose);
    final requests = CanvasObjectMenuRequests();
    final harness = _Harness(document: document, requests: requests);
    await tester.pumpWidget(harness.build());

    requests.request('a');
    await tester.pumpAndSettle();
    // Dismiss without picking anything, the same as an Escape or a tap outside.
    await tester.tapAt(const Offset(10, 390));
    await tester.pumpAndSettle();
    expect(find.text('Bring to front'), findsNothing);

    requests.request('a');
    await tester.pumpAndSettle();

    expect(
      find.text('Bring to front'),
      findsOneWidget,
      reason:
          'a ValueNotifier-style equality gate would silently swallow this '
          'second, identical request',
    );
  });
}

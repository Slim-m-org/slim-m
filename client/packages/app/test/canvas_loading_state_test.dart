// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// canvas.md: the loading state was a flat, featureless rectangle with no
/// spinner or skeleton, pixel-identical for a sighted user to what a
/// broken or blank canvas would look like - the `Semantics` label already
/// covered a screen reader, but nothing stood in for it on screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_activity_log.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane_body.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Widget _pane(CanvasDocument document, {required bool loading}) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox(
        width: 1000,
        height: 800,
        child: CanvasPaneBody(
          channelId: 'c1',
          onClose: () {},
          tool: CanvasTool.pen,
          onToolChanged: (_) {},
          canUndo: false,
          onUndo: () {},
          canRedo: false,
          onRedo: () {},
          canManage: false,
          document: document,
          onClear: () async {},
          onPasteImage: () {},
          onPasteImageAt: (_) {},
          onRecenter: () {},
          error: null,
          onDismissError: () {},
          truncated: false,
          loading: loading,
          onStroke: (_) {},
          onErase: (_) {},
          onEraseEnd: () {},
          onSelectStart: (_) {},
          onSelectDrag: (_) {},
          onSelectEnd: () {},
          onNotePlace: (_) {},
          onShapePlace: (_, __) {},
          shapeKind: CanvasShapeKind.rectangle,
          onShapeKindChanged: (_) {},
          pen: const CanvasPenStyle(),
          onPenChanged: (_) {},
          onBringToFront: (_) {},
          onSendToBack: (_) {},
          onDeleteSelected: (_) {},
          selfId: 'me',
          activityLog: CanvasActivityLog(isBlocked: (_) => false),
          callParticipants: const [],
          cameraViewFor: (_) => const SizedBox(),
          screenShareViewFor: (_) => const SizedBox(),
          tileOverrides: CanvasPresenceTileOverrides(),
          onCommitTile: (_, __) {},
          onVideoInterest: (_) {},
          selfBubbleHidden: false,
          onToggleSelfBubbleHidden: () {},
          fullscreen: false,
          onToggleFullscreen: () {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('loading shows a visible spinner, not a bare rectangle', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);

    await tester.pumpWidget(_pane(document, loading: true));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.text('Nothing on this canvas yet'),
      findsNothing,
      reason: 'a loading canvas must not also claim to be genuinely empty',
    );
  });

  testWidgets('once loaded, an empty canvas keeps its own hint instead', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);

    await tester.pumpWidget(_pane(document, loading: false));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Nothing on this canvas yet'), findsOneWidget);
  });
}

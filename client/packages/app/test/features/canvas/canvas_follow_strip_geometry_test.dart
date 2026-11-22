// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-214: the follow chip and the summon card sit in the pane's own chrome, so
/// neither covers the board (desktop-vs-mobile.md rule 1: width decides, at 390 and 1280).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane_body.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Widget _pane(
  CanvasDocument document,
  CanvasViewRelay relay,
  CanvasCursors cursors,
) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox.expand(
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
          onRecenter: () {},
          onBringIntoBoard: () {},
          error: null,
          onDismissError: () {},
          truncated: false,
          loading: false,
          onStroke: (_) {},
          onErase: (_) {},
          onEraseEnd: () {},
          onSelectStart: (_) {},
          onSelectDrag: (_) {},
          onSelectEnd: () {},
          onNotePlace: (_, [__]) {},
          onShapePlace: (_, __, {flipX = false, flipY = false}) {},
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
          viewRelay: relay,
          cursors: cursors,
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
  for (final width in [390.0, 1280.0]) {
    testWidgets('at $width wide the chip and summon card clear the board', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final document = CanvasDocument()..setViewport(Size(width, 700));
      addTearDown(document.dispose);
      final relay = CanvasViewRelay(
        board: const Rect.fromLTWH(0, 0, 1000, 1000),
        send: (_, {required summon, tile}) {},
        showView: (_) {},
        isBlocked: (_) => false,
        selfId: () => 'me',
      );
      final cursors = CanvasCursors()
        ..upsert(id: 'amy', x: 0, y: 0, label: 'amy', colorIndex: 0);
      addTearDown(relay.dispose);
      addTearDown(cursors.dispose);
      await tester.pumpWidget(_pane(document, relay, cursors));
      await tester.pump();
      relay.follow('amy');
      relay.applyRemote('bo', const Rect.fromLTWH(0, 0, 10, 10), summon: true);
      await tester.pump();
      await tester.pump();

      final board = tester.getRect(
        find.byKey(const ValueKey('canvas-surface')),
      );
      final chip = tester.getRect(find.text('Following amy'));
      final card = tester.getRect(find.textContaining('wants to bring you'));
      expect(chip.bottom, lessThanOrEqualTo(board.top));
      expect(card.bottom, lessThanOrEqualTo(board.top));
      expect(chip.overlaps(card), isFalse);
      relay.declineSummon();
    });
  }
}

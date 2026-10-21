// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Audit C-114: at phone width the overflow menu lives in the header's
/// `CanvasCompactEditGroup`, which was handed a one-time `CanvasDockData`
/// snapshot, so a tile hidden afterwards never got its "Show" restore row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane_body.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_compact_dock.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pen_style.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _bob = VoiceParticipant(
  identity: 'bob',
  name: 'Bob',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

Widget _pane(CanvasDocument document, CanvasPresenceTileOverrides overrides) =>
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SizedBox(
            width: 390,
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
              callParticipants: const [_bob],
              cameraViewFor: (_) => const SizedBox(),
              screenShareViewFor: (_) => const SizedBox(),
              tileOverrides: overrides,
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
  testWidgets(
    'a tile hidden after build gets a Show row in the phone header menu',
    (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final document = CanvasDocument()..setViewport(const Size(390, 800));
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(document.dispose);
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_pane(document, overrides));
      await tester.pump();

      overrides.setHidden(presenceTileKeyForSlot(cameraTrackKind, 'bob'), true);
      await tester.pump();
      expect(find.byType(CanvasCompactEditGroup), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(AppMenuItem, "Show Bob's camera"),
        findsOneWidget,
      );
    },
  );
}

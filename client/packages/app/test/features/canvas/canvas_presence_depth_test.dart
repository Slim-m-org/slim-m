// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a presence tile's pieces paint (decision 0086): the video in
/// [CanvasPresenceBackdrop], before [CanvasSurface] so ink, drafts and cursors
/// land on top of every tile, and the controls in [CanvasPresenceLayer] above
/// the surface, since [CanvasSurface] claims every pointer in its own bounds.
///
/// The paint-order test asserts `Stack.children` order alone;
/// `canvas_presence_depth_paint_test.dart` is the pixel-level companion.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane_body.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pen_style.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'presence_stack.dart';

/// Camera on: a person without a feed has no tile at all.
const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

Widget _wrapLayer(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SizedBox(width: 1000, height: 800, child: child)),
  ),
);

Widget _layer(CanvasDocument document, CanvasPresenceTileOverrides overrides) =>
    PresenceStack(
      document: document,
      participants: const [_noor],
      cameraViewFor: (_) => const SizedBox(),
      screenShareViewFor: (_) => const SizedBox(),
      overrides: overrides,
      onCommit: (_, __) {},
    );

Widget _backdrop(
  CanvasDocument document,
  CanvasPresenceTileOverrides overrides,
) => CanvasPresenceBackdrop(
  document: document,
  participants: const [_noor],
  cameraViewFor: (_) => const SizedBox(),
  screenShareViewFor: (_) => const SizedBox(),
  overrides: overrides,
);

/// A full pane, the same construction `canvas_assembled_snapshot_support
/// .dart` uses, minus everything that needs a real voice controller:
/// `callDock` stays null, and nothing here opens the activity panel (the
/// one branch under this file's own subtree that reaches further into
/// Riverpod than a bare [ProviderScope] covers).
Widget _pane(CanvasDocument document, CanvasPresenceTileOverrides overrides) =>
    ProviderScope(
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
              callParticipants: const [_noor],
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
    'CanvasPresenceBackdrop paints before CanvasSurface, so its content '
    'never wins a pointer over the drawing surface',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_pane(document, overrides));
      await tester.pump();

      final stack = tester.widget<Stack>(
        find
            .ancestor(
              of: find.byType(CanvasSurface),
              matching: find.byType(Stack),
            )
            .first,
      );
      final types = stack.children.map((w) => w.runtimeType).toList();
      final gridIndex = types.indexOf(CanvasGridLayer);
      final backdropIndex = types.indexOf(CanvasPresenceBackdrop);
      final surfaceIndex = types.indexOf(CanvasSurface);
      final frontLayerIndex = types.indexOf(CanvasPresenceLayer);

      expect(gridIndex, isNot(-1));
      expect(backdropIndex, isNot(-1));
      expect(
        gridIndex,
        lessThan(backdropIndex),
        reason:
            'the grid must sit under a tile\'s own video, not paint over it',
      );
      expect(
        backdropIndex,
        lessThan(surfaceIndex),
        reason:
            'a widget earlier in a Stack paints, and hit-tests, before one '
            'later in it - CanvasSurface must never come before its own '
            'backdrop',
      );
      expect(
        surfaceIndex,
        lessThan(frontLayerIndex),
        reason: 'every tile\'s controls stay above the drawing surface',
      );
    },
  );

  testWidgets('the interactive layer holds no video, only the control shell', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(
      _wrapLayer(
        CanvasPresenceLayer(
          document: document,
          participants: const [_noor],
          overrides: overrides,
          onCommit: (_, _) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CanvasPresenceBubble), findsNothing);
    expect(find.byKey(const ValueKey('camera:user-noor')), findsOneWidget);
  });

  testWidgets('every tile\'s video renders in the backdrop', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_backdrop(document, overrides)));
    await tester.pump();

    expect(find.byType(CanvasPresenceBubble), findsOneWidget);
  });

  testWidgets('the backdrop never intercepts a pointer', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_backdrop(document, overrides)));
    await tester.pump();

    final ignorePointer = tester.widget<IgnorePointer>(
      find.byKey(canvasPresenceBackdropIgnorePointerKey),
    );
    expect(ignorePointer.ignoring, isTrue);
  });

  testWidgets('dragging a tile writes its new position to the overrides', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();
    expect(overrides.stateFor('camera:user-noor').rect, isNull);

    await tester.drag(
      find.byKey(const ValueKey('camera:user-noor')),
      const Offset(50, 30),
    );
    await tester.pump();

    final rect = overrides.stateFor('camera:user-noor').rect;
    expect(rect, isNotNull);
    expect(rect!.left, greaterThan(0));
  });
}

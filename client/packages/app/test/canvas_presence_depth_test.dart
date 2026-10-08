// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sending a presence tile to the back: its own content moves into
/// [CanvasPresenceBackdrop], painted before [CanvasSurface] so real ink
/// lands on top of it, while every control - drag, resize, lock, hide, and
/// the depth toggle itself - stays reachable exactly where it already was.
///
/// The paint-order test below is a structural regression guard for the
/// hit-testing trap a rendered probe found before this file existed: moving
/// the whole manipulable tile behind [CanvasSurface] does not merely dim its
/// controls, it deletes them, since [CanvasSurface] claims every pointer in
/// its own bounds and Flutter's Stack hit-testing never reaches past the
/// first claimant. See `canvas_presence_layer.dart`'s own doc for the full
/// account.
///
/// That structural test asserts `Stack.children` order alone, which - the
/// same `canvas_grid_layer_test.dart` lesson - proves nothing about what
/// actually paints. `canvas_presence_depth_paint_test.dart` is the
/// pixel-level companion: it rasterises the real assembled pane and reads
/// colours back, so a widget correctly ordered but silently painting
/// nothing, or painting the wrong thing, fails there even when it passes
/// here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_activity_log.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane_body.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pen_style.dart';
import 'package:slimm_app/src/screens/canvas/canvas_presence_layer.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Camera on: depth is a video-tile verb - an avatar-only tile forces
/// `sentToBack` to `false` regardless of what overrides says, so this suite
/// needs a real video tile to exercise the toggle at all. See
/// `canvas_presence_tile_kind_test.dart` for the avatar side of that.
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
    CanvasPresenceLayer(
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
            'the grid must sit under a sent-to-back tile\'s own video, not '
            'paint over it - report 1 in the backlog channel',
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

  testWidgets(
    'a sent-to-back tile has no bubble in the interactive layer, but its '
    'manipulable shell is still there',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides()
        ..setSentToBack('camera:user-noor', true);
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();

      expect(find.byType(CanvasPresenceBubble), findsNothing);
      expect(
        find.byKey(const ValueKey('camera:user-noor')),
        findsOneWidget,
        reason: 'depth never removes the control shell, only its content',
      );
    },
  );

  testWidgets(
    'the same sent-to-back tile\'s content renders in the backdrop instead',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides()
        ..setSentToBack('camera:user-noor', true);
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_backdrop(document, overrides)));
      await tester.pump();

      expect(find.byType(CanvasPresenceBubble), findsOneWidget);
    },
  );

  testWidgets('a tile still in front renders nothing in the backdrop', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_backdrop(document, overrides)));
    await tester.pump();

    expect(find.byType(CanvasPresenceBubble), findsNothing);
  });

  testWidgets('the backdrop never intercepts a pointer', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides()
      ..setSentToBack('camera:user-noor', true);
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_backdrop(document, overrides)));
    await tester.pump();

    final ignorePointer = tester.widget<IgnorePointer>(
      find.byKey(canvasPresenceBackdropIgnorePointerKey),
    );
    expect(ignorePointer.ignoring, isTrue);
  });

  testWidgets(
    'dragging a sent-to-back tile still writes its new position back to '
    'the overrides, unchanged from a tile still in front',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides()
        ..setSentToBack('camera:user-noor', true);
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
    },
  );

  testWidgets('the depth control toggles sentToBack, and its icon reflects the '
      'current state', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();

    final tileFinder = find.byKey(const ValueKey('camera:user-noor'));
    expect(
      find.descendant(
        of: tileFinder,
        matching: find.byIcon(AppIcons.bringToFront),
      ),
      findsOneWidget,
      reason: 'front is the default, so its state glyph shows first',
    );

    // A first tap reveals the control row - report 3 asked for it gone until asked for.
    await tester.tap(tileFinder);
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: tileFinder,
        matching: find.byIcon(AppIcons.bringToFront),
      ),
    );
    await tester.pump();

    expect(overrides.stateFor('camera:user-noor').sentToBack, isTrue);
    expect(
      find.descendant(
        of: tileFinder,
        matching: find.byIcon(AppIcons.sendToBack),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: tileFinder,
        matching: find.byIcon(AppIcons.sendToBack),
      ),
    );
    await tester.pump();

    expect(overrides.stateFor('camera:user-noor').sentToBack, isFalse);
  });
}

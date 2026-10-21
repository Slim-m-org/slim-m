// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A presence tile's own lock/depth/hide row and resize grip, hidden until
/// hovered (desktop), pressed once (touch, where there is no hover), or
/// focused (keyboard) - report 3 in the backlog channel: "the buttons...
/// don't ever go away and they are quite large", reported again after the
/// hover/press reveal shipped because tabbing onto a control still operated
/// it invisibly rather than showing it.
///
/// `canvas_presence_depth_test.dart` already covers what these controls do
/// once reached; this file covers whether they can be reached at all, and
/// the one non-negotiable this change must not break: a locked tile still
/// has a way back to its own unlock button.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile_controls.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'presence_stack.dart';

/// Camera on: an avatar-only tile has no lock control at all for this suite
/// to reveal - see `canvas_presence_tile_kind_test.dart`'s own coverage of
/// that.
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

const _lockLabel = 'Lock this tile in place';
const _tileKey = ValueKey('camera:user-noor');

/// Requests focus on the lock button's own [Focus] node, found from a
/// descendant [Icon] rather than the outer [Semantics] the label finder
/// matches - `Focus.of` only ever looks upward, so it has to start below
/// `AppIconButton`'s own `FocusableActionDetector`, not above it.
void _focusLockButton(WidgetTester tester) {
  final icon = find
      .descendant(
        of: find.bySemanticsLabel(_lockLabel),
        matching: find.byWidgetPredicate((w) => w is Icon),
      )
      .first;
  Focus.of(tester.element(icon)).requestFocus();
}

/// The counterpart to [_focusLockButton]: reads the same node back out to
/// drop focus from it, rather than guessing at an ancestor scope.
void _unfocusLockButton(WidgetTester tester) {
  final icon = find
      .descendant(
        of: find.bySemanticsLabel(_lockLabel),
        matching: find.byWidgetPredicate((w) => w is Icon),
      )
      .first;
  Focus.of(tester.element(icon)).unfocus();
}

void main() {
  testWidgets('the lock control does nothing to a bare tap before the tile '
      'has been hovered or pressed once', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel(_lockLabel), warnIfMissed: false);
    await tester.pump();

    expect(
      overrides.stateFor('camera:user-noor').locked,
      isFalse,
      reason:
          'a hidden control must not be tappable, or hidden is only '
          'a visual claim',
    );
  });

  testWidgets(
    'hovering the tile with a mouse reveals the control row, and it stays '
    'reachable for as long as the mouse stays over it',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(
        location: tester.getCenter(find.byKey(_tileKey)),
      );
      await tester.pump(AppMotion.fast);

      await tester.tap(find.bySemanticsLabel(_lockLabel));
      await tester.pump();

      expect(overrides.stateFor('camera:user-noor').locked, isTrue);
    },
  );

  testWidgets('the mouse leaving the tile hides the control row again', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: tester.getCenter(find.byKey(_tileKey)));
    await tester.pump(AppMotion.fast);
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump(AppMotion.fast);

    await tester.tap(find.bySemanticsLabel(_lockLabel), warnIfMissed: false);
    await tester.pump();

    expect(
      overrides.stateFor('camera:user-noor').locked,
      isFalse,
      reason: 'the reveal must not outlive the hover that started it',
    );
  });

  testWidgets(
    'a first touch on the tile reveals the control row for a following tap',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();

      await tester.tap(find.byKey(_tileKey));
      await tester.pump(AppMotion.fast);

      await tester.tap(find.bySemanticsLabel(_lockLabel));
      await tester.pump();

      expect(overrides.stateFor('camera:user-noor').locked, isTrue);
    },
  );

  testWidgets('a touch reveal expires on its own after the reveal window, with '
      'nothing else keeping it up', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();

    await tester.tap(find.byKey(_tileKey));
    await tester.pump(
      canvasPresenceTileTouchRevealDuration + const Duration(seconds: 1),
    );

    await tester.tap(find.bySemanticsLabel(_lockLabel), warnIfMissed: false);
    await tester.pump();

    expect(overrides.stateFor('camera:user-noor').locked, isFalse);
  });

  testWidgets(
    'a locked tile still reveals its own unlock button on a touch - the '
    'one control this reveal gate must never hide for good',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides()
        ..setLocked('camera:user-noor', true);
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();

      // The content area is IgnorePointer'd while locked, so the down event reaches straight through to whatever the tile is stacked over - exactly the surface this test proves the reveal still fires above.
      await tester.tap(find.byKey(_tileKey), warnIfMissed: false);
      await tester.pump(AppMotion.fast);

      await tester.tap(find.bySemanticsLabel('Unlock this tile'));
      await tester.pump();

      expect(overrides.stateFor('camera:user-noor').locked, isFalse);
    },
  );

  testWidgets('the resize grip is also hidden until revealed', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();

    final grip = find.byType(TileResizeGrip);
    expect(grip, findsOneWidget);
    final ignorePointer = find.ancestor(
      of: grip,
      matching: find.byType(IgnorePointer),
    );
    expect(tester.widget<IgnorePointer>(ignorePointer.first).ignoring, isTrue);

    await tester.tap(find.byKey(_tileKey));
    await tester.pump(AppMotion.fast);

    expect(
      tester.widget<IgnorePointer>(ignorePointer.first).ignoring,
      isFalse,
      reason:
          'a reveal must uncover the resize grip exactly as it does '
          'the lock/depth/hide row',
    );
  });

  testWidgets(
    'tabbing keyboard focus onto the lock button reveals the row, not just '
    'lets a pointer tap that follows it operate an invisible control',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();

      _focusLockButton(tester);
      await tester.pump(AppMotion.fast);

      await tester.tap(find.bySemanticsLabel(_lockLabel));
      await tester.pump();

      expect(
        overrides.stateFor('camera:user-noor').locked,
        isTrue,
        reason:
            'focus must reveal the row the same way hover does, or a '
            'sighted keyboard user operates a button they cannot see',
      );
    },
  );

  testWidgets('moving keyboard focus off the tile hides the row again', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();

    _focusLockButton(tester);
    await tester.pump(AppMotion.fast);
    _unfocusLockButton(tester);
    await tester.pump(AppMotion.fast);

    await tester.tap(find.bySemanticsLabel(_lockLabel), warnIfMissed: false);
    await tester.pump();

    expect(
      overrides.stateFor('camera:user-noor').locked,
      isFalse,
      reason: 'a focus reveal must not outlive the focus that started it',
    );
  });

  group('a tile too small for the control row', () {
    Future<CanvasPresenceTileOverrides> pumpSmall(WidgetTester tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      overrides.applyServer(
        'camera:user-noor',
        rect: const Rect.fromLTWH(100, 100, 40, 30),
        locked: false,
        sentToBack: false,
      );
      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();
      return overrides;
    }

    testWidgets('keeps its hidden buttons out of keyboard focus', (
      tester,
    ) async {
      await pumpSmall(tester);

      _focusLockButton(tester);
      await tester.pump(AppMotion.fast);

      final icon = find
          .descendant(
            of: find.bySemanticsLabel(_lockLabel),
            matching: find.byWidgetPredicate((w) => w is Icon),
          )
          .first;
      expect(Focus.of(tester.element(icon)).hasFocus, isFalse);
    });

    testWidgets('still shows the resize grip once touched', (tester) async {
      await pumpSmall(tester);
      final grip = find.byType(TileResizeGrip);
      final ignoring = find.ancestor(
        of: grip,
        matching: find.byType(IgnorePointer),
      );
      expect(tester.widget<IgnorePointer>(ignoring.first).ignoring, isTrue);

      await tester.tap(find.byKey(_tileKey));
      await tester.pump(AppMotion.fast);

      expect(tester.widget<IgnorePointer>(ignoring.first).ignoring, isFalse);
    });
  });

  testWidgets('resizing at the board edge stops at it and never slides the '
      'tile', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides()..board = canvasBoard;
    addTearDown(overrides.dispose);
    overrides.applyServer(
      'camera:user-noor',
      rect: const Rect.fromLTWH(1800, 100, 100, 75),
      locked: false,
      sentToBack: false,
    );
    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();
    await tester.tap(find.byKey(_tileKey));
    await tester.pump(AppMotion.fast);

    final grip = tester.getCenter(find.byType(TileResizeGrip));
    final drag = await tester.startGesture(grip);
    await drag.moveBy(const Offset(200, 0));
    await tester.pump();
    await drag.up();
    await tester.pump();

    final rect = overrides.stateFor('camera:user-noor').rect!;
    expect(rect.left, 1800);
    expect(rect.right, lessThanOrEqualTo(canvasBoard.right + 1e-6));
  });
}

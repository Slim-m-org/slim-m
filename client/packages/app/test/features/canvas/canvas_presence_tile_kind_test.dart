// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The scoping report 4 asked for by name: "the pfp should not be broken or
/// resizeable." An avatar-only tile (camera off, no screen share) drags and
/// hides like any other presence tile, but exposes no resize grip and no
/// lock or depth row - those exist to manipulate a video track, and a bare
/// avatar has none. A camera-on tile keeps every affordance exactly as
/// before, proven here directly rather than only inferred from the other
/// presence suites staying green.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile_controls.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _avatarOnly = VoiceParticipant(
  identity: 'user-avatar',
  name: 'Avatar Only',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _onCamera = VoiceParticipant(
  identity: 'user-video',
  name: 'On Camera',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _avatarKey = ValueKey('camera:user-avatar');
const _videoKey = ValueKey('camera:user-video');

Widget _wrapLayer(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SizedBox(width: 1000, height: 800, child: child)),
  ),
);

Widget _layer(
  CanvasDocument document,
  CanvasPresenceTileOverrides overrides, {
  List<VoiceParticipant> participants = const [_avatarOnly, _onCamera],
}) => CanvasPresenceLayer(
  document: document,
  participants: participants,
  cameraViewFor: (_) => const SizedBox(),
  screenShareViewFor: (_) => const SizedBox(),
  overrides: overrides,
  onCommit: (_, __) {},
);

/// Reveals a tile's own control row the same way a real touch would - a tap
/// on the tile itself, once - matching `canvas_presence_tile_reveal_test
/// .dart`'s own sequence.
Future<void> _reveal(WidgetTester tester, Key tileKey) async {
  await tester.tap(find.byKey(tileKey));
  await tester.pump(AppMotion.fast);
}

void main() {
  testWidgets('an avatar-only tile exposes no resize grip, even revealed', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();
    await _reveal(tester, _avatarKey);

    expect(
      find.descendant(
        of: find.byKey(_avatarKey),
        matching: find.byType(TileResizeGrip),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'an avatar-only tile exposes no lock or depth control, even revealed',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();
      await _reveal(tester, _avatarKey);

      expect(
        find.descendant(
          of: find.byKey(_avatarKey),
          matching: find.bySemanticsLabel('Lock this tile in place'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(_avatarKey),
          matching: find.bySemanticsLabel('Send this tile to the back'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('an avatar-only tile still exposes hide', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();
    await _reveal(tester, _avatarKey);

    await tester.tap(
      find.descendant(
        of: find.byKey(_avatarKey),
        matching: find.bySemanticsLabel(
          'Hide this tile on your canvas; other participants still see it',
        ),
      ),
    );
    await tester.pump();

    expect(overrides.stateFor('camera:user-avatar').hidden, isTrue);
  });

  testWidgets(
    "hide's own tooltip says other participants still see it, not only "
    'that it leaves your canvas',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();
      await _reveal(tester, _avatarKey);

      expect(
        find.descendant(
          of: find.byKey(_avatarKey),
          matching: find.byTooltip('Hide on your canvas - others still see it'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('an avatar-only tile still drags to reposition', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
    await tester.pump();
    expect(overrides.stateFor('camera:user-avatar').rect, isNull);

    await tester.drag(find.byKey(_avatarKey), const Offset(40, 20));
    await tester.pump();

    final rect = overrides.stateFor('camera:user-avatar').rect;
    expect(rect, isNotNull);
    expect(rect!.left, greaterThan(0));
  });

  testWidgets(
    'an avatar-only tile paints at its fixed marker size regardless of a '
    'resized rect stored from before its camera turned off',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides()
        ..setRect('camera:user-avatar', const Rect.fromLTWH(50, 50, 400, 300));
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();

      expect(tester.getSize(find.byKey(_avatarKey)), canvasAvatarMarkerSize);
    },
  );

  testWidgets(
    'dragging an avatar-only tile never overwrites the size stored for it, '
    'only its position',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides()
        ..setRect('camera:user-avatar', const Rect.fromLTWH(50, 50, 400, 300));
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();

      await tester.drag(find.byKey(_avatarKey), const Offset(40, 20));
      await tester.pump();

      final rect = overrides.stateFor('camera:user-avatar').rect!;
      expect(
        rect.size,
        const Size(400, 300),
        reason:
            'a stale resize from when this key was a video tile must '
            'survive an avatar-only drag untouched, so the video tile is '
            'not left tiny the next time this camera turns on',
      );
      expect(rect.left, isNot(50));
    },
  );

  testWidgets(
    'a camera-on tile still exposes the resize grip, lock and depth row',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrapLayer(_layer(document, overrides)));
      await tester.pump();
      await _reveal(tester, _videoKey);

      expect(
        find.descendant(
          of: find.byKey(_videoKey),
          matching: find.byType(TileResizeGrip),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_videoKey),
          matching: find.bySemanticsLabel('Lock this tile in place'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_videoKey),
          matching: find.bySemanticsLabel('Send this tile to the back'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a camera turning off mid-call drops the lock its tile had while the '
    'camera was on, rather than freezing the now-avatar tile forever',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides()
        ..setLocked('camera:user-video', true);
      addTearDown(overrides.dispose);

      IgnorePointer contentIgnorePointer() => tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byType(CanvasPresenceBubble),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );

      await tester.pumpWidget(
        _wrapLayer(
          _layer(document, overrides, participants: const [_onCamera]),
        ),
      );
      await tester.pump();
      expect(
        contentIgnorePointer().ignoring,
        isTrue,
        reason: 'sanity: the lock actually engaged while the camera was on',
      );

      const cameraOff = VoiceParticipant(
        identity: 'user-video',
        name: 'On Camera',
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: false,
      );
      await tester.pumpWidget(
        _wrapLayer(
          _layer(document, overrides, participants: const [cameraOff]),
        ),
      );
      await tester.pump();
      await _reveal(tester, _videoKey);

      expect(
        contentIgnorePointer().ignoring,
        isFalse,
        reason:
            'a stale lock from while the camera was on must not freeze the '
            'tile now that it is a bare avatar - a lock is meaningless here',
      );
      expect(
        find.descendant(
          of: find.byKey(_videoKey),
          matching: find.bySemanticsLabel('Unlock this tile'),
        ),
        findsNothing,
        reason: 'and must not resurface as an unreachable dead end either',
      );
    },
  );
}

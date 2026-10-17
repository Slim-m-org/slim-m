// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasPresenceLayer]: which tiles render (self and remote, camera and
/// screen share), whether a live view or an avatar fallback fills one, that
/// panning far away drops a tile through the viewport hysteresis, and the
/// manipulation the owner asked for by name - drag, resize, lock and hide -
/// each written back to [CanvasPresenceTileOverrides] rather than lost.
///
/// Deliberately no `ProviderScope` and no [VoiceController]: this widget
/// takes participants and builder functions as plain constructor arguments,
/// the same "nothing here reaches Riverpod" rule `canvas_pane_body.dart`'s
/// own doc comment states for its sibling.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _cameraOff = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: true,
  isMuted: true,
  isLocal: false,
  isScreenSharing: false,
);

/// Lock is a video-tile verb now - an avatar-only tile forces it to `false`
/// regardless of overrides, so the lock test below needs a real video tile.
/// See `canvas_presence_tile_kind_test.dart` for the avatar side of that.
const _cameraOn = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: true,
  isMuted: true,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _localSharing = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: true,
);

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SizedBox(width: 1000, height: 800, child: child)),
  ),
);

Widget _layer(
  CanvasDocument document,
  List<VoiceParticipant> participants,
  CanvasPresenceTileOverrides overrides, {
  CameraViewBuilder cameraViewFor = _noView,
  ScreenShareViewBuilder screenShareViewFor = _noView,
  bool hideSelfCamera = false,
}) => CanvasPresenceLayer(
  document: document,
  participants: participants,
  cameraViewFor: cameraViewFor,
  screenShareViewFor: screenShareViewFor,
  overrides: overrides,
  onCommit: (_, __) {},
  hideSelfCamera: hideSelfCamera,
);

Widget _noView(String identity) => const SizedBox();

void main() {
  testWidgets('an empty roster renders nothing', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();

    await tester.pumpWidget(_wrap(_layer(document, const [], overrides)));
    await tester.pump();
    document.setViewport(const Size(1000, 800));
    await tester.pump();

    expect(find.byType(CanvasPresenceBubble), findsNothing);
  });

  testWidgets('a participant inside the viewport renders exactly one bubble', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();

    await tester.pumpWidget(
      _wrap(_layer(document, const [_cameraOff], overrides)),
    );
    await tester.pump();

    expect(find.byType(CanvasPresenceBubble), findsOneWidget);
  });

  testWidgets('the caller\'s own entry renders through this same layer', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();

    await tester.pumpWidget(
      _wrap(_layer(document, const [_cameraOff, _localSharing], overrides)),
    );
    await tester.pump();

    // Noor's camera, plus the local caller's own camera and screen-share tiles.
    expect(find.byType(CanvasPresenceBubble), findsNWidgets(2));
    expect(find.byType(CanvasScreenShareBubble), findsOneWidget);
  });

  testWidgets('hideSelfCamera drops only the self camera tile, never a self '
      'screen share', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();

    await tester.pumpWidget(
      _wrap(
        _layer(
          document,
          const [_localSharing],
          overrides,
          hideSelfCamera: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CanvasPresenceBubble), findsNothing);
    expect(find.byType(CanvasScreenShareBubble), findsOneWidget);
  });

  testWidgets(
    'panning the camera far past the exit band drops a previously-visible '
    'tile',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));
      final overrides = CanvasPresenceTileOverrides();

      await tester.pumpWidget(
        _wrap(_layer(document, const [_cameraOff], overrides)),
      );
      await tester.pump();
      expect(find.byType(CanvasPresenceBubble), findsOneWidget);

      document.setCamera(document.camera.copyWith(x: 100000, y: 100000));
      await tester.pump();

      expect(find.byType(CanvasPresenceBubble), findsNothing);
    },
  );

  testWidgets('an unlocked tile intercepts the pointer; a locked one does '
      'not, so a drawing tool reaches through it', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();

    await tester.pumpWidget(
      _wrap(_layer(document, const [_cameraOn], overrides)),
    );
    await tester.pump();

    IgnorePointer contentIgnorePointer() => tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byType(CanvasPresenceBubble),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(contentIgnorePointer().ignoring, isFalse);

    overrides.setLocked('camera:user-noor', true);
    await tester.pump();

    expect(contentIgnorePointer().ignoring, isTrue);
  });

  testWidgets('dragging a tile brings it to the front of paint order, so an '
      'untouched participant\'s tile can never sit over it', (tester) async {
    const other = VoiceParticipant(
      identity: 'user-avery',
      name: 'Avery',
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
    );
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();

    List<String> tileOrder() => tester
        .widgetList<CanvasPresenceManipulableTile>(
          find.byType(CanvasPresenceManipulableTile),
        )
        .map((tile) => (tile.key! as ValueKey<String>).value)
        .toList();

    await tester.pumpWidget(
      _wrap(_layer(document, const [_cameraOff, other], overrides)),
    );
    await tester.pump();
    // Both untouched: paints in the roster's own order, [_cameraOff, other].
    expect(tileOrder(), ['camera:user-noor', 'camera:user-avery']);

    // Touch the tile that already paints first, so a real move is the only way the order below could change.
    overrides.setRect(
      'camera:user-noor',
      const Rect.fromLTWH(500, 500, 140, 140),
    );
    await tester.pump();

    expect(
      tileOrder(),
      ['camera:user-avery', 'camera:user-noor'],
      reason:
          'the tile just touched paints last - on top - regardless of '
          'its own roster order',
    );
  });

  testWidgets('dragging an unlocked tile writes its new world position back '
      'to the overrides', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();

    await tester.pumpWidget(
      _wrap(_layer(document, const [_cameraOff], overrides)),
    );
    await tester.pump();
    expect(overrides.stateFor('camera:user-noor').rect, isNull);

    await tester.drag(find.byType(CanvasPresenceBubble), const Offset(50, 30));
    await tester.pump();

    final rect = overrides.stateFor('camera:user-noor').rect;
    expect(rect, isNotNull);
    expect(rect!.left, greaterThan(0));
  });

  testWidgets('a tile marked hidden in overrides renders nothing', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides()
      ..setHidden('camera:user-noor', true);

    await tester.pumpWidget(
      _wrap(_layer(document, const [_cameraOff], overrides)),
    );
    await tester.pump();

    expect(find.byType(CanvasPresenceBubble), findsNothing);
  });

  testWidgets(
    'a participant who leaves the call keeps their shared position, lock '
    'and depth - decision 0010\'s reversal made those persistent rather '
    'than reset on rejoin',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));
      final overrides = CanvasPresenceTileOverrides()
        ..setRect('camera:user-noor', const Rect.fromLTWH(500, 500, 100, 100))
        ..setLocked('camera:user-noor', true)
        ..setSentToBack('camera:user-noor', true);

      final widget = _wrap(_layer(document, const [_cameraOff], overrides));
      await tester.pumpWidget(widget);
      await tester.pump();
      expect(overrides.stateFor('camera:user-noor').rect, isNotNull);

      await tester.pumpWidget(_wrap(_layer(document, const [], overrides)));
      await tester.pump();

      final state = overrides.stateFor('camera:user-noor');
      expect(state.rect, const Rect.fromLTWH(500, 500, 100, 100));
      expect(state.locked, isTrue);
      expect(state.sentToBack, isTrue);
    },
  );

  testWidgets('a participant who leaves the call has their hide reset, so a '
      'rejoin shows their tile again', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides()
      ..setHidden('camera:user-noor', true);

    final widget = _wrap(_layer(document, const [_cameraOff], overrides));
    await tester.pumpWidget(widget);
    await tester.pump();
    expect(overrides.stateFor('camera:user-noor').hidden, isTrue);

    await tester.pumpWidget(_wrap(_layer(document, const [], overrides)));
    await tester.pump();

    expect(overrides.stateFor('camera:user-noor').hidden, isFalse);
  });

  testWidgets('a tile removed mid-drag (its owner left the call) balances '
      'CanvasDocument.externalPointers rather than leaving it stuck high', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();

    await tester.pumpWidget(
      _wrap(_layer(document, const [_cameraOff], overrides)),
    );
    await tester.pump();

    final pointer = TestPointer(1, PointerDeviceKind.touch);
    await tester.sendEventToBinding(pointer.down(const Offset(50, 50)));
    expect(document.externalPointers.count, 1);

    // Noor leaves with the pointer still down: no `.up()`, no `.cancel()`, the tile's own element is simply gone.
    await tester.pumpWidget(_wrap(_layer(document, const [], overrides)));
    await tester.pump();

    expect(
      document.externalPointers.count,
      0,
      reason:
          'a stuck-high count would block every future single-finger '
          'placement on this canvas, forever',
    );
  });

  testWidgets(
    'settling a drag commits the final rect, not the last live frame',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));
      final overrides = CanvasPresenceTileOverrides();
      String? committedKey;
      Rect? committedRect;

      await tester.pumpWidget(
        _wrap(
          CanvasPresenceLayer(
            document: document,
            participants: const [_cameraOff],
            cameraViewFor: _noView,
            screenShareViewFor: _noView,
            overrides: overrides,
            onCommit: (key, rect) {
              committedKey = key;
              committedRect = rect;
            },
          ),
        ),
      );
      await tester.pump();
      expect(committedKey, isNull, reason: 'nothing settled yet');

      await tester.drag(
        find.byKey(const ValueKey('camera:user-noor')),
        const Offset(40, 15),
      );
      await tester.pump();

      expect(committedKey, 'camera:user-noor');
      expect(committedRect, overrides.stateFor('camera:user-noor').rect);
    },
  );
}

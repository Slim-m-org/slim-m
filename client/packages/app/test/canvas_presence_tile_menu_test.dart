// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A presence tile's own right-click menu - the fix for the owner's report
/// that a camera or screen-share tile could not be right-clicked at all.
/// `canvas_presence_tile.dart`'s own `onSecondaryTapUp` used to be a
/// deliberate no-op purely to keep the click from leaking to a canvas
/// object underneath; it now opens this menu instead, while staying just as
/// opaque. `canvas_presence_tile_context_menu_test.dart` already covers an
/// avatar-only tile, whose menu is just "Hide" - this file covers a
/// full-featured tile's menu (every verb `TileControls`'s hover row already
/// has), that each item calls the same callback the row would, and that the
/// absorption survives a tile whose own menu genuinely shares label text
/// with the object menu it must still keep from opening.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_context_menu.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/voice/voice_controller_harness.dart';
import 'features/canvas/presence_stack.dart';

const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _tileKey = ValueKey('camera:user-noor');

/// [requests] is only ever non-null for the absorption test: the other cases
/// have nothing underneath the presence layer to absorb a click for.
Widget _wrap({
  required CanvasDocument document,
  required CanvasPresenceTileOverrides overrides,
  CanvasObjectMenuRequests? requests,
}) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 800,
        child: Stack(
          children: [
            if (requests != null)
              CanvasObjectContextMenu(
                document: document,
                canManage: false,
                selfId: 'me',
                requests: requests,
                tool: CanvasTool.pan,
                onToolChanged: (_) {},
                onBringToFront: (_) {},
                onSendToBack: (_) {},
                onDeleteSelected: (_) {},
                onPasteImageAt: (_) {},
                onAddNoteAt: (_) {},
                onRecenter: () {},
              ),
            PresenceStack(
              document: document,
              participants: const [_noor],
              cameraViewFor: (_) => const SizedBox(),
              screenShareViewFor: (_) => const SizedBox(),
              overrides: overrides,
              onCommit: (_, __) {},
              onFocus: (_) {},
            ),
          ],
        ),
      ),
    ),
  ),
);

Future<void> _rightClickTile(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(_tileKey)),
    buttons: kSecondaryButton,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a right-click on a full-featured tile opens a menu with every '
      'TileControls verb', (tester) async {
    final document = CanvasDocument()..setViewport(const Size(1200, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    await tester.pumpWidget(_wrap(document: document, overrides: overrides));
    await tester.pump();

    await _rightClickTile(tester);

    expect(find.text('Full screen'), findsOneWidget);
    expect(find.text('Lock in place'), findsOneWidget);
    expect(find.text('Send to back'), findsNothing);
    expect(find.text('Bring to front'), findsNothing);
    expect(find.text('Hide on your canvas'), findsOneWidget);
  });

  testWidgets(
    "Hide's own accessible label says other participants still see it, not "
    'only that it leaves your canvas',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1200, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      await tester.pumpWidget(_wrap(document: document, overrides: overrides));
      await tester.pump();

      await _rightClickTile(tester);

      expect(
        find.bySemanticsLabel(
          'Hide this tile on your canvas; other participants still see it',
        ),
        // A merged ancestor Semantics node can inherit a lone child's label, matching this text twice.
        findsAtLeastNWidgets(1),
      );
    },
  );

  testWidgets('tapping Full screen in the menu focuses the tile the way the '
      'hover control does, and closes the menu', (tester) async {
    final focused = <String>[];
    final harness = VoiceHarness();
    addTearDown(harness.dispose);
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    final document = CanvasDocument()..setViewport(const Size(1200, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 800,
              child: PresenceStack(
                document: document,
                participants: const [_noor],
                cameraViewFor: (_) => const SizedBox(),
                screenShareViewFor: (_) => const SizedBox(),
                overrides: overrides,
                onCommit: (_, __) {},
                onFocus: focused.add,
              ),
            ),
          ),
        ),
      ),
    );
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pump();
    session.emitParticipants(const [_noor]);
    await tester.pumpAndSettle();

    await _rightClickTile(tester);
    await tester.tap(find.text('Full screen'));
    await tester.pumpAndSettle();

    expect(focused, ['camera:user-noor']);
    expect(find.byType(FullscreenVideoView), findsNothing);
    expect(find.text('Hide on your canvas'), findsNothing);

    await harness.container.read(voiceControllerProvider.notifier).leave();
  });

  testWidgets('tapping Lock in place locks the tile and closes the menu', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1200, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    await tester.pumpWidget(_wrap(document: document, overrides: overrides));
    await tester.pump();

    await _rightClickTile(tester);
    await tester.tap(find.text('Lock in place'));
    await tester.pump();

    expect(overrides.stateFor('camera:user-noor').locked, isTrue);
    expect(find.text('Full screen'), findsNothing);
  });

  testWidgets(
    'tapping Hide on your canvas hides the tile and closes the menu',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1200, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      await tester.pumpWidget(_wrap(document: document, overrides: overrides));
      await tester.pump();

      await _rightClickTile(tester);
      await tester.tap(find.text('Hide on your canvas'));
      await tester.pump();

      expect(overrides.stateFor('camera:user-noor').hidden, isTrue);
      expect(find.text('Full screen'), findsNothing);
    },
  );

  testWidgets(
    'tapping outside the open menu dismisses it without invoking any verb',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1200, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      await tester.pumpWidget(_wrap(document: document, overrides: overrides));
      await tester.pump();

      await _rightClickTile(tester);
      expect(find.text('Hide on your canvas'), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.text('Hide on your canvas'), findsNothing);
      expect(overrides.stateFor('camera:user-noor').hidden, isFalse);
    },
  );

  testWidgets(
    'a right-click on a full-featured tile still does not reach a canvas '
    'object underneath, even though the tile menu shares label text with '
    'the object menu',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1200, 800));
      // Covers the whole viewport so wherever the tile lands sits over it - proving CanvasObjectContextMenu's own hit-catcher never even sees this pointer, not that this particular shape happens to be missed.
      document.applyPlaced(
        const CanvasStrokeInput(
          id: 'a',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 1200,
          h: 800,
          points: [],
          width: 0,
          colorKey: 'shape',
          kind: CanvasObjectKind.shape,
          authorId: 'me',
        ),
      );
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      final requests = CanvasObjectMenuRequests();
      await tester.pumpWidget(
        _wrap(document: document, overrides: overrides, requests: requests),
      );
      await tester.pump();

      await _rightClickTile(tester);

      expect(
        find.text('Delete'),
        findsNothing,
        reason:
            'Delete only ever appears in the object menu, never this '
            "tile's own",
      );
      expect(document.selectedObjectId.value, isNull);
      expect(
        find.text('Hide on your canvas'),
        findsOneWidget,
        reason: "the tile's own menu opened instead",
      );
    },
  );
}

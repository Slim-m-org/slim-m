// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A right-click landing on a presence tile is absorbed rather than
/// reaching a canvas object underneath it - the interaction #456's per-
/// object right-click menu and a presence tile share one `Stack`, and the
/// old, self-only version of this coverage (`canvas_self_presence_overlay
/// .dart`) moved with it once self and remote tiles became one layer. See
/// `canvas_presence_tile.dart`'s own doc for why this is deliberate rather
/// than a stacking-order accident.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_context_menu.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _local = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

/// Mirrors `canvas_pane_body.dart`'s own Stack order: the object menu's
/// full-screen catcher first, the presence layer last so it paints - and
/// hit tests - on top of it.
Widget _wrap({
  required CanvasDocument document,
  required CanvasObjectMenuRequests requests,
  required CanvasPresenceTileOverrides overrides,
}) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 400,
        child: Stack(
          children: [
            CanvasObjectContextMenu(
              document: document,
              canManage: false,
              selfId: 'me',
              requests: requests,
              tool: CanvasTool.pan,
              onBringToFront: (_) {},
              onSendToBack: (_) {},
              onDeleteSelected: (_) {},
              onPasteImageAt: (_) {},
              onAddNoteAt: (_) {},
              onRecenter: () {},
            ),
            CanvasPresenceLayer(
              document: document,
              participants: const [_local],
              cameraViewFor: (_) => const SizedBox(),
              screenShareViewFor: (_) => const SizedBox(),
              overrides: overrides,
              onCommit: (_, __) {},
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'a right-click on the presence tile opens no object menu, even for an '
    'object placed directly underneath it',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(400, 400));
      document.applyPlaced(
        const CanvasStrokeInput(
          id: 'a',
          seq: 1,
          zIndex: 1,
          x: 50,
          y: 50,
          w: 40,
          h: 40,
          points: [],
          width: 0,
          colorKey: 'shape',
          kind: CanvasObjectKind.note,
          text: 'note',
          authorId: 'me',
        ),
      );
      addTearDown(document.dispose);
      final requests = CanvasObjectMenuRequests();
      final overrides = CanvasPresenceTileOverrides();
      await tester.pumpWidget(
        _wrap(document: document, requests: requests, overrides: overrides),
      );

      // The default avatar-only tile sits at world (24,24)-(136,120) (margin 24, canvasAvatarMarkerSize): well inside it.
      await tester.tapAt(const Offset(90, 90), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Send to back'), findsNothing);
      expect(find.text('Bring to front'), findsNothing);
      expect(document.selectedObjectId.value, isNull);
    },
  );

  testWidgets(
    'a right-click well outside the tile still reaches the object beneath '
    'it - the absorption is scoped to the tile, not the whole layer',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(400, 400));
      document.applyPlaced(
        const CanvasStrokeInput(
          id: 'a',
          seq: 1,
          zIndex: 1,
          x: 300,
          y: 300,
          w: 40,
          h: 40,
          points: [],
          width: 0,
          colorKey: 'shape',
          kind: CanvasObjectKind.note,
          text: 'note',
          authorId: 'me',
        ),
      );
      addTearDown(document.dispose);
      final requests = CanvasObjectMenuRequests();
      final overrides = CanvasPresenceTileOverrides();
      await tester.pumpWidget(
        _wrap(document: document, requests: requests, overrides: overrides),
      );

      await tester.tapAt(const Offset(320, 320), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Send to back'), findsOneWidget);
      expect(document.selectedObjectId.value, 'a');
    },
  );
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member who can see the channel but not draw (`USE_CANVAS` withheld) is put
/// into the canvas like anyone else: the shared board, live, with nothing that
/// edits it, and the personal view still theirs.
library;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';
import 'presence_stack.dart';

const _settle = Duration(milliseconds: 400);

Future<CanvasPaneFixture> _pane(
  WidgetTester tester, {
  required int permissions,
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture(channelPermissions: permissions)
    ..objects = [canvasNoteJson('a', x: 400, authorId: 'me')];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pump(_settle);
  return fixture;
}

void main() {
  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    testWidgets('a spectator sees the board with no tools and no undo at '
        '${size.width}', (tester) async {
      await _pane(tester, permissions: Perm.viewChannel, size: size);

      expect(
        find.bySemanticsLabel(RegExp(r'^Canvas, 1 object')),
        findsOneWidget,
      );
      for (final label in ['Pen', 'Note', 'Eraser', 'Undo', 'Redo']) {
        expect(find.bySemanticsLabel(label), findsNothing, reason: label);
      }
      expect(
        find.text('The canvas is not available in this channel.'),
        findsNothing,
      );
      expect(find.text('Shared view'), findsOneWidget);
    });
  }

  testWidgets('a member who may draw keeps the tools', (tester) async {
    await _pane(tester, permissions: Perm.viewChannel | Perm.useCanvas);
    expect(find.bySemanticsLabel('Pen'), findsOneWidget);
    expect(find.bySemanticsLabel('Undo'), findsOneWidget);
  });

  testWidgets(
    "a spectator's overflow offers only what changes their own view",
    (tester) async {
      await _pane(tester, permissions: Perm.viewChannel);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pump();
      await tester.pump(_settle);

      expect(find.text('Enter fullscreen'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is AppMenuDivider),
        findsNothing,
        reason: 'no divider is left hanging under the one item',
      );
      for (final item in [
        'Add image from file',
        'Hide drawing tools',
        'Snap to grid',
        'Clear canvas',
      ]) {
        expect(find.text(item), findsNothing, reason: item);
      }
    },
  );

  testWidgets(
    "a spectator's keys and drags never edit, and their own old note does not move",
    (tester) async {
      final fixture = await _pane(tester, permissions: Perm.viewChannel);
      final document = surfaceDocument(tester);
      final before = document.objectBounds('a');

      await tester.tap(find.bySemanticsLabel(RegExp(r'^Canvas, ')));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump(_settle);
      expect(find.bySemanticsLabel('Pen'), findsNothing);

      final drag = await tester.startGesture(
        screenFor(tester, Offset(before!.x + 10, before.y + 10)),
      );
      await drag.moveTo(
        screenFor(tester, Offset(before.x + 80, before.y + 60)),
      );
      await drag.up();
      await tester.pump(_settle);

      expect(document.objectCount.value, 1);
      expect(document.objectBounds('a'), before, reason: 'the note stayed put');
      expect(fixture.postedOps, isEmpty, reason: 'nothing was sent');
      expect(fixture.posted, isEmpty, reason: 'nothing was placed');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump(_settle);
      expect(fixture.postedOps, isEmpty, reason: 'Delete edits nothing');
      expect(document.objectCount.value, 1);
    },
  );

  testWidgets(
    'a right-click on an object gives a spectator only Recenter, never an '
    'action that edits',
    (tester) async {
      await _pane(tester, permissions: Perm.viewChannel);
      final note = surfaceDocument(tester).objectBounds('a')!;

      await tester.tapAt(
        screenFor(tester, Offset(note.x + 10, note.y + 10)),
        buttons: kSecondaryButton,
      );
      await tester.pump(_settle);

      expect(find.text('Recenter view'), findsOneWidget);
      for (final item in [
        'Delete',
        'Bring to front',
        'Edit note',
        'Add note',
      ]) {
        expect(find.text(item), findsNothing, reason: item);
      }
    },
  );

  testWidgets(
    'a spectator cannot drag a call tile in the shared view, and can in the '
    'personal view',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              height: 800,
              child: PresenceStack(
                document: document,
                participants: const [
                  VoiceParticipant(
                    identity: 'ada',
                    name: 'Ada',
                    isSpeaking: false,
                    isMuted: false,
                    isLocal: false,
                    isScreenSharing: false,
                    isCameraOn: true,
                  ),
                ],
                cameraViewFor: (_) => const SizedBox(),
                screenShareViewFor: (_) => const SizedBox(),
                overrides: overrides,
                onCommit: (_, _) {},
                readOnly: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      bool ignoring() => tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find
                      .descendant(
                        of: find.byWidgetPredicate(
                          (w) => w is CanvasPresenceManipulableTile,
                        ),
                        matching: find.byWidgetPredicate(
                          (w) => w is GestureDetector,
                        ),
                      )
                      .first,
                  matching: find.byWidgetPredicate((w) => w is IgnorePointer),
                )
                .first,
          )
          .ignoring;
      expect(ignoring(), isTrue, reason: 'shared view: read only');

      overrides.personal = true;
      await tester.pump();
      expect(ignoring(), isFalse, reason: 'personal view: arrange freely');
    },
  );
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// screen-review canvas.md: the pane's own error banner kept the pen tool
/// and the dock's "Paste image" reachable underneath it, so a person could
/// pick a tool, or an action, that was guaranteed to fail the same write
/// the banner already refused. `canvas_tools_row_test.dart` proves the row
/// itself gates correctly given `canDraw`; this proves `CanvasPaneBody`
/// actually derives that flag from its own `error` field rather than a
/// copy that could drift from it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_activity_log.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane_body.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Widget _pane(CanvasDocument document, {required String? error}) =>
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
              canManage: false,
              document: document,
              onClear: () async {},
              onPasteImage: () {},
              onPasteImageAt: (_) {},
              onRecenter: () {},
              error: error,
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
              callParticipants: const [],
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
  testWidgets('an error banner disables the pen tool and paste image', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);

    await tester.pumpWidget(
      _pane(
        document,
        error: "You don't have permission to draw here right now.",
      ),
    );
    await tester.pump();

    final pen = tester.widget<AppIconButton>(
      find.ancestor(
        of: find.bySemanticsLabel('Pen'),
        matching: find.byType(AppIconButton),
      ),
    );
    expect(pen.onPressed, isNull);

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    final pasteItem = tester.widget<AppMenuItem>(
      find.widgetWithText(AppMenuItem, 'Paste image'),
    );
    expect(pasteItem.onTap, isNull);
  });

  testWidgets('with no error the pen tool and paste image stay live', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1000, 800));
    addTearDown(document.dispose);

    await tester.pumpWidget(_pane(document, error: null));
    await tester.pump();

    final pen = tester.widget<AppIconButton>(
      find.ancestor(
        of: find.bySemanticsLabel('Pen'),
        matching: find.byType(AppIconButton),
      ),
    );
    expect(pen.onPressed, isNotNull);

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    final pasteItem = tester.widget<AppMenuItem>(
      find.widgetWithText(AppMenuItem, 'Paste image'),
    );
    expect(pasteItem.onTap, isNotNull);
  });
}

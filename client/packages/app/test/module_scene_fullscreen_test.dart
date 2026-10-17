// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scene on a screen of its own.
///
/// Inline, a board is a child of the transcript's scroll view, and the two
/// want the same gestures - Flutter hands a vertical drag to the nearest
/// `Scrollable`, so drawing works sideways and scrolls the chat the moment
/// the finger moves down. Full screen resolves that by removing the
/// competition rather than arbitrating it, so the cases worth holding are:
/// the board really does take the room, there is no scrollable left to lose
/// a drag to, and the control is offered only where it leads somewhere.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_frame.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_fullscreen.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

String _sceneJson({int cols = 3, int rows = 3}) => jsonEncode({
  r'$slim': 'scene/1',
  'width': cols,
  'height': rows,
  'ops': [
    {
      'op': 'cells',
      'cols': cols,
      'rows': rows,
      'data': '0' * (cols * rows),
      'palette': ['sunken', 'accent'],
      'tap': 'c',
    },
  ],
  'controls': ['play'],
  'status': 'ready',
});

ModuleScene _scene({int cols = 3, int rows = 3}) =>
    parseModuleScene(_sceneJson(cols: cols, rows: rows))!;

Future<api.RunModuleCommandResult> _run(String input) async =>
    const api.RunModuleCommandResult(ok: true, output: 'x');

Future<void> _pumpFullscreen(
  WidgetTester tester, {
  Size window = const Size(1200, 900),
  int rows = 3,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: ModuleSceneFullscreen(
        initial: _scene(rows: rows),
        runCommand: _run,
        title: 'game-of-life',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the board takes the room it is given, not a share of it', (
    tester,
  ) async {
    await _pumpFullscreen(tester);

    final board = tester.getRect(find.byType(ModuleSceneFrame));
    // Inline a three-row grid caps at 160px a cell; here that cap is the bug.
    expect(
      board.height,
      greaterThan(ModuleSceneFrame.maxCellSize * 3),
      reason: 'full screen must not keep the inline per-cell cap',
    );
  });

  testWidgets('a non-square scene is letterboxed, not stretched', (
    tester,
  ) async {
    // 7x6, connect-four's own shape: the reported case, tall in a phone viewport whose own aspect is nothing like the board's.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: ModuleSceneFullscreen(
          initial: _scene(cols: 7, rows: 6),
          runCommand: _run,
          title: 'connect-four',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final board = tester.getRect(
      find.descendant(
        of: find.byType(ModuleSceneFrame),
        matching: find.byType(Container),
      ),
    );
    expect(
      board.width / board.height,
      closeTo(7 / 6, 0.01),
      reason:
          'the scene declared a 7x6 board; stretched to the viewport it '
          'would fill the whole (much taller) frame instead',
    );
  });

  testWidgets('a tap in full screen still lands on the cell it was drawn on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? sentAction;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: ModuleSceneFullscreen(
          initial: _scene(cols: 7, rows: 6),
          runCommand: (input) async {
            sentAction = jsonDecode(input)['action'] as String;
            return const api.RunModuleCommandResult(ok: true, output: 'x');
          },
          title: 'connect-four',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final paint = find.descendant(
      of: find.byType(ModuleSceneFrame),
      matching: find.byType(CustomPaint),
    );
    final topLeft = tester.getTopLeft(paint.last);
    final size = tester.getSize(paint.last);
    // The last column of the last row: the corner farthest from the origin, so a stretched or misaligned box would miss it in either axis.
    final cellW = size.width / 7;
    final cellH = size.height / 6;
    await tester.tapAt(
      topLeft + Offset(cellW * 6 + cellW / 2, cellH * 5 + cellH / 2),
    );
    await tester.pumpAndSettle();

    expect(sentAction, 'c:5,6');
  });

  testWidgets('nothing is left to lose a vertical drag to', (tester) async {
    await _pumpFullscreen(tester);

    expect(
      find.byType(Scrollable),
      findsNothing,
      reason:
          'a scrollable ancestor is what steals the vertical drag inline; '
          'the whole point of this screen is that there is not one',
    );
  });

  testWidgets('it names the module, for somebody arriving from a transcript', (
    tester,
  ) async {
    await _pumpFullscreen(tester);

    expect(find.text('game-of-life'), findsOneWidget);
  });

  testWidgets('the scene keeps its controls and status here', (tester) async {
    await _pumpFullscreen(tester);

    expect(find.text('ready'), findsOneWidget);
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
  });

  testWidgets('already full screen, it offers no way to expand again', (
    tester,
  ) async {
    await _pumpFullscreen(tester);

    expect(find.bySemanticsLabel('Open full screen'), findsNothing);
    expect(find.bySemanticsLabel('Leave full screen'), findsOneWidget);
  });

  testWidgets('an inline view offers expand when given somewhere to go', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var expanded = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ModuleSceneView(
            initial: _scene(),
            runCommand: _run,
            onExpand: () => expanded++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Open full screen'));
    await tester.pump();
    expect(expanded, 1);
  });

  testWidgets('a run with nowhere to expand to offers no control', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // The Dock panel's shape: an ephemeral run that already has the pane.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ModuleSceneView(initial: _scene(), runCommand: _run),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Open full screen'), findsNothing);
    expect(
      find.bySemanticsLabel('Play'),
      findsOneWidget,
      reason: 'its own controls are untouched by having no expand',
    );
  });

  group('leaving full screen', () {
    Future<void> openFromInline(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => ModuleSceneView(
                initial: _scene(),
                runCommand: _run,
                onExpand: () => showModuleSceneFullscreen(
                  context,
                  initial: _scene(),
                  runCommand: _run,
                  title: 'tic-tac-toe',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Open full screen'));
      await tester.pumpAndSettle();
      expect(find.byType(ModuleSceneFullscreen), findsOneWidget);
    }

    testWidgets('Escape leaves, and focus returns to the expand control', (
      tester,
    ) async {
      await openFromInline(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(ModuleSceneFullscreen), findsNothing);
      final expand = tester.widget<AppIconButton>(
        find.widgetWithIcon(AppIconButton, AppIcons.expand),
      );
      expect(expand.focusNode?.hasPrimaryFocus, isTrue);
    });

    testWidgets('the system back gesture leaves too', (tester) async {
      await openFromInline(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(ModuleSceneFullscreen), findsNothing);
    });

    testWidgets('the screen announces itself as a route naming the module', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await openFromInline(tester);

      expect(
        tester.getSemantics(find.byType(ModuleSceneFullscreen)),
        matchesSemantics(
          scopesRoute: true,
          namesRoute: true,
          label: 'tic-tac-toe, full screen',
        ),
      );
      handle.dispose();
    });

    testWidgets('focus enters full screen without a tap', (tester) async {
      await openFromInline(tester);

      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<ModuleSceneFullscreen>(),
        isNotNull,
      );
    });
  });
}

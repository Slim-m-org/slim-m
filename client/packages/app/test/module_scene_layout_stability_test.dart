// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Frame behaviour a crop must not break: a field near the canvas edge stays
/// whole, the frame holds its size as content shrinks, the painter honours the
/// crop origin, and an unbounded parent still gets a finite board.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/module_scene.dart';
import 'package:slimm_app/src/widgets/module_scene_frame.dart';
import 'package:slimm_app/src/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene_fixtures.dart';

Map<String, Object?> _rectAt(double x, double y, double w, [double? h]) =>
    sceneOf(100, 100, [
      {'op': 'rect', 'x': x, 'y': y, 'w': w, 'h': h ?? w, 'fill': 'accent'},
    ]);

Widget _host(ModuleScene scene, {double width = 400, Key? boundary}) =>
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: RepaintBoundary(
          key: boundary,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: ModuleSceneView(
                initial: scene,
                runCommand: (_) async =>
                    const api.RunModuleCommandResult(ok: true, output: ''),
              ),
            ),
          ),
        ),
      ),
    );

Rect _frame(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(ModuleSceneFrame),
        matching: find.byType(Container),
      )
      .first,
);

void main() {
  testWidgets('an input near the bottom edge is wholly inside the frame', (
    tester,
  ) async {
    final scene = sceneOf(100, 100, [
      {'op': 'rect', 'x': 20, 'y': 4, 'w': 60, 'h': 60, 'fill': 'sunken'},
      {'op': 'input', 'x': 21, 'y': 95, 'w': 58, 'submit': 'guess'},
    ]);
    await tester.pumpWidget(
      _host(parseModuleScene(jsonEncode(scene))!, width: 200),
    );
    await tester.pumpAndSettle();
    final frame = _frame(tester);
    final field = tester.getRect(find.byType(TextField));
    expect(frame.top <= field.top && field.bottom <= frame.bottom, isTrue);
    expect(frame.left <= field.left && field.right <= frame.right, isTrue);
  });

  testWidgets('shrinking content does not resize the frame', (tester) async {
    final first = parseModuleScene(jsonEncode(_rectAt(20, 20, 60, 50)))!;
    final notifier = ValueNotifier<ModuleScene>(first);
    addTearDown(notifier.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: notifier,
            builder: (_, scene, _) => ModuleSceneView(
              initial: scene,
              runCommand: (_) async =>
                  const api.RunModuleCommandResult(ok: true, output: ''),
            ),
          ),
        ),
      ),
    );
    final before = _frame(tester).size;
    for (final (i, size) in [(10.0, 30.0), (5.0, 10.0)].indexed) {
      final next = _rectAt(40, 30, size.$1, size.$2);
      next['state'] = 's$i';
      notifier.value = parseModuleScene(jsonEncode(next))!;
      await tester.pumpAndSettle();
      expect(_frame(tester).size, before, reason: 'scene ${i + 1}');
    }
  });

  testWidgets('the painter draws at the crop origin, not the canvas origin', (
    tester,
  ) async {
    final key = GlobalKey();
    final scene = parseModuleScene(jsonEncode(_rectAt(60, 60, 20)))!;
    expect(scene.viewLeft, greaterThan(50));
    await tester.pumpWidget(_host(scene, width: 300, boundary: key));
    await tester.pumpAndSettle();
    final frame = _frame(tester);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final pixel = (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = (await image.toByteData())!;
      final dx = frame.center.dx.round();
      final dy = frame.center.dy.round();
      final at = (dy * image.width + dx) * 4;
      return ui.Color.fromARGB(
        data.getUint8(at + 3),
        data.getUint8(at),
        data.getUint8(at + 1),
        data.getUint8(at + 2),
      );
    }))!;
    expect(pixel.toARGB32(), AppTokens.dark.accent.toARGB32());
  });

  test('an unbounded width still gives a finite inline board', () {
    final width = ModuleSceneFrame.inlineWidth(
      maxWidth: null,
      windowHeight: 900,
      aspect: 0.5,
      sceneHeight: 0,
    );
    expect(width, ModuleSceneFrame.maxInlineEdge * 0.5);
  });

  testWidgets('a scene in an unbounded row lays out at its own size', (
    tester,
  ) async {
    final scene = parseModuleScene(jsonEncode(sceneOf(100, 50, const [])))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ModuleSceneView(
              initial: scene,
              runCommand: (_) async =>
                  const api.RunModuleCommandResult(ok: true, output: ''),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      _frame(tester).width,
      closeTo(ModuleSceneFrame.maxInlineEdge * 2, 2),
    );
  });
}

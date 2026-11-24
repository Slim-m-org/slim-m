// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the text box pane tests share: a placed box, an open pane, the editor finders and the keys that commit.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_text_editor.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

Map<String, dynamic> textBoxJson(String id, {String authorId = 'me'}) => {
  'id': id,
  'kind': 'text',
  'z_index': 1,
  'x': 400.0,
  'y': 10.0,
  'w': 240.0,
  'h': 34.0,
  'props': {'text': 'before', 'size': 'medium', 'color': 'ink'},
  'author_id': authorId,
  'seq': 1,
  'created_at': 0,
};

Future<CanvasPaneFixture> openPane(
  WidgetTester tester, {
  List<Map<String, dynamic>> objects = const [],
  Widget? below,
}) async {
  final fixture = CanvasPaneFixture()..objects = [...objects];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, below: below);
  await pumpFrames(tester);
  return fixture;
}

Finder get editor => find.byWidgetPredicate((w) => w is CanvasTextEditor);

Finder get field => find.descendant(
  of: editor,
  matching: find.byWidgetPredicate((w) => w is TextField),
);

Future<void> placeWithTool(WidgetTester tester, Offset world) async {
  await tester.tap(find.bySemanticsLabel('Text'));
  await tester.pump();
  final gesture = await tester.startGesture(screenFor(tester, world));
  await gesture.up();
  await pumpFrames(tester);
}

Future<void> fingerTapTwice(WidgetTester tester, Offset world) async {
  final at = screenFor(tester, world);
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tapAt(at);
  await pumpFrames(tester);
}

Future<void> commit(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
  await pumpFrames(tester);
}

Rect boxOnScreen(WidgetTester tester, String id) {
  final document = surfaceDocument(tester);
  final bounds = document.objectBounds(id)!;
  final camera = document.camera;
  final origin = tester.getTopLeft(
    find.byWidgetPredicate((w) => w is CanvasSurface),
  );
  return Rect.fromLTWH(
    (bounds.x - camera.x) * camera.zoom,
    (bounds.y - camera.y) * camera.zoom,
    bounds.w * camera.zoom,
    bounds.h * camera.zoom,
  ).shift(origin);
}

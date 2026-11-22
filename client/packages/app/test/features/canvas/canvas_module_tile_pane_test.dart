// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module tile placed from the canvas menu lands as a `module` object and
/// shows its scene over the board at the box it was placed with.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../module_scene_fixtures.dart';
import 'canvas_pane_harness.dart';

http.Response? _tileRoutes(http.Request request) {
  final path = request.url.path;
  if (path == '/modules/canvas-tiles') {
    return jsonResponse([
      {
        'module_id': 'board',
        'tile': 'Board',
        'module': {
          'name': 'Board',
          'verified': true,
          'capabilities': <Object>[],
        },
      },
    ]);
  }
  if (path.endsWith('/scene')) {
    return jsonResponse({
      'object_id': request.url.pathSegments[4],
      'output': jsonEncode({...sceneOf(4, 3, const []), 'status': 'ready'}),
      'ran_at': 1,
    });
  }
  return null;
}

/// Enough frames for the menu's open and close animations and the placement's reply.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the menu places a module tile and its scene fills the box', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture()..routes = _tileRoutes;
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await _frames(tester);

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await _frames(tester);
    await tester.tap(find.text('Add Board'));
    await _frames(tester);

    final placed = fixture.posted.single;
    expect(placed['kind'], api.canvasModuleTileKind);
    expect(placed['props'], {'module_id': 'board', 'tile': 'Board'});
    expect(placed['w'], 640);
    expect(placed['h'], 480);

    final document = surfaceDocument(tester);
    final id = placed['id'] as String;
    expect(document.kindOf(id), CanvasObjectKind.tile);
    final world = Rect.fromLTWH(
      (placed['x'] as num).toDouble(),
      (placed['y'] as num).toDouble(),
      640,
      480,
    );
    expect(document.camera, const Camera(), reason: 'world is screen here');
    final origin = screenFor(tester, world.topLeft);
    final tile = tester.getRect(
      find.bySemanticsLabel(RegExp('^Board, a module tile')),
    );
    expect(tile.left, moreOrLessEquals(origin.dx, epsilon: 0.5));
    expect(tile.top, moreOrLessEquals(origin.dy, epsilon: 0.5));
    expect(tile.width, moreOrLessEquals(world.width, epsilon: 0.5));
    expect(tile.height, moreOrLessEquals(world.height, epsilon: 0.5));
    final status = tester.getRect(find.text('ready'));
    expect(tile.contains(status.center), isTrue, reason: '$status in $tile');
  });
}

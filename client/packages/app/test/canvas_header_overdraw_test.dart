// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas header stays clean however the canvas is panned. A grid line
/// rounded to just before the camera used to land a few pixels above the
/// surface, inside the header, and draw straight across its text; the
/// owner's screenshot showed exactly that at a panned camera.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_bar.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

final _boundary = GlobalKey();

Future<ui.Image> _capture(WidgetTester tester) async {
  late ui.Image image;
  await tester.runAsync(() async {
    final render =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    image = await render.toImage();
  });
  return image;
}

Future<List<Color>> _headerColumn(WidgetTester tester, double x) async {
  final image = await _capture(tester);
  late ByteData bytes;
  await tester.runAsync(
    () async =>
        bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
  );
  final header = tester.getRect(find.byType(CanvasBar));
  return [
    // The header's own bottom hairline is its last row, so stop one short.
    for (var y = header.top.ceil(); y < header.bottom.floor() - 1; y++)
      () {
        final i = (y * image.width + x.round()) * 4;
        return Color.fromARGB(
          bytes.getUint8(i + 3),
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
      }(),
  ];
}

/// A shape straddling the top edge once the camera moves down to it.
const _straddling = CanvasStrokeInput(
  id: 'tall',
  seq: 1,
  zIndex: 1,
  x: 1060,
  y: 0,
  w: 140,
  h: 200,
  points: [],
  width: 0,
  colorKey: 'shape',
  kind: CanvasObjectKind.shape,
  authorId: 'someone',
);

void main() {
  for (final (cameraY, withShape) in [
    (0.0, false),
    (23.0, false),
    (41.5, false),
    (63.0, false),
    (30.0, true),
  ]) {
    testWidgets('a camera at y=$cameraY${withShape ? ' over a shape' : ''} '
        'draws nothing over the header', (tester) async {
      tester.view.physicalSize = const Size(1200, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundary,
          child: UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.dark, AppTokens.dark),
              home: const Scaffold(body: CanvasPane(channelId: 'c1')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final document = tester
          .widget<CanvasSurface>(find.byType(CanvasSurface))
          .document;
      if (withShape) document.applyPlaced(_straddling);
      document.setCamera(Camera(x: withShape ? 0 : 17, y: cameraY));
      await tester.pump();

      // Right of the header's text, where only its own fill should show.
      final column = await _headerColumn(tester, 1150);
      expect(column, isNotEmpty);
      expect(column.toSet(), {
        AppTokens.dark.surfaceRaised,
      }, reason: 'only the header fill may paint here, never a canvas line');
    });
  }
}

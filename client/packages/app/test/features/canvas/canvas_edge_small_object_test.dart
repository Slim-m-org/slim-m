// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small selected or hovered object still moves under the Move tool: its side dots must not swallow a press on its body.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_edge_style.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

Map<String, dynamic> _small(
  String id, {
  required bool emoji,
  required int seq,
}) {
  final base = canvasNoteJson(id, x: 300, seq: seq);
  return {
    ...base,
    'kind': emoji ? 'emoji' : 'note',
    'y': 200.0,
    'w': emoji ? 43.0 : 160.0,
    'h': emoji ? 43.0 : 34.0,
    'props': emoji ? {'emoji': '\u{1F389}'} : {'text': 'one line'},
  };
}

Future<CanvasPaneFixture> _open(
  WidgetTester tester,
  bool emoji,
  double zoom,
) async {
  final fixture = CanvasPaneFixture();
  fixture.routes = (request) async => request.url.path == '/version'
      ? jsonResponse({
          'name': 'slim-m',
          'version': '0.118.0',
          'protocol': 1,
          'push_enabled': false,
          'invite_required': false,
          'claimed': true,
          'canvas_edges': true,
        })
      : null;
  fixture.objects = [_small('s', emoji: emoji, seq: 1)];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: 'Pan');
  final document = surfaceDocument(tester);
  await waitUntil(tester, () => document.isAlive('s'));
  await waitUntil(tester, () => container.read(canvasEdgesSupportedProvider));
  document.setCamera(Camera(zoom: zoom));
  await tester.pump();
  return fixture;
}

Offset _screen(WidgetTester tester, CanvasDocument document, Offset world) {
  final camera = document.camera;
  final local = Offset(
    (world.dx - camera.x) * camera.zoom,
    (world.dy - camera.y) * camera.zoom,
  );
  return screenFor(tester, Offset.zero) + local;
}

Future<void> _dragCentre(
  WidgetTester tester,
  CanvasDocument document,
  PointerDeviceKind kind,
) async {
  final box = document.objectBounds('s')!;
  final centre = Offset(box.x + box.w / 2, box.y + box.h / 2);
  final from = _screen(tester, document, centre);
  final gesture = await tester.startGesture(from, kind: kind);
  for (var i = 1; i <= 8; i++) {
    await gesture.moveTo(from + Offset(10.0 * i, 6.0 * i));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  for (final emoji in [false, true]) {
    final what = emoji ? '43px stamp' : 'single-line text box';
    for (final (kind, zoom) in [
      (PointerDeviceKind.touch, 0.8),
      (PointerDeviceKind.mouse, 0.5),
    ]) {
      testWidgets('a selected $what moves from its middle ($kind at $zoom)', (
        tester,
      ) async {
        final fixture = await _open(tester, emoji, zoom);
        final document = surfaceDocument(tester);
        final before = document.objectBounds('s')!;
        final centre = Offset(before.x + before.w / 2, before.y + before.h / 2);
        await tester.tapAt(_screen(tester, document, centre));
        await tester.pump();
        expect(document.selectedObjectId.value, 's');
        expect(document.edges.dotsOn.value, 's');
        // The geometry that made the bug: the middle sits inside a dot's reach.
        final reach =
            (kind == PointerDeviceKind.touch
                ? sideDotTouchReachPx
                : sideDotReachPx) /
            zoom;
        final box = Rect.fromLTWH(before.x, before.y, before.w, before.h);
        expect((box.topCenter - centre).distance, lessThan(reach));

        await _dragCentre(tester, document, kind);
        await waitUntil(
          tester,
          () => fixture.postedOps.any((o) => o['kind'] == 'move'),
        );

        expect(fixture.posted.where((p) => p['kind'] == 'edge'), isEmpty);
        final after = document.objectBounds('s')!;
        expect(after.x, greaterThan(before.x));
        expect(after.y, greaterThan(before.y));
      });
    }
  }
}

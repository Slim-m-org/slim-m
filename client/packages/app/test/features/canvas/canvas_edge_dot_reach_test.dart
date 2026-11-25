// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The side dots stay while the pointer travels from the object onto a dot, outer half included, and a press there starts a connection.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

Future<CanvasPaneFixture> _open(
  WidgetTester tester, {
  List<Map<String, dynamic>> extra = const [],
}) async {
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
  fixture.objects = [
    {...canvasNoteJson('a', x: 100, seq: 1), 'y': 100.0, 'w': 120.0, 'h': 60.0},
    {...canvasNoteJson('c', x: 400, seq: 2), 'y': 300.0, 'w': 120.0, 'h': 60.0},
    ...extra,
  ];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: 'Pan');
  await waitUntil(tester, () => surfaceDocument(tester).isAlive('c'));
  return fixture;
}

void main() {
  testWidgets('the dots stay on the outer half of a dot and a press there '
      'draws a connection', (tester) async {
    final fixture = await _open(tester);
    final document = surfaceDocument(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: screenFor(tester, const Offset(0, 0)));

    await mouse.moveTo(screenFor(tester, const Offset(160, 130)));
    await tester.pump();
    expect(document.edges.dotsOn.value, 'a', reason: 'baseline: over the body');

    // The bottom dot sits at (160, 160); this is its outer half.
    const outer = Offset(160, 160 + sideDotReachPx - 3);
    await mouse.moveTo(screenFor(tester, const Offset(160, 168)));
    await mouse.moveTo(screenFor(tester, outer));
    await tester.pump();
    expect(document.edges.dotsOn.value, 'a');

    await mouse.down(screenFor(tester, outer));
    await mouse.moveTo(screenFor(tester, const Offset(300, 250)));
    await mouse.moveTo(screenFor(tester, const Offset(460, 330)));
    await mouse.up();
    await waitUntil(
      tester,
      () => fixture.posted.any((p) => p['kind'] == 'edge'),
    );
    final props = fixture.posted.single['props'] as Map<String, dynamic>;
    expect(props['from'], {'object_id': 'a', 'side': 'bottom'});
  });

  testWidgets('past the reach of the dot the dots go', (tester) async {
    await _open(tester);
    final document = surfaceDocument(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: screenFor(tester, const Offset(0, 0)));
    await mouse.moveTo(screenFor(tester, const Offset(160, 130)));
    await tester.pump();

    await mouse.moveTo(
      screenFor(tester, const Offset(160, 160 + sideDotReachPx + 6)),
    );
    await tester.pump();

    expect(document.edges.dotsOn.value, isNull);
  });

  testWidgets('hovering straight onto a dot from outside shows the dots and '
      'a press there draws a connection', (tester) async {
    final fixture = await _open(tester);
    final document = surfaceDocument(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: screenFor(tester, const Offset(0, 0)));
    expect(document.edges.dotsOn.value, isNull, reason: 'baseline');

    const outer = Offset(160, 160 + sideDotReachPx - 3);
    await mouse.moveTo(screenFor(tester, const Offset(160, 220)));
    await mouse.moveTo(screenFor(tester, outer));
    await tester.pump();
    expect(document.edges.dotsOn.value, 'a');

    await mouse.down(screenFor(tester, outer));
    await mouse.moveTo(screenFor(tester, const Offset(300, 250)));
    await mouse.moveTo(screenFor(tester, const Offset(460, 330)));
    await mouse.up();
    await waitUntil(
      tester,
      () => fixture.posted.any((p) => p['kind'] == 'edge'),
    );
    final props = fixture.posted.single['props'] as Map<String, dynamic>;
    expect(props['from'], {'object_id': 'a', 'side': 'bottom'});
  });

  testWidgets('with two dots in reach the nearest object wins', (tester) async {
    await _open(
      tester,
      extra: [
        {
          ...canvasNoteJson('d', x: 100, seq: 3),
          'y': 180.0,
          'w': 120.0,
          'h': 60.0,
        },
      ],
    );
    final document = surfaceDocument(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: screenFor(tester, const Offset(0, 0)));

    // Between a's bottom dot (160, 160) and d's top dot (160, 180), nearer d's.
    await mouse.moveTo(screenFor(tester, const Offset(160, 172)));
    await tester.pump();

    expect(document.edges.dotsOn.value, 'd');
  });
}

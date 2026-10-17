// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tap with a drawing tool leaves a dot, driven through the full pane
/// because the surface sits under the dock and tiles: a bare pointer-up
/// commit is only safe if every gesture that is not a lone primary tap on
/// empty canvas still draws nothing.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/canvas/canvas_pane_harness.dart';

Future<CanvasPaneFixture> _pump(
  WidgetTester tester, {
  bool withObject = false,
}) async {
  final fixture = CanvasPaneFixture();
  if (withObject) fixture.objects = [canvasObjectJson('mine', x: 0)];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  testWidgets('a pen tap on empty canvas posts one dot sized by the stroke '
      'width and undoes as one step', (tester) async {
    final fixture = await _pump(tester);

    final tap = await tester.startGesture(
      screenFor(tester, const Offset(200, 120)),
    );
    await tap.up();
    await tester.pumpAndSettle();

    expect(fixture.posted, hasLength(1));
    final dot = fixture.posted.single;
    expect(dot['kind'], 'stroke');
    expect(dot['props']['points'], [0.0, 0.0]);
    expect(dot['props']['width'], 3.0);
    expect(dot['x'], 200.0);
    expect(dot['y'], 120.0);
    expect(surfaceDocument(tester).objectCount.value, 1);

    await tester.tap(find.bySemanticsLabel('Undo'));
    await tester.pumpAndSettle();
    expect(fixture.postedOps.single['object_ids'], [dot['id']]);
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  testWidgets('a tap on a dock button leaves no dot under it', (tester) async {
    final fixture = await _pump(tester);

    final button = find.bySemanticsLabel('Eraser');
    final press = await tester.startGesture(tester.getCenter(button));
    await tester.pump(kPressTimeout);
    await press.up();
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  testWidgets('a middle-button press, the pan gesture, leaves no dot', (
    tester,
  ) async {
    final fixture = await _pump(tester);

    final at = screenFor(tester, const Offset(200, 120));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      mouse.down(at, buttons: kMiddleMouseButton),
    );
    await tester.sendEventToBinding(mouse.up());
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
  });

  testWidgets('a right-button press leaves no dot', (tester) async {
    final fixture = await _pump(tester);

    final at = screenFor(tester, const Offset(200, 120));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      mouse.down(at, buttons: kSecondaryMouseButton),
    );
    await tester.sendEventToBinding(mouse.up());
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
  });

  testWidgets('two fingers landing together (a pinch) leave no dot', (
    tester,
  ) async {
    final fixture = await _pump(tester);

    final first = await tester.startGesture(
      screenFor(tester, const Offset(200, 120)),
    );
    final second = await tester.startGesture(
      screenFor(tester, const Offset(260, 160)),
    );
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
  });

  testWidgets('a second finger lifting first still leaves no dot from the '
      'finger that stayed', (tester) async {
    final fixture = await _pump(tester);

    final first = await tester.startGesture(
      screenFor(tester, const Offset(200, 120)),
    );
    final second = await tester.startGesture(
      screenFor(tester, const Offset(260, 160)),
    );
    await second.up();
    await first.up();
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
  });

  testWidgets('an eraser tap erases the stroke under it and draws nothing', (
    tester,
  ) async {
    final fixture = await _pump(tester, withObject: true);
    expect(surfaceDocument(tester).objectCount.value, 1);

    await tester.tap(find.bySemanticsLabel('Eraser'));
    await tester.pump();
    final tap = await tester.startGesture(
      screenFor(tester, const Offset(10, 20)),
    );
    await tap.up();
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
    expect(fixture.postedOps.single['kind'], 'remove');
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  testWidgets('a select-tool tap on empty canvas draws nothing', (
    tester,
  ) async {
    final fixture = await _pump(tester);

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    final tap = await tester.startGesture(
      screenFor(tester, const Offset(200, 120)),
    );
    await tap.up();
    await tester.pumpAndSettle();

    expect(fixture.posted, isEmpty);
    expect(fixture.postedOps, isEmpty);
  });
}

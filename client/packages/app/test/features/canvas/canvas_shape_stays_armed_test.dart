// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shape tool stays armed after a placement, the new shape carries live resize handles, and Escape goes back to Pan.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_gesture_fuzz_rig.dart';
import 'canvas_gesture_repro_support.dart';

Iterable<Map<String, dynamic>> _shapes(FuzzRig rig) =>
    rig.fixture.posted.where((p) => p['kind'] == 'shape');

Future<void> _tapShape(FuzzRig rig, Offset at, int id) async {
  final pointer = await down(
    rig.tester,
    at,
    kind: PointerDeviceKind.mouse,
    id: id,
  );
  await lift(rig.tester, pointer);
}

Future<FuzzRig> _armShape(WidgetTester tester) async {
  final rig = await FuzzRig.start(tester, phone: false);
  await key(tester, LogicalKeyboardKey.keyS);
  expect(rig.tool, CanvasTool.shape, reason: 'baseline: S arms the shape tool');
  return rig;
}

void main() {
  testWidgets('two shapes in a row need no re-arming', (tester) async {
    final rig = await _armShape(tester);
    final centre = rig.boardOnScreen.center;

    await _tapShape(rig, centre + const Offset(-300, 150), 40);
    await waitUntil(tester, () => _shapes(rig).length == 1);
    expect(rig.tool, CanvasTool.shape, reason: 'the first placement left it');

    await _tapShape(rig, centre + const Offset(300, 150), 41);
    await waitUntil(tester, () => _shapes(rig).length == 2);

    expect(rig.tool, CanvasTool.shape);
  });

  testWidgets('the shape just placed is selected', (tester) async {
    final rig = await _armShape(tester);

    await _tapShape(rig, rig.boardOnScreen.center + const Offset(0, 150), 40);
    await waitUntil(tester, () => rig.document.selectedObjectId.value != null);

    final id = rig.document.selectedObjectId.value;
    expect(id, _shapes(rig).single['id']);
  });

  testWidgets('a drag from the new shape handle resizes it, not draws', (
    tester,
  ) async {
    final rig = await _armShape(tester);
    await _tapShape(rig, rig.boardOnScreen.center + const Offset(0, 150), 40);
    await waitUntil(tester, () => rig.document.selectedObjectId.value != null);
    final id = rig.document.selectedObjectId.value!;
    final before = rig.document.objectBounds(id)!;
    final handle = rig.toScreen(
      Offset(before.x + before.w, before.y + before.h),
    );

    final pointer = await down(
      tester,
      handle,
      kind: PointerDeviceKind.mouse,
      id: 41,
    );
    await move(tester, pointer, handle + const Offset(30, 20));
    await move(tester, pointer, handle + const Offset(60, 40));
    await lift(tester, pointer);
    await waitUntil(
      tester,
      () => rig.fixture.postedOps.any((o) => o['kind'] == 'move'),
    );

    final after = rig.document.objectBounds(id)!;
    expect(after.w, greaterThan(before.w), reason: 'the shape did not grow');
    expect(_shapes(rig), hasLength(1), reason: 'the drag drew a second shape');
    expect(rig.tool, CanvasTool.shape);
  });

  testWidgets('Escape puts the tool down to Pan', (tester) async {
    final rig = await _armShape(tester);
    await _tapShape(rig, rig.boardOnScreen.center + const Offset(0, 150), 40);
    await waitUntil(tester, () => rig.document.selectedObjectId.value != null);

    await key(tester, LogicalKeyboardKey.escape);

    expect(rig.tool, CanvasTool.pan);
  });
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Helpers the hand-written gesture replays share: where a seeded object is on
/// screen, raw pointer steps, and what the pane sent to the fake server.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_gesture_fuzz_rig.dart';

Offset centerOf(FuzzRig rig, String id) {
  final b = rig.document.objectBounds(id)!;
  return rig.toScreen(Offset(b.x + b.w / 2, b.y + b.h / 2));
}

/// A vertex of a seeded stroke, which the bounding box centre is not.
Offset onStroke(FuzzRig rig, String id) => rig.toScreen(switch (id) {
  's1' => const Offset(350, 290),
  _ => const Offset(800, 750),
});

Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

Future<TestPointer> down(
  WidgetTester tester,
  Offset at, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
  int buttons = kPrimaryButton,
  int id = 7,
}) async {
  final pointer = TestPointer(
    id,
    kind,
    kind == PointerDeviceKind.mouse ? 1 : 0,
    buttons,
  );
  await tester.sendEventToBinding(pointer.down(at));
  await tester.pump(const Duration(milliseconds: 16));
  return pointer;
}

Future<void> move(WidgetTester tester, TestPointer pointer, Offset to) async {
  await tester.sendEventToBinding(pointer.move(to));
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> lift(WidgetTester tester, TestPointer pointer) async {
  await tester.sendEventToBinding(pointer.up());
  await settle(tester);
}

bool draftsEmpty(FuzzRig rig) {
  for (final painter in rig.surfacePainters()) {
    final name = painter.runtimeType.toString();
    if (name == 'DraftPainter' &&
        !((painter as dynamic).draft.isEmpty as bool)) {
      return false;
    }
    if (name == 'DraftShapePainter' &&
        (painter as dynamic).draft.rect != null) {
      return false;
    }
  }
  return true;
}

List<String> removedIds(FuzzRig rig) => [
  for (final op in rig.fixture.postedOps)
    if (op['kind'] == 'remove') ...(op['object_ids'] as List).cast<String>(),
];

List<String> movedIds(FuzzRig rig) => [
  for (final op in rig.fixture.postedOps)
    if (op['kind'] == 'move') op['object_id'] as String,
];

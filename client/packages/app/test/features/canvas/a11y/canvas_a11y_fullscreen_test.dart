// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fullscreen canvas from the keyboard: the call controls stay reachable from a fresh fullscreen to Mute, Leave call and back out.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';

import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

Future<A11yRig> _fullscreen(
  WidgetTester tester, {
  Size size = desktopSize,
}) async {
  final rig = await pumpA11yCanvas(tester, size: size);
  rig.container.read(canvasFullscreenProvider.notifier).state = 'c1';
  await settle(tester);
  return rig;
}

void main() {
  a11yTest('a folded dock keeps its controls out of the tree and focus order', (
    tester,
  ) async {
    await _fullscreen(tester);

    expect(rowsNamed(tester, 'Mute'), isEmpty);
    expect(rowsNamed(tester, 'Leave call'), isEmpty);
    expect(rowsNamed(tester, 'Show controls'), hasLength(1));
    final names = await tabThrough(tester, 40);
    expect(names.where((n) => n.startsWith('Mute')), isEmpty);
  });

  a11yTest('the handle that brings the dock back is within a few Tab presses', (
    tester,
  ) async {
    await _fullscreen(tester);
    final names = await tabThrough(tester, 40);

    final handle = names.indexWhere((n) => n.startsWith('Show controls'));
    expect(
      handle,
      inInclusiveRange(0, 5),
      reason:
          'the handle is Tab stop ${handle + 1}, after every call tile '
          'control and the follow panel',
    );
  });

  a11yTest(
    'Enter on the handle opens the dock, and Mute and Leave call are reachable from it',
    (tester) async {
      await _fullscreen(tester);
      expect(await tabTo(tester, 'Show controls'), isTrue);

      await pressKey(tester, LogicalKeyboardKey.enter);
      await settle(tester);

      expect(focusedName(tester), 'Hide controls');
      expect(await tabTo(tester, 'Mute', limit: 12), isTrue);
      expect(await tabTo(tester, 'Leave call', limit: 12), isTrue);
    },
  );

  a11yTest('Escape in the revealed dock leaves fullscreen', (tester) async {
    final rig = await _fullscreen(tester);
    expect(await tabTo(tester, 'Show controls'), isTrue);
    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);
    expect(await tabTo(tester, 'Mute', limit: 12), isTrue);

    await pressKey(tester, LogicalKeyboardKey.escape);
    await settle(tester);

    expect(rig.container.read(canvasFullscreenProvider), isNull);
    expect(rowsNamed(tester, 'Mute'), isNotEmpty);
  });

  a11yTest('Hide controls folds the dock and keeps focus on the handle', (
    tester,
  ) async {
    await _fullscreen(tester);
    expect(await tabTo(tester, 'Show controls'), isTrue);
    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);

    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);

    expect(focusedName(tester), 'Show controls');
    expect(rowsNamed(tester, 'Mute'), isEmpty);
  });
}

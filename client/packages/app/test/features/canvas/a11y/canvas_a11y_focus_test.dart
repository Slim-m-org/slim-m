// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keyboard focus must be visible on every control: tab through the pane and compare pixels under the focused control with focus moved away.
/// Call tile controls are left out since they are hidden until focused.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show FocusManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';

import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

const _tileControls = [
  'Show this tile',
  'Lock this tile',
  'Unlock this tile',
  'Send this tile',
  'Bring this tile',
  'Hide this tile',
];

/// Whether the control holding focus looks different from the same control without it.
Future<bool> _focusShows(A11yRig rig) async {
  final node = FocusManager.instance.primaryFocus!;
  final rect = focusedRect()!.inflate(3);
  final focused = await pixelsOf(rig, rect);
  node.unfocus();
  await rig.tester.pump(const Duration(milliseconds: 200));
  final blurred = await pixelsOf(rig, rect);
  node.requestFocus();
  await rig.tester.pump(const Duration(milliseconds: 200));
  return pixelsDiffer(focused, blurred);
}

/// The names of the stops in [presses] Tab presses that draw no focus ring.
Future<Set<String>> _stopsWithoutRing(A11yRig rig, int presses) async {
  final window = rig.tester.view.physicalSize;
  final bare = <String>{};
  for (var i = 0; i < presses; i++) {
    await pressKey(rig.tester, LogicalKeyboardKey.tab);
    final rect = focusedRect();
    final name = focusedName(rig.tester);
    if (rect == null || _tileControls.any(name.startsWith)) continue;
    if (rect.width * rect.height > window.width * window.height / 2) continue;
    if (!await _focusShows(rig)) {
      bare.add('$name (${rect.width.round()}x${rect.height.round()})');
    }
  }
  return bare;
}

void main() {
  final scenes = {
    'desktop dark': (desktopSize, Brightness.dark),
    'phone dark': (phoneSize, Brightness.dark),
    'phone light': (phoneSize, Brightness.light),
  };
  for (final scene in scenes.entries) {
    a11yTest('${scene.key}: every Tab stop in the pane draws a focus ring', (
      tester,
    ) async {
      final rig = await pumpA11yCanvas(
        tester,
        size: scene.value.$1,
        brightness: scene.value.$2,
        objects: [
          canvasObjectJson('s1'),
          canvasNoteJson('n1', x: 100),
          // Past the board edge (2880), so the outside-the-board pill is on screen.
          canvasObjectJson('far', x: 3000, seq: 3),
        ],
      );

      final bare = await _stopsWithoutRing(rig, 40);

      expect(
        bare,
        isEmpty,
        reason: 'no visible change when these hold keyboard focus',
      );
    });
  }

  a11yTest('the pen options swatches draw a focus ring', (tester) async {
    final rig = await pumpA11yCanvas(tester);
    await pressKey(tester, LogicalKeyboardKey.keyP);
    expect(await tabTo(tester, 'Pen options'), isTrue);
    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);

    for (final swatch in ['Coral', 'Amber', 'Thin']) {
      expect(await tabTo(tester, swatch), isTrue, reason: swatch);
      expect(await _focusShows(rig), isTrue, reason: swatch);
    }
  });

  a11yTest('the overflow menu items draw a focus ring', (tester) async {
    final rig = await pumpA11yCanvas(tester);
    await openOverflowByKeyboard(tester);
    await pressKey(tester, LogicalKeyboardKey.arrowDown);

    for (final item in ['Paste image', 'Enter fullscreen', 'Participants']) {
      expect(await arrowTo(tester, item), isTrue, reason: item);
      expect(await _focusShows(rig), isTrue, reason: item);
    }
  });

  a11yTest('the fullscreen handle and the revealed dock draw a focus ring', (
    tester,
  ) async {
    final rig = await pumpA11yCanvas(tester);
    rig.container.read(canvasFullscreenProvider.notifier).state = 'c1';
    await settle(tester);
    expect(await tabTo(tester, 'Show controls'), isTrue);
    expect(await _focusShows(rig), isTrue, reason: 'Show controls');

    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);
    expect(await tabTo(tester, 'Mute'), isTrue);
    expect(await _focusShows(rig), isTrue, reason: 'Mute');
  });

  a11yTest('an icon-only control shows its name when it takes keyboard focus', (
    tester,
  ) async {
    await pumpA11yCanvas(tester);
    final nameless = <String>[];
    final cases = {
      'Pan': 'Pan (H)',
      'Eraser': 'Eraser (E)',
      'Mute': 'Mute (Ctrl+Shift+M)',
      'Close canvas': 'Close canvas',
    };
    for (final control in cases.entries) {
      expect(await tabTo(tester, control.key), isTrue, reason: control.key);
      await tester.pump(const Duration(milliseconds: 1500));
      if (find.textContaining(control.value).evaluate().isEmpty) {
        nameless.add(control.key);
      }
    }

    expect(
      nameless,
      isEmpty,
      reason:
          'the tooltip appears on hover but not on keyboard focus, so a '
          'sighted keyboard user meets a ring around an unnamed icon',
    );
  });
}

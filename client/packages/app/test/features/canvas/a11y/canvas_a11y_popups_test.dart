// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Accessibility probe: Escape, focus and modality for everything that pops up
/// from the canvas dock (the overflow menu, the pen options, and the sheets and
/// confirmation the overflow menu opens), driven from the keyboard.
///
/// The pane binds Escape for the docked member pane and for fullscreen with a
/// `CallbackShortcuts` that sits above every popup, so a test that only opens
/// the menu in a row-sized harness (as `canvas_tools_row_accessibility_test`
/// does) never meets it.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

bool _overflowOpen() => find.text('Paste image').evaluate().isNotEmpty;

void main() {
  group('Escape closes the popup that is open', () {
    a11yTest('the overflow menu closes on Escape beside a docked member pane', (
      tester,
    ) async {
      await pumpA11yCanvas(tester);
      await openOverflowByKeyboard(tester);
      expect(_overflowOpen(), isTrue);

      await pressKey(tester, LogicalKeyboardKey.escape);
      await settle(tester);

      expect(
        _overflowOpen(),
        isFalse,
        reason:
            'Escape went to the pane-level member-pane binding, so a keyboard '
            'user cannot leave the menu: Tab only cycles inside it',
      );
    });

    a11yTest('Escape in the overflow menu leaves the member pane alone', (
      tester,
    ) async {
      final rig = await pumpA11yCanvas(tester);
      await openOverflowByKeyboard(tester);

      await pressKey(tester, LogicalKeyboardKey.escape);
      await settle(tester);

      expect(
        rig.memberPaneVisible,
        isTrue,
        reason: 'Escape meant for the menu closed the member pane instead',
      );
    });

    a11yTest('the overflow menu closes on Escape at phone width', (
      tester,
    ) async {
      await pumpA11yCanvas(tester, size: phoneSize);
      await openOverflowByKeyboard(tester);
      expect(_overflowOpen(), isTrue);

      await pressKey(tester, LogicalKeyboardKey.escape);
      await settle(tester);

      expect(_overflowOpen(), isFalse);
    });

    a11yTest(
      'in fullscreen Escape closes the menu before it leaves fullscreen',
      (tester) async {
        final rig = await pumpA11yCanvas(tester);
        await runOverflowItem(tester, 'Enter fullscreen');
        expect(rig.container.read(canvasFullscreenProvider), 'c1');
        await openOverflowByKeyboard(tester);
        expect(_overflowOpen(), isTrue);

        await pressKey(tester, LogicalKeyboardKey.escape);
        await settle(tester);

        expect(
          rig.container.read(canvasFullscreenProvider),
          'c1',
          reason: 'Escape meant for the open menu exited fullscreen',
        );
        expect(_overflowOpen(), isFalse);
      },
    );

    a11yTest('the pen options close on Escape beside a docked member pane', (
      tester,
    ) async {
      final rig = await pumpA11yCanvas(tester);
      await pressKey(tester, LogicalKeyboardKey.keyP);
      expect(await tabTo(tester, 'Pen options'), isTrue);
      await pressKey(tester, LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.bySemanticsLabel('Coral'), findsOneWidget);

      await pressKey(tester, LogicalKeyboardKey.escape);
      await settle(tester);

      expect(find.bySemanticsLabel('Coral'), findsNothing);
      expect(rig.memberPaneVisible, isTrue);
    });
  });

  group('a modal opened from the overflow menu owns the keyboard', () {
    a11yTest('the Participants sheet takes keyboard focus', (tester) async {
      await pumpA11yCanvas(tester);
      await runOverflowItem(tester, 'Participants');
      expect(find.text('In this call'), findsOneWidget);

      expect(
        focusIsInTopRoute(),
        isTrue,
        reason:
            'focus is on "${focusedName(tester)}" behind the sheet, so the '
            'next Tab walks the dock under the barrier',
      );
    });

    a11yTest('the Participants sheet takes keyboard focus at phone width', (
      tester,
    ) async {
      await pumpA11yCanvas(tester, size: phoneSize);
      await runOverflowItem(tester, 'Participants');
      expect(find.text('In this call'), findsOneWidget);

      expect(focusIsInTopRoute(), isTrue, reason: focusedName(tester));
    });

    a11yTest('the clear confirmation takes keyboard focus', (tester) async {
      await pumpA11yCanvas(tester, objects: [canvasObjectJson('s1')]);
      await runOverflowItem(tester, 'Clear canvas');
      expect(find.text('Clear this canvas?'), findsOneWidget);

      expect(
        focusIsInTopRoute(),
        isTrue,
        reason:
            'focus is on "${focusedName(tester)}" behind a destructive '
            'confirmation',
      );
    });

    a11yTest('canvas hotkeys do nothing while a sheet is open', (tester) async {
      await pumpA11yCanvas(tester);
      await runOverflowItem(tester, 'Participants');
      final before = currentTool(tester);

      await pressKey(tester, LogicalKeyboardKey.keyE);

      expect(
        currentTool(tester),
        before,
        reason: 'E armed the eraser on the canvas behind the open sheet',
      );
    });

    a11yTest('Ctrl+Z does not undo a stroke behind an open sheet', (
      tester,
    ) async {
      final rig = await pumpA11yCanvas(tester);
      useFreeCamera(tester);
      await pressKey(tester, LogicalKeyboardKey.keyP);
      await tester.dragFrom(
        screenFor(tester, const Offset(100, 100)),
        const Offset(80, 30),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(surfaceDocument(tester).objectCount.value, 1);
      await runOverflowItem(tester, 'Participants');

      await pressKey(tester, LogicalKeyboardKey.keyZ, control: true);
      await settle(tester);

      expect(
        rig.fixture.postedOps,
        isEmpty,
        reason: 'the stroke was undone through the modal sheet',
      );
    });

    a11yTest(
      'Escape closes the sheet and focus returns to the overflow button',
      (tester) async {
        await pumpA11yCanvas(tester);
        await runOverflowItem(tester, 'Participants');
        await pressKey(tester, LogicalKeyboardKey.escape);
        await settle(tester);

        expect(
          find.text('In this call'),
          findsNothing,
          reason: 'sheet still open',
        );
        expect(
          focusedName(tester),
          contains('More canvas actions'),
          reason: 'focus was not handed back to the control that opened it',
        );
      },
    );
  });

  for (final entry in {'desktop': desktopSize, 'phone': phoneSize}.entries) {
    a11yTest('the shape options close on Escape at ${entry.key} width', (
      tester,
    ) async {
      final rig = await pumpA11yCanvas(tester, size: entry.value);
      await pressKey(tester, LogicalKeyboardKey.keyS);
      expect(currentTool(tester), CanvasTool.shape);
      expect(await tabTo(tester, 'Shape options'), isTrue);
      await pressKey(tester, LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.text('Ellipse'), findsOneWidget);

      await pressKey(tester, LogicalKeyboardKey.escape);
      await settle(tester);

      expect(find.text('Ellipse'), findsNothing);
      expect(rig.memberPaneVisible, isTrue);
    });
  }
}

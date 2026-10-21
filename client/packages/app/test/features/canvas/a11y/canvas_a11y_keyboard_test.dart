// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Accessibility probe: can the canvas and its dock be used with a keyboard alone?
///
/// Tab order and stops, Enter and Space on the tools, undo and redo from the
/// keyboard, and the part a keyboard cannot do at all today: put anything on
/// the board, select it, or move the camera.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

Future<List<({String name, Rect? rect})>> _cycle(
  WidgetTester tester,
  int presses,
) async {
  final stops = <({String name, Rect? rect})>[];
  for (var i = 0; i < presses; i++) {
    await pressKey(tester, LogicalKeyboardKey.tab);
    stops.add((name: focusedName(tester), rect: focusedRect()));
  }
  return stops;
}

void main() {
  group('Tab order', () {
    a11yTest('the tool strip is within a few Tab presses of the pane', (
      tester,
    ) async {
      await pumpA11yCanvas(tester);
      final names = [for (final s in await _cycle(tester, 40)) s.name];

      final pan = names.indexWhere((n) => n.startsWith('Pan'));
      expect(
        pan,
        inInclusiveRange(0, 5),
        reason:
            'Pan is Tab stop ${pan + 1}; the stops before it are the hidden '
            'controls of every call tile:\n${names.take(pan + 1).join('\n')}',
      );
    });

    a11yTest('Mute and Leave call are within a dozen Tab presses', (
      tester,
    ) async {
      await pumpA11yCanvas(tester);
      final names = [for (final s in await _cycle(tester, 40)) s.name];

      final mute = names.indexWhere((n) => n.startsWith('Mute'));
      final leave = names.indexWhere((n) => n.startsWith('Leave call'));
      expect(mute, inInclusiveRange(0, 11), reason: 'Mute is stop ${mute + 1}');
      expect(
        leave,
        inInclusiveRange(0, 15),
        reason: 'Leave call is stop ${leave + 1}',
      );
    });

    a11yTest('no Tab stop is the whole pane', (tester) async {
      await pumpA11yCanvas(tester);
      final window = tester.view.physicalSize;
      final stops = await _cycle(tester, 40);

      // The board is a named stop with its own ring (C-091); an unnamed one this size is the old phantom.
      final phantom = [
        for (final s in stops)
          if (s.rect != null &&
              !s.name.startsWith('Canvas board') &&
              s.rect!.width * s.rect!.height > window.width * window.height / 2)
            s.name,
      ];
      expect(
        phantom,
        isEmpty,
        reason:
            'the pane root takes a Tab stop with no ring and no name of its '
            'own, once per cycle',
      );
    });
  });

  group('operating the controls', () {
    a11yTest('Enter and Space arm every tool', (tester) async {
      await pumpA11yCanvas(tester);
      final cases = <(String, LogicalKeyboardKey, CanvasTool)>[
        ('Eraser', LogicalKeyboardKey.enter, CanvasTool.eraser),
        ('Note', LogicalKeyboardKey.space, CanvasTool.note),
        ('Pen', LogicalKeyboardKey.space, CanvasTool.pen),
        ('Shape', LogicalKeyboardKey.enter, CanvasTool.shape),
        ('Pan', LogicalKeyboardKey.enter, CanvasTool.pan),
      ];
      for (final (name, key, tool) in cases) {
        expect(await tabTo(tester, name), isTrue, reason: name);
        await pressKey(tester, key);
        expect(currentTool(tester), tool, reason: '$name via ${key.keyLabel}');
      }
    });

    a11yTest('the tool hotkeys arm their tools', (tester) async {
      await pumpA11yCanvas(tester);
      final cases = <(LogicalKeyboardKey, CanvasTool)>[
        (LogicalKeyboardKey.keyE, CanvasTool.eraser),
        (LogicalKeyboardKey.keyN, CanvasTool.note),
        (LogicalKeyboardKey.keyP, CanvasTool.pen),
        (LogicalKeyboardKey.keyS, CanvasTool.shape),
        (LogicalKeyboardKey.keyH, CanvasTool.pan),
      ];
      for (final (key, tool) in cases) {
        await pressKey(tester, key);
        expect(currentTool(tester), tool, reason: key.keyLabel);
      }
    });

    a11yTest('undo and redo run from the keyboard', (tester) async {
      final rig = await pumpA11yCanvas(tester);
      useFreeCamera(tester);
      await pressKey(tester, LogicalKeyboardKey.keyP);
      await tester.dragFrom(
        screenFor(tester, const Offset(100, 100)),
        const Offset(80, 30),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(surfaceDocument(tester).objectCount.value, 1);

      expect(await tabTo(tester, 'Undo'), isTrue);
      await pressKey(tester, LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 300));
      expect(surfaceDocument(tester).objectCount.value, 0);

      expect(await tabTo(tester, 'Redo'), isTrue);
      await pressKey(tester, LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        [for (final op in rig.fixture.postedOps) op['kind']],
        ['remove', 'restore'],
      );
    });

    a11yTest('the call controls answer to Enter', (tester) async {
      await pumpA11yCanvas(tester);
      expect(await tabTo(tester, 'Mute'), isTrue);
      await pressKey(tester, LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 100));
      expect(rowsNamed(tester, 'Unmute'), isNotEmpty);
    });

    a11yTest('the tool hotkeys are named where a keyboard user looks', (
      tester,
    ) async {
      await pumpA11yCanvas(tester);
      final keys = {
        'Pan': 'H',
        'Pen': 'P',
        'Note': 'N',
        'Shape': 'S',
        'Eraser': 'E',
      };
      final unnamed = <String>[];
      for (final tool in keys.entries) {
        final row = rowsNamed(tester, tool.key).first;
        final text = '${row.accessibleName} ${row.hint}';
        final mentionsKey = RegExp(
          '(^|[^A-Za-z])${tool.value}([^A-Za-z]|\$)',
        ).hasMatch(text);
        if (!mentionsKey) unnamed.add('${tool.key} (${tool.value})');
      }
      expect(
        unnamed,
        isEmpty,
        reason:
            'Mute, Leave and Camera put their shortcut in the name; the tool '
            'keys are bound but never shown or announced',
      );
    });
  });

  group('the board itself', () {
    a11yTest('a keyboard can place a note', (tester) async {
      final rig = await pumpA11yCanvas(tester);
      await pressKey(tester, LogicalKeyboardKey.keyN);
      expect(currentTool(tester), CanvasTool.note);

      await pressKey(tester, LogicalKeyboardKey.enter);
      await pressKey(tester, LogicalKeyboardKey.space);
      await settle(tester);

      expect(
        find.text('Add a note').evaluate().isNotEmpty ||
            rig.fixture.posted.isNotEmpty,
        isTrue,
        reason: 'with the note tool armed no key opens the note sheet',
      );
    });

    a11yTest('a keyboard can select an object on the board', (tester) async {
      await pumpA11yCanvas(
        tester,
        objects: [canvasNoteJson('n1', x: 100, text: 'hello world')],
      );
      // The board holds focus; ] steps the selection through what is in view (C-091).
      expect(focusedName(tester), startsWith('Canvas board'));
      await pressKey(tester, LogicalKeyboardKey.bracketRight);

      expect(surfaceDocument(tester).selectedObjectId.value, 'n1');
      expect(find.bySemanticsLabel(RegExp('hello world')), findsWidgets);
    });

    a11yTest('a keyboard can pan and zoom the board', (tester) async {
      await pumpA11yCanvas(tester);
      final document = surfaceDocument(tester);
      final before = (
        document.camera.x,
        document.camera.y,
        document.camera.zoom,
      );

      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.equal,
        LogicalKeyboardKey.minus,
      ]) {
        await pressKey(tester, key);
      }

      expect(
        (document.camera.x, document.camera.y, document.camera.zoom),
        isNot(before),
        reason: 'no key moves the camera; only Fit view is reachable',
      );
    });
  });
}

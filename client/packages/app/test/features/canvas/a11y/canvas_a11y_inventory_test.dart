// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a screen reader meets on the canvas pane: the live semantics tree listed per control, asserting names that merge into the wrong node, dropped nodes and content with no node.
/// `A11Y_DUMP_DIR` keeps the listings.
library;

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';

import '../../../support/semantics_audit.dart';
import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

const _tools = ['Pan', 'Pen', 'Note', 'Shape', 'Eraser'];

bool _isTile(SemRow row) => row.label.contains("on this call's canvas");

void main() {
  for (final entry in {'desktop': desktopSize, 'phone': phoneSize}.entries) {
    group('${entry.key} inventory', () {
      a11yTest('every control has a name', (tester) async {
        await pumpA11yCanvas(
          tester,
          size: entry.value,
          objects: [
            canvasObjectJson('s1'),
            canvasNoteJson('n1', seq: 2, x: 100, text: 'hello world'),
          ],
        );
        // The pen arms its options caret, which wraps the button in a group.
        await pressKey(tester, LogicalKeyboardKey.keyP);
        final dump = dumpSemantics(tester, '${entry.key}-pane');
        final unnamed = [
          for (final row in semanticsRows(tester, onlyControls: true))
            if (row.accessibleName.isEmpty) row.describe(),
        ];
        expect(unnamed, isEmpty, reason: dump);
      });

      a11yTest('the dock controls have distinct names', (tester) async {
        await pumpA11yCanvas(tester, size: entry.value);
        // The dock's own top, not a fixed band: the roster row makes a phone dock taller than 160.
        final dockTop = find
            .byType(FloatingDockCard)
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)).top)
            .reduce((a, b) => a < b ? a : b);
        final names = [
          for (final row in semanticsRows(tester, onlyControls: true))
            if (row.rect.top >= dockTop - 1) row.name,
        ];
        expect(names.toSet().length, names.length, reason: names.join('\n'));
        expect(names, containsAll(['Pan', 'Pen', 'Note', 'Shape', 'Eraser']));
      });

      a11yTest('every painted text and enabled button has a semantics node', (
        tester,
      ) async {
        await pumpA11yCanvas(tester, size: entry.value);
        expect(semanticsProblems(tester), isEmpty);
      });
    });
  }

  group('roles and state', () {
    a11yTest('exactly one tool is announced as on, and it follows the hotkey', (
      tester,
    ) async {
      await pumpA11yCanvas(tester);
      int on() => [
        for (final tool in _tools)
          if (rowsNamed(tester, tool).first.isOn) tool,
      ].length;

      expect(on(), 1);
      await pressKey(tester, LogicalKeyboardKey.keyE);
      expect(rowsNamed(tester, 'Eraser').first.isOn, isTrue);
      expect(on(), 1);
    });

    a11yTest('the board label is only the board', (tester) async {
      await pumpA11yCanvas(
        tester,
        objects: [canvasNoteJson('n1', text: 'hello world')],
      );
      final board = semanticsRows(
        tester,
      ).firstWhere((r) => r.label.startsWith('Canvas, '));
      final others = [
        for (final row in semanticsRows(tester, onlyControls: true))
          if (row.name.length > 3 && !identical(row, board)) row.name,
      ];

      expect(
        board.label,
        matches(RegExp(r'^Canvas, \d+ objects?: |^Canvas, no')),
      );
      expect(others.where(board.label.contains), isEmpty);
      expect(board.taps, isFalse);
      expect(board.flags.isButton, isFalse);
    });

    a11yTest('More canvas actions announces whether its menu is open', (
      tester,
    ) async {
      await pumpA11yCanvas(tester);
      await openOverflowByKeyboard(tester);

      final trigger = rowsNamed(tester, 'More canvas actions');
      expect(trigger, isNotEmpty);
      expect(
        trigger.first.flags.isExpanded,
        ui.Tristate.isTrue,
        reason: 'the menu button never says expanded or collapsed',
      );
    });
  });

  group('call tiles', () {
    a11yTest('a tile node does not swallow its own control', (tester) async {
      await pumpA11yCanvas(tester);
      final merged = [
        for (final row in semanticsRows(tester).where(_isTile))
          if (row.label.contains('Hide this tile') || row.flags.isButton)
            row.describe(),
      ];
      expect(
        merged,
        isEmpty,
        reason:
            'a camera-off tile has one control, and one compatible child '
            'merges into its parent: the node reads as a button named after '
            'both',
      );
    });

    a11yTest('every tile keeps Hide as a node of its own', (tester) async {
      await pumpA11yCanvas(tester);
      final tiles = semanticsRows(tester).where(_isTile).length;
      final hides = rowsNamed(tester, 'Hide this tile').length;
      expect(hides, tiles, reason: '$tiles tiles but $hides Hide controls');
    });

    // Camera-off people have no tile any more (decision 0086); a share tile has the same Hide.
    a11yTest('activating the Hide control of a tile hides it', (tester) async {
      await pumpA11yCanvas(tester);
      final hides = semanticsRows(
        tester,
      ).where((r) => r.label.contains('Hide this tile'));
      final hideCount = hides.length;
      final hide = hides.first;

      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
        hide.node.id,
        SemanticsAction.tap,
      );
      await settle(tester);

      expect(
        semanticsRows(tester).where((r) => r.label.contains('Hide this tile')),
        hasLength(lessThan(hideCount)),
        reason:
            'the node is announced as a Hide button and the tap does nothing',
      );
    });

    a11yTest('a muted participant is announced as muted on their tile', (
      tester,
    ) async {
      await pumpA11yCanvas(tester);
      // Mute state is told in the call list the corner cluster opens (decision 0086).
      await tester.tap(find.byTooltip('People in this call'));
      await tester.pump(const Duration(milliseconds: 400));
      final sam = semanticsRows(tester).where((r) => r.label.startsWith('Sam'));

      expect(
        sam.any((r) => r.label.toLowerCase().contains('muted')),
        isTrue,
        reason:
            'the mute badge and the speaking ring are drawn, never labelled: '
            '${sam.map((r) => r.label).join(' / ')}',
      );
    });

    a11yTest('a tile does not advertise a tap it ignores', (tester) async {
      await pumpA11yCanvas(tester);
      final tapping = [
        for (final row in semanticsRows(tester).where(_isTile))
          if (row.taps && !row.flags.isButton) row.name,
      ];
      expect(
        tapping,
        isEmpty,
        reason:
            'the tile gesture only listens for a secondary tap, which a '
            'semantic tap never sends',
      );
    });
  });

  group('board content', () {
    a11yTest('a selected note is announced with its text', (tester) async {
      await pumpA11yCanvas(
        tester,
        call: false,
        objects: [canvasNoteJson('n1', x: 400, text: 'hello world')],
      );
      useFreeCamera(tester);
      await tester.pump();
      await tester.tapAt(
        screenFor(tester, const Offset(410, 20)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(surfaceDocument(tester).selectedObjectId.value, 'n1');

      expect(
        semanticsText(tester),
        contains('Selected note: hello world'),
        reason:
            'the selection node is a zero-size box, so Flutter drops it from '
            'the tree; its text and its object-actions route never reach a '
            'screen reader',
      );
    });

    a11yTest('notes already on the board can be read by a screen reader', (
      tester,
    ) async {
      await pumpA11yCanvas(
        tester,
        call: false,
        objects: [canvasNoteJson('n1', x: 100, text: 'hello world')],
      );

      expect(
        semanticsText(tester),
        contains('hello world'),
        reason: 'the board exposes only counts, never a note\'s text',
      );
    });

    a11yTest('a screen reader is offered a way to add something', (
      tester,
    ) async {
      await pumpA11yCanvas(tester);
      final board = semanticsRows(
        tester,
      ).firstWhere((r) => r.label.startsWith('Canvas, '));

      expect(
        board.data.customSemanticsActionIds,
        isNotEmpty,
        reason: 'the board node carries no action at all: ${board.describe()}',
      );
    });
  });

  group('the in-place note editor', () {
    a11yTest('the text field has a name and nothing unlabeled covers the board', (
      tester,
    ) async {
      await pumpA11yCanvas(
        tester,
        call: false,
        objects: [canvasNoteJson('n1', x: 400, text: 'hello world')],
      );
      useFreeCamera(tester);
      await tester.pump();
      // A finger's first tap selects the note; a tap on the selected note opens its editor.
      await tester.tapAt(screenFor(tester, const Offset(410, 20)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(screenFor(tester, const Offset(410, 20)));
      await tester.pump(const Duration(milliseconds: 100));
      final rows = semanticsRows(tester);
      final field = rows.where((r) => r.flags.isTextField);
      expect(
        field,
        isNotEmpty,
        reason: 'a touch tap on a note opens its editor',
      );

      final unnamedField = [
        for (final row in field)
          if (row.label.isEmpty && row.hint.isEmpty) row.describe(),
      ];
      final blankCover = [
        for (final row in rows)
          if (row.taps &&
              row.accessibleName.isEmpty &&
              row.rect.width * row.rect.height > 200 * 200)
            row.describe(),
      ];
      expect([...unnamedField, ...blankCover], isEmpty);
    });
  });

  group('sheets and dialogs', () {
    a11yTest('the Participants sheet says who is muted', (tester) async {
      await pumpA11yCanvas(tester);
      await runOverflowItem(tester, 'Participants');

      final sam = rowsNamed(tester, 'Sam');
      expect(sam, isNotEmpty);
      expect(
        sam.first.label.toLowerCase(),
        contains('muted'),
        reason:
            'the row shows a mic-off icon with no label: ${sam.first.label}',
      );
    });

    for (final entry in {'desktop': desktopSize, 'phone': phoneSize}.entries) {
      a11yTest('the Participants sheet names itself on ${entry.key}', (
        tester,
      ) async {
        await pumpA11yCanvas(tester, size: entry.value);
        await runOverflowItem(tester, 'Participants');
        final dump = dumpSemantics(tester, '${entry.key}-participants-sheet');
        final rows = semanticsRows(tester);

        expect(
          rows.where((r) => r.flags.isHeader && r.label == 'In this call'),
          isNotEmpty,
          reason:
              'the title is plain text and the route is named '
              '"${rows.where((r) => r.flags.namesRoute).map((r) => r.label)}"'
              '\n$dump',
        );
      });
    }
  });
}

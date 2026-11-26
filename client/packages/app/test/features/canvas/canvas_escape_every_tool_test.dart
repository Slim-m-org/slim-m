// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One Escape puts every armed tool down to Pan; ending a note or text edit counts as that press.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_edge_style.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_text_focus.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tool_model.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_gesture_fuzz_rig.dart';
import 'canvas_gesture_repro_support.dart';

void main() {
  _buttons();
  _clickOutOnEmptyDraft();
  for (final tool in [
    CanvasTool.pen,
    CanvasTool.eraser,
    CanvasTool.shape,
    CanvasTool.note,
    CanvasTool.text,
    CanvasTool.stamp,
    CanvasTool.connect,
  ]) {
    testWidgets('one Escape puts ${tool.name} down to Pan', (tester) async {
      final rig = await FuzzRig.start(
        tester,
        phone: false,
        overrides: [
          canvasEdgesSupportedProvider.overrideWithValue(true),
          canvasStampsSupportedProvider.overrideWithValue(true),
        ],
      );
      rig.container
          .read(armedStampProvider.notifier)
          .arm(const EmojiStamp('x'));
      await key(tester, tool.shortcutKey);
      expect(rig.tool, tool, reason: 'baseline: the shortcut arms it');

      await key(tester, LogicalKeyboardKey.escape);

      expect(rig.tool, CanvasTool.pan);
    });
  }

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    for (final tool in CanvasTool.values) {
      if (tool == CanvasTool.pan || tool == CanvasTool.note) continue;
      if (tool == CanvasTool.text) continue;
      testWidgets('one Escape after dragging ${tool.name} by ${kind.name}', (
        tester,
      ) async {
        final rig = await _arm(tester, tool);
        final at = rig.boardOnScreen.center + const Offset(0, 250);
        final pointer = await down(tester, at, kind: kind, id: 40);
        await move(tester, pointer, at + const Offset(40, 20));
        await move(tester, pointer, at + const Offset(90, 50));
        await lift(tester, pointer);

        await key(tester, LogicalKeyboardKey.escape);

        expect(rig.tool, CanvasTool.pan);
      });
    }
  }

  for (final tool in [CanvasTool.note, CanvasTool.text]) {
    testWidgets('one Escape ends the ${tool.name} edit and leaves the tool', (
      tester,
    ) async {
      final rig = await _arm(tester, tool);
      final at = rig.boardOnScreen.center + const Offset(0, 250);
      final pointer = await down(
        tester,
        at,
        kind: PointerDeviceKind.mouse,
        id: 40,
      );
      await lift(tester, pointer);
      await tester.pump(const Duration(milliseconds: 300));
      expect(textInputHasFocus(), isTrue, reason: 'baseline: an edit is open');

      await key(tester, LogicalKeyboardKey.escape);

      expect(textInputHasFocus(), isFalse, reason: 'the edit ended');
      expect(rig.tool, CanvasTool.pan);
    });
  }
}

void _buttons() {
  for (final entry in {
    CanvasTool.pen: 'Pen',
    CanvasTool.eraser: 'Eraser',
    CanvasTool.shape: 'Shape',
    CanvasTool.note: 'Note',
    CanvasTool.text: 'Text',
    CanvasTool.stamp: 'Stamp',
    CanvasTool.connect: 'Connect',
  }.entries) {
    testWidgets('one Escape after the ${entry.value} button', (tester) async {
      final rig = await _arm(tester, CanvasTool.pan);
      await tester.tap(
        find
            .ancestor(
              of: find.bySemanticsLabel(entry.value),
              matching: find.byWidgetPredicate((w) => w is AppIconButton),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.tool, entry.key, reason: 'baseline');

      await key(tester, LogicalKeyboardKey.escape);

      expect(rig.tool, CanvasTool.pan);
    });
  }
}

Future<FuzzRig> _arm(WidgetTester tester, CanvasTool tool) async {
  final rig = await FuzzRig.start(
    tester,
    phone: false,
    overrides: [
      canvasEdgesSupportedProvider.overrideWithValue(true),
      canvasStampsSupportedProvider.overrideWithValue(true),
    ],
  );
  rig.container.read(armedStampProvider.notifier).arm(const EmojiStamp('x'));
  await key(tester, tool.shortcutKey);
  return rig;
}

void _clickOutOnEmptyDraft() {
  for (final tool in [CanvasTool.note, CanvasTool.text]) {
    testWidgets('saving an empty ${tool.name} draft keeps the tool armed', (
      tester,
    ) async {
      final rig = await _arm(tester, tool);
      final at = rig.boardOnScreen.center + const Offset(0, 250);
      final pointer = await down(
        tester,
        at,
        kind: PointerDeviceKind.mouse,
        id: 40,
      );
      await lift(tester, pointer);
      await tester.pump(const Duration(milliseconds: 300));
      expect(textInputHasFocus(), isTrue, reason: 'baseline: an edit is open');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await key(tester, LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 300));

      expect(textInputHasFocus(), isFalse, reason: 'the empty draft ended');
      expect(rig.tool, tool);
    });
  }
}

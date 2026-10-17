// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scene is framed around what it drew, not around the canvas it declared.
///
/// word-guess declares 100x100 and draws a 60x88 board, so the old frame spent
/// a third of a card on empty fill. These assert the rendered geometry for the
/// shapes the shipped modules emit, at a desktop card and a phone card.
/// Layout follows window width, never platform (desktop-vs-mobile.md, "The one
/// rule" and law 1); no surface rule applies because a scene is inline content.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_frame.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene_fixtures.dart';

Future<void> _pump(WidgetTester tester, Map<String, Object?> scene, Size card) {
  tester.view.physicalSize = Size(card.width + 32, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: const Key('card'),
            width: card.width,
            child: ModuleSceneView(
              initial: parseModuleScene(jsonEncode(scene))!,
              runCommand: (_) async =>
                  const api.RunModuleCommandResult(ok: true, output: ''),
            ),
          ),
        ),
      ),
    ),
  );
}

Rect _frame(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(ModuleSceneFrame),
        matching: find.byType(Container),
      )
      .first,
);

/// Modules that declare more canvas than they draw on; the rest fill it.
const _cropped = {'word-guess', 'spirograph', 'plot'};

void main() {
  for (final (label, width) in const [('desktop', 760.0), ('phone', 358.0)]) {
    for (final entry in shippedScenes.entries) {
      testWidgets('${entry.key} fits its card at $label width', (tester) async {
        await _pump(tester, entry.value, Size(width, 0));
        final card = tester.getRect(find.byKey(const Key('card')));
        final frame = _frame(tester);
        expect(frame.left, card.left);
        expect(frame.width, lessThanOrEqualTo(card.width));
        expect(
          frame.height,
          lessThanOrEqualTo(ModuleSceneFrame.inlineEdge(width) + 2),
        );
        final scene = parseModuleScene(jsonEncode(entry.value))!;
        expect(
          scene.viewWidth * scene.viewHeight < scene.width * scene.height,
          _cropped.contains(entry.key),
          reason: 'only scenes with slack around their drawing are cropped',
        );
        expect(
          frame.width / frame.height,
          closeTo(scene.viewWidth / scene.viewHeight, 0.08),
          reason: 'the frame follows the content aspect',
        );
      });
    }
  }

  testWidgets('word-guess no longer carries empty canvas around the board', (
    tester,
  ) async {
    final scene = parseModuleScene(jsonEncode(wordGuessScene()))!;
    final crop = scene.crop!;
    // Board spans x 21..81 and y 4..74; the input reserves room under y 80.
    expect(crop.left, inExclusiveRange(15, 21));
    expect(crop.right, inExclusiveRange(81, 87));
    expect(crop.top, inExclusiveRange(0, 4));
    expect(crop.width / 100, lessThan(0.7), reason: 'was the full 100 wide');
    await _pump(tester, wordGuessScene(), const Size(760, 0));
    final frame = _frame(tester);
    expect(frame.width, lessThan(frame.height), reason: 'portrait, not square');
    expect(frame.width, lessThan(360), reason: 'was a 360px square');
    final pad = (21 - crop.left) * frame.width / crop.width;
    expect(pad, inInclusiveRange(2, 18), reason: 'small padding, in pixels');
    // The field must sit wholly inside the frame, not be clipped by the crop.
    expect(
      frame.contains(tester.getBottomRight(find.byType(TextField))),
      isTrue,
    );
  });

  testWidgets('a tap lands on the same op after the crop shifts the origin', (
    tester,
  ) async {
    final scene = sceneOf(100, 100, [
      {
        'op': 'rect',
        'x': 60,
        'y': 60,
        'w': 20,
        'h': 20,
        'fill': 'accent',
        'tap': 'go',
      },
    ]);
    final parsed = parseModuleScene(jsonEncode(scene))!;
    expect(parsed.crop, isNotNull);
    const size = Size(100, 100);
    final sx = size.width / parsed.viewWidth;
    final centre = Offset(
      (70 - parsed.viewLeft) * sx,
      (70 - parsed.viewTop) * (size.height / parsed.viewHeight),
    );
    expect(sceneTapAction(parsed, centre, size), 'go');
    expect(sceneTapAction(parsed, Offset.zero, size), isNull);
  });
}

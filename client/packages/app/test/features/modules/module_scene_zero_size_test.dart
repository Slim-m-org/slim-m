// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scene that declares no area at all still draws as a square card, so it can
/// be tapped; the grid hit test must answer null there rather than divide by
/// the grid's zero width.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

String _grid({required num width, required num height}) => jsonEncode({
  r'$slim': 'scene/1',
  'width': width,
  'height': height,
  'ops': [
    {
      'op': 'cells',
      'cols': 3,
      'rows': 3,
      'data': '0' * 9,
      'palette': ['sunken'],
      'tap': 't',
      'alt': 'a',
    },
  ],
});

void main() {
  group('sceneTapAction on a scene with no area', () {
    for (final (width, height) in [(0, 100), (100, 0), (0, 0)]) {
      test('${width}x$height answers nothing instead of throwing', () {
        final scene = parseModuleScene(_grid(width: width, height: height))!;
        expect(
          sceneTapAction(scene, const Offset(10, 10), const Size(100, 100)),
          isNull,
        );
        expect(
          sceneTapAction(
            scene,
            const Offset(10, 10),
            const Size(100, 100),
            secondary: true,
          ),
          isNull,
        );
      });
    }

    test('a box laid out at zero size answers nothing either', () {
      final scene = parseModuleScene(_grid(width: 100, height: 100))!;
      expect(sceneTapAction(scene, Offset.zero, Size.zero), isNull);
    });
  });

  testWidgets('tapping a zero-width scene is a no-op, not an exception', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ModuleSceneView(
            key: const ValueKey('scene'),
            initial: parseModuleScene(_grid(width: 0, height: 100))!,
            runCommand: (_) async {
              calls++;
              return const api.RunModuleCommandResult(ok: true, output: '');
            },
          ),
        ),
      ),
    );

    // The card is a square on top of its footer, so a point just inside its corner is on the paint.
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const ValueKey('scene'))) +
          const Offset(20, 20),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(calls, 0);
  });
}

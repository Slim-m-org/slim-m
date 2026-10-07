// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A command that throws something that is not an API error must still end
/// the busy state and say so, not leave the board spinning and ignoring taps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/module_scene.dart';
import 'package:slimm_app/src/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _scene =
    '{"\$slim":"scene/1","width":3,"height":3,"ops":[],'
    '"controls":["step"],"state":"s","live":false}';

void main() {
  testWidgets('an unexpected throw clears the spinner and shows an error', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ModuleSceneView(
            initial: parseModuleScene(_scene)!,
            runCommand: (_) async {
              calls++;
              throw StateError('the widget was disposed');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Step forward'));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.bySemanticsLabel('Step forward'));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2, reason: 'the board is not stuck busy');
  });
}

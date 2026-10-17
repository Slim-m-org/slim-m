// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Play against a server that keeps refusing for rate: the timer must give up
/// and say so, not retry behind a spinner for as long as the view is mounted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _scene =
    '{"\$slim":"scene/1","width":3,"height":3,"ops":[],'
    '"controls":["play"],"state":"s","live":true}';

void main() {
  testWidgets('a refused play stops after a few asks and shows a Retry', (
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
              throw const api.RateLimitedException('slow down');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Play'));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(calls, lessThanOrEqualTo(6));
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
  });
}

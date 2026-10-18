// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Play must stop asking the server when nobody can see the scene.
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

Future<void> _pump(
  WidgetTester tester,
  ValueNotifier<bool> visible,
  void Function() onCall,
) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (_, on, _) => TickerMode(
        enabled: on,
        child: Scaffold(
          body: ModuleSceneView(
            initial: parseModuleScene(_scene)!,
            runCommand: (_) async {
              onCall();
              return api.RunModuleCommandResult(ok: true, output: _scene);
            },
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('play stops when the app loses focus', (tester) async {
    var calls = 0;
    await _pump(tester, ValueNotifier(true), () => calls++);
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, greaterThan(0));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final before = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, before);
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('play stops when the view is covered', (tester) async {
    var calls = 0;
    final visible = ValueNotifier(true);
    await _pump(tester, visible, () => calls++);
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, greaterThan(0));

    visible.value = false;
    await tester.pump();
    final before = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, before);
  });
}

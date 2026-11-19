// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Play must stop asking the server when nobody can see the scene.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/window_lifecycle.dart';

const _scene =
    '{"\$slim":"scene/1","width":3,"height":3,"ops":[],'
    '"controls":["play"],"state":"s","live":true}';

Future<void> _pump(
  WidgetTester tester,
  ValueNotifier<bool> visible,
  void Function() onCall, {
  AppLifecycleNotifier? window,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [if (window != null) windowLifecycle(window)],
    child: MaterialApp(
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
                return const api.RunModuleCommandResult(
                  ok: true,
                  output: _scene,
                );
              },
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('play runs on in an unfocused window and stops in a hidden one', (
    tester,
  ) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    var calls = 0;
    await _pump(tester, ValueNotifier(true), () => calls++);
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, greaterThan(0));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final unfocused = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, greaterThan(unfocused), reason: 'it is still being watched');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    final hidden = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
  });

  testWidgets('play stops for a minimise only the window reported', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final events = StreamController<DesktopWindowEventKind>(sync: true);
    addTearDown(events.close);
    final window = AppLifecycleNotifier(
      mobile: false,
      windowEvents: events.stream,
    );
    var calls = 0;
    await _pump(tester, ValueNotifier(true), () => calls++, window: window);
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, greaterThan(0));

    events.add(DesktopWindowEventKind.minimize);
    await tester.pump();
    final minimised = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, minimised);
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
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

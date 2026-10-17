// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Playing a scene: pacing against the rate limit, what a step in flight may
/// and may not block, and the controls staying steady while a call runs.
///
/// Split from module_scene_drag_test.dart, which keeps the drawing tests; see
/// support/module_scene_fixtures.dart for the board both files mount.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/module_scene_fixtures.dart';

void main() {
  testWidgets('a rate limit while playing paces it instead of stopping it', (
    tester,
  ) async {
    // Playing outruns the write budget; a long run used to fail outright.
    var calls = 0;
    var gen = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ModuleSceneView(
            initial: parseModuleScene(sceneJson(0))!,
            runCommand: (_) async {
              calls++;
              if (calls == 2) {
                throw const api.RateLimitedException('too many requests');
              }
              return api.RunModuleCommandResult(
                ok: true,
                output: sceneJson(++gen),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 140));
    }

    expect(
      find.bySemanticsLabel('Pause'),
      findsOneWidget,
      reason: 'a refusal for asking too fast must not stop the animation',
    );
    expect(
      find.byType(AppErrorState),
      findsNothing,
      reason: 'nor put an error in front of somebody watching a board play',
    );
    expect(calls, greaterThan(2), reason: 'it kept going after the refusal');

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a drag while play has a step in flight is not dropped', (
    tester,
  ) async {
    // A drag queued behind play's own step used to be lost when it finished.
    final actions = <String>[];
    var gen = 0;
    Completer<api.RunModuleCommandResult>? heldStep;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: ModuleSceneView(
                initial: parseModuleScene(sceneJson(0))!,
                runCommand: (input) {
                  final action = jsonDecode(input)['action'] as String;
                  actions.add(action);
                  final result = api.RunModuleCommandResult(
                    ok: true,
                    output: sceneJson(++gen),
                  );
                  if (action == 'step' && heldStep == null) {
                    heldStep = Completer<api.RunModuleCommandResult>();
                    return heldStep!.future;
                  }
                  return Future.value(result);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final board = find.descendant(
      of: find.byType(ModuleSceneView),
      matching: find.byType(CustomPaint),
    );
    final topLeft = tester.getTopLeft(board.last);

    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump(const Duration(milliseconds: 140));
    expect(heldStep, isNotNull, reason: 'the first step is now in flight');

    // Paint across the top row while that step is still outstanding.
    await dragThrough(tester, topLeft + const Offset(50, 50), [
      topLeft + const Offset(350, 50),
    ]);
    heldStep!.complete(
      api.RunModuleCommandResult(ok: true, output: sceneJson(++gen)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 140));
    }
    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(
      actions.where((a) => a.startsWith('toggle')),
      isNotEmpty,
      reason: 'the cells painted during the in-flight step were never sent',
    );
  });

  testWidgets('a rate limit on a manual step still surfaces', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ModuleSceneView(
            initial: parseModuleScene(sceneJson(0))!,
            runCommand: (_) async =>
                throw const api.RateLimitedException('too many requests'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Step forward'));
    await tester.pumpAndSettle();

    expect(
      find.byType(AppErrorState),
      findsOneWidget,
      reason: 'a press that did nothing has to say why; only play paces',
    );
  });

  testWidgets('the controls do not disable themselves mid-call', (
    tester,
  ) async {
    // Disabling on every in-flight call is what made them flash while playing.
    final completer = Completer<api.RunModuleCommandResult>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ModuleSceneView(
            initial: parseModuleScene(sceneJson(0))!,
            runCommand: (_) => completer.future,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Step forward'));
    await tester.pump();

    final step = tester.widget<AppIconButton>(
      find
          .ancestor(
            of: find.bySemanticsLabel('Step forward'),
            matching: find.byType(AppIconButton),
          )
          .first,
    );
    expect(
      step.onPressed,
      isNotNull,
      reason: 'greying out for the length of every generation is the flicker',
    );

    completer.complete(
      api.RunModuleCommandResult(ok: true, output: sceneJson(1)),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('play survives the shared path echoing each step back', (
    tester,
  ) async {
    // The shape a message-owned scene has: every action stores and broadcasts.
    var gen = 0;
    var latest = sceneJson(0);
    final actions = <String>[];
    late StateSetter rebuildHost;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setHostState) {
              rebuildHost = setHostState;
              return ModuleSceneView(
                initial: parseModuleScene(latest)!,
                runCommand: (input) async {
                  actions.add(jsonDecode(input)['action'] as String);
                  latest = sceneJson(++gen);
                  // The broadcast lands on the row that owns this widget.
                  rebuildHost(() {});
                  return api.RunModuleCommandResult(ok: true, output: latest);
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 140));
    }

    expect(
      actions.length,
      greaterThan(3),
      reason:
          'the widget stopped its own timer when its own step came back: '
          'played $actions',
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  testWidgets('a run somebody else started still resets and stops', (
    tester,
  ) async {
    // The other half of the guard: a state this view never produced is new.
    var latest = sceneJson(0);
    late StateSetter rebuildHost;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setHostState) {
              rebuildHost = setHostState;
              return ModuleSceneView(
                initial: parseModuleScene(latest)!,
                runCommand: (_) async =>
                    api.RunModuleCommandResult(ok: true, output: latest),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump();
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);

    // Nothing in flight, and a state this view has never seen.
    latest = sceneJson(999);
    rebuildHost(() {});
    await tester.pump();

    expect(
      find.bySemanticsLabel('Play'),
      findsOneWidget,
      reason: 'a foreign run must stop the animation, not inherit it',
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });
}

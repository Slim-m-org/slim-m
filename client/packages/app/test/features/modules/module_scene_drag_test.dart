// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drawing on a scene, and the control that says whether it is playing.
///
/// A module call is a round trip and only one runs at a time, so a drag across
/// a grid produces cells faster than they can be sent. The `_busy` guard used
/// to drop everything that arrived mid-flight, which for a drag would mean a
/// line with holes in it, so cells queue and drain in order.
///
/// Pause is here for a related reason: it stopped the timer without repainting
/// the button, so the control kept drawing a pause glyph while the animation
/// had already stopped, and pressing it again started play while still showing
/// pause. The board going still was the only feedback either way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/module_scene_fixtures.dart';

void main() {
  testWidgets('a drag paints every cell it crosses, in order', (tester) async {
    // Roughly 100px a cell, so the row-0 centres sit near 50, 150, 250, 350.
    final actions = await actionsFrom(tester, (tester, origin) async {
      final gesture = await tester.startGesture(origin + const Offset(50, 50));
      for (final dx in [150.0, 250.0, 350.0]) {
        await gesture.moveTo(origin + Offset(dx, 50));
        await tester.pump();
      }
      await gesture.up();
    });

    expect(actions, [
      'toggle:0,0',
      'toggle:0,1',
      'toggle:0,2',
      'toggle:0,3',
    ], reason: 'a dragged line must not have holes where the module was busy');
  });

  testWidgets('a drag still paints every cell when calls are slow', (
    tester,
  ) async {
    late List<String> actions;
    await tester.runAsync(() async {
      actions = await actionsFrom(tester, (tester, origin) async {
        final gesture = await tester.startGesture(
          origin + const Offset(50, 50),
        );
        for (final dx in [150.0, 250.0, 350.0]) {
          await gesture.moveTo(origin + Offset(dx, 50));
          await tester.pump();
        }
        await gesture.up();
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
        }
      }, latency: const Duration(milliseconds: 40));
    });

    expect(
      actions.length,
      4,
      reason: 'the queue drains, it does not drop: $actions',
    );
  });

  testWidgets('a module that reads a list gets the drag in far fewer calls', (
    tester,
  ) async {
    // Latency is the point: cells only pile up behind a call already in flight.
    late List<String> actions;
    await tester.runAsync(() async {
      actions = await actionsFrom(
        tester,
        (tester, origin) async {
          final gesture = await tester.startGesture(
            origin + const Offset(50, 50),
          );
          for (final dx in [150.0, 250.0, 350.0]) {
            await gesture.moveTo(origin + Offset(dx, 50));
            await tester.pump();
          }
          await gesture.up();
          for (var i = 0; i < 30; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump(const Duration(milliseconds: 20));
          }
        },
        latency: const Duration(milliseconds: 40),
        tapBatch: true,
      );
    });

    // The first cell goes alone; the rest ride together in the next call.
    expect(actions.length, lessThan(4), reason: 'sent $actions');
    expect(
      actions.last.split(';').length,
      greaterThan(1),
      reason: 'the tail should have been coalesced: $actions',
    );
    expect(actions.expand((a) => a.split(':').last.split(';')).toSet(), {
      '0,0',
      '0,1',
      '0,2',
      '0,3',
    }, reason: 'every cell still arrives, whatever the grouping');
  });

  testWidgets('a module that never said it reads a list still gets singles', (
    tester,
  ) async {
    // game-of-life 0.2.0's shape: a list would come back "bad cell".
    final actions = await actionsFrom(tester, (tester, origin) async {
      final gesture = await tester.startGesture(origin + const Offset(50, 50));
      for (final dx in [150.0, 250.0, 350.0]) {
        await gesture.moveTo(origin + Offset(dx, 50));
        await tester.pump();
      }
      await gesture.up();
    });

    expect(actions, [
      'toggle:0,0',
      'toggle:0,1',
      'toggle:0,2',
      'toggle:0,3',
    ], reason: 'batching is opt-in, and an older module never opted in');
  });

  testWidgets('crossing a cell twice in one drag paints it once', (
    tester,
  ) async {
    final actions = await actionsFrom(tester, (tester, origin) async {
      await dragThrough(tester, origin + const Offset(50, 50), [
        origin + const Offset(150, 50),
        origin + const Offset(50, 50),
      ]);
    });

    expect(actions, [
      'toggle:0,0',
      'toggle:0,1',
    ], reason: 'a second crossing would toggle the cell back off');
  });

  testWidgets('pause repaints the control it belongs to', (tester) async {
    var gen = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ModuleSceneView(
            initial: parseModuleScene(sceneJson(0))!,
            runCommand: (_) async =>
                api.RunModuleCommandResult(ok: true, output: sceneJson(++gen)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump();
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(
      find.bySemanticsLabel('Play'),
      findsOneWidget,
      reason: 'the button kept saying pause after it had already stopped',
    );

    await tester.pumpAndSettle(const Duration(seconds: 1));
  });
}

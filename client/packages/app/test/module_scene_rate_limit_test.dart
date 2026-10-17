// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a drag does when the server says it is asking too fast.
///
/// A drag queues one action per cell, and a module that never declared
/// `tap_batch` gets a call each. When the burst runs out, the refusal used to
/// land on the branch that stops everything - and the `finally` in `_send`
/// restarted the drain immediately, so the rest of the queue was spent against
/// a closed limit as fast as the round trips came back. The drawn line stopped
/// where the budget did and the error was overwritten several times in one
/// frame-span.
///
/// game-of-life declares `tap_batch`, so the shipped module never showed this;
/// the fixtures here leave it off, which is the third-party module the contract
/// exists for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_pacing.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';
import 'support/module_scene_fixtures.dart';

/// Advances past the pacing waits, which are plain delays rather than
/// animations - `pumpAndSettle` alone returns while one is still outstanding
/// because nothing has a frame scheduled.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.pumpAndSettle();
}

/// Where the painted board starts, which drag coordinates are relative to.
Offset boardTopLeft(WidgetTester tester) => tester.getTopLeft(
  find
      .descendant(
        of: find.byType(ModuleSceneView),
        matching: find.byType(CustomPaint),
      )
      .last,
);

/// Mounts the board with a runner that refuses calls and answers the rest,
/// recording every action it was asked for. Either the first [refusals] calls,
/// or whichever 1-based call numbers [refuseWhen] picks.
Future<List<String>> actionsAgainstLimit(
  WidgetTester tester, {
  int refusals = 0,
  bool Function(int call)? refuseWhen,
}) async {
  final actions = <String>[];
  var gen = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ModuleSceneView(
              initial: parseModuleScene(sceneJson(0))!,
              runCommand: (input) async {
                actions.add(input);
                final refuse =
                    refuseWhen?.call(actions.length) ??
                    actions.length <= refusals;
                if (refuse) {
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
      ),
    ),
  );
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  testWidgets('a refused cell is sent again rather than lost', (tester) async {
    final actions = await actionsAgainstLimit(tester, refusals: 1);
    final board = boardTopLeft(tester);

    await dragThrough(tester, board + const Offset(50, 50), [
      board + const Offset(350, 50),
    ]);
    await settle(tester);

    expect(
      actions.where((a) => a.contains('"toggle:0,0"')).length,
      2,
      reason:
          'the refused cell has to be attempted again or the line has a hole '
          'in it: $actions',
    );
    expect(
      actions.where((a) => a.contains('"toggle:0,3"')).length,
      1,
      reason: 'and the rest of the line is sent once each, not retried with it',
    );
    expect(
      find.byType(AppErrorState),
      findsNothing,
      reason:
          'a refusal the drain waited out and recovered from is not an error',
    );
  });

  testWidgets(
    'a limit hit once, recovered from, and hit again still finishes',
    (tester) async {
      // Every other call refused, so the run of refusals never passes one.
      final actions = await actionsAgainstLimit(
        tester,
        refuseWhen: (call) => call.isOdd,
      );
      final board = boardTopLeft(tester);

      await dragThrough(tester, board + const Offset(50, 50), [
        board + const Offset(350, 50),
      ]);
      await settle(tester);

      for (final cell in ['0,0', '0,1', '0,2', '0,3']) {
        expect(
          actions.any(
            (a) =>
                a.contains('"toggle:$cell"') && !a.contains('"toggle:$cell;'),
          ),
          isTrue,
          reason: 'cell $cell never reached the module: $actions',
        );
      }
      expect(find.byType(AppErrorState), findsNothing);
    },
  );

  testWidgets('a drag against a limit that never opens gives up once', (
    tester,
  ) async {
    final actions = await actionsAgainstLimit(tester, refusals: 1000);
    final board = boardTopLeft(tester);

    // Two rows: a drag inside the allowance could not tell holding from burning.
    await dragThrough(tester, board + const Offset(50, 50), [
      board + const Offset(350, 50),
      board + const Offset(350, 150),
      board + const Offset(50, 150),
    ]);
    await settle(tester);

    expect(
      actions.length,
      lessThanOrEqualTo(ScenePacing.maxRefusals + 1),
      reason:
          'the queue must be held and then dropped, not spent against a closed '
          'limit: ${actions.length} calls for ${actions.toSet().length} cells',
    );
    expect(
      find.byType(AppErrorState),
      findsOneWidget,
      reason: 'giving up has to say so, once',
    );
  });
}

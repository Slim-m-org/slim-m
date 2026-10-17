// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `_send` already drops a tap while busy (correct debouncing), but nothing
/// on screen said a tap had been received at all until the response, or the
/// manifest's wall-clock cap, landed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/module_scene_fixtures.dart';

void main() {
  testWidgets(
    'shows a busy indicator while a command is in flight, gone once it lands',
    (tester) async {
      final completer = Completer<api.RunModuleCommandResult>();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: ModuleSceneView(
                  initial: parseModuleScene(sceneJson(0))!,
                  runCommand: (input) => completer.future,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.bySemanticsLabel('Step forward'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete(
        api.RunModuleCommandResult(ok: true, output: sceneJson(1)),
      );
      // Not pumpAndSettle: mid-fade-out the spinner is still ticking.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
}

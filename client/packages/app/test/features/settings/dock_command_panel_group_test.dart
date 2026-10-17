// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module declaring several `command` extension points used to get one
/// full-height panel per command, stacked without end.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_command_panel_group.dart';
import 'package:slimm_design_system/design_system.dart';

api.DockExtensionPoint _command(String name) => api.DockExtensionPoint(
  kind: 'command',
  name: name,
  description: '$name does a thing.',
  permission: '$name:run',
);

Future<void> _pump(
  WidgetTester tester,
  List<api.DockExtensionPoint> commands,
  double width,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DockCommandPanelGroup(
              moduleId: 'm1',
              extensionPoints: commands,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [390.0, 1200.0]) {
    group('at width $width', () {
      testWidgets(
        'at or under the threshold, every command is a full panel already',
        (tester) async {
          final commands = [_command('run'), _command('reset')];
          await _pump(tester, commands, width);

          expect(find.widgetWithText(AppInput, 'Input'), findsNWidgets(2));
        },
      );

      testWidgets(
        'past the threshold, commands collapse to a row until tapped open',
        (tester) async {
          final commands = [
            _command('run'),
            _command('reset'),
            _command('seed'),
            _command('clear'),
          ];
          await _pump(tester, commands, width);

          // Names are visible as collapsed rows, but nothing is open yet.
          for (final c in commands) {
            expect(find.text(c.name), findsOneWidget);
          }
          expect(find.byType(AppInput), findsNothing);

          await tester.tap(find.widgetWithText(AppListRow, 'seed'));
          await tester.pumpAndSettle();

          expect(find.byType(AppInput), findsOneWidget);

          await tester.tap(find.widgetWithText(AppListRow, 'seed'));
          await tester.pumpAndSettle();

          expect(find.byType(AppInput), findsNothing);
        },
      );

      testWidgets('only one command is open at a time', (tester) async {
        final commands = [
          _command('run'),
          _command('reset'),
          _command('seed'),
          _command('clear'),
        ];
        await _pump(tester, commands, width);

        await tester.tap(find.widgetWithText(AppListRow, 'seed'));
        await tester.pumpAndSettle();
        expect(find.byType(AppInput), findsOneWidget);

        await tester.tap(find.widgetWithText(AppListRow, 'clear'));
        await tester.pumpAndSettle();
        expect(find.byType(AppInput), findsOneWidget);
      });
    });
  }
}

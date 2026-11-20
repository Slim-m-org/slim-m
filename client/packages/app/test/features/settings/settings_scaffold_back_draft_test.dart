// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A routed settings screen's app-bar back asks before it drops a draft
/// behind a Save bar, whether it pops back or was opened cold from a link.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/settings_screen_scaffold.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/module_settings_form.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

final _doc = api.ModuleSettingsDoc.fromJson({
  'settings': [
    {'key': 'loud', 'type': 'bool', 'label': 'Loud mode', 'value': false},
  ],
});

final _back = find.byTooltip('Back to dock');
final _toggle = find.byWidgetPredicate((w) => w is AppToggle);

Widget _screen() => SettingsScreenScaffold(
  title: 'Module',
  backTooltip: 'Back to dock',
  backFallback: '/',
  child: ModuleSettingsForm(doc: _doc, onSave: (_) async {}),
);

Future<void> _openPushed(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => _screen())),
          child: const Text('dock list'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('dock list'));
  await pumpFrames(tester);
}

Future<void> _openCold(WidgetTester tester) async {
  final router = GoRouter(
    initialLocation: '/module',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('dock list')),
      GoRoute(path: '/module', builder: (_, _) => _screen()),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      theme: buildTheme(Brightness.light, AppTokens.light),
      routerConfig: router,
    ),
  );
  await pumpFrames(tester);
}

Future<void> _tapThenSettle(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await pumpFrames(tester);
}

void main() {
  for (final (how, open) in [
    ('pushed', _openPushed),
    ('opened cold', _openCold),
  ]) {
    testWidgets('$how: back with unsaved edits asks, and Keep editing stays', (
      tester,
    ) async {
      await open(tester);
      await _tapThenSettle(tester, _toggle);

      await _tapThenSettle(tester, _back);
      expect(find.text('Discard your changes?'), findsOneWidget);
      await _tapThenSettle(tester, find.text('Keep editing'));
      expect(find.text('Save changes'), findsOneWidget);

      await _tapThenSettle(tester, _back);
      await _tapThenSettle(tester, find.text('Discard').last);
      expect(find.text('dock list'), findsOneWidget);
    });

    testWidgets('$how: back with nothing edited leaves without asking', (
      tester,
    ) async {
      await open(tester);

      await _tapThenSettle(tester, _back);

      expect(find.text('Discard your changes?'), findsNothing);
      expect(find.text('dock list'), findsOneWidget);
    });
  }
}

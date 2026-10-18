// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a member is told about the module behind a command or an app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_items.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_query.dart';
import 'package:slimm_app/src/features/modules/widgets/module_about_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

const _weather = api.ModuleInfo(
  name: 'Weather',
  verified: true,
  capabilities: ['net.fetch', 'kv.store'],
  networkHosts: ['api.open-meteo.com'],
);

Finder _badge(String label) =>
    find.byWidgetPredicate((w) => w is AppBadge && w.label == label);

void main() {
  test('a command row names its module and flags the internet', () {
    expect(
      moduleCommandDetail('Current weather', _weather),
      'Current weather · Weather · uses the internet',
    );
    expect(moduleCommandDetail(null, null), '');
    expect(
      moduleCommandDetail(
        'Roll',
        const api.ModuleInfo(name: 'Dice', verified: true),
      ),
      'Roll · Dice',
    );
  });

  test(
    'the slash autocomplete rows carry the module beside the description',
    () {
      final rows = autocompleteSuggestions(
        query: const AutocompleteQuery(
          kind: AutocompleteKind.command,
          term: 'wea',
          start: 0,
          end: 4,
        ),
        custom: const [],
        members: const [],
        slashCommands: const [
          api.SlashCommand(
            moduleId: 'weather',
            command: 'now',
            name: 'weather',
            description: 'Current weather',
            module: _weather,
          ),
        ],
      );
      expect(
        rows.single.detail,
        'Current weather · Weather · uses the internet',
      );
    },
  );

  test('every approved power gets a plain sentence', () {
    expect(moduleAboutLines(_weather), [
      'Sends requests to api.open-meteo.com.',
      'Remembers data for this space.',
    ]);
    expect(
      moduleAboutLines(
        const api.ModuleInfo(
          name: 'Reminder',
          verified: false,
          capabilities: ['schedule', 'message.post'],
        ),
      ),
      [
        'Posts messages as whoever runs it, marked as this module.',
        'Runs on a timer and posts as itself in a channel an admin chose.',
      ],
    );
  });

  testWidgets('the sheet says whose module it is and what it may do', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Center(child: ModuleAboutButton(module: _weather)),
        ),
      ),
    );
    await tester.tap(find.byTooltip('About Weather'));
    await tester.pumpAndSettle();
    expect(find.text('A module from the official registry.'), findsOneWidget);
    expect(find.text('Sends requests to api.open-meteo.com.'), findsOneWidget);
    expect(find.text('An admin let it:'), findsOneWidget);
  });

  testWidgets('only a module that can fetch gets the Internet badge', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: ModuleNetworkBadge(module: _weather)),
      ),
    );
    expect(_badge('Internet'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: ModuleNetworkBadge(
            module: api.ModuleInfo(name: 'Dice', verified: true),
          ),
        ),
      ),
    );
    expect(_badge('Internet'), findsNothing);
  });
}

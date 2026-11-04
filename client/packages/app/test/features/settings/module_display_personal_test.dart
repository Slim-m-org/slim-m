// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A person's own module display switches only narrow what the Space allows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/modules/providers/module_display_settings.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_module_toggle.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

Future<ProviderContainer> _container({
  required bool space,
  required bool personal,
}) async {
  SharedPreferences.setMockInitialValues({
    moduleMemberBadgesKey: personal,
    moduleProfileSectionsKey: personal,
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      spaceMemberBadgesProvider.overrideWithValue(space),
      spaceProfileSectionsProvider.overrideWithValue(space),
    ],
  );
  await container.read(preferencesProvider.future);
  return container;
}

SettingsToggleRow _row(WidgetTester tester, String label) =>
    tester.widget<SettingsToggleRow>(
      find.byWidgetPredicate((w) => w is SettingsToggleRow && w.label == label),
    );

void main() {
  for (final (space, personal, shown) in const [
    (true, true, true),
    (true, false, false),
    (false, true, false),
    (false, false, false),
  ]) {
    test('space $space and personal $personal shows $shown', () async {
      final container = await _container(space: space, personal: personal);
      addTearDown(container.dispose);
      expect(container.read(moduleMemberBadgesShownProvider), shown);
      expect(container.read(moduleProfileSectionsShownProvider), shown);
    });
  }

  testWidgets('a person can hide levels while the Space allows them', (
    tester,
  ) async {
    final container = await _container(space: true, personal: true);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: Column(
              children: [
                PersonalModuleToggle(ModuleDisplayKind.memberBadges),
                PersonalModuleToggle(ModuleDisplayKind.profileSections),
              ],
            ),
          ),
        ),
      ),
    );
    _row(tester, 'Sections on profiles').onChanged!(false);
    await tester.pump(const Duration(milliseconds: 100));

    expect(container.read(moduleProfileSectionsShownProvider), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(moduleProfileSectionsKey), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the rows are disabled with a reason when the Space has them off',
    (tester) async {
      final container = await _container(space: false, personal: true);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(
              body: Column(
                children: [
                  PersonalModuleToggle(ModuleDisplayKind.memberBadges),
                  PersonalModuleToggle(ModuleDisplayKind.profileSections),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(_row(tester, 'Badges in member list').onChanged, isNull);
      expect(_row(tester, 'Sections on profiles').onChanged, isNull);
      expect(find.text('Turned off for this Space.'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    },
  );
}

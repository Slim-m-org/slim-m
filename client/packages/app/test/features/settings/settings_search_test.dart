// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings search finds a setting by its label or the words people use for
/// it, hides what this person cannot open, and takes them to the row itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index_gates.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/providers/providers.dart' show keyStoreProvider;
import 'package:slimm_app/src/features/settings/widgets/settings_search.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../settings_rendered_rows.dart';
import '../../ui_snapshot_support.dart';

const _all = [...personalSettingsIndex, ...spaceSettingsIndex];

List<String> _labels(String query) => [
  for (final e in searchSettings(query, _all)) e.label,
];

final _field = find.byKey(const Key('settings-search'));

Finder _result(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('settings-result-'),
  ),
  matching: find.text(label),
);

Color? _tint(WidgetTester tester, String label) {
  final target = find.byWidgetPredicate(
    (w) => w is SettingsHighlightTarget && w.label == label,
  );
  final box = tester.widget<AnimatedContainer>(
    find.descendant(of: target, matching: find.byType(AnimatedContainer)).first,
  );
  return (box.decoration! as BoxDecoration).color;
}

void main() {
  group('matching', () {
    test('a keyword finds a setting whose label does not contain it', () {
      expect(_labels('gif').first, 'Autoplay GIFs');
      expect(_labels('push to talk'), contains('Hold a key to talk'));
      expect(_labels('zoom').first, 'Interface scale');
    });

    test('noise finds both the personal and the Space setting', () {
      expect(
        _labels('noise'),
        containsAll(['Noise suppression', 'Strong by default']),
      );
    });

    test('a label prefix ranks first, and nonsense finds nothing', () {
      expect(_labels('theme').first, 'Theme');
      expect(_labels('qqzx'), isEmpty);
      expect(_labels('   '), isEmpty);
    });

    test('every word of a query has to match', () {
      expect(_labels('screen share fps'), ['Frame rate']);
    });

    test('the theme gallery and following the Space are findable', () {
      for (final word in ['gallery', 'store', 'import', 'recent']) {
        expect(_labels(word), contains('Browse themes'), reason: word);
      }
      expect(_labels('follow space'), contains('Follow Space default'));
    });
  });

  group('gating', () {
    test(
      'Follow Space default is offered only while the Space has one',
      () async {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer(
          overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
        );
        addTearDown(container.dispose);
        bool offered() => container
            .read(personalSearchEntriesProvider)
            .any((e) => e.label == 'Follow Space default');

        expect(offered(), isFalse);
        await container
            .read(spaceDefaultThemeProvider.notifier)
            .set(
              ThemeDocument.of(
                AppTokens.forest,
                name: 'Pine',
                author: '',
                base: 'forest',
                brightness: Brightness.dark,
              ),
            );
        expect(offered(), isTrue);
      },
    );

    test('a pane this person cannot open contributes nothing', () {
      final visible = settingsEntriesFor(spaceSettingsIndex, {'invites'});
      expect(visible.map((e) => e.pane).toSet(), {'invites'});
    });

    test('a row unavailable on this platform is never offered', () {
      bool never() => false;
      final entries = [
        const SettingsEntry('voice', 'Speaker'),
        SettingsEntry('voice', 'Phantom', available: never),
      ];
      expect(settingsEntriesFor(entries, {'voice'}).map((e) => e.label), [
        'Speaker',
      ]);
    });
  });

  for (final (name, size) in [
    ('desktop', const Size(1400, 880)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('on $name, a result opens its pane and lights the row', (
      tester,
    ) async {
      final fixture = await pumpSettingsAt(tester, '/settings', size: size);

      await tester.enterText(_field, 'gif');
      await tester.pump();
      await tester.tap(_result('Autoplay GIFs'));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 350));
      }

      expect(
        _tint(tester, 'Autoplay GIFs'),
        AppTokens.dark.accentSoft,
        reason: 'the row the search named is lit',
      );
      await tester.pump(const Duration(seconds: 2));
      expect(_tint(tester, 'Autoplay GIFs')!.a, 0);
      await teardownFixture(tester, fixture.container, fixture.db);
    });
  }

  testWidgets('Browse themes lights the Theme card\'s name and buttons', (
    tester,
  ) async {
    final fixture = await pumpSettingsAt(
      tester,
      '/settings',
      size: const Size(1400, 880),
    );

    await tester.enterText(_field, 'gallery');
    await tester.pump();
    await tester.tap(_result('Browse themes'));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 350));
    }

    expect(_tint(tester, 'Browse themes'), AppTokens.dark.accentSoft);
    await tester.pump(const Duration(seconds: 2));
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('Escape clears the search and brings the nav back', (
    tester,
  ) async {
    final fixture = await pumpSettingsAt(
      tester,
      '/settings',
      size: const Size(1400, 880),
    );
    await tester.enterText(_field, 'theme');
    await tester.pump();
    expect(_result('Theme'), findsOneWidget);

    await tester.tap(_field);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(_result('Theme'), findsNothing);
    expect(find.text('Appearance'), findsWidgets);
    await teardownFixture(tester, fixture.container, fixture.db);
  });
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which channel categories are folded, per device (design review note 8/2).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/channels/providers/collapsed_categories_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a fresh install has nothing folded', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(loadCollapsedCategories(prefs), isEmpty);
  });

  test('a stored set reads back', () async {
    SharedPreferences.setMockInitialValues({
      collapsedCategoriesKey: ['cat-1', 'cat-2'],
    });
    final prefs = await SharedPreferences.getInstance();
    expect(loadCollapsedCategories(prefs), {'cat-1', 'cat-2'});
  });

  test('toggling an uncollapsed category folds it and persists', () async {
    final c = container();
    await c.read(collapsedCategoriesProvider.notifier).toggle('cat-1');

    expect(c.read(collapsedCategoriesProvider), {'cat-1'});
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        collapsedCategoriesKey,
      ),
      ['cat-1'],
    );
  });

  test('toggling a folded category unfolds it', () async {
    SharedPreferences.setMockInitialValues({
      collapsedCategoriesKey: ['cat-1'],
    });
    final c = container();
    // Reading first is what creates the notifier and starts its load - a lazy provider has nothing to pump yet before that.
    c.read(collapsedCategoriesProvider);
    await pumpEventQueue();
    await c.read(collapsedCategoriesProvider.notifier).toggle('cat-1');

    expect(c.read(collapsedCategoriesProvider), isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        collapsedCategoriesKey,
      ),
      isEmpty,
    );
  });

  test('folding one category never touches another', () async {
    SharedPreferences.setMockInitialValues({
      collapsedCategoriesKey: ['cat-1'],
    });
    final c = container();
    c.read(collapsedCategoriesProvider);
    await pumpEventQueue();
    await c.read(collapsedCategoriesProvider.notifier).toggle('cat-2');

    expect(c.read(collapsedCategoriesProvider), {'cat-1', 'cat-2'});
  });
}

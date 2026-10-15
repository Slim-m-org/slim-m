// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A switch flipped or a category folded before the stored preferences load
/// keeps both the choice and what was stored (issue 2018).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/activity_sharing_settings.dart';
import 'package:slimm_app/src/providers/collapsed_categories_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  (ProviderContainer, Completer<void>) heldContainer() {
    final held = Completer<void>();
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith((ref) async {
          await held.future;
          return SharedPreferences.getInstance();
        }),
      ],
    );
    addTearDown(c.dispose);
    return (c, held);
  }

  test('a category folded before the load keeps the stored folds', () async {
    SharedPreferences.setMockInitialValues({
      collapsedCategoriesKey: ['cat-1'],
    });
    final (c, held) = heldContainer();
    c.read(collapsedCategoriesProvider);
    final toggled = c
        .read(collapsedCategoriesProvider.notifier)
        .toggle('cat-2');
    held.complete();
    await toggled;

    expect(c.read(collapsedCategoriesProvider), {'cat-1', 'cat-2'});
    final stored = (await SharedPreferences.getInstance()).getStringList(
      collapsedCategoriesKey,
    );
    expect(stored?.toSet(), {'cat-1', 'cat-2'});
  });

  test('a switch flipped before the load is not reverted by it', () async {
    SharedPreferences.setMockInitialValues({shareListeningKey: false});
    final (c, held) = heldContainer();
    c.read(shareListeningProvider);
    final set = c.read(shareListeningProvider.notifier).setEnabled(true);
    held.complete();
    await set;
    await Future<void>.delayed(Duration.zero);

    expect(c.read(shareListeningProvider), isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool(shareListeningKey),
      isTrue,
    );
  });
}

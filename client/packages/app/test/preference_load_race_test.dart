// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// #2018: a switch flipped or a category folded before preferences have
/// loaded keeps the user's change and the values already stored.
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

  ({ProviderContainer container, Completer<void> release}) held() {
    final release = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith((ref) async {
          await release.future;
          return SharedPreferences.getInstance();
        }),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, release: release);
  }

  test('folding a category before the load keeps the stored ones', () async {
    SharedPreferences.setMockInitialValues({
      collapsedCategoriesKey: ['a', 'b'],
    });
    final h = held();
    final toggled = h.container
        .read(collapsedCategoriesProvider.notifier)
        .toggle('c');
    final again = h.container
        .read(collapsedCategoriesProvider.notifier)
        .toggle('a');

    h.release.complete();
    await toggled;
    await again;

    expect(h.container.read(collapsedCategoriesProvider), {'b', 'c'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(collapsedCategoriesKey)!.toSet(), {'b', 'c'});
  });

  test('a switch flipped before the load is not put back', () async {
    SharedPreferences.setMockInitialValues({shareListeningKey: false});
    final h = held();
    final set = h.container
        .read(shareListeningProvider.notifier)
        .setEnabled(true);

    h.release.complete();
    await set;
    await Future<void>.delayed(Duration.zero);

    expect(h.container.read(shareListeningProvider), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(shareListeningKey), isTrue);
  });
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stored answer to "keep slim-m up to date automatically?".
///
/// On by default: an install nobody has touched updates itself, and a saved
/// answer of either kind is kept.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/auto_update_preference.dart';
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

  test('a fresh install defaults to on without saving anything', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(loadAutoUpdatePreference(prefs), isTrue);
    expect(prefs.containsKey(autoUpdateKey), isFalse);
  });

  test('a saved no is kept, not overwritten by the default', () async {
    SharedPreferences.setMockInitialValues({autoUpdateKey: false});
    final prefs = await SharedPreferences.getInstance();
    expect(loadAutoUpdatePreference(prefs), isFalse);

    final c = container()..read(autoUpdateProvider);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(autoUpdateProvider), isFalse);
  });

  test('a fresh install reads as on in the provider', () async {
    final c = container()..read(autoUpdateProvider);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(autoUpdateProvider), isTrue);
  });

  test('setting it persists and shows up in the provider', () async {
    final c = container();
    await c.read(autoUpdateProvider.notifier).set(true);

    expect(c.read(autoUpdateProvider), isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool(autoUpdateKey),
      isTrue,
    );
  });

  test('a stored yes is restored into the provider', () async {
    SharedPreferences.setMockInitialValues({autoUpdateKey: true});
    // Reading builds the controller; its load resolves a microtask later, long before anything reads it for real.
    final c = container()..read(autoUpdateProvider);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(autoUpdateProvider), isTrue);
  });

  test('turning it back off persists too', () async {
    SharedPreferences.setMockInitialValues({autoUpdateKey: true});
    final c = container();
    await c.read(autoUpdateProvider.notifier).set(false);

    expect(c.read(autoUpdateProvider), isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(autoUpdateKey),
      isFalse,
    );
  });
}

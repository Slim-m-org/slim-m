// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A personal module switch flipped before preferences load keeps the flip.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/modules/providers/module_display_settings.dart';
import 'package:slimm_app/src/features/modules/providers/module_sound_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';

ProviderContainer _slowPrefs(Completer<SharedPreferences> loading) {
  final container = ProviderContainer(
    overrides: [preferencesProvider.overrideWith((ref) => loading.future)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      moduleMemberBadgesKey: true,
      moduleSoundEnabledKey: true,
    }),
  );

  test('the display switch is not undone by its own late load', () async {
    final loading = Completer<SharedPreferences>();
    final container = _slowPrefs(loading);
    final provider = personalMemberBadgesProvider;
    container.listen(provider, (_, _) {});

    final saving = container.read(provider.notifier).setShown(false);
    loading.complete(await SharedPreferences.getInstance());
    await saving;

    expect(container.read(provider), isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(moduleMemberBadgesKey),
      isFalse,
    );
  });

  test('the sound switch is not undone by its own late load', () async {
    final loading = Completer<SharedPreferences>();
    final container = _slowPrefs(loading);
    container.listen(moduleSoundSettingsProvider, (_, _) {});

    final saving = container
        .read(moduleSoundSettingsProvider.notifier)
        .setEnabled(false);
    loading.complete(await SharedPreferences.getInstance());
    await saving;

    expect(container.read(moduleSoundSettingsProvider), isFalse);
  });
}

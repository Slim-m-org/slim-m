// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal "Soundboard sounds" switch beside "Dock module sounds":
/// on by default, persisted both ways, and independent of the other sounds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/modules/providers/module_sound_settings.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_app/src/features/voice/providers/soundboard_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

Widget _wrap() => UncontrolledProviderScope(
  container: ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  )..read(preferencesProvider),
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(
      body: SingleChildScrollView(child: NotificationsSection()),
    ),
  ),
);

final _toggle = find.byWidgetPredicate(
  (w) =>
      w is AppToggle &&
      w.semanticLabel == 'Hear soundboard clips played in a call',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the soundboard switch starts on and says what it does', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<AppToggle>(_toggle).value, isTrue);
    expect(find.text('Soundboard sounds'), findsOneWidget);
    expect(find.text('Hear clips people play in a call.'), findsOneWidget);
  });

  testWidgets('it persists both ways without touching module sounds', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pump(const Duration(milliseconds: 300));
    final prefs = await SharedPreferences.getInstance();

    await tester.ensureVisible(_toggle);
    await tester.tap(_toggle);
    await tester.pump(const Duration(milliseconds: 300));
    expect(prefs.getBool(soundboardSoundsEnabledKey), isFalse);
    expect(prefs.getBool(moduleSoundEnabledKey), isNull);

    await tester.tap(_toggle);
    await tester.pump(const Duration(milliseconds: 300));
    expect(prefs.getBool(soundboardSoundsEnabledKey), isTrue);
  });
}

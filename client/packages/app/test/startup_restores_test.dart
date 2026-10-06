// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A truncated preferences file must not strand the splash.
///
/// `SharedPreferences.getInstance()` throws on a corrupt file, every launch,
/// and the voice restores in the bootstrap did not catch it, so the app sat on
/// "Loading preferences" for good. These run the real restores against a real
/// Linux preferences store holding a truncated file.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/desktop_splash_preference.dart';
import 'package:slimm_app/src/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/startup_restores.dart';

/// A container whose preferences read throws what `getInstance()` throws on a
/// truncated file: a [FormatException] out of `json.decode`.
ProviderContainer _unreadable() {
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => Future<SharedPreferences>.error(
          const FormatException('Unterminated string', '{"flutter.slimm.voice'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A container over a readable preferences store holding [values].
Future<ProviderContainer> _readable(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [preferencesProvider.overrideWith((ref) async => prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

List<String> _recorded(ProviderContainer container) => [
  for (final event in container.read(debugLogProvider))
    if (event.source == 'startup') event.message,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('with an unreadable preferences file', () {
    test('every startup restore completes instead of rejecting', () async {
      final container = _unreadable();

      await restoreStartupPreferences(container);
    });

    test('each controller keeps its default', () async {
      final container = _unreadable();

      await restoreStartupPreferences(container);

      expect(container.read(themeControllerProvider), AppThemeChoice.system);
      expect(
        container.read(timeFormatControllerProvider),
        TimeFormatPreference.system,
      );
    });

    test('each restore that could not read it is recorded', () async {
      final container = _unreadable();

      await restoreStartupPreferences(container);

      final recorded = _recorded(container).join('\n');
      for (final name in [
        'camera on join',
        'voice activity sensitivity',
        'push to talk',
        'audio devices',
      ]) {
        expect(recorded, contains('could not restore $name'));
      }
    });

    test('the splash duration falls back to its default floor', () async {
      final container = _unreadable();

      final floor = await restoreSplashFloor(
        container,
        (c) => splashFloorFor(c.read(splashDurationControllerProvider)),
      );

      expect(floor, splashFloorFor(SplashDuration.standard));
    });
  });

  group('with a readable preferences file', () {
    test('a stored choice still restores, with nothing recorded', () async {
      final container = await _readable({themeChoiceKey: 'dark'});

      await restoreStartupPreferences(container);

      expect(container.read(themeControllerProvider), AppThemeChoice.dark);
      expect(_recorded(container), isEmpty);
    });
  });

  group('runStartupStep', () {
    test('a step that throws is recorded and does not escape', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await runStartupStep(container, 'update check', () async {
        throw StateError('boom');
      });

      expect(_recorded(container).single, contains('update check failed'));
    });

    test('a step that works runs and records nothing', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var ran = false;

      await runStartupStep(container, 'update check', () async => ran = true);

      expect(ran, isTrue);
      expect(_recorded(container), isEmpty);
    });
  });
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop startup-splash preference: one duration choice, with Disabled
/// standing in for the old on/off toggle. Defaults to standard (900ms), a
/// choice persists and restores, an unknown stored value degrades to the
/// default, an install that had the old toggle off migrates to Disabled, and
/// [SplashDurationX] maps each choice to a concrete duration - Disabled to
/// zero, standard to [minSplashDuration] itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/splash_floor.dart';
import 'package:slimm_app/src/desktop/providers/desktop_splash_preference.dart';
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

  group('SplashDurationController', () {
    test('defaults to standard, so it changes nothing on its own', () {
      expect(
        container().read(splashDurationControllerProvider),
        SplashDuration.standard,
      );
    });

    test('every choice honours its own concrete duration', () {
      expect(SplashDuration.disabled.duration, Duration.zero);
      expect(SplashDuration.brief.duration, const Duration(milliseconds: 500));
      expect(SplashDuration.standard.duration, minSplashDuration);
      expect(SplashDuration.long.duration, const Duration(milliseconds: 1500));
    });

    test('standard is minSplashDuration itself, so the two cannot drift '
        'apart', () {
      expect(
        SplashDuration.standard.duration,
        const Duration(milliseconds: 900),
      );
    });

    test('the labels name Disabled and the default distinctly', () {
      expect(SplashDuration.disabled.label, 'Disabled');
      expect(SplashDuration.standard.label, contains('default'));
      expect(SplashDuration.brief.label, isNot(contains('default')));
      expect(SplashDuration.long.label, isNot(contains('default')));
    });

    test('selecting persists, and restore reads it back', () async {
      final c = container();
      await c
          .read(splashDurationControllerProvider.notifier)
          .select(SplashDuration.long);
      expect(
        (await SharedPreferences.getInstance()).getString(
          desktopSplashDurationKey,
        ),
        'long',
      );

      final c2 = container();
      await c2.read(splashDurationControllerProvider.notifier).restore();
      expect(c2.read(splashDurationControllerProvider), SplashDuration.long);
    });

    test(
      'selecting Disabled persists and restores like any other choice',
      () async {
        final c = container();
        await c
            .read(splashDurationControllerProvider.notifier)
            .select(SplashDuration.disabled);
        final c2 = container();
        await c2.read(splashDurationControllerProvider.notifier).restore();
        expect(
          c2.read(splashDurationControllerProvider),
          SplashDuration.disabled,
        );
      },
    );

    test('an unknown stored value degrades to the default', () async {
      SharedPreferences.setMockInitialValues({
        desktopSplashDurationKey: 'glacial',
      });
      final c = container();
      await c.read(splashDurationControllerProvider.notifier).restore();
      expect(c.read(splashDurationControllerProvider), SplashDuration.standard);
    });

    test(
      'an install that had the old toggle off migrates to Disabled',
      () async {
        SharedPreferences.setMockInitialValues({
          desktopSplashEnabledKey: false,
        });
        final c = container();
        await c.read(splashDurationControllerProvider.notifier).restore();
        expect(
          c.read(splashDurationControllerProvider),
          SplashDuration.disabled,
          reason: 'a splash turned off under the old toggle stays off',
        );
      },
    );

    test(
      'the old toggle left on (or unset) keeps the default, not Disabled',
      () async {
        SharedPreferences.setMockInitialValues({desktopSplashEnabledKey: true});
        final c = container();
        await c.read(splashDurationControllerProvider.notifier).restore();
        expect(
          c.read(splashDurationControllerProvider),
          SplashDuration.standard,
        );
      },
    );

    test('a stored duration wins over the legacy toggle', () async {
      SharedPreferences.setMockInitialValues({
        desktopSplashEnabledKey: false,
        desktopSplashDurationKey: 'long',
      });
      final c = container();
      await c.read(splashDurationControllerProvider.notifier).restore();
      expect(
        c.read(splashDurationControllerProvider),
        SplashDuration.long,
        reason: 'an explicit new choice is not overridden by the old key',
      );
    });
  });

  group('splashFloorFor', () {
    test('Disabled means Duration.zero, no dwell at all', () {
      expect(splashFloorFor(SplashDuration.disabled), Duration.zero);
    });

    test('every other choice is its own duration', () {
      expect(
        splashFloorFor(SplashDuration.brief),
        const Duration(milliseconds: 500),
      );
      expect(splashFloorFor(SplashDuration.standard), minSplashDuration);
      expect(
        splashFloorFor(SplashDuration.long),
        const Duration(milliseconds: 1500),
      );
    });
  });
}

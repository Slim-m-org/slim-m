// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three preferences added for #38: a 12/24-hour clock, an in-app
/// reduce-motion override, and a high-contrast toggle. Each controller
/// mirrors `ThemeController`'s own shape, so these tests mirror
/// `theme_preference_test.dart`'s: an install with nothing stored keeps
/// today's behaviour, and a choice survives a restart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_design_system/design_system.dart';

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('formatMessageTime', () {
    // 1970-01-01 09:05:00 UTC.
    const nineOhFive = 9 * 60 * 60 * 1000 + 5 * 60 * 1000;
    // 1970-01-01 00:05:00 UTC.
    const midnightOhFive = 5 * 60 * 1000;

    test('24-hour is always zero-padded HH:mm', () {
      final hour = DateTime.fromMillisecondsSinceEpoch(
        nineOhFive,
      ).hour.toString().padLeft(2, '0');
      expect(formatMessageTime(nineOhFive, use24Hour: true), '$hour:05');
    });

    test('12-hour drops the leading zero and uses a one-letter suffix, so '
        'a grouped row\'s 36px gutter never wraps to two lines', () {
      final local = DateTime.fromMillisecondsSinceEpoch(nineOhFive);
      final expectedHour = local.hour % 12 == 0 ? 12 : local.hour % 12;
      final expectedSuffix = local.hour < 12 ? 'a' : 'p';
      expect(
        formatMessageTime(nineOhFive, use24Hour: false),
        '$expectedHour:05$expectedSuffix',
      );
    });

    test('12-hour renders midnight as 12, not 0', () {
      final local = DateTime.fromMillisecondsSinceEpoch(midnightOhFive);
      if (local.hour != 0) return; // Only meaningful in a UTC-ish timezone.
      expect(formatMessageTime(midnightOhFive, use24Hour: false), '12:05a');
    });
  });

  group('resolveUse24Hour', () {
    testWidgets('h24 and h12 ignore the device setting entirely', (
      tester,
    ) async {
      for (final deviceIs24 in [false, true]) {
        late bool forced24;
        late bool forced12;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: deviceIs24),
            child: Builder(
              builder: (context) {
                forced24 = resolveUse24Hour(context, TimeFormatPreference.h24);
                forced12 = resolveUse24Hour(context, TimeFormatPreference.h12);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(forced24, isTrue);
        expect(forced12, isFalse);
      }
    });

    testWidgets('system follows the device\'s own reported setting', (
      tester,
    ) async {
      for (final deviceIs24 in [false, true]) {
        late bool resolved;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: deviceIs24),
            child: Builder(
              builder: (context) {
                resolved = resolveUse24Hour(
                  context,
                  TimeFormatPreference.system,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(resolved, deviceIs24);
      }
    });
  });

  group('TimeFormatController', () {
    test('an install with nothing stored follows the system', () async {
      final container = _container();
      await container.read(timeFormatControllerProvider.notifier).restore();
      expect(
        container.read(timeFormatControllerProvider),
        TimeFormatPreference.system,
      );
    });

    test(
      'a stored value this build does not know falls back to system',
      () async {
        SharedPreferences.setMockInitialValues({
          timeFormatPreferenceKey: 'stardate',
        });
        final container = _container();
        await container.read(timeFormatControllerProvider.notifier).restore();
        expect(
          container.read(timeFormatControllerProvider),
          TimeFormatPreference.system,
        );
      },
    );

    test('the choice survives a restart', () async {
      final first = _container();
      await first.read(timeFormatControllerProvider.notifier).restore();
      await first
          .read(timeFormatControllerProvider.notifier)
          .select(TimeFormatPreference.h24);

      final second = _container();
      await second.read(timeFormatControllerProvider.notifier).restore();
      expect(
        second.read(timeFormatControllerProvider),
        TimeFormatPreference.h24,
      );
    });
  });

  group('MotionPreferenceController', () {
    test('an install with nothing stored follows the system', () async {
      final container = _container();
      await container
          .read(motionPreferenceControllerProvider.notifier)
          .restore();
      expect(
        container.read(motionPreferenceControllerProvider),
        MotionOverride.system,
      );
    });

    test('the choice survives a restart', () async {
      final first = _container();
      await first.read(motionPreferenceControllerProvider.notifier).restore();
      await first
          .read(motionPreferenceControllerProvider.notifier)
          .select(MotionOverride.alwaysReduce);

      final second = _container();
      await second.read(motionPreferenceControllerProvider.notifier).restore();
      expect(
        second.read(motionPreferenceControllerProvider),
        MotionOverride.alwaysReduce,
      );
    });
  });

  group('HighContrastController', () {
    test('an install with nothing stored is off', () async {
      final container = _container();
      await container.read(highContrastControllerProvider.notifier).restore();
      expect(container.read(highContrastControllerProvider), isFalse);
    });

    test('the choice survives a restart', () async {
      final first = _container();
      await first.read(highContrastControllerProvider.notifier).restore();
      await first.read(highContrastControllerProvider.notifier).select(true);

      final second = _container();
      await second.read(highContrastControllerProvider.notifier).restore();
      expect(second.read(highContrastControllerProvider), isTrue);
    });
  });
}

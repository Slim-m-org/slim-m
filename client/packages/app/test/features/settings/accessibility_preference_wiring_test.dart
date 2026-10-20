// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `main.dart`'s own doc comment on [appChromeBuilder] and [SlimMApp.build]
/// claims two preferences reach the running app: high contrast swaps two
/// token roles, and the reduce-motion override reaches
/// `MediaQuery.disableAnimationsOf`. `high_contrast_test.dart` and
/// `app_motion_test.dart` (in `design_system`) prove the two pure transforms
/// in isolation; `motion_preference_controller_test.dart` and
/// `high_contrast_controller_test.dart` prove persistence. Nothing proves the
/// wiring between them - that `SlimMApp` actually reads the controller and
/// applies the transform - which is exactly the shape
/// `theme_preference_test.dart` already proves for the theme choice. This
/// follows that same pattern (mount the real [SlimMApp], read what is
/// actually painted) for the other two.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const SlimMApp()),
  );
  await tester.pumpAndSettle();
}

/// The theme actually painting, read from below `MaterialApp` the same way
/// `theme_preference_test.dart`'s own helper does, so a missing `theme:` or
/// a transform never reaching it cannot pass.
ThemeData _paintedTheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold).first));

bool _disableAnimationsPainted(WidgetTester tester) =>
    MediaQuery.disableAnimationsOf(tester.element(find.byType(Scaffold).first));

void main() {
  testWidgets(
    'high contrast moves borderSubtle and textDisabled to the boosted roles',
    (tester) async {
      final container = _container();
      container.read(highContrastControllerProvider.notifier).state = true;
      await _pumpApp(tester, container);

      final tokens = _paintedTheme(tester).extension<AppTokens>()!;
      expect(
        tokens.borderSubtle,
        AppTokens.light.borderStrong,
        reason:
            'SlimMApp.build must apply applyHighContrast when the '
            'controller reports true, not just when a test calls it '
            'directly',
      );
      expect(tokens.textDisabled, AppTokens.light.textSecondary);
    },
  );

  testWidgets('high contrast off keeps the ordinary quiet roles', (
    tester,
  ) async {
    final container = _container();
    container.read(highContrastControllerProvider.notifier).state = false;
    await _pumpApp(tester, container);

    final tokens = _paintedTheme(tester).extension<AppTokens>()!;
    expect(tokens.borderSubtle, AppTokens.light.borderSubtle);
    expect(tokens.textDisabled, AppTokens.light.textDisabled);
  });

  testWidgets(
    'an always-reduce motion choice reaches MediaQuery.disableAnimationsOf '
    'below the router',
    (tester) async {
      final container = _container();
      container.read(motionPreferenceControllerProvider.notifier).state =
          MotionOverride.alwaysReduce;
      await _pumpApp(tester, container);

      expect(
        _disableAnimationsPainted(tester),
        isTrue,
        reason:
            'appChromeBuilder must have wrapped the routed tree in a '
            'MediaQuery carrying overrideMotion(..., motionChoice), not a '
            'hardcoded MotionOverride.system',
      );
    },
  );

  testWidgets(
    'the system motion choice leaves disableAnimations at whatever the '
    'platform already reported',
    (tester) async {
      final container = _container();
      container.read(motionPreferenceControllerProvider.notifier).state =
          MotionOverride.system;
      await _pumpApp(tester, container);

      expect(_disableAnimationsPainted(tester), isFalse);
    },
  );
}

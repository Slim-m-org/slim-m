// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the appearance choice: it must actually drive the theme, it must
/// survive a restart, and an install with nothing stored must keep following
/// the operating system exactly as it did before there was a control at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/main.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/themes_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/appearance_settings_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

/// A container built the way `main()` builds one, so a second call to this
/// after a `select` is the same thing as relaunching the app.
ProviderContainer _restartedContainer() {
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  );
  addTearDown(container.dispose);
  return container;
}

/// The theme the app is really painting with, read from below MaterialApp
/// rather than from the provider, so a missing `themeMode:` cannot pass.
ThemeData _paintedTheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold).first));

/// The Themes page, where the theme is actually picked.
Future<void> _pumpThemes(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const ThemesScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

/// The labels the section draws, spelled out here rather than imported: they
/// are the user-facing contract, so a rename should fail a test.
String _labelOf(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => 'System',
  AppThemeChoice.light => 'Light',
  AppThemeChoice.dark => 'Dark',
  AppThemeChoice.trueBlack => 'True black',
  AppThemeChoice.catppuccin => 'Catppuccin',
  AppThemeChoice.softDark => 'Soft dark',
  AppThemeChoice.forest => 'Forest',
  AppThemeChoice.halloween => 'Halloween',
  AppThemeChoice.spaceDefault => 'Space default',
  AppThemeChoice.custom => 'Custom',
};

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const SlimMApp()),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an install with nothing stored follows the Space default', () async {
    final container = _restartedContainer();
    await container.read(themeControllerProvider.notifier).restore();

    expect(
      container.read(themeControllerProvider),
      AppThemeChoice.spaceDefault,
    );
  });

  test(
    'a stored value this build does not know falls back to the Space default',
    () async {
      SharedPreferences.setMockInitialValues({themeChoiceKey: 'solarized'});
      final container = _restartedContainer();
      await container.read(themeControllerProvider.notifier).restore();

      expect(
        container.read(themeControllerProvider),
        AppThemeChoice.spaceDefault,
      );
    },
  );

  test('the choice survives a restart', () async {
    final first = _restartedContainer();
    await first.read(themeControllerProvider.notifier).restore();
    await first
        .read(themeControllerProvider.notifier)
        .select(AppThemeChoice.trueBlack);

    // A fresh container reads the same preference store, which is what a
    // relaunch does; nothing is carried over in memory.
    final second = _restartedContainer();
    expect(second.read(themeControllerProvider), AppThemeChoice.spaceDefault);
    await second.read(themeControllerProvider.notifier).restore();

    expect(second.read(themeControllerProvider), AppThemeChoice.trueBlack);
  });

  testWidgets('the picker survives a list and a phone at a large text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final container = _restartedContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            // A list is what settings is. The row states its current value,
            // which is the thing that used to overflow at this text scale.
            child: ListView(children: const [AppearanceSettingsSection()]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Theme'), findsOneWidget);
    // Clock and Motion default to "System"; the theme to "Space default".
    expect(find.text('System'), findsNWidgets(2));
    expect(find.text('Space default'), findsOneWidget);
  });

  testWidgets('tapping a segment is what actually changes the theme', (
    tester,
  ) async {
    final container = _restartedContainer();
    await container.read(themeControllerProvider.notifier).restore();
    await _pumpThemes(tester, container);

    expect(
      container.read(themeControllerProvider),
      AppThemeChoice.spaceDefault,
    );

    await _choose(tester, AppThemeChoice.trueBlack);

    expect(
      container.read(themeControllerProvider),
      AppThemeChoice.trueBlack,
      reason:
          'the segment is the only control the user has for the whole '
          'theme feature; driving the controller directly proves nothing '
          'about whether it is wired to anything',
    );
    expect(
      find.text('True black'),
      findsOneWidget,
      reason: 'the row has to restate the choice it just reported',
    );

    // A relaunch reads the preference store, so this is the tap proving it
    // reached `select` rather than only setting state.
    final relaunched = _restartedContainer();
    await relaunched.read(themeControllerProvider.notifier).restore();
    expect(relaunched.read(themeControllerProvider), AppThemeChoice.trueBlack);
  });

  testWidgets('every appearance option is reachable by tapping it', (
    tester,
  ) async {
    // Custom and the followed Space default are listed only while one exists.
    for (final choice in AppThemeChoice.values.where(
      (c) => c != AppThemeChoice.custom && c != AppThemeChoice.spaceDefault,
    )) {
      SharedPreferences.setMockInitialValues({});
      final container = _restartedContainer();
      await container.read(themeControllerProvider.notifier).restore();
      container.read(themeControllerProvider.notifier).state =
          AppThemeChoice.light;
      await _pumpThemes(tester, container);

      await _choose(tester, choice);

      expect(
        container.read(themeControllerProvider),
        choice,
        reason: 'tapping ${_labelOf(choice)} must select it',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('on a phone the Themes page lists swatches', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final container = _restartedContainer();
    await container.read(themeControllerProvider.notifier).restore();
    await _pumpThemes(tester, container);

    await _choose(tester, AppThemeChoice.halloween);

    expect(container.read(themeControllerProvider), AppThemeChoice.halloween);
  });

  testWidgets('a chosen light theme wins over a dark operating system', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final container = _restartedContainer();
    container.read(themeControllerProvider.notifier).state =
        AppThemeChoice.light;
    await _pumpApp(tester, container);

    expect(_paintedTheme(tester).brightness, Brightness.light);
  });

  testWidgets('a chosen dark theme wins over a light operating system', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final container = _restartedContainer();
    container.read(themeControllerProvider.notifier).state =
        AppThemeChoice.dark;
    await _pumpApp(tester, container);

    final theme = _paintedTheme(tester);
    expect(theme.brightness, Brightness.dark);
    expect(theme.extension<AppTokens>(), AppTokens.dark);
  });

  for (final (choice, tokens) in [
    (AppThemeChoice.catppuccin, AppTokens.mocha),
    (AppThemeChoice.softDark, AppTokens.soft),
    (AppThemeChoice.forest, AppTokens.forest),
    (AppThemeChoice.halloween, AppTokens.halloween),
  ]) {
    testWidgets(
      'a stored ${choice.name} choice paints its tokens on relaunch',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

        final first = _restartedContainer();
        await first.read(themeControllerProvider.notifier).restore();
        await first.read(themeControllerProvider.notifier).select(choice);

        final relaunched = _restartedContainer();
        await relaunched.read(themeControllerProvider.notifier).restore();
        await _pumpApp(tester, relaunched);

        final theme = _paintedTheme(tester);
        expect(theme.brightness, Brightness.dark);
        expect(theme.extension<AppTokens>(), tokens);
        expect(theme.extension<AppTokens>()!.accent, tokens.accent);
      },
    );
  }

  testWidgets('true black is reachable, and following the system never is', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final container = _restartedContainer();
    container.read(themeControllerProvider.notifier).state =
        AppThemeChoice.trueBlack;
    await _pumpApp(tester, container);

    expect(
      _paintedTheme(tester).extension<AppTokens>()!.surfaceBase,
      const Color(0xFF000000),
    );

    container.read(themeControllerProvider.notifier).state =
        AppThemeChoice.system;
    await tester.pumpAndSettle();

    // On a dark system this is dark, but it is the ordinary dark palette:
    // true black is an OLED decision no operating system reports.
    expect(_paintedTheme(tester).extension<AppTokens>(), AppTokens.dark);
  });
}

/// Taps [choice] on the Themes page, so a tap proves the row is wired to the controller.
Future<void> _choose(WidgetTester tester, AppThemeChoice choice) async {
  await tester.tap(find.byKey(Key('theme-builtin-${choice.name}')));
  await tester.pump(const Duration(milliseconds: 100));
}

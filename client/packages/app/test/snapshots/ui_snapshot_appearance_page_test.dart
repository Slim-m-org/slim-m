// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Appearance at a laptop and a phone: the Theme card with its hero, Recent
/// and Follow, a theme from the Space, a Not saved theme, System with no
/// Space default, a Recent tile previewed under the pointer, the Background
/// card after a theme brought its picture, the controls in their column, and
/// the titled picture sheet.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/background_from_theme.dart';
import 'package:slimm_app/src/features/settings/providers/recent_themes.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/widgets/background_settings_card.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';
import 'ui_snapshot_appearance_fixture.dart';
import 'ui_snapshot_themes_fixture.dart';

const _route = '/settings?pane=appearance';
const _viewports = ['laptop-1280', 'phone-portrait'];

class _Recent extends RecentThemesController {
  _Recent(this.seeded);

  final List<RecentTheme> seeded;

  @override
  List<RecentTheme> build() {
    super.build();
    return seeded;
  }
}

class _From extends BackgroundFromThemeController {
  _From(this.seeded);

  final String? seeded;

  @override
  String? build() {
    super.build();
    return seeded;
  }
}

RecentTheme _builtIn(AppThemeChoice choice) =>
    RecentTheme(source: BuiltInThemeSource(choice));

final _pine = RecentTheme(
  source: const SpaceThemeSource('pine'),
  theme: pineAtDusk,
);

/// Dark in use with the mockup's recents, or Light with the light set.
List<RecentTheme> _recents(String theme) => theme == 'dark'
    ? [
        _builtIn(AppThemeChoice.dark),
        _builtIn(AppThemeChoice.light),
        const RecentTheme(source: MineThemeSource('harbour')),
        _pine,
        _builtIn(AppThemeChoice.catppuccin),
      ]
    : [
        _builtIn(AppThemeChoice.light),
        _builtIn(AppThemeChoice.dark),
        const RecentTheme(source: MineThemeSource('sand')),
        _pine,
        const RecentTheme(source: MineThemeSource('harbour')),
      ];

List<Override> _fixture(
  String theme, {
  ThemeDocument? applied,
  ThemeSource? source,
  AppThemeChoice? choice,
  bool emptyStore = false,
  String? backgroundFrom,
  List<Override> extra = const [],
}) => [
  ...themesFixture(
    applied: applied,
    source: source,
    choice:
        choice ??
        (applied != null
            ? null
            : theme == 'dark'
            ? AppThemeChoice.dark
            : AppThemeChoice.light),
    emptyStore: emptyStore,
  ),
  recentThemesProvider.overrideWith(() => _Recent(_recents(theme))),
  backgroundFromThemeProvider.overrideWith(() => _From(backgroundFrom)),
  ...extra,
];

/// Pictures decode outside the fake clock.
Future<void> _decode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await _decode(tester);
}

Future<void> _render(
  WidgetTester tester,
  String viewport,
  String theme,
  String name,
  List<Override> overrides, {
  Future<void> Function(WidgetTester tester)? then,
}) => renderSurface(
  tester,
  _route,
  viewport,
  theme,
  '$name-$viewport-$theme',
  overrides: overrides,
  afterSettle: (tester) async {
    await _decode(tester);
    await then?.call(tester);
  },
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in _viewports) {
    for (final theme in ['dark', 'light']) {
      testWidgets('the top at $viewport in $theme', (tester) async {
        await _render(
          tester,
          viewport,
          theme,
          'settings-appearance-top',
          _fixture(theme),
        );
      });

      testWidgets('a Space theme at $viewport in $theme', (tester) async {
        await _render(
          tester,
          viewport,
          theme,
          'settings-appearance-space',
          _fixture(
            theme,
            applied: pineAtDusk,
            source: const SpaceThemeSource('pine'),
          ),
        );
      });

      testWidgets('a Not saved theme at $viewport in $theme', (tester) async {
        await _render(
          tester,
          viewport,
          theme,
          'settings-appearance-unsaved',
          _fixture(theme, applied: lilac, source: const FileThemeSource()),
        );
      });

      testWidgets('the background at $viewport in $theme', (tester) async {
        await _render(
          tester,
          viewport,
          theme,
          'settings-appearance-background',
          _fixture(
            theme,
            applied: pineAtDusk,
            source: const SpaceThemeSource('pine'),
            backgroundFrom: 'Pine at dusk',
            extra: await backgroundPictureOverrides(tester),
          ),
          then: (tester) => _scrollTo(tester, find.text('Background')),
        );
      });

      testWidgets('the controls at $viewport in $theme', (tester) async {
        await _render(
          tester,
          viewport,
          theme,
          'settings-appearance-controls',
          _fixture(theme),
          then: (tester) => _scrollTo(tester, find.text('Text and layout')),
        );
      });
    }
  }

  for (final theme in ['dark', 'light']) {
    testWidgets('a Recent tile under the pointer in $theme', (tester) async {
      await _render(
        tester,
        'laptop-1280',
        theme,
        'settings-appearance-previewing',
        _fixture(theme),
        then: (tester) async {
          final other = theme == 'dark'
              ? AppThemeChoice.light
              : AppThemeChoice.dark;
          final tile = find.byKey(
            Key('recent-theme-${BuiltInThemeSource(other).key}'),
          );
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);
          await mouse.moveTo(tester.getCenter(tile));
          await tester.pump();
        },
      );
    });
  }

  testWidgets('System with no Space default on a laptop', (tester) async {
    await _render(
      tester,
      'laptop-1280',
      'dark',
      'settings-appearance-system',
      _fixture('dark', choice: AppThemeChoice.system, emptyStore: true),
    );
  });

  testWidgets('System with no Space default on a phone', (tester) async {
    await _render(
      tester,
      'phone-portrait',
      'light',
      'settings-appearance-system',
      _fixture('light', choice: AppThemeChoice.system, emptyStore: true),
    );
  });

  testWidgets('the picture sheet on a phone', (tester) async {
    await _render(
      tester,
      'phone-portrait',
      'light',
      'settings-appearance-picture-sheet',
      _fixture('light', extra: await backgroundPictureOverrides(tester)),
      then: (tester) async {
        await _scrollTo(
          tester,
          find.byKey(BackgroundSettingsCard.pictureRowKey),
        );
        await tester.tap(find.byKey(BackgroundSettingsCard.pictureRowKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      },
    );
  });
}

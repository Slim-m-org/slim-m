// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Appearance mounted in a real settings pane over the gallery's fake store,
/// with helpers that apply themes the way the app does before it opens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/recent_themes.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/widgets/appearance_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_editor_page.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_gallery.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_gallery_rig.dart';

const appearanceWide = Size(1280, 2400);
const appearancePhone = Size(390, 2400);

class AppearanceRig {
  AppearanceRig({String? defaultId, List<Map<String, dynamic>>? themes})
    : gallery = GalleryRig(defaultId: defaultId, themes: themes) {
    SharedPreferences.setMockInitialValues({});
  }

  final GalleryRig gallery;

  ProviderContainer get container => gallery.container;

  Future<void> choose(AppThemeChoice choice) =>
      container.read(themeControllerProvider.notifier).select(choice);

  /// [document] in use, recorded as coming from [source].
  Future<void> apply(ThemeDocument document, ThemeSource source) async {
    await container.read(customThemeProvider.notifier).set(document);
    await container.read(customThemeSourceProvider.notifier).set(source);
    await choose(AppThemeChoice.custom);
  }

  Future<String> keep(ThemeDocument document) async =>
      (await container.read(myThemesProvider.notifier).save(document))!;

  /// Recent, most recent first.
  Future<void> recent(List<RecentTheme> recents) async {
    final controller = container.read(recentThemesProvider.notifier);
    for (final r in recents.reversed) {
      await controller.record(r.source, theme: r.theme);
    }
  }

  Future<void> pump(WidgetTester tester, {Size size = appearanceWide}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: SettingsPanesScaffold(
            title: 'Settings',
            backTooltip: 'Back to channels',
            backFallback: '/',
            initialPaneId: 'appearance',
            groups: [
              SettingsPaneGroup(
                label: 'App',
                panes: [
                  SettingsPane(
                    id: 'appearance',
                    label: 'Appearance',
                    builder: (_) => const AppearanceSettingsSection(),
                    subPages: {
                      'themes': () => [themesSubPage()],
                      'new-theme': () => [
                        themesSubPage(),
                        themeEditorSubPage(null),
                      ],
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await settleGallery(tester);
  }
}

/// Scrolls Appearance until [finder] is on screen.
Future<void> revealOnAppearance(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
}

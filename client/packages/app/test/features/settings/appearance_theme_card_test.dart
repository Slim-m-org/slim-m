// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Appearance's Theme card: the theme in use with where it came from and its
/// one main action, Browse themes, Follow Space default and High contrast,
/// each driven by a tap.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/widgets/appearance_theme_card.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_miniature.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'appearance_rig.dart';
import 'theme_gallery_rig.dart';

Finder _key(Key key) => find.byKey(key);

Finder _action(String label) => find.descendant(
  of: _key(AppearanceThemeCard.actionKey),
  matching: find.text(label),
);

String _editorName(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('theme-editor-name')),
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
    )
    .controller
    .text;

Finder _toggle(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is SettingsToggleRow && w.label == label),
  matching: find.byWidgetPredicate((w) => w is AppToggle),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await revealOnAppearance(tester, finder);
  await tester.tap(finder);
  await settleGallery(tester);
}

AppTokens _heroTokens(WidgetTester tester) =>
    tester.widget<ThemeMiniature>(_key(AppearanceThemeCard.heroKey)).tokens;

/// The Space default, whose file carries picture settings of its own.
final _pine = () {
  final plain = galleryDoc('Pine at dusk');
  return ThemeDocument(
    name: plain.name,
    author: plain.author,
    base: plain.base,
    brightness: plain.brightness,
    colours: plain.colours,
    picture: const ThemePicture(dim: 0.6, vignette: true, blur: 0.8),
  );
}();

AppearanceRig _withDefault() => AppearanceRig(
  defaultId: 'pine',
  themes: [stored('pine', 'Pine at dusk', author: 'ada', file: _pine.toJson())],
);

void main() {
  group('the theme in use', () {
    testWidgets('a built-in names itself and offers Customise', (tester) async {
      final rig = AppearanceRig();
      await rig.choose(AppThemeChoice.softDark);
      await rig.pump(tester);

      expect(find.text('Soft dark'), findsOneWidget);
      expect(find.text('In use · Built in'), findsOneWidget);
      expect(_action('Customise'), findsOneWidget);
      expect(_heroTokens(tester), AppTokens.soft);
    });

    testWidgets('System has a split preview and no main action', (
      tester,
    ) async {
      final rig = AppearanceRig();
      await rig.choose(AppThemeChoice.system);
      await rig.pump(tester);

      expect(find.text('In use · Built in, follows your device'), findsOne);
      expect(_key(AppearanceThemeCard.actionKey), findsNothing);
      final hero = tester.widget<ThemeMiniature>(
        _key(AppearanceThemeCard.heroKey),
      );
      expect(hero.tokens, AppTokens.light);
      expect(hero.split, AppTokens.dark);
    });

    testWidgets('a Mine theme offers Edit, which opens it', (tester) async {
      final rig = AppearanceRig();
      final harbour = galleryDoc('Harbour');
      final id = await rig.keep(harbour);
      await rig.apply(harbour, MineThemeSource(id));
      await rig.pump(tester);

      expect(find.text('In use · Mine'), findsOneWidget);
      await _tap(tester, _key(AppearanceThemeCard.actionKey));

      expect(find.text('Edit theme'), findsOneWidget);
      expect(_editorName(tester), 'Harbour');
    });

    testWidgets('Customise opens the editor on a copy of the built-in', (
      tester,
    ) async {
      final rig = AppearanceRig();
      await rig.choose(AppThemeChoice.forest);
      await rig.pump(tester);

      await _tap(tester, _key(AppearanceThemeCard.actionKey));

      expect(find.text('New theme'), findsOneWidget);
      expect(_editorName(tester), 'Forest copy');
      expect(
        find.byTooltip('Back to Themes'),
        findsOneWidget,
        reason: 'the editor sits above the gallery it saves into',
      );
    });

    testWidgets('a file theme says Not saved', (tester) async {
      final rig = AppearanceRig();
      await rig.apply(galleryDoc('Lilac'), const FileThemeSource());
      await rig.pump(tester);

      expect(find.text('NOT SAVED'), findsOneWidget);
      expect(_action('Save to Mine'), findsOneWidget);
    });

    testWidgets('Save to Mine keeps a Space theme, which is then edited', (
      tester,
    ) async {
      final rig = _withDefault();
      await rig.apply(_pine, const SpaceThemeSource('pine'));
      await rig.pump(tester);

      expect(find.text('In use · Space, by Ren'), findsOneWidget);
      await _tap(tester, _action('Save to Mine'));

      final mine = rig.container.read(myThemesProvider);
      expect(mine, hasLength(1));
      expect(
        rig.container.read(customThemeSourceProvider),
        MineThemeSource(mine.single.id),
      );
      expect(find.text('In use · Mine'), findsOneWidget);
      expect(_action('Edit'), findsOneWidget);
    });

    testWidgets('a followed default hides Save to Mine once Mine has it', (
      tester,
    ) async {
      final rig = _withDefault();
      await rig.choose(AppThemeChoice.spaceDefault);
      await rig.pump(tester);

      expect(find.text('In use · Space default, by Ren'), findsOneWidget);
      await _tap(tester, _action('Save to Mine'));

      expect(rig.container.read(myThemesProvider), hasLength(1));
      expect(
        rig.container.read(themeControllerProvider),
        AppThemeChoice.spaceDefault,
      );
      expect(_key(AppearanceThemeCard.actionKey), findsNothing);
    });
  });

  group('Browse themes', () {
    testWidgets('opens Themes beside the nav on a laptop', (tester) async {
      await AppearanceRig().pump(tester);

      await _tap(tester, _key(AppearanceThemeCard.browseKey));

      expect(find.byKey(const Key('themes-page-list')), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget, reason: 'the nav stays');
      expect(find.byTooltip('Back to Appearance'), findsOneWidget);
    });

    testWidgets('opens Themes under its app bar on a phone', (tester) async {
      await AppearanceRig().pump(tester, size: appearancePhone);

      await _tap(tester, _key(AppearanceThemeCard.browseKey));

      expect(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is AppBar),
          matching: find.text('Themes'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Back to Appearance'), findsOneWidget);
    });
  });

  group('Follow Space default', () {
    testWidgets('is absent when the Space has no default', (tester) async {
      await AppearanceRig().pump(tester);
      expect(find.text(AppearanceThemeCard.followLabel), findsNothing);
    });

    testWidgets('on follows the default; off keeps it, nothing repaints', (
      tester,
    ) async {
      final rig = _withDefault();
      await rig.choose(AppThemeChoice.dark);
      await rig.pump(tester);

      expect(
        find.text('Use Pine at dusk and keep up with its changes.'),
        findsOneWidget,
      );
      final toggle = _toggle(AppearanceThemeCard.followLabel);
      await _tap(tester, toggle);
      expect(
        rig.container.read(themeControllerProvider),
        AppThemeChoice.spaceDefault,
      );

      final background = rig.container.read(appBackgroundControllerProvider);
      await _tap(tester, toggle);
      expect(
        rig.container.read(themeControllerProvider),
        AppThemeChoice.custom,
      );
      expect(
        rig.container.read(customThemeSourceProvider),
        const SpaceThemeSource('pine'),
      );
      expect(
        rig.container.read(customThemeProvider)!.tokens,
        _pine.tokens,
        reason: 'the same colours, so nothing repaints',
      );
      expect(rig.container.read(appBackgroundControllerProvider), background);
      expect(find.text('In use · Space, by Ren'), findsOneWidget);
    });
  });

  testWidgets('High contrast is on the card and repaints the preview', (
    tester,
  ) async {
    final rig = AppearanceRig();
    await rig.choose(AppThemeChoice.dark);
    await rig.pump(tester);

    final toggle = _toggle('High contrast');
    await _tap(tester, toggle);

    expect(rig.container.read(highContrastControllerProvider), isTrue);
    expect(_heroTokens(tester), applyHighContrast(AppTokens.dark));
  });
}

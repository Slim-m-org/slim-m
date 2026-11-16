// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Themes gallery (decision 0106): applying each kind of theme, the In use
/// card, who sees what in a card's menu, the confirms, broken Space themes,
/// and the source filter.
library;

import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/resolved_theme.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_gallery_menu.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_gallery_rig.dart';

Finder _key(String key) => find.byKey(Key(key));

/// The card's own node, the one that says selected and why it is disabled.
SemanticsNode _card(WidgetTester tester, String key) => tester.getSemantics(
  find
      .descendant(
        of: _key(key),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.selected != null,
        ),
      )
      .first,
);

bool _selected(WidgetTester tester, String key) =>
    _card(tester, key).flagsCollection.isSelected == Tristate.isTrue;

Future<void> _openMenu(WidgetTester tester, String key) =>
    tapAndSettle(tester, _key(key));

Future<void> _dismissMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(2, 2));
  await settleGallery(tester);
}

void main() {
  testWidgets('tapping a built-in, a Mine and a Space theme applies each', (
    tester,
  ) async {
    final rig = GalleryRig();
    await rig.pump(tester);
    final c = rig.container;

    await tapAndSettle(tester, _key('theme-builtin-forest'));
    expect(c.read(themeControllerProvider), AppThemeChoice.forest);

    final id = await c.read(myThemesProvider.notifier).save(galleryDoc('Fir'));
    await settleGallery(tester);
    await tapAndSettle(tester, _key('theme-mine-$id'));
    expect(c.read(themeControllerProvider), AppThemeChoice.custom);
    expect(c.read(customThemeSourceProvider), MineThemeSource(id!));

    await tapAndSettle(tester, _key('theme-store-t1'));
    expect(c.read(customThemeProvider)!.name, 'Pine');
    expect(c.read(customThemeSourceProvider), const SpaceThemeSource('t1'));
  });

  testWidgets('the applied card is selected, whatever its source', (
    tester,
  ) async {
    final rig = GalleryRig();
    await rig.pump(tester);
    final handle = tester.ensureSemantics();

    expect(_selected(tester, 'theme-store-t1'), isFalse);
    await tapAndSettle(tester, _key('theme-store-t1'));
    expect(_selected(tester, 'theme-store-t1'), isTrue);
    expect(find.text('In use'), findsOneWidget);

    await tapAndSettle(tester, _key('theme-builtin-dark'));
    expect(_selected(tester, 'theme-store-t1'), isFalse);
    expect(_selected(tester, 'theme-builtin-dark'), isTrue);
    handle.dispose();
  });

  testWidgets('System is in use while following a Space with no default', (
    tester,
  ) async {
    final rig = GalleryRig();
    await rig.pump(tester);
    final handle = tester.ensureSemantics();
    expect(
      rig.container.read(themeControllerProvider),
      AppThemeChoice.spaceDefault,
    );
    expect(_selected(tester, 'theme-builtin-system'), isTrue);
    expect(find.byKey(const Key('theme-store-default-badge')), findsNothing);
    handle.dispose();
  });

  testWidgets('the followed Space default is one card, tagged and in use', (
    tester,
  ) async {
    final rig = GalleryRig(defaultId: 't1');
    await rig.pump(tester);
    final handle = tester.ensureSemantics();

    expect(_selected(tester, 'theme-store-t1'), isTrue);
    expect(_selected(tester, 'theme-builtin-system'), isFalse);
    expect(find.byKey(const Key('theme-store-default-badge')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Space default')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('built-ins have a pencil, no kebab, and System has neither', (
    tester,
  ) async {
    await GalleryRig().pump(tester);
    expect(_key('theme-customise-system'), findsNothing);
    expect(_key('theme-customise-forest'), findsOneWidget);
    expect(find.bySemanticsLabel('Customise Forest'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^More for ')), findsNWidgets(2));
  });

  testWidgets('a member may copy any Space theme and remove only their own', (
    tester,
  ) async {
    await GalleryRig().pump(tester);

    await _openMenu(tester, 'theme-menu-t1');
    expect(find.text('Edit a copy'), findsOneWidget);
    expect(find.text('Set as Space default'), findsNothing);
    expect(find.text('Remove'), findsNothing);
    await _dismissMenu(tester);

    await _openMenu(tester, 'theme-menu-t2');
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('an administrator removes any theme and sets the default', (
    tester,
  ) async {
    final rig = GalleryRig(permissions: Perm.manageServer, defaultId: 't1');
    await rig.pump(tester);

    await _openMenu(tester, 'theme-menu-t1');
    expect(find.text('Clear default'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    await _dismissMenu(tester);

    await _openMenu(tester, 'theme-menu-t2');
    await tapAndSettle(tester, find.text('Set as Space default'));
    expect(rig.calls, contains('PUT /space/default-theme'));
    expect(rig.lastBody, {'theme_id': 't2'});
  });

  testWidgets('Remove asks first, and Cancel sends nothing', (tester) async {
    final rig = GalleryRig(permissions: Perm.manageServer);
    await rig.pump(tester);

    await _openMenu(tester, 'theme-menu-t1');
    await tapAndSettle(tester, find.text('Remove'));
    expect(find.text('Remove Pine for everyone?'), findsOneWidget);
    expect(find.text('People using it keep their copy.'), findsOneWidget);
    await tapAndSettle(tester, find.text('Cancel'));
    expect(rig.calls.where((c) => c.startsWith('DELETE')), isEmpty);

    await _openMenu(tester, 'theme-menu-t1');
    await tapAndSettle(tester, find.text('Remove'));
    await tapAndSettle(tester, find.byKey(ThemeGalleryMenu.confirmKey));
    expect(rig.calls, contains('DELETE /space/themes/t1'));
  });

  testWidgets('Delete asks first, and Cancel keeps the theme', (tester) async {
    final rig = GalleryRig();
    await rig.pump(tester);
    final mine = rig.container.read(myThemesProvider.notifier);
    final id = await mine.save(galleryDoc('Harbour'));
    await settleGallery(tester);

    await _openMenu(tester, 'theme-mine-$id-menu');
    await tapAndSettle(tester, find.text('Delete'));
    expect(find.text('Delete Harbour?'), findsOneWidget);
    expect(find.text('This device holds the only copy.'), findsOneWidget);
    await tapAndSettle(tester, find.text('Cancel'));
    expect(rig.container.read(myThemesProvider), hasLength(1));

    await _openMenu(tester, 'theme-mine-$id-menu');
    await tapAndSettle(tester, find.text('Delete'));
    await tapAndSettle(tester, find.byKey(ThemeGalleryMenu.confirmKey));
    expect(rig.container.read(myThemesProvider), isEmpty);
  });

  testWidgets('a removal that never reached the server says so in words', (
    tester,
  ) async {
    final rig = GalleryRig(permissions: Perm.manageServer, deletesDrop: true);
    await rig.pump(tester);

    await _openMenu(tester, 'theme-menu-t1');
    await tapAndSettle(tester, find.text('Remove'));
    await tapAndSettle(tester, find.byKey(ThemeGalleryMenu.confirmKey));

    expect(
      find.text(
        'Could not remove the theme: the server could not be reached. '
        'Nothing was changed.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('DELETE'), findsNothing);
  });

  testWidgets('right-click opens the menu at the pointer, untitled', (
    tester,
  ) async {
    await GalleryRig().pump(tester, size: const Size(1280, 1600));
    final at = tester.getCenter(_key('theme-store-t1'));
    await tester.tapAt(at, buttons: kSecondaryButton);
    await settleGallery(tester);

    final item = tester.getTopLeft(find.text('Edit a copy'));
    expect((item - at).distance, lessThan(64));
    expect(find.text('Space · by Ren'), findsNothing);
  });

  testWidgets('a long-press on a phone opens a sheet titled with the theme', (
    tester,
  ) async {
    await GalleryRig(defaultId: 't1').pump(tester, size: const Size(390, 844));
    await tester.scrollUntilVisible(_key('theme-store-t1'), 200);
    await tester.longPress(_key('theme-store-t1'));
    await settleGallery(tester);

    expect(find.text('Space default · by Ren'), findsOneWidget);
    expect(find.text('Edit a copy'), findsOneWidget);
  });

  testWidgets('a Space theme that fails contrast says why and does nothing', (
    tester,
  ) async {
    final rig = GalleryRig(
      themes: [
        stored('p1', 'Paper', author: 'ren', file: failingFile('Paper')),
      ],
    );
    await rig.pump(tester);
    final handle = tester.ensureSemantics();

    expect(find.textContaining('Fails a contrast check.'), findsOneWidget);
    final node = _card(tester, 'theme-store-p1');
    expect(node.label, contains('fails a contrast check'));
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);
    await tapAndSettle(tester, _key('theme-store-p1'));
    expect(
      rig.container.read(themeControllerProvider),
      AppThemeChoice.spaceDefault,
    );
    handle.dispose();

    await _openMenu(tester, 'theme-menu-p1');
    await tapAndSettle(tester, find.text('Edit a copy'));
    expect(find.text('Paper copy'), findsOneWidget);
    expect(_key('theme-contrast-panel'), findsOneWidget);
    expect(_key('theme-contrast-ok'), findsNothing);
  });

  testWidgets('a Space theme that cannot be read says so', (tester) async {
    await GalleryRig(
      themes: [
        stored('u1', 'Scrap', author: 'self', file: {'format': 'slimm-theme'}),
      ],
    ).pump(tester);
    expect(find.textContaining('Cannot be read.'), findsOneWidget);
    await _openMenu(tester, 'theme-menu-u1');
    expect(find.text('Edit a copy'), findsNothing);
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('a Space theme with a picture shows it in the miniature', (
    tester,
  ) async {
    final rig = GalleryRig(
      themes: [stored('p1', 'Photo', author: 'ren', picture: true)],
    );
    await rig.pump(tester);
    expect(rig.calls, contains('GET /space/themes/p1/picture'));
    expect(
      find.descendant(
        of: _key('theme-store-p1'),
        matching: find.byWidgetPredicate(
          (w) => w is Image && w.image is ResizeImage,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the filter shows one section at a time', (tester) async {
    await GalleryRig().pump(tester);
    await tapAndSettle(tester, find.text('Space').first);
    expect(_key('theme-builtin-dark'), findsNothing);
    expect(_key('theme-store-t1'), findsOneWidget);
    expect(_key('theme-new'), findsNothing);

    await tapAndSettle(tester, find.text('Mine').first);
    expect(_key('theme-new'), findsOneWidget);
    expect(_key('theme-store-t1'), findsNothing);

    await tapAndSettle(tester, find.text('All'));
    expect(_key('theme-builtin-dark'), findsOneWidget);
  });

  testWidgets('while an action runs every card and button waits', (
    tester,
  ) async {
    final rig = GalleryRig()..pickGate = Completer();
    await rig.pump(tester);
    final handle = tester.ensureSemantics();
    await tapAndSettle(tester, _key('theme-import'));

    expect(
      _card(tester, 'theme-builtin-forest').flagsCollection.isEnabled,
      Tristate.isFalse,
    );
    for (final label in ['Customise Forest', 'More for Pine', 'New']) {
      final button = tester.getSemantics(find.bySemanticsLabel(label));
      expect(button.flagsCollection.isEnabled, Tristate.isFalse, reason: label);
    }
    await tapAndSettle(tester, _key('theme-builtin-forest'));
    expect(
      rig.container.read(themeControllerProvider),
      AppThemeChoice.spaceDefault,
    );

    rig.pickGate!.complete(null);
    await settleGallery(tester);
    expect(
      _card(tester, 'theme-builtin-forest').flagsCollection.isEnabled,
      Tristate.isTrue,
    );
    handle.dispose();
  });

  testWidgets('a store that will not load shows one error with Retry', (
    tester,
  ) async {
    await GalleryRig(storeFails: true).pump(tester);
    expect(_key('themes-store-error'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  test('a custom or Space default document is what the choice paints with', () {
    final doc = galleryDoc('Pine');
    for (final choice in [AppThemeChoice.custom, AppThemeChoice.spaceDefault]) {
      final resolved = resolveTheme(
        choice,
        custom: choice == AppThemeChoice.custom ? doc : null,
        spaceDefault: choice == AppThemeChoice.spaceDefault ? doc : null,
      );
      expect(resolved.dark.surfaceBase, doc.tokens.surfaceBase);
      expect(resolved.mode, ThemeMode.dark);
    }
    final missing = resolveTheme(AppThemeChoice.spaceDefault);
    expect(missing.mode, ThemeMode.system);
    expect(missing.dark.surfaceBase, AppTokens.dark.surfaceBase);
  });
}

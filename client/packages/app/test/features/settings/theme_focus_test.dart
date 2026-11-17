// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keyboard focus on Themes and Appearance stays on the card, tile or button
/// that started an action, while it runs and after it ends.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/recent_themes.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/widgets/appearance_theme_card.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_gallery_frame.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'appearance_rig.dart';
import 'theme_gallery_rig.dart';

/// Preferences whose writes wait for [gate], as a disk does.
class _SlowStore extends InMemorySharedPreferencesStore {
  _SlowStore() : super.empty();

  Completer<void>? gate;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await gate?.future;
    return super.setValue(valueType, key, value);
  }
}

/// The node the card, tile or button at [finder] takes focus with.
FocusNode _nodeOf(WidgetTester tester, Finder finder) {
  final frame = find.descendant(
    of: finder,
    matching: find.byWidgetPredicate((w) => w is ThemeCardFrame),
  );
  final inner = frame.evaluate().isNotEmpty
      ? frame
      : find
            .descendant(
              of: finder,
              matching: find.byWidgetPredicate((w) => w is GestureDetector),
            )
            .first;
  return Focus.of(tester.element(inner));
}

/// Presses Enter on [finder], checks focus mid-action, then lets [release]
/// end the action.
Future<FocusNode> _enterOn(
  WidgetTester tester,
  Finder finder, {
  required void Function() release,
}) async {
  final node = _nodeOf(tester, finder)..requestFocus();
  await tester.pump();
  expect(node.hasPrimaryFocus, isTrue, reason: 'focused before Enter');
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  expect(node.hasPrimaryFocus, isTrue, reason: 'still focused while busy');
  release();
  await settleGallery(tester);
  return node;
}

final _photo = stored('p1', 'Photo', author: 'ren', picture: true);

void main() {
  testWidgets('Enter on a gallery card applies it and keeps focus there', (
    tester,
  ) async {
    final rig = GalleryRig(themes: [_photo])..pictureGate = Completer();
    await rig.pump(tester);
    final card = find.byKey(const Key('theme-store-p1'));
    await revealInGallery(tester, card);

    final node = await _enterOn(
      tester,
      card,
      release: () => rig.pictureGate!.complete(),
    );

    expect(
      rig.container.read(customThemeSourceProvider),
      isA<SpaceThemeSource>(),
    );
    expect(node.hasPrimaryFocus, isTrue);
  });

  testWidgets('Enter on Import keeps focus there while the file is chosen', (
    tester,
  ) async {
    final rig = GalleryRig()..pickGate = Completer();
    await rig.pump(tester);
    final import = find.byKey(const Key('theme-import'));
    await revealInGallery(tester, import);

    final node = await _enterOn(
      tester,
      import,
      release: () => rig.pickGate!.complete(null),
    );

    expect(node.hasPrimaryFocus, isTrue);
  });

  testWidgets('Enter on a Recent tile applies it and keeps focus there', (
    tester,
  ) async {
    final rig = AppearanceRig(themes: [_photo]);
    await rig.recent([const RecentTheme(source: SpaceThemeSource('p1'))]);
    await rig.choose(AppThemeChoice.dark);
    rig.gallery.pictureGate = Completer();
    await rig.pump(tester);
    final tile = find.byKey(const Key('recent-theme-space:p1'));
    await revealOnAppearance(tester, tile);

    final node = await _enterOn(
      tester,
      tile,
      release: () => rig.gallery.pictureGate!.complete(),
    );

    expect(
      rig.container.read(customThemeSourceProvider),
      const SpaceThemeSource('p1'),
    );
    expect(node.hasPrimaryFocus, isTrue);
  });

  testWidgets('Enter on a Recent tile keeps focus as it moves to the front', (
    tester,
  ) async {
    final rig = AppearanceRig();
    await rig.recent([
      const RecentTheme(source: BuiltInThemeSource(AppThemeChoice.light)),
    ]);
    await rig.choose(AppThemeChoice.dark);
    await rig.pump(tester);
    final tile = find.byKey(const Key('recent-theme-builtin:light'));
    await revealOnAppearance(tester, tile);

    final node = await _enterOn(tester, tile, release: () {});

    expect(rig.container.read(themeControllerProvider), AppThemeChoice.light);
    expect(node.hasPrimaryFocus, isTrue);
  });

  testWidgets('Enter on Save to Mine keeps focus on what becomes Edit', (
    tester,
  ) async {
    final rig = AppearanceRig();
    final store = _SlowStore();
    SharedPreferencesStorePlatform.instance = store;
    await rig.apply(galleryDoc('Lilac'), const FileThemeSource());
    await rig.pump(tester);
    final action = find.byKey(AppearanceThemeCard.actionKey);
    await revealOnAppearance(tester, action);
    store.gate = Completer();

    final node = await _enterOn(
      tester,
      action,
      release: () => store.gate!.complete(),
    );

    expect(rig.container.read(myThemesProvider), hasLength(1));
    expect(
      find.descendant(of: action, matching: find.text('Edit')),
      findsOneWidget,
    );
    expect(node.hasPrimaryFocus, isTrue);
  });
}

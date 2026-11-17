// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Recent row on Appearance: the theme in use first and marked, the last
/// few applied after it, one tap to apply, and with a pointer a preview in the
/// hero that repaints nothing else.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/recent_themes.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/widgets/appearance_theme_card.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_miniature.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'appearance_rig.dart';
import 'theme_gallery_rig.dart';

Finder _tile(ThemeSource source) =>
    find.byKey(Key('recent-theme-${source.key}'));

const _dark = BuiltInThemeSource(AppThemeChoice.dark);
const _light = BuiltInThemeSource(AppThemeChoice.light);

final _tiles = find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('recent-theme-'),
);

AppTokens _hero(WidgetTester tester) => tester
    .widget<ThemeMiniature>(find.byKey(AppearanceThemeCard.heroKey))
    .tokens;

/// Dark in use, with five more applied before it, one since deleted.
Future<AppearanceRig> _rig(WidgetTester tester, {Size? size}) async {
  final rig = AppearanceRig(
    themes: [stored('pine', 'Pine at dusk', author: 'ada')],
  );
  final harbour = await rig.keep(galleryDoc('Harbour'));
  await rig.recent([
    const RecentTheme(source: _light),
    RecentTheme(source: MineThemeSource(harbour)),
    const RecentTheme(source: MineThemeSource('deleted')),
    const RecentTheme(source: SpaceThemeSource('pine')),
    const RecentTheme(source: BuiltInThemeSource(AppThemeChoice.forest)),
  ]);
  await rig.choose(AppThemeChoice.dark);
  await rig.pump(tester, size: size ?? appearanceWide);
  await revealOnAppearance(tester, find.text('RECENT'));
  return rig;
}

List<String> _order(WidgetTester tester) {
  final tiles = _tiles.evaluate().toList()
    ..sort(
      (a, b) => tester
          .getTopLeft(find.byWidget(a.widget))
          .dx
          .compareTo(tester.getTopLeft(find.byWidget(b.widget)).dx),
    );
  return [
    for (final t in tiles)
      (t.widget.key! as ValueKey<String>).value.substring(
        'recent-theme-'.length,
      ),
  ];
}

void main() {
  testWidgets('five tiles on a laptop: the theme in use first, marked', (
    tester,
  ) async {
    await _rig(tester);

    final order = _order(tester);
    expect(order, hasLength(5));
    expect(order.first, _dark.key);
    expect(order, isNot(contains('mine:deleted')));
    expect(order, contains('space:pine'));
    expect(find.bySemanticsLabel('Dark, in use'), findsOneWidget);
  });

  testWidgets('four tiles on a phone', (tester) async {
    await _rig(tester, size: appearancePhone);
    expect(_order(tester), hasLength(4));
  });

  testWidgets('nothing but the theme in use shows no Recent row', (
    tester,
  ) async {
    final rig = AppearanceRig();
    await rig.choose(AppThemeChoice.dark);
    await rig.pump(tester);
    expect(find.text('RECENT'), findsNothing);
  });

  testWidgets('a tap applies a tile and moves it to the front', (tester) async {
    final rig = await _rig(tester);

    await tester.tap(_tile(_light));
    await settleGallery(tester);

    expect(rig.container.read(themeControllerProvider), AppThemeChoice.light);
    expect(_order(tester).take(2), [_light.key, _dark.key]);
  });

  testWidgets('a touch applies with no preview on the way', (tester) async {
    final rig = await _rig(tester);

    final touch = await tester.startGesture(tester.getCenter(_tile(_light)));
    await tester.pump();
    expect(find.textContaining('Previewing'), findsNothing);
    await touch.up();
    await settleGallery(tester);

    expect(rig.container.read(themeControllerProvider), AppThemeChoice.light);
    expect(find.textContaining('Previewing'), findsNothing);
  });

  group('with a pointer', () {
    late TestGesture mouse;

    Future<void> point(WidgetTester tester) async {
      mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
    }

    testWidgets('resting on a tile previews it in the hero alone', (
      tester,
    ) async {
      await _rig(tester);
      await point(tester);
      expect(_hero(tester), AppTokens.dark);

      final outside = <String>[];
      var inside = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        var hero = element.widget.key == AppearanceThemeCard.heroHostKey;
        element.visitAncestorElements((a) {
          if (a.widget.key == AppearanceThemeCard.heroHostKey) hero = true;
          return !hero;
        });
        hero ? inside++ : outside.add('${element.widget.runtimeType}');
      };
      await mouse.moveTo(tester.getCenter(_tile(_light)));
      await tester.pump();
      debugOnRebuildDirtyWidget = null;

      expect(find.text('Previewing Light'), findsOneWidget);
      expect(_hero(tester), AppTokens.light);
      expect(inside, greaterThan(0));
      expect(outside, isEmpty, reason: 'only the hero repaints');

      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(find.textContaining('Previewing'), findsNothing);
      expect(_hero(tester), AppTokens.dark);
    });

    testWidgets('resting on the tile in use previews nothing', (tester) async {
      await _rig(tester);
      await point(tester);
      await mouse.moveTo(tester.getCenter(_tile(_dark)));
      await tester.pump();
      expect(find.textContaining('Previewing'), findsNothing);
    });

    testWidgets('a click applies, and the row reordering under a still '
        'pointer previews nothing', (tester) async {
      final rig = await _rig(tester);
      await point(tester);
      await mouse.moveTo(tester.getCenter(_tile(_light)));
      await tester.pump();

      await mouse.down(tester.getCenter(_tile(_light)));
      await mouse.up();
      await settleGallery(tester);

      expect(rig.container.read(themeControllerProvider), AppThemeChoice.light);
      expect(find.textContaining('Previewing'), findsNothing);

      await mouse.moveBy(const Offset(1, 0));
      await tester.pump();
      expect(find.text('Previewing Dark'), findsOneWidget);
    });
  });

  testWidgets('the keyboard on a tile previews it too', (tester) async {
    await _rig(tester);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );

    final inside = find
        .descendant(
          of: _tile(_light),
          matching: find.byWidgetPredicate((w) => w is GestureDetector),
        )
        .first;
    Focus.of(tester.element(inside)).requestFocus();
    await tester.pump();

    expect(find.text('Previewing Light'), findsOneWidget);
  });
}

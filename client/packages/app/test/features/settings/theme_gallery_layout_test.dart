// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gallery's geometry, measured: three columns beside the nav and two on a
/// phone, names on one edge in every section, the Space default on the text
/// line, Mine's buttons centred on its title, and a lazy, steady grid.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_miniature.dart';

import 'theme_gallery_rig.dart';

const _laptop = Size(1280, 1600);
const _phone = Size(390, 844);

Finder _key(String key) => find.byKey(Key(key));

Finder _miniatures() => find.byWidgetPredicate((w) => w is ThemeMiniature);

/// The distinct left edges of the built-in cards.
Set<double> _columns(WidgetTester tester) => {
  for (final name in ['system', 'dark', 'softDark', 'light'])
    tester.getTopLeft(_key('theme-builtin-$name')).dx,
};

Future<void> _withMine(GalleryRig rig, WidgetTester tester) async {
  final mine = rig.container.read(myThemesProvider.notifier);
  await mine.save(galleryDoc('Same'));
  await settleGallery(tester);
}

void main() {
  for (final (size, columns) in [(_laptop, 3), (_phone, 2)]) {
    testWidgets('${size.width.toInt()} wide shows $columns columns', (
      tester,
    ) async {
      await GalleryRig().pump(tester, size: size);
      expect(_columns(tester), hasLength(columns));
      final first = tester.getRect(_key('theme-builtin-system'));
      final second = tester.getRect(_key('theme-builtin-dark'));
      expect(second.left - first.right, 12);
    });

    testWidgets('names start at one x at ${size.width.toInt()}', (
      tester,
    ) async {
      final rig = GalleryRig(
        defaultId: 't1',
        themes: [stored('t1', 'Same'), stored('t2', 'Same')],
      );
      await rig.pump(tester, size: const Size(1280, 2400));
      await _withMine(rig, tester);
      final names = find.text('Same');
      expect(names, findsNWidgets(3));
      final lefts = <double>{};
      for (final element in names.evaluate()) {
        final card = find.ancestor(
          of: find.byElementPredicate((e) => e == element),
          matching: find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('theme-'),
          ),
        );
        lefts.add(
          tester.getTopLeft(find.byElementPredicate((e) => e == element)).dx -
              tester.getTopLeft(card.first).dx,
        );
      }
      expect(lefts, hasLength(1));
      final builtIn = tester.getTopLeft(find.text('System')).dx;
      final first = tester.getTopLeft(_key('theme-builtin-system')).dx;
      expect(builtIn - first, lefts.single);
    });
  }

  testWidgets('the Space default tag leaves the name its full width', (
    tester,
  ) async {
    await GalleryRig(
      defaultId: 't1',
      themes: [stored('t1', 'Same'), stored('t2', 'Same')],
    ).pump(tester);
    final [tagged, plain] = [
      for (final e in find.text('Same').evaluate())
        (e.renderObject! as RenderBox).size,
    ];
    expect(tagged, plain);
  });

  testWidgets('the Space default is said on the text line, off the miniature', (
    tester,
  ) async {
    await GalleryRig(defaultId: 't1').pump(tester);
    final card = tester.getRect(_key('theme-store-t1'));
    final tag = tester.getRect(_key('theme-store-default-badge'));
    expect(
      tag.top,
      greaterThan(card.top + card.width / ThemeMiniatureGeometry.aspect),
    );
    expect(tag.bottom, lessThanOrEqualTo(card.bottom));
  });

  testWidgets('a card that fails contrast leads its line with its mode too', (
    tester,
  ) async {
    await GalleryRig(
      themes: [
        stored('t1', 'Fine'),
        stored('t2', 'Faint', file: failingFile('Faint')),
      ],
    ).pump(tester);
    double lead(String id) {
      final line = find.descendant(
        of: _key('theme-store-$id'),
        matching: find.text('By Ren'),
      );
      return tester.getTopLeft(line).dx -
          tester.getTopLeft(_key('theme-store-$id')).dx;
    }

    expect(lead('t2'), lead('t1'));
  });

  for (final size in [_laptop, _phone]) {
    testWidgets('Mine buttons are centred on its title at ${size.width}', (
      tester,
    ) async {
      await GalleryRig().pump(tester, size: size);
      await revealInGallery(tester, _key('theme-import'));
      final header = find
          .ancestor(
            of: _key('theme-import'),
            matching: find.byWidgetPredicate((w) => w is Row),
          )
          .first;
      final title = tester
          .getCenter(find.descendant(of: header, matching: find.text('Mine')))
          .dy;
      expect(tester.getCenter(_key('theme-import')).dy, closeTo(title, 0.5));
      expect(tester.getCenter(_key('theme-new')).dy, closeTo(title, 0.5));
      final gap =
          tester.getTopLeft(_key('theme-new')).dx -
          tester.getTopRight(_key('theme-import')).dx;
      expect(gap, 8);
    });
  }

  testWidgets('fifty Space themes on a phone build only what is near', (
    tester,
  ) async {
    await GalleryRig(
      themes: [for (var i = 0; i < 50; i++) stored('s$i', 'Theme $i')],
    ).pump(tester, size: _phone);
    expect(_miniatures().evaluate().length, lessThan(58));
    expect(_key('theme-store-s49'), findsNothing);
  });

  testWidgets('applying one card rebuilds no miniature', (tester) async {
    await GalleryRig().pump(tester, size: _laptop);
    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is ThemeMiniature) rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    await tapAndSettle(tester, _key('theme-builtin-forest'));
    await tapAndSettle(tester, _key('theme-builtin-light'));
    expect(rebuilt, 0);
  });
}

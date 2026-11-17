// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme miniature paints with the theme it shows, never the one around
/// it, read from its pixels; the text details show what each surface needs.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_miniature.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_miniature_painter.dart';
import 'package:slimm_design_system/design_system.dart';

const _boundary = Key('mini-boundary');
const _bars = Size(320, 200);

const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Future<void> _pump(WidgetTester tester, Widget child, {double width = 320}) {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: RepaintBoundary(key: _boundary, child: child),
          ),
        ),
      ),
    ),
  );
}

/// The colour at each of [points], read from the miniature's own pixels.
Future<List<Color>> _pixels(WidgetTester tester, List<Offset> points) async {
  late List<Color> colours;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_boundary),
    );
    final image = await boundary.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    colours = [
      for (final p in points)
        () {
          final i = (p.dy.round() * image.width + p.dx.round()) * 4;
          return Color.fromARGB(
            data.getUint8(i + 3),
            data.getUint8(i),
            data.getUint8(i + 1),
            data.getUint8(i + 2),
          );
        }(),
    ];
    image.dispose();
  });
  return colours;
}

Matcher _near(Color expected) => predicate<Color>(
  (c) =>
      (c.r - expected.r).abs() * 255 <= 2 &&
      (c.g - expected.g).abs() * 255 <= 2 &&
      (c.b - expected.b).abs() * 255 <= 2,
  'near ${expected.toARGB32().toRadixString(16)}',
);

void main() {
  testWidgets('bars paint the theme shown, not the theme around them', (
    tester,
  ) async {
    const t = AppTokens.forest;
    await _pump(tester, const ThemeMiniature(tokens: t));

    final row = ThemeMiniatureGeometry.selectedRow(_bars);
    final send = ThemeMiniatureGeometry.send(_bars);
    final colours = await _pixels(tester, [
      Offset(row.right - 3, row.center.dy),
      Offset(row.left + 0.96, row.center.dy),
      send.center,
      Offset(_bars.width - 3, _bars.height / 2),
      Offset(2, _bars.height - 2),
    ]);

    expect(colours[0], _near(t.accentSoft));
    expect(colours[1], _near(t.accent));
    expect(colours[2], _near(t.accentFill));
    expect(colours[3], _near(t.surfaceBase));
    expect(colours[4], _near(t.surfaceSunken));
  });

  testWidgets('System paints light with dark across the lower right', (
    tester,
  ) async {
    await _pump(
      tester,
      const ThemeMiniature(
        tokens: AppTokens.light,
        brightness: Brightness.light,
        split: AppTokens.dark,
      ),
    );

    final colours = await _pixels(tester, [
      const Offset(2, 2),
      Offset(_bars.width - 3, _bars.height / 2),
    ]);

    expect(colours[0], _near(AppTokens.light.surfaceSunken));
    expect(colours[1], _near(AppTokens.dark.surfaceBase));
  });

  testWidgets('a System hero shows both halves across the diagonal', (
    tester,
  ) async {
    await _pump(
      tester,
      const ThemeMiniature(
        tokens: AppTokens.light,
        split: AppTokens.dark,
        detail: ThemeMiniatureDetail.hero,
      ),
      width: 600,
    );

    final colours = await _pixels(tester, [
      const Offset(2, 170),
      const Offset(596, 120),
    ]);

    expect(colours[0], _near(AppTokens.light.surfaceSunken));
    expect(colours[1], _near(AppTokens.dark.surfaceBase));
  });

  testWidgets('a narrow hero shows only messages that fit whole', (
    tester,
  ) async {
    const hero = ThemeMiniature(
      tokens: AppTokens.forest,
      detail: ThemeMiniatureDetail.hero,
    );
    await _pump(tester, hero, width: 600);
    expect(find.text('Grace'), findsOneWidget);

    await _pump(tester, hero, width: 360);
    expect(find.text('Grace'), findsNothing);
    final box = tester.getRect(find.byKey(_boundary));
    final composer = tester.getRect(find.text('Message #general'));
    final ada = tester.getRect(
      find.textContaining('Release notes', findRichText: true),
    );
    expect(ada.bottom, lessThan(composer.top));
    expect(composer.bottom, lessThan(box.bottom));
  });

  testWidgets('a picture sits under the chat column only', (tester) async {
    final picture = MemoryImage(base64Decode(_pixelPng));
    await _pump(
      tester,
      ThemeMiniature(tokens: AppTokens.forest, picture: picture),
    );

    final image = tester.getRect(find.image(picture));
    expect(image.left, ThemeMiniatureGeometry.chatLeft(_bars.width));
    expect(image.right, _bars.width);
  });

  testWidgets('it stays out of semantics; the card around it names it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      Semantics(
        label: 'Forest',
        container: true,
        child: const ThemeMiniature(
          tokens: AppTokens.forest,
          detail: ThemeMiniatureDetail.hero,
        ),
      ),
      width: 600,
    );

    expect(find.bySemanticsLabel('Forest'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('general')), findsNothing);
    handle.dispose();
  });

  testWidgets('the hero shows a channel and one accent link', (tester) async {
    const t = AppTokens.forest;
    await _pump(
      tester,
      const ThemeMiniature(tokens: t, detail: ThemeMiniatureDetail.hero),
      width: 600,
    );

    expect(tester.getSize(find.byKey(_boundary)).height, 176);
    expect(find.text('general'), findsOneWidget);
    expect(find.text('Message #general'), findsOneWidget);
    final link = find.textContaining('Release notes', findRichText: true);
    TextSpan? accent;
    tester.widget<RichText>(link).text.visitChildren((span) {
      if (span is TextSpan && span.text == ' Release notes') accent = span;
      return accent == null;
    });
    expect(accent!.style!.color, t.accent);
    expect(tester.getTopLeft(find.text('Ada')).dx, 152 + 12);

    await _pump(
      tester,
      const ThemeMiniature(tokens: t, detail: ThemeMiniatureDetail.hero),
      width: 360,
    );
    expect(tester.getSize(find.byKey(_boundary)).height, 152);
    expect(tester.getTopLeft(find.text('Ada')).dx, 104 + 12);
  });

  testWidgets('the hero names the Space and centres each channel in its row', (
    tester,
  ) async {
    await _pump(
      tester,
      const ThemeMiniature(
        tokens: AppTokens.forest,
        detail: ThemeMiniatureDetail.hero,
      ),
      width: 600,
    );

    final space = tester.getRect(find.text('slim-m'));
    final rows = [
      for (final name in ['general', 'design', 'music'])
        (
          name: tester.getRect(find.text(name)),
          row: tester.getRect(
            find
                .ancestor(
                  of: find.text(name),
                  matching: find.byWidgetPredicate(
                    (w) => w is SizedBox && w.height == AppSizes.rowPointer,
                  ),
                )
                .first,
          ),
        ),
    ];
    expect(rows.first.row.top, greaterThanOrEqualTo(space.bottom + 8));
    for (final r in rows) {
      expect(r.name.center.dy, moreOrLessEquals(r.row.center.dy, epsilon: 1));
    }
  });

  testWidgets('the draft lists channels from 400 wide; the strip is short', (
    tester,
  ) async {
    const t = AppTokens.forest;
    const draft = ThemeMiniature(tokens: t, detail: ThemeMiniatureDetail.draft);
    await _pump(tester, draft, width: 420);
    expect(find.text('builds'), findsOneWidget);
    expect(find.text('Focused control'), findsOneWidget);

    await _pump(tester, draft, width: 380);
    expect(find.text('builds'), findsNothing);

    await _pump(
      tester,
      const ThemeMiniature(tokens: t, detail: ThemeMiniatureDetail.draftStrip),
      width: 420,
    );
    expect(find.text('builds'), findsNothing);
    expect(find.text('Reads well. The links are a bit dim.'), findsNothing);
    expect(find.text('Low battery'), findsOneWidget);
  });

  testWidgets('at a laptop the draft keeps to the mockup height, Low battery '
      'on the link line', (tester) async {
    const t = AppTokens.forest;
    await _pump(
      tester,
      const ThemeMiniature(tokens: t, detail: ThemeMiniatureDetail.draft),
      width: 868,
    );

    expect(tester.getSize(find.byKey(_boundary)).height, lessThan(232));
    expect(
      tester.getCenter(find.text('Low battery')).dy,
      closeTo(tester.getCenter(find.text('Delete failed')).dy, 1),
    );
  });

  test('the painter repaints only for different colours', () {
    const a = ThemeMiniaturePainter(tokens: AppTokens.forest);
    expect(
      a.shouldRepaint(const ThemeMiniaturePainter(tokens: AppTokens.forest)),
      isFalse,
    );
    expect(
      a.shouldRepaint(const ThemeMiniaturePainter(tokens: AppTokens.dark)),
      isTrue,
    );
  });
}

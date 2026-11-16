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
import 'package:slimm_app/src/providers/providers.dart' show AppThemeChoice;
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
    await _pump(tester, ThemeMiniature.forChoice(AppThemeChoice.system));

    final colours = await _pixels(tester, [
      const Offset(2, 2),
      Offset(_bars.width - 3, _bars.height / 2),
    ]);

    expect(colours[0], _near(AppTokens.light.surfaceSunken));
    expect(colours[1], _near(AppTokens.dark.surfaceBase));
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

  testWidgets('a label names it to a screen reader; none leaves it out', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      Column(
        children: [
          ThemeMiniature.forChoice(AppThemeChoice.forest, label: 'Forest'),
          ThemeMiniature.forChoice(AppThemeChoice.dark),
        ],
      ),
    );

    expect(find.bySemanticsLabel('Forest'), findsOneWidget);
    expect(find.bySemanticsLabel('Dark'), findsNothing);
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

  testWidgets('the draft lists channels from 400 wide; the strip is short', (
    tester,
  ) async {
    const t = AppTokens.forest;
    const draft = ThemeMiniature(tokens: t, detail: ThemeMiniatureDetail.draft);
    await _pump(tester, draft, width: 420);
    expect(find.text('builds'), findsOneWidget);
    expect(find.text('Focused control'), findsOneWidget);
    final low = tester.getRect(find.text('Low battery'));
    expect(
      low.top,
      greaterThan(tester.getRect(find.text('Delete failed')).bottom),
    );

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

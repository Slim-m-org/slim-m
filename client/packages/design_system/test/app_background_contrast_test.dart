// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A background picture must never take text on a pane below AA, measured on
/// the pixels the real painter and pane blend produce, in every theme.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

final _themes = <String, AppTokens>{
  'light': AppTokens.light,
  'dark': AppTokens.dark,
  'trueBlack': AppTokens.trueBlack,
  'mocha': AppTokens.mocha,
  'soft': AppTokens.soft,
  'forest': AppTokens.forest,
  'halloween': AppTokens.halloween,
};

Future<ui.Image> _solid(Color c) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    Paint()..color = c,
  );
  return rec.endRecording().toImage(8, 8);
}

Future<ui.Image> _painted(
  AppTokens t,
  Color picture,
  AppBackgroundStyle style,
) async {
  final src = await _solid(picture);
  final rec = ui.PictureRecorder();
  AppBackgroundPainter(
    image: src,
    style: style,
    base: t.surfaceBase,
  ).paint(ui.Canvas(rec), const Size(160, 100));
  return rec.endRecording().toImage(160, 100);
}

void main() {
  const worstColours = [Color(0xFF000000), Color(0xFFFFFFFF)];

  test('each theme reaches AA for primary and secondary text at its floor', () {
    for (final entry in _themes.entries) {
      final t = entry.value;
      final dim = minimumBackgroundDim(t);
      for (final (text, surface) in [
        (t.textPrimary, t.surfaceBase),
        (t.textPrimary, t.surfaceSunken),
        (t.textSecondary, t.surfaceBase),
        (t.textSecondary, t.surfaceSunken),
      ]) {
        final ratio = worstPaneContrast(t, text, surface, dim);
        expect(ratio, greaterThanOrEqualTo(4.49), reason: entry.key);
      }
    }
  });

  test('a wanted fade below the floor is raised to it', () {
    const t = AppTokens.light;
    expect(effectiveBackgroundDim(t, 0), minimumBackgroundDim(t));
    expect(effectiveBackgroundDim(t, 1), kBackgroundMaxDim);
  });

  test('a picture that stays inside a narrow range needs a lower floor', () {
    const t = AppTokens.dark;
    const dark = PictureRange(Color(0xFF101810), Color(0xFF305038));
    expect(
      minimumBackgroundDim(t, dark),
      lessThan(minimumBackgroundDim(t)),
    );
    expect(
      worstPaneContrast(t, t.textSecondary, t.surfaceSunken,
          minimumBackgroundDim(t, dark), dark),
      greaterThanOrEqualTo(4.49),
    );
  });

  testWidgets('painted pixels under real panes keep AA, vignette on or off', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final entry in _themes.entries) {
        final t = entry.value;
        for (final vignette in [true, false]) {
          final style = AppBackgroundStyle(
            dim: effectiveBackgroundDim(t, 0),
            vignette: vignette,
            blur: 0,
          );
          for (final picture in worstColours) {
            final img = await _painted(t, picture, style);
            final data = (await img.toByteData())!;
            var worst = double.infinity;
            for (var y = 0; y < img.height; y += 7) {
              for (var x = 0; x < img.width; x += 7) {
                final i = (y * img.width + x) * 4;
                final px = Color.fromARGB(
                  255,
                  data.getUint8(i),
                  data.getUint8(i + 1),
                  data.getUint8(i + 2),
                );
                for (final (text, surface) in [
                  (t.textPrimary, t.surfaceBase),
                  (t.textSecondary, t.surfaceBase),
                  (t.textSecondary, t.surfaceSunken),
                ]) {
                  final pane = Color.alphaBlend(
                    surface.withValues(alpha: kBackgroundPaneAlpha),
                    px,
                  );
                  final r = contrastRatio(text, pane);
                  if (r < worst) worst = r;
                }
              }
            }
            expect(worst, greaterThanOrEqualTo(4.4),
                reason: '${entry.key} vignette=$vignette over $picture');
          }
        }
      }
    });
  });

  testWidgets('PaneSurface is translucent in a scope and opaque outside', (
    tester,
  ) async {
    Color? seen;
    Widget probe() => Builder(
          builder: (context) {
            seen =
                AppBackgroundScope.paneColor(context, const Color(0xFF123456));
            return const SizedBox();
          },
        );
    await tester.pumpWidget(probe());
    expect(seen!.a, 1);
    await tester.pumpWidget(AppBackgroundScope.active(child: probe()));
    expect(seen!.a, closeTo(kBackgroundPaneAlpha, 0.01));
    await tester.pumpWidget(
      AppBackgroundScope.active(child: OpaquePanes(child: probe())),
    );
    expect(seen!.a, 1);
  });
}

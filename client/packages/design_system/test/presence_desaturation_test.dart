// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every presence state, proved distinguishable once the colour is gone.
///
/// `core_test.dart` already asserts the five states map to five different
/// [AppStatusShape] values, but that is the enum agreeing with itself: it
/// would still pass if two of the shapes painted the same pixels. This renders
/// each state through the real widget, converts the pixels to greyscale, and
/// compares the resulting silhouettes against each other, which is the form
/// the claim actually takes when a bug report arrives as a screenshot someone
/// took on a monochrome display or printed.
///
/// The comparison is on a binarised silhouette, not on grey levels, on purpose.
/// Two states painted the same shape in two different hues do differ in
/// greyscale, and treating that as a pass would be measuring the colour cue
/// this test exists to remove.
///
/// Machine-independent by default: the arithmetic runs everywhere, and only
/// the reference image is behind `--dart-define=SLIMM_GOLDENS=true`, for the
/// reason `golden_matrix_test.dart` gives at length.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

/// Large enough that the thinnest distinguishing mark (the 2px bar across the
/// appearing-offline ring, which deliberately does not scale) still lands on
/// enough pixels to count.
const double _dotSize = 48;

const _themes = <String, (Brightness, AppTokens)>{
  'light': (Brightness.light, AppTokens.light),
  'dark': (Brightness.dark, AppTokens.dark),
  'true_black': (Brightness.dark, AppTokens.trueBlack),
  'mocha': (Brightness.dark, AppTokens.mocha),
  'soft': (Brightness.dark, AppTokens.soft),
  'forest': (Brightness.dark, AppTokens.forest),
};

/// The luma coefficients of Rec. 709, matching [_greyscaleMatrix] so the
/// arithmetic here and the reference image describe the same conversion.
double _luma(double r, double g, double b) =>
    0.2126 * r + 0.7152 * g + 0.0722 * b;

const _greyscaleMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// How far a pixel's grey must sit from the surface's own grey to count as
/// part of the mark.
const double _inkThreshold = 0.15;

/// A pixel-by-pixel "is this ink" map of one presence state.
List<bool> _maskFrom(ByteData rgba, Color surface) {
  final background = _luma(surface.r, surface.g, surface.b);
  final mask = <bool>[];
  for (var i = 0; i < rgba.lengthInBytes; i += 4) {
    final grey = _luma(
      rgba.getUint8(i) / 255,
      rgba.getUint8(i + 1) / 255,
      rgba.getUint8(i + 2) / 255,
    );
    mask.add((grey - background).abs() > _inkThreshold);
  }
  return mask;
}

/// One state's ink map, taken from the pixels the real widget paints.
///
/// The surface is drawn inside the repaint boundary rather than behind it:
/// capturing the dot on its own leaves transparent pixels, which this then
/// reads as ink in a light theme and as background in a dark one, so the
/// answer would depend on which theme it was asked about.
Future<List<bool>> _silhouette(
  WidgetTester tester,
  AppPresence status,
  Brightness brightness,
  AppTokens tokens,
) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness, tokens),
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: tokens.surfaceBase,
            child: AppStatusDot(status: status, size: _dotSize),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  late List<bool> mask;
  // Rasterising is engine work the fake clock never finishes; leave its zone.
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    mask = _maskFrom(bytes!, tokens.surfaceBase);
  });
  return mask;
}

int _countInk(List<bool> mask) => mask.where((ink) => ink).length;

int _differing(List<bool> a, List<bool> b) {
  var count = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) count++;
  }
  return count;
}

/// The floor for two silhouettes counting as telling apart, as a share of the
/// dot's own box.
///
/// The tightest real pair is offline against appearing-offline, which differ
/// only by the bar struck across the ring; that measures at roughly 2.2% of
/// the box across all three themes, so 1% keeps half of it as headroom while
/// still failing outright for two states that paint the same shape.
const double _minDifference = 0.01;

/// A state whose mark covers less than this is not surviving greyscale at all,
/// whatever it looks like next to another one.
const double _minCoverage = 0.15;

Widget _strip(AppTokens tokens) {
  return ColoredBox(
    color: tokens.surfaceBase,
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(_greyscaleMatrix),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s16,
          children: [
            for (final status in AppStatusDot.shapeOf.keys)
              AppStatusDot(status: status, size: _dotSize),
          ],
        ),
      ),
    ),
  );
}

void main() {
  for (final theme in _themes.entries) {
    final (brightness, tokens) = theme.value;

    testWidgets('${theme.key}: every presence state survives greyscale',
        (tester) async {
      final area = (_dotSize * _dotSize).toInt();
      final masks = <AppPresence, List<bool>>{};
      for (final status in AppStatusDot.shapeOf.keys) {
        masks[status] = await _silhouette(tester, status, brightness, tokens);
      }

      for (final entry in masks.entries) {
        expect(entry.value, hasLength(area));
        final coverage = _countInk(entry.value) / area;
        expect(
          coverage,
          greaterThan(_minCoverage),
          reason: '${entry.key} all but disappears against ${theme.key}: its '
              'hue may differ from the surface while its grey does not',
        );
        expect(
          coverage,
          lessThan(1.0),
          reason: '${entry.key} fills its whole box, so it has no silhouette '
              'left to tell it from anything else',
        );
      }

      final states = AppStatusDot.shapeOf.keys.toList();
      for (var i = 0; i < states.length; i++) {
        for (var j = i + 1; j < states.length; j++) {
          final difference = _differing(masks[states[i]]!, masks[states[j]]!);
          expect(
            difference / area,
            greaterThan(_minDifference),
            reason: '${states[i]} and ${states[j]} paint the same silhouette, '
                'so only colour tells them apart and a greyscale screenshot '
                'loses one of them',
          );
        }
      }
    });

    testWidgets('${theme.key}: the desaturated strip looks the way it did',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness, tokens),
          home: Center(child: _strip(tokens)),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Reference images only where they were produced; see the library note.
      if (const bool.fromEnvironment('SLIMM_GOLDENS')) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/presence_desaturated_${theme.key}.png'),
        );
      }
    });
  }
}

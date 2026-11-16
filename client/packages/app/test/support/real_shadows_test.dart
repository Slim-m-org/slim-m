// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves `withRealShadows` actually produces a blurred shadow (a gradient,
/// not a hard step) and always leaves `debugDisableShadows` restored, by
/// sampling real rendered pixels rather than trusting the mechanism by
/// reading it.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'real_shadows.dart';

const _boundaryKey = Key('probe');

/// A white 100x60 card, `AppShadows.float`-shaped shadow (blur 64, offset
/// (0, 24)), inside a padded grey field wide enough for the shadow's own
/// blur radius to land fully inside the capture rather than being clipped
/// by the boundary's own bounds.
///
/// [nested] puts the card behind a repaint boundary of its own, as an
/// overlay's popover is, so only a repaint that reaches it shows the blur.
Future<RenderRepaintBoundary> _pumpCard(
  WidgetTester tester, {
  bool nested = false,
}) async {
  const card = DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white,
      boxShadow: [
        BoxShadow(
          color: Color(0x85000000),
          blurRadius: 64,
          offset: Offset(0, 24),
        ),
      ],
    ),
    child: SizedBox(width: 100, height: 60),
  );
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          key: _boundaryKey,
          child: Container(
            width: 300,
            height: 260,
            color: Colors.grey.shade200,
            padding: const EdgeInsets.all(100),
            child: nested ? const RepaintBoundary(child: card) : card,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));
}

/// The red channel across a horizontal line 5px below the card's own bottom
/// edge (y=165 in this fixture's fixed layout), sampled every 2px - where a
/// hard-edged shadow reads as one flat value and a blurred one reads as a
/// gradient either side of the card's own width.
Future<List<int>> _shadowRow(RenderRepaintBoundary boundary) async {
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final buf = bytes!.buffer.asUint8List();
  final row = <int>[
    for (var x = 60; x < 240; x += 2) buf[(165 * image.width + x) * 4],
  ];
  image.dispose();
  return row;
}

/// True when consecutive samples never jump by more than [maxStep] - the
/// shape a real Gaussian blur has and a flat-then-hard-edge step does not.
bool _isGradient(List<int> row, {int maxStep = 20}) {
  for (var i = 1; i < row.length; i++) {
    if ((row[i] - row[i - 1]).abs() > maxStep) return false;
  }
  return true;
}

void main() {
  testWidgets(
    'the captured shadow is a real gradient, not a flat hard-edged step',
    (tester) async {
      final boundary = await _pumpCard(tester);
      late List<int> row;
      await withRealShadows(tester, boundary, () async {
        row = (await tester.runAsync(() => _shadowRow(boundary)))!;
      });

      expect(
        row.toSet().length,
        greaterThan(10),
        reason: 'a hard step has only two distinct values',
      );
      expect(_isGradient(row), isTrue, reason: 'row: $row');
    },
  );

  testWidgets(
    'a shadow behind a nested repaint boundary is captured blurred too',
    (tester) async {
      final boundary = await _pumpCard(tester, nested: true);
      late List<int> row;
      await withRealShadows(tester, boundary, () async {
        row = (await tester.runAsync(() => _shadowRow(boundary)))!;
      });

      expect(_isGradient(row), isTrue, reason: 'row: $row');
    },
  );

  testWidgets(
    'without the fix the same fixture reads as a hard, flat step - proving '
    'the test above is actually discriminating, not just permissive',
    (tester) async {
      final boundary = await _pumpCard(tester);
      final row = (await tester.runAsync(() => _shadowRow(boundary)))!;

      expect(row.toSet().length, lessThanOrEqualTo(2));
    },
  );

  testWidgets('debugDisableShadows is restored before the test body returns', (
    tester,
  ) async {
    final boundary = await _pumpCard(tester);
    await withRealShadows(tester, boundary, () async {
      expect(debugDisableShadows, isFalse);
    });

    expect(debugDisableShadows, isTrue);
  });

  testWidgets('the restore holds even across two calls in the same test', (
    tester,
  ) async {
    final boundary = await _pumpCard(tester);
    await withRealShadows(tester, boundary, () async {});
    await withRealShadows(tester, boundary, () async {});

    expect(debugDisableShadows, isTrue);
  });
}

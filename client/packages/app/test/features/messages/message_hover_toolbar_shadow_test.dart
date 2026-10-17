// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hover toolbar's shadow, measured on rendered pixels: it is a 30 px
/// control, so its shadow may not reach further than that onto the rows
/// around it. The shipped float token reached about 60 px.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_hover_toolbar.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _boundary = Key('toolbar-capture');
const _field = Size(500, 300);

/// Painted with real blur: the test binding turns shadows off for the process.
///
/// How many pixels below the toolbar's bottom edge are visibly darker than
/// the field, and how dark the nearest one is relative to the field.
Future<({int reach, int nearestDelta})> _measure(
  WidgetTester tester,
  AppTokens tokens,
  Brightness brightness,
) async {
  debugDisableShadows = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(brightness, tokens),
      home: Center(
        child: RepaintBoundary(
          key: _boundary,
          child: ColoredBox(
            color: tokens.surfaceRaised,
            child: SizedBox.fromSize(
              size: _field,
              child: Center(
                child: MessageHoverToolbar(
                  actions: noActions,
                  onPickReaction: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  final plateBottom =
      tester.getBottomLeft(find.byKey(MessageHoverToolbar.plateKey)).dy -
      tester.getTopLeft(find.byKey(_boundary)).dy;
  late ({int reach, int nearestDelta}) result;
  {
    result = (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      final x = image.width ~/ 2;
      int red(int y) => bytes[(y * image.width + x) * 4];
      final background = red(image.height - 1);
      var reach = 0;
      final start = plateBottom.ceil() + 1;
      for (var y = start; y < image.height; y++) {
        if ((background - red(y)).abs() >= 3) reach = y - start + 1;
      }
      image.dispose();
      return (reach: reach, nearestDelta: (background - red(start)).abs());
    }))!;
  }
  debugDisableShadows = true;
  return result;
}

void main() {
  for (final (name, tokens, brightness) in [
    ('light', AppTokens.light, Brightness.light),
    ('dark', AppTokens.dark, Brightness.dark),
  ]) {
    testWidgets('the toolbar shadow reaches no further than the toolbar is '
        'tall, and still lifts it off the row in $name', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final m = await _measure(tester, tokens, brightness);

      expect(m.reach, lessThanOrEqualTo(MessageHoverToolbar.height.round()));
      expect(m.nearestDelta, greaterThanOrEqualTo(3), reason: 'no lift');
    });
  }
}

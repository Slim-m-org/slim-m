// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hovered message over an image backdrop must let the image show through
/// instead of painting a hard opaque band across it.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _backdropKey = ValueKey('backdrop');

Widget _overImage(Brightness brightness, AppTokens tokens) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(brightness, tokens),
    home: Scaffold(
      backgroundColor: Colors.transparent,
      body: RepaintBoundary(
        key: _backdropKey,
        child: Stack(
          children: [
            const Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: ColoredBox(color: Color(0xFF101820))),
                  Expanded(child: ColoredBox(color: Color(0xFFE8D8B8))),
                ],
              ),
            ),
            MessageRow(
              message: message(content: 'x'),
              grouped: false,
              showNewDivider: false,
              knownUsernames: const {},
              actions: noActions,
              editing: false,
              callbacks: MessageRowCallbacks(
                onRetry: () {},
                onDiscard: () {},
                onPickReaction: (_) {},
                onReactionTap: (_) {},
                onVote: (_) {},
                onSubmitEdit: (_) {},
                onCancelEdit: () {},
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

Future<(Color, Color)> _hoveredEdges(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(find.byKey(MessageRow.hoverFillKey)));
  await tester.pump(const Duration(seconds: 1));
  final fill = tester.getRect(find.byKey(MessageRow.hoverFillKey));
  late ByteData data;
  late int width;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_backdropKey),
    );
    final image = await boundary.toImage();
    width = image.width;
    data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });
  Color at(int x) {
    final i = ((fill.top + 2).round() * width + x) * 4;
    return Color.fromARGB(
      255,
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }

  return (at(fill.right.round() - 3), at(fill.left.round() + 3));
}

void main() {
  for (final (name, brightness, tokens) in [
    ('dark', Brightness.dark, AppTokens.dark),
    ('light', Brightness.light, AppTokens.light),
  ]) {
    testWidgets('hovered row shows the $name backdrop through its fill', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_overImage(brightness, tokens));
      await tester.pump(const Duration(seconds: 1));

      final (onLight, onDark) = await _hoveredEdges(tester);

      expect(onLight, isNot(onDark));
      expect(onLight, isNot(tokens.surfaceRaised));
      expect(onDark, isNot(tokens.surfaceRaised));
    });
  }
}

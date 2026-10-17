// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Informational copy must resolve to a readable colour: the disabled text
/// token is exempt from WCAG 1.4.3 only on controls that are disabled.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_recap.dart';
import 'package:slimm_app/src/features/voice/widgets/call_recap_card.dart';
import 'package:slimm_design_system/design_system.dart';

import 'features/canvas/canvas_pane_harness.dart';

double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Color _colorOf(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  return text.style!.color!;
}

void main() {
  testWidgets('the empty-canvas instructions are at least 4.5:1', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final color = _colorOf(
      tester,
      find.textContaining('Draw with the pen, drop a note'),
    );

    expect(
      _contrast(color, AppTokens.dark.surfaceBase),
      greaterThanOrEqualTo(4.5),
    );
  });

  for (final (name, brightness, tokens) in [
    ('light', Brightness.light, AppTokens.light),
    ('dark', Brightness.dark, AppTokens.dark),
  ]) {
    testWidgets('the "Your last call" label is at least 4.5:1 in $name', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(brightness, tokens),
          home: Scaffold(
            body: CallRecapCard(
              recap: CallRecap(
                channelId: 'c1',
                startedAt: DateTime(2026, 1, 1, 12),
                endedAt: DateTime(2026, 1, 1, 12, 5),
                others: const [],
                sharedScreen: false,
                usedCamera: false,
              ),
            ),
          ),
        ),
      );

      final color = _colorOf(tester, find.text('Your last call'));

      expect(
        _contrast(color, tokens.surfaceRaised),
        greaterThanOrEqualTo(4.5),
        reason: name,
      );
    });
  }
}

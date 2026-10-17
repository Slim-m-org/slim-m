// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone-width app bar and the transcript below it shared one surface
/// colour with zero elevation, so there was no visible boundary between the
/// channel header and the chat area - the wide header and the wide voice
/// header both already draw a bottom hairline, and this one did not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _app(AppTokens tokens, Brightness brightness) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(brightness, tokens),
    home: Scaffold(
      appBar: CompactChannelAppBar(channelId: 'c1', onBack: () {}),
      body: const SizedBox.expand(),
    ),
  ),
);

void main() {
  for (final (name, brightness, tokens) in [
    ('light', Brightness.light, AppTokens.light),
    ('dark', Brightness.dark, AppTokens.dark),
  ]) {
    testWidgets('the $name compact app bar draws a bottom hairline', (
      tester,
    ) async {
      await tester.pumpWidget(_app(tokens, brightness));
      await tester.pump();

      final bar = tester.widget<AppBar>(find.byType(AppBar));
      final shape = bar.shape;
      expect(
        shape,
        isA<Border>(),
        reason:
            'the bar needs its own bottom border, the same border-first '
            'divider the wide header and the wide voice header already draw',
      );
      final bottom = (shape as Border).bottom;
      expect(bottom.color, tokens.borderSubtle);
      expect(bottom.width, greaterThan(0));
      expect(
        bar.elevation,
        anyOf(isNull, 0),
        reason:
            'a shadow is not this design language\'s divider; the theme '
            'already pins app bar elevation to zero',
      );
    });
  }
}

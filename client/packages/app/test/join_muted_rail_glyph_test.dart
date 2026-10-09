// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel that starts joiners muted says so on its rail row, and an
/// ordinary voice channel does not.
///
/// Layout follows width, not platform (desktop-vs-mobile.md, rule 1), so the
/// same row is checked at 1280 and 390.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'voice_controller_harness.dart';

Channel _voice({required bool joinMuted}) => Channel(
  id: 'ch-1',
  name: 'General voice',
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: joinMuted,
  isPersonalSpace: false,
);

Future<void> _pump(WidgetTester tester, Channel channel, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(ref, const VoiceState()),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: AppTouchTargets(
            enabled: width < 600,
            child: VoiceChannelRow(channel: channel, selected: false),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final width in [1280.0, 390.0]) {
    group('at ${width.toInt()} wide', () {
      testWidgets('a join-muted voice channel shows the glyph, named', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await _pump(tester, _voice(joinMuted: true), width);
        final glyph = find.byIcon(AppIcons.micOff);
        expect(glyph, findsOneWidget);
        expect(
          tester.getSemantics(find.byType(AppListRow)).label,
          contains('Joins muted'),
        );
        expect(find.byTooltip('Joins muted'), findsOneWidget);
        final row = tester.getRect(find.byType(AppListRow));
        expect(tester.getRect(glyph).right, lessThanOrEqualTo(row.right));
        expect(tester.getRect(glyph).left, greaterThan(row.center.dx));
        semantics.dispose();
      });

      testWidgets('an ordinary voice channel has no glyph', (tester) async {
        await _pump(tester, _voice(joinMuted: false), width);
        expect(find.byIcon(AppIcons.micOff), findsNothing);
        expect(find.byTooltip('Joins muted'), findsNothing);
      });
    });
  }
}

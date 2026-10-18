// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail shows how long a voice channel's call has been running.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_length.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _app(List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(
      body: RailCallLength(channelId: 'c-voice', inCall: false),
    ),
  ),
);

void main() {
  testWidgets('an active channel shows its call length', (tester) async {
    await tester.pumpWidget(
      _app([
        voiceRosterStartProvider('c-voice').overrideWith(
          (ref) =>
              DateTime.now().subtract(const Duration(minutes: 5, seconds: 3)),
        ),
      ]),
    );
    expect(find.textContaining('05:0'), findsOneWidget);
  });

  testWidgets('a channel with no known call start shows nothing', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const []));
    expect(find.byType(Text), findsNothing);
  });
}

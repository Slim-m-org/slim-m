// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Rejoin call" in a DM after a declined or unanswered ring calls the other
/// person again, unless they are already in the room.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

Future<int> _rejoinAndCountRings(
  WidgetTester tester, {
  required List<api.VoiceRosterParticipant> roster,
}) async {
  final harness = VoiceHarness();
  var rings = 0;
  void onRequest(http.Request r) {
    if (r.method == 'POST' && r.url.path.endsWith('/voice/ring')) rings++;
  }

  try {
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(onRequest: onRequest),
      extraOverrides: [
        voiceRosterProvider.overrideWith(
          (ref, channelId) => Stream.value(roster),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: VoiceScreen(channelId: 'channel-1', isDm: true),
          ),
        ),
      ),
    );
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pump();
    await controller.leave();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Rejoin call'), findsOneWidget);
    expect(rings, 0, reason: 'nothing rings before the button is pressed');

    await tester.tap(find.text('Rejoin call'));
    await tester.pump();
    await tester.pump();
    return rings;
  } finally {
    harness.dispose();
  }
}

void main() {
  testWidgets('rejoining an empty DM call rings the other person again', (
    tester,
  ) async {
    final rings = await _rejoinAndCountRings(tester, roster: const []);
    expect(rings, 1);
  });

  testWidgets('rejoining a DM call the other person is in does not ring', (
    tester,
  ) async {
    final rings = await _rejoinAndCountRings(
      tester,
      roster: const [
        api.VoiceRosterParticipant(userId: 'user-2', displayName: 'Bob'),
      ],
    );
    expect(rings, 0);
  });
}

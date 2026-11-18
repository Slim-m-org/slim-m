// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-sided call of 2026-11-18 on the stage: the server lists someone the
/// room never delivered, and the stage says so until the room catches up.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/features/voice/providers/call_roster_gap.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stage_layout.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Bob',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

const _alice = VoiceParticipant(
  identity: 'user-2',
  name: 'Alice',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

/// The server's answer lists this device and Alice, whatever the room says.
http.Client _api() {
  final base = voiceApi();
  return MockClient((request) async {
    if (request.url.path.endsWith('/voice/roster')) {
      return http.Response(
        jsonEncode({
          'participants': [
            {'user_id': 'user-1', 'display_name': 'Bob', 'this_device': true},
            {'user_id': 'user-2', 'display_name': 'Alice'},
          ],
          'call_age_ms': 1000,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return base.send(request).then(http.Response.fromStream);
  });
}

void main() {
  testWidgets('someone the server has and the room never delivered shows as '
      'connecting, and clears once the room delivers them', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    var now = DateTime(2026, 11, 18, 20, 17);
    final harness = VoiceHarness();
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      _api(),
      extraOverrides: [rosterGapClockProvider.overrideWithValue(() => now)],
    );
    try {
      await _run(
        tester,
        harness,
        controller,
        session,
        () => now,
        (next) => now = next,
      );
    } finally {
      harness.dispose();
      handle.dispose();
    }
  });
}

Future<void> _run(
  WidgetTester tester,
  VoiceHarness harness,
  VoiceController controller,
  FakeSession session,
  DateTime Function() now,
  void Function(DateTime) setNow,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: CallStageLayout(
            controller: controller,
            onOpenProfile: (_, _) {},
            isDm: false,
          ),
        ),
      ),
    ),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  session.emitParticipants(const [_me]);
  await tester.pump();
  await tester.pump();
  expect(find.bySemanticsLabel(RegExp('^Alice')), findsNothing);

  setNow(now().add(kRosterGapConfirm));
  await tester.pump(kRosterGapPoll);
  await tester.pump();
  expect(find.bySemanticsLabel('Alice, connecting'), findsOneWidget);
  expect(
    find.textContaining('Alice is in the call but not connected to you'),
    findsOneWidget,
  );

  session.emitParticipants(const [_me, _alice]);
  await tester.pump();
  await tester.pump();
  expect(find.bySemanticsLabel('Alice, connecting'), findsNothing);
  expect(
    find.bySemanticsLabel(RegExp('^Alice, microphone on')),
    findsOneWidget,
  );
  expect(find.textContaining('not connected to you'), findsNothing);
}

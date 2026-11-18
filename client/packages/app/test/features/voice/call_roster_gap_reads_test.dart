// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roster check when its reads fail or the call is joined again: it never
/// names someone from a reading it could not repeat.
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

const _bobRow = {
  'user_id': 'user-1',
  'display_name': 'Bob',
  'this_device': true,
};
const _aliceRow = {'user_id': 'user-2', 'display_name': 'Alice'};

/// The server's roster, read from [rows] each time after [delay], or a 503 while [failing].
class _Roster {
  List<Map<String, Object>> rows = const [_bobRow, _aliceRow];
  bool failing = false;
  Duration delay = Duration.zero;

  http.Client client() {
    final base = voiceApi();
    return MockClient((request) async {
      if (!request.url.path.endsWith('/voice/roster')) {
        return base.send(request).then(http.Response.fromStream);
      }
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (failing) return http.Response('', 503);
      return http.Response(
        jsonEncode({'participants': rows, 'call_age_ms': 1000}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  }
}

class _Call {
  _Call(this.tester, this.roster);

  final WidgetTester tester;
  final _Roster roster;
  final harness = VoiceHarness();
  final session = FakeSession();
  var now = DateTime(2026, 11, 18, 20, 17);
  late final VoiceController controller;

  Future<void> start(List<VoiceParticipant> delivered) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    controller = harness.controllerWith(
      session,
      roster.client(),
      extraOverrides: [rosterGapClockProvider.overrideWithValue(() => now)],
    );
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
    session.emitParticipants(delivered);
    await tester.pump();
    await tester.pump();
  }

  /// Moves both clocks on by [by], so the next poll runs and reads at the new time.
  Future<void> advance(Duration by) async {
    now = now.add(by);
    await tester.pump(by);
    await tester.pump();
  }

  void dispose() {
    tester.view.reset();
    harness.dispose();
  }
}

void main() {
  testWidgets('someone who left is never shown as connecting from a reading '
      'that failed to repeat', (tester) async {
    final roster = _Roster();
    final call = _Call(tester, roster);
    final handle = tester.ensureSemantics();
    try {
      await call.start(const [_me, _alice]);
      roster.failing = true;
      call.session.emitParticipants(const [_me]);
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await call.advance(kRosterGapPoll);
        expect(find.bySemanticsLabel('Alice, connecting'), findsNothing);
        expect(find.textContaining('not connected to you'), findsNothing);
      }
    } finally {
      call.dispose();
      handle.dispose();
    }
  });

  testWidgets('"the call server lost you" goes once reads stop answering', (
    tester,
  ) async {
    final roster = _Roster()..rows = const [_aliceRow];
    final call = _Call(tester, roster);
    try {
      await call.start(const [_me, _alice]);
      await call.advance(kRosterGapPoll);
      expect(find.textContaining('The call server lost you'), findsOneWidget);
      roster.failing = true;
      await call.advance(kRosterGapPoll);
      await call.advance(kRosterGapStale - kRosterGapPoll);
      expect(find.textContaining('The call server lost you'), findsNothing);
    } finally {
      call.dispose();
    }
  });

  testWidgets('reads that answer slowly still confirm someone undelivered, '
      'and keep them shown', (tester) async {
    final roster = _Roster()..delay = const Duration(seconds: 6);
    final call = _Call(tester, roster);
    final handle = tester.ensureSemantics();
    try {
      await call.start(const [_me]);
      for (var s = 1; s <= 40; s++) {
        await call.advance(const Duration(seconds: 1));
        if (s < 23) continue;
        expect(
          find.bySemanticsLabel('Alice, connecting'),
          findsOneWidget,
          reason: 'at ${s}s',
        );
      }
    } finally {
      call.dispose();
      handle.dispose();
    }
  });

  testWidgets('a slow read that then fails still drops the gap it outlived', (
    tester,
  ) async {
    final roster = _Roster()..rows = const [_aliceRow];
    final call = _Call(tester, roster);
    try {
      await call.start(const [_me, _alice]);
      await call.advance(kRosterGapPoll);
      expect(find.textContaining('The call server lost you'), findsOneWidget);
      roster
        ..delay = const Duration(seconds: 6)
        ..failing = true;
      for (var s = 1; s <= 17; s++) {
        await call.advance(const Duration(seconds: 1));
      }
      expect(find.textContaining('The call server lost you'), findsNothing);
    } finally {
      call.dispose();
    }
  });

  testWidgets('a rejoin confirms afresh rather than on the clock from before '
      'it', (tester) async {
    final roster = _Roster()..rows = const [_aliceRow];
    final call = _Call(tester, roster);
    try {
      await call.start(const [_me, _alice]);
      call.session.emitState(VoiceSessionState.connecting);
      await call.advance(kRosterGapPoll);
      call.session.emitState(VoiceSessionState.connected);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('The call server lost you'), findsNothing);
    } finally {
      call.dispose();
    }
  });
}

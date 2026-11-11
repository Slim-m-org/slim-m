// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Joining a call while this account is already in one on another device asks
/// first, because the join moves the call here and drops the other device.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

/// The voice API, with this account listed in the rosters of [occupied].
http.Client _api(Set<String> occupied) {
  final base = voiceApi();
  return MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/voice/roster')) {
      final channel = path.split('/')[2];
      final self = occupied.contains(channel);
      return http.Response(
        jsonEncode({
          'participants': [
            if (self) {'user_id': tokens.userId, 'display_name': 'Me'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return base.send(request).then(http.Response.fromStream);
  });
}

void main() {
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  VoiceController setUpController(FakeSession session, Set<String> occupied) {
    return harness.controllerWith(session, _api(occupied));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // Unmounting cancels the roster polls the screen started.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    harness.container.dispose();
  }

  testWidgets('arriving at the channel this account is in elsewhere asks '
      'before joining', (tester) async {
    final session = FakeSession();
    final controller = setUpController(session, {'channel-1'});

    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
    );
    await settle(tester);

    expect(find.text('Join here'), findsOneWidget);
    expect(controller.state.channelId, isNull);
    expect(session.askedForMicrophoneOnJoin, isNull);
    await unmount(tester);
  });

  testWidgets('arriving while in another channel elsewhere asks before '
      'joining', (tester) async {
    final session = FakeSession();
    final controller = setUpController(session, {'channel-a'});
    final rail = harness.container.listen(
      voiceRosterProvider('channel-a'),
      (_, _) {},
    );
    await settle(tester);

    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-b'), harness.container),
    );
    await settle(tester);

    expect(find.text('Join here'), findsOneWidget);
    expect(controller.state.channelId, isNull);
    rail.close();
    await unmount(tester);
  });

  testWidgets('cancel keeps the call where it is', (tester) async {
    final session = FakeSession();
    final controller = setUpController(session, {'channel-1'});
    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
    );
    await settle(tester);

    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(find.text('Join here'), findsNothing);
    expect(controller.state.channelId, isNull);
    expect(session.askedForMicrophoneOnJoin, isNull);
    await unmount(tester);
  });

  testWidgets('join here moves the call to this device', (tester) async {
    final session = FakeSession();
    final controller = setUpController(session, {'channel-1'});
    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
    );
    await settle(tester);

    await tester.tap(find.text('Join here'));
    await settle(tester);
    await settle(tester);

    expect(controller.state.channelId, 'channel-1');
    expect(find.text('Join here'), findsNothing);
    await unmount(tester);
  });

  testWidgets('this device own reconnect never asks', (tester) async {
    final session = FakeSession();
    final controller = setUpController(session, {'channel-1'});
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pumpWidget(
      _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
    );
    await settle(tester);
    session.emitState(VoiceSessionState.connecting);
    await settle(tester);

    expect(find.text('Join here'), findsNothing);
    await unmount(tester);
  });

  testWidgets('answering a ring into a DM call asks before joining', (
    tester,
  ) async {
    final session = FakeSession();
    final controller = setUpController(session, {'dm-1'});

    await tester.pumpWidget(
      _harness(
        const VoiceScreen(channelId: 'dm-1', isDm: true),
        harness.container,
      ),
    );
    await settle(tester);

    expect(find.text('Join here'), findsOneWidget);
    expect(controller.state.channelId, isNull);
    await unmount(tester);
  });
}

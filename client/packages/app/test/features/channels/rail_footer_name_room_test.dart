// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a call the rail's user bar holds mic, deafen, Notes and the gear, so the
/// name either keeps a readable width or gives way to the controls entirely.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';
import '../voice/voice_controller_harness.dart' show FixedVoiceController;

const _name = 'Alexandria Montgomery';

ProviderContainer _container() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(
      api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'self',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
    ),
    syncControllerProvider.overrideWith(StubSyncController.new),
    voiceControllerProvider.overrideWith(
      (ref) => FixedVoiceController(
        ref,
        const VoiceState(state: VoiceSessionState.connected, channelId: 'c1'),
      ),
    ),
    mockApiOverride((request) async {
      if (request.url.path == '/me') {
        return http.Response(
          jsonEncode({
            'id': 'self',
            'username': 'self',
            'display_name': _name,
            'created_at': 0,
            'permissions': 0,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    }),
  ],
);

void main() {
  for (final width in [216.0, 240.0, 248.0, 264.0]) {
    testWidgets('at a ${width.toInt()} rail in a call the name is readable or '
        'gone', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(
                  width: width,
                  child: const RailUserFooter(activeChannelId: 'c1'),
                ),
              ),
            ),
          ),
        ),
      );
      await pumpFrames(tester, frames: 10);

      expect(find.bySemanticsLabel('Mute'), findsOneWidget, reason: 'in call');
      final name = find.text(_name);
      if (name.evaluate().isNotEmpty) {
        expect(tester.getSize(name).width, greaterThanOrEqualTo(64));
      }
    });
  }
}

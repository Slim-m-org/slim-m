// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real `HomeShell` at a phone size, in a connected voice call with a bot
/// that offers playback controls and a screen share on the stage: the screen
/// the owner screenshotted. Width alone picks the phone branch.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../home_shell_harness.dart';
import '../ui_snapshot_support.dart' show snapshotBoundary;
import '../voice_controller_harness.dart';

const callChannelId = 'c-voice';

const _bot = api.ChannelBotUi(
  botUserId: 'jelly',
  botUsername: 'jellyfin',
  botDisplayName: 'Jellyfin',
  messageMenu: [],
  callControls: [
    api.BotUiEntry(id: 'pause', label: 'Play or pause', icon: 'pause'),
    api.BotUiEntry(id: 'back', label: 'Back 30s', icon: 'skip_previous'),
    api.BotUiEntry(id: 'fwd', label: 'Forward 30s', icon: 'skip_next'),
    api.BotUiEntry(id: 'stop', label: 'Stop', icon: 'stop'),
  ],
);

const _participants = [
  VoiceParticipant(
    identity: 'bob',
    name: 'Bob',
    isSpeaking: false,
    isMuted: true,
    isLocal: true,
    isScreenSharing: false,
  ),
  VoiceParticipant(
    identity: 'jelly',
    name: 'Jellyfin',
    isSpeaking: false,
    isMuted: false,
    isLocal: false,
    isScreenSharing: true,
  ),
];

final _quietParticipants = [
  for (final p in _participants)
    VoiceParticipant(
      identity: p.identity,
      name: p.name,
      isSpeaking: p.isSpeaking,
      isMuted: p.isMuted,
      isLocal: p.isLocal,
      isScreenSharing: false,
    ),
];

typedef CallScreen = ({
  ProviderContainer container,
  SlimmDatabase db,
  GoRouter router,
  FakeSession session,
});

MockClient _client() {
  final quiet = quietClient();
  return MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/voice/heartbeat')) return http.Response('', 204);
    if (path.endsWith('/voice/token')) {
      return http.Response(
        jsonEncode({
          'url': 'wss://sfu.example.com',
          'room': callChannelId,
          'token': 'jwt',
          'expires_at': 0,
          'can_publish': true,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response.fromStream(
      await quiet.send(http.Request(request.method, request.url)),
    );
  });
}

/// Pumps the call screen at [size]; [canvas] opens the canvas over the call
/// [bots] offers the playback controls and [share] puts a screen on the stage.
Future<CallScreen> pumpCallScreen(
  WidgetTester tester,
  Size size, {
  bool canvas = false,
  bool bots = true,
  bool share = true,
  Brightness brightness = Brightness.dark,
}) async {
  final session = FakeSession(supportsAudioOutputSelection: false);
  final fixture = setup(
    signedIn: true,
    httpClient: _client(),
    extraOverrides: [
      voiceRosterProvider(
        callChannelId,
      ).overrideWith((ref) => const Stream.empty()),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
      channelBotUiProvider(
        callChannelId,
      ).overrideWith((ref) async => bots ? [_bot] : const []),
    ],
  );
  final store = await fixture.container.read(storeProvider.future);
  await store.upsertChannels([
    const api.Channel(
      id: callChannelId,
      name: 'movie-room',
      kind: 'voice',
      createdAt: 0,
    ),
  ]);
  final router = testRouter('/channels/$callChannelId');
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(seconds: 1));
  session.emitState(VoiceSessionState.connected);
  await tester.pumpAndSettle();
  session.emitParticipants(share ? _participants : _quietParticipants);
  await tester.pumpAndSettle();
  if (canvas) {
    fixture.container.read(canvasOpenProvider.notifier).state = callChannelId;
    await tester.pumpAndSettle();
  }
  return (
    container: fixture.container,
    db: fixture.db,
    router: router,
    session: session,
  );
}

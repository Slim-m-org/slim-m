// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel rail's voice group (channel row plus the people under it) and
/// a scrolling list's idle scrollbar, at rail width in both themes.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

const _tokens = api.TokenPair(
  userId: 'u-nick',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _voice(String id, String name) => Channel(
  id: id,
  name: name,
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

VoiceParticipant _person(
  String id,
  String name, {
  bool muted = false,
  bool sharing = false,
  bool camera = false,
  bool speaking = false,
}) => VoiceParticipant(
  identity: id,
  name: name,
  isSpeaking: speaking,
  isMuted: muted,
  isLocal: false,
  isScreenSharing: sharing,
  isCameraOn: camera,
);

Future<void> _capture(
  WidgetTester tester, {
  required Brightness brightness,
  required Size size,
  required String name,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final apiClient = api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: api.SessionStore(tokens: _tokens),
    httpClient: MockClient((_) async => http.Response('', 404)),
  );
  addTearDown(apiClient.close);
  final tokens = brightness == Brightness.dark
      ? AppTokens.dark
      : AppTokens.light;
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(apiClient),
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            VoiceState(
              channelId: 'v1',
              state: VoiceSessionState.connected,
              participants: [
                _person('u-nick', 'Nick', sharing: true),
                _person('u-priya', 'Priya', muted: true, speaking: true),
                _person('u-sam', 'Samantha Longname-Jones', camera: true),
              ],
            ),
          ),
        ),
        voiceRosterProvider('v2').overrideWith(
          (ref) => Stream.value(const [
            api.VoiceRosterParticipant(
              userId: 'u-alex',
              displayName: 'Alex',
              isSharingScreen: true,
              hasVideo: true,
            ),
          ]),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brightness, tokens),
        home: RepaintBoundary(
          key: snapshotBoundary,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 250,
                child: Scrollbar(
                  controller: scroll,
                  thumbVisibility: true,
                  child: ListView(
                    controller: scroll,
                    children: [
                      VoiceChannelRow(
                        channel: _voice('v1', 'voice'),
                        selected: true,
                      ),
                      VoiceChannelRow(
                        channel: _voice('v2', 'movie-room'),
                        selected: false,
                      ),
                      VoiceChannelRow(
                        channel: _voice('v3', 'empty-room'),
                        selected: false,
                      ),
                      const SizedBox(height: 800),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await expectSettled(tester, name, allowNoText: false);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  for (final brightness in Brightness.values) {
    for (final (label, size) in [
      ('desktop', const Size(250, 300)),
      ('phone', const Size(390, 300)),
    ]) {
      final name = 'voice-rail-$label-${brightness.name}';
      testWidgets(name, (tester) async {
        await _capture(tester, brightness: brightness, size: size, name: name);
      });
    }
  }
}

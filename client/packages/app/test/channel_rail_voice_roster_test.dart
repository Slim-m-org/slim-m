// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's voice row for a channel the caller has not joined: it now has
/// a real roster to draw on ([voiceRosterProvider]) instead of always
/// rendering as empty. See `channel_rail_channel_rows.dart`'s
/// `_ParticipantList` for the counterpart that is still, correctly, always
/// empty for a channel nobody in this client has joined and the server has
/// never been asked about.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_app/src/widgets/user_avatar.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

final _channel = Channel(
  id: 'ch-1',
  name: 'General voice',
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

const _rosterPath = '/channels/ch-1/voice/roster';

Widget _harness({required http.Client httpClient, required VoiceState voice}) {
  final apiClient = api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: api.SessionStore(tokens: _tokens),
    httpClient: httpClient,
  );
  addTearDown(apiClient.close);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(apiClient),
      // The row watches voiceControllerProvider itself now; see channel_rail_voice_watch_scope_test.dart.
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, voice),
      ),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: VoiceChannelRow(channel: _channel, selected: false)),
    ),
  );
}

/// The count text the row shows beside a voice channel, or null when it
/// shows none: the same trailing slot `AppListRow` uses for an unread dot.
String? _trailingCount(WidgetTester tester) {
  final micro = tester
      .widgetList<Text>(find.byType(Text))
      .where(
        (t) =>
            t.style?.fontFeatures?.contains(
              const FontFeature.tabularFigures(),
            ) ??
            false,
      );
  return micro.isEmpty ? null : micro.single.data;
}

void main() {
  testWidgets(
    'before the roster is fetched, an unjoined channel shows nothing, '
    'the same as it always has',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          httpClient: MockClient((_) async => http.Response('', 501)),
          voice: const VoiceState(),
        ),
      );
      await tester.pump();

      expect(_trailingCount(tester), isNull);
      expect(find.byType(UserAvatar), findsNothing);
    },
  );

  testWidgets(
    'once the server answers, an unjoined channel shows who is really there',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          httpClient: MockClient((request) async {
            if (request.url.path == _rosterPath) {
              return http.Response(
                jsonEncode({
                  'participants': [
                    {'user_id': 'u-alice', 'display_name': 'Alice'},
                  ],
                }),
                200,
              );
            }
            return http.Response('', 404);
          }),
          voice: const VoiceState(),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(_trailingCount(tester), isNull);
      expect(find.byType(UserAvatar), findsOneWidget);
    },
  );

  testWidgets(
    'a fresh relaunch does not render this device as already in the call '
    'it was just killed out of',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          httpClient: MockClient((request) async {
            if (request.url.path == _rosterPath) {
              // The server has not reaped this client's own dead connection.
              return http.Response(
                jsonEncode({
                  'participants': [
                    {'user_id': 'u-me', 'display_name': 'Me'},
                  ],
                }),
                200,
              );
            }
            return http.Response('', 404);
          }),
          // A genuinely fresh launch: idle, not connected anywhere.
          voice: const VoiceState(),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        _trailingCount(tester),
        isNull,
        reason:
            'this device is not in the call; the roster reporting its '
            'own stale entry must not be read as though it were',
      );
      expect(find.byType(UserAvatar), findsNothing);
    },
  );

  testWidgets('a genuinely empty room shows no count, same as an unknown one', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        httpClient: MockClient(
          (_) async =>
              http.Response(jsonEncode({'participants': <dynamic>[]}), 200),
        ),
        voice: const VoiceState(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(_trailingCount(tester), isNull);
    expect(find.byType(UserAvatar), findsNothing);
  });

  testWidgets(
    'the channel already joined never asks the server for its own roster: '
    'its live participant list is authoritative and the fetch is free',
    (tester) async {
      final rosterCalls = <Uri>[];
      await tester.pumpWidget(
        _harness(
          httpClient: MockClient((request) async {
            if (request.url.path == _rosterPath) rosterCalls.add(request.url);
            // Anything else asking (an avatar, a profile) just gets a plain 404.
            return http.Response('', 404);
          }),
          voice: const VoiceState(
            channelId: 'ch-1',
            state: VoiceSessionState.connected,
            participants: [
              VoiceParticipant(
                identity: 'u-me',
                name: 'Me',
                isSpeaking: false,
                isMuted: false,
                isLocal: true,
                isScreenSharing: false,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(_trailingCount(tester), isNull);
      expect(
        rosterCalls,
        isEmpty,
        reason:
            'a joined call already has this live; fetching it again would '
            'be a wasted round trip on every rebuild',
      );
    },
  );
}

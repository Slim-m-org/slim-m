// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle voice channel mounted with a call history, shared by the idle
/// voice channel snapshot scenes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/voice_call_history.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/voice_channel_idle.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'call_header_fixture.dart';
import '../ui_snapshot_support.dart';

final idleYesterday = DateTime(2026, 10, 13, 19, 2).millisecondsSinceEpoch;
final idleNow = DateTime(2026, 10, 14, 10, 0).millisecondsSinceEpoch;
const idleMin = 60000;

api.VoiceCallEvent _ev(int minute, String who, api.VoiceCallEventKind kind) =>
    api.VoiceCallEvent(
      at: idleYesterday + minute * idleMin,
      userId: who,
      kind: kind,
    );

api.VoiceCallHistory idleHistory() {
  final saturday = DateTime(2026, 10, 10, 20, 10).millisecondsSinceEpoch;
  final thursday = DateTime(2026, 10, 8, 21, 30).millisecondsSinceEpoch;
  return api.VoiceCallHistory(
    retentionDays: 30,
    canvasObjectCount: 3,
    calls: [
      api.VoiceCall(
        startedAt: idleYesterday,
        endedAt: idleYesterday + 119 * idleMin,
        events: [
          _ev(0, 'nick', api.VoiceCallEventKind.joined),
          _ev(0, 'kiki', api.VoiceCallEventKind.joined),
          _ev(4, 'jelly', api.VoiceCallEventKind.joined),
          _ev(30, 'jelly', api.VoiceCallEventKind.shareStarted),
          _ev(70, 'jelly', api.VoiceCallEventKind.shareStopped),
          _ev(82, 'kiki', api.VoiceCallEventKind.left),
          _ev(118, 'jelly', api.VoiceCallEventKind.left),
          _ev(119, 'nick', api.VoiceCallEventKind.left),
        ],
        canvas: [
          api.VoiceCallCanvasActivity(
            userId: 'kiki',
            kind: 'image',
            firstAt: idleYesterday + 46 * idleMin,
            count: 1,
          ),
          api.VoiceCallCanvasActivity(
            userId: 'nick',
            kind: 'stroke',
            firstAt: idleYesterday + 49 * idleMin,
            count: 12,
          ),
        ],
      ),
      api.VoiceCall(
        startedAt: saturday,
        endedAt: saturday + 210 * idleMin,
        events: [
          api.VoiceCallEvent(
            at: saturday,
            userId: 'nick',
            kind: api.VoiceCallEventKind.joined,
          ),
          api.VoiceCallEvent(
            at: saturday + 5 * idleMin,
            userId: 'jelly',
            kind: api.VoiceCallEventKind.joined,
          ),
          api.VoiceCallEvent(
            at: saturday + 10 * idleMin,
            userId: 'jelly',
            kind: api.VoiceCallEventKind.shareStarted,
          ),
          api.VoiceCallEvent(
            at: saturday + 135 * idleMin,
            userId: 'jelly',
            kind: api.VoiceCallEventKind.shareStopped,
          ),
          api.VoiceCallEvent(
            at: saturday + 200 * idleMin,
            userId: 'jelly',
            kind: api.VoiceCallEventKind.left,
          ),
          api.VoiceCallEvent(
            at: saturday + 210 * idleMin,
            userId: 'nick',
            kind: api.VoiceCallEventKind.left,
          ),
        ],
        canvas: const [],
      ),
      api.VoiceCall(
        startedAt: thursday,
        endedAt: thursday + 35 * idleMin,
        events: [
          api.VoiceCallEvent(
            at: thursday,
            userId: 'nick',
            kind: api.VoiceCallEventKind.joined,
          ),
          api.VoiceCallEvent(
            at: thursday + 35 * idleMin,
            userId: 'nick',
            kind: api.VoiceCallEventKind.left,
          ),
        ],
        canvas: const [],
      ),
    ],
  );
}

const idleNames = {'nick': 'Nick', 'kiki': 'Kiki', 'jelly': 'Jellyfin'};

/// Pumps [VoiceChannelIdle] at [size] in the chosen theme over [history].
Future<void> pumpIdle(
  WidgetTester tester, {
  required Size size,
  required bool dark,
  api.VoiceCallHistory? history,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'nick',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      ...callPeople(
        [
          for (final e in idleNames.entries)
            api.UserProfile(
              id: e.key,
              username: e.key,
              displayName: e.value,
              createdAt: 0,
            ),
        ],
        {'kiki'},
        roster: const [],
      ),
      userProfileProvider.overrideWith(
        (ref, id) async => api.UserProfile(
          id: id,
          username: id,
          displayName: idleNames[id] ?? id,
          createdAt: 0,
        ),
      ),
      voiceCallHistoryProvider.overrideWith(
        (ref, channelId) async => history ?? idleHistory(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: VoiceChannelIdle(
              channelId: 'voice-1',
              onJoin: () {},
              onOpenCanvas: () {},
              clock: () => idleNow,
            ),
          ),
        ),
      ),
    ),
  );
}

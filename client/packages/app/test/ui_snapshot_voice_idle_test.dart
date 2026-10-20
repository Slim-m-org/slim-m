// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle voice channel (design 13, decision 0066): join bar, last call's
/// lanes and moments, and earlier calls, at desktop and phone width in both
/// themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this
/// asserts the pane lays out without overflow.
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

import 'support/call_header_fixture.dart';
import 'ui_snapshot_support.dart';

final _yesterday = DateTime(2026, 10, 13, 19, 2).millisecondsSinceEpoch;
final _now = DateTime(2026, 10, 14, 10, 0).millisecondsSinceEpoch;
const _min = 60000;

api.VoiceCallEvent _ev(int minute, String who, api.VoiceCallEventKind kind) =>
    api.VoiceCallEvent(at: _yesterday + minute * _min, userId: who, kind: kind);

api.VoiceCallHistory _history() {
  final saturday = DateTime(2026, 10, 10, 20, 10).millisecondsSinceEpoch;
  final thursday = DateTime(2026, 10, 8, 21, 30).millisecondsSinceEpoch;
  return api.VoiceCallHistory(
    retentionDays: 30,
    canvasObjectCount: 3,
    calls: [
      api.VoiceCall(
        startedAt: _yesterday,
        endedAt: _yesterday + 119 * _min,
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
            firstAt: _yesterday + 46 * _min,
            count: 1,
          ),
          api.VoiceCallCanvasActivity(
            userId: 'nick',
            kind: 'stroke',
            firstAt: _yesterday + 49 * _min,
            count: 12,
          ),
        ],
      ),
      api.VoiceCall(
        startedAt: saturday,
        endedAt: saturday + 210 * _min,
        events: [
          api.VoiceCallEvent(
            at: saturday,
            userId: 'nick',
            kind: api.VoiceCallEventKind.joined,
          ),
          api.VoiceCallEvent(
            at: saturday + 5 * _min,
            userId: 'jelly',
            kind: api.VoiceCallEventKind.joined,
          ),
          api.VoiceCallEvent(
            at: saturday + 10 * _min,
            userId: 'jelly',
            kind: api.VoiceCallEventKind.shareStarted,
          ),
          api.VoiceCallEvent(
            at: saturday + 135 * _min,
            userId: 'jelly',
            kind: api.VoiceCallEventKind.shareStopped,
          ),
          api.VoiceCallEvent(
            at: saturday + 200 * _min,
            userId: 'jelly',
            kind: api.VoiceCallEventKind.left,
          ),
          api.VoiceCallEvent(
            at: saturday + 210 * _min,
            userId: 'nick',
            kind: api.VoiceCallEventKind.left,
          ),
        ],
        canvas: const [],
      ),
      api.VoiceCall(
        startedAt: thursday,
        endedAt: thursday + 35 * _min,
        events: [
          api.VoiceCallEvent(
            at: thursday,
            userId: 'nick',
            kind: api.VoiceCallEventKind.joined,
          ),
          api.VoiceCallEvent(
            at: thursday + 35 * _min,
            userId: 'nick',
            kind: api.VoiceCallEventKind.left,
          ),
        ],
        canvas: const [],
      ),
    ],
  );
}

const _names = {'nick': 'Nick', 'kiki': 'Kiki', 'jelly': 'Jellyfin'};

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'desktop': Size(1100, 1000), 'phone': Size(390, 900)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('idle voice channel at ${entry.key} ($theme)', (
        tester,
      ) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final dark = theme == 'dark';
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
                for (final e in _names.entries)
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
                displayName: _names[id] ?? id,
                createdAt: 0,
              ),
            ),
            voiceCallHistoryProvider.overrideWith(
              (ref, channelId) async => _history(),
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
                    clock: () => _now,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining("Nobody's here"), findsOneWidget);
        expect(find.text('Last call'), findsOneWidget);
        await writeSnapshot(tester, 'voice-idle-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
      });
    }
  }
}

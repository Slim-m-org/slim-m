// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel in the real shell with its call history served over the
/// mocked API and its live events in the test's hand, for the call details
/// panel and the details page a row's menu opens.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/settings/home_shell_harness.dart';
import '../features/voice/voice_controller_harness.dart'
    show FakeSession, FixedVoiceController;
import '../ui_snapshot_support.dart' show snapshotBoundary;
import 'async_wait.dart';

const detailsVoiceId = 'c-voice';

/// A second voice channel, for being in a call other than [detailsVoiceId]'s.
const otherVoiceId = 'c-other';
const detailsTranscriptId = 't-1';
const _min = 60000;

const detailsNames = {'bob': 'Bob', 'ann': 'Ann', 'kiki': 'Kiki'};

/// The shell, its history and its live events.
class CallDetailsShell {
  CallDetailsShell({
    required this.container,
    required this.db,
    required this.router,
    required this.events,
    required this.tokenRequests,
    required this.startedAt,
  });

  final ProviderContainer container;
  final SlimmDatabase db;
  final GoRouter router;
  final StreamController<api.ServerEvent> events;
  final List<String> tokenRequests;

  /// When the call on show began, a few minutes before the test did.
  final int startedAt;

  /// Who joined the call on show after Bob started it, in order.
  final joinedLater = <String>[];

  String get location =>
      router.routerDelegate.currentConfiguration.uri.toString();

  /// Ann (or [who]) joins: the server records it, then says so live.
  Future<void> join(WidgetTester tester, String who) async {
    joinedLater.add(who);
    events.add(
      api.VoiceParticipantJoined(channelId: detailsVoiceId, userId: who),
    );
    await tester.pump(const Duration(seconds: 3));
    await pumpFrames(tester);
  }

  Future<void> dispose(WidgetTester tester) async {
    await events.close();
    await teardown(tester, container, db);
  }

  Map<String, Object?> _historyJson() {
    Map<String, Object?> event(int at, String who, String kind) => {
      'at': at,
      'user_id': who,
      'kind': kind,
    };
    final yesterday = yesterdayNoonMs(DateTime.now().millisecondsSinceEpoch);
    return {
      'retention_days': 30,
      'canvas_object_count': 0,
      'calls': [
        {
          'started_at': startedAt,
          'ended_at': null,
          'transcript_id': detailsTranscriptId,
          'events': [
            event(startedAt, 'bob', 'joined'),
            for (final (i, who) in joinedLater.indexed)
              event(startedAt + (i + 2) * _min, who, 'joined'),
          ],
          'canvas': const <Object>[],
        },
        {
          'started_at': yesterday,
          'ended_at': yesterday + 95 * _min,
          'events': [
            event(yesterday, 'bob', 'joined'),
            event(yesterday + 3 * _min, 'kiki', 'joined'),
            event(yesterday + 40 * _min, 'kiki', 'share_started'),
            event(yesterday + 70 * _min, 'kiki', 'share_stopped'),
            event(yesterday + 90 * _min, 'kiki', 'left'),
            event(yesterday + 95 * _min, 'bob', 'left'),
          ],
          'canvas': const <Object>[],
        },
      ],
    };
  }

  Map<String, Object?> _transcriptJson() => {
    'id': detailsTranscriptId,
    'channel_id': detailsVoiceId,
    'started_at': startedAt,
    'ended_at': null,
    'mode': 'always',
    'lines': [
      {
        'seq': 1,
        'speaker_id': 'bob',
        'at': startedAt + 30000,
        'text': 'Can everyone see the board?',
      },
    ],
    'next_after_seq': null,
  };
}

/// The real shell at [width] on [location], in [callId]'s call when [inCall],
/// with Bob's call going in [detailsVoiceId] since a few minutes ago.
Future<CallDetailsShell> pumpCallDetailsShell(
  WidgetTester tester, {
  required double width,
  double height = 900,
  bool inCall = true,
  String callId = detailsVoiceId,
  bool dark = false,
  String location = '/channels/$detailsVoiceId',
  List<VoiceParticipant> participants = const [],
}) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  final tokenRequests = <String>[];
  late CallDetailsShell shell;
  final quiet = quietClient();
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/voice/token')) tokenRequests.add(path);
    final Object? body = switch (path) {
      '/channels/$detailsVoiceId/voice/calls' => shell._historyJson(),
      '/voice/transcripts/$detailsTranscriptId' => shell._transcriptJson(),
      _ => null,
    };
    if (body == null) {
      return http.Response.fromStream(
        await quiet.send(http.Request(request.method, request.url)),
      );
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  final fixture = setup(
    signedIn: true,
    httpClient: client,
    extraOverrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      for (final id in [detailsVoiceId, otherVoiceId])
        voiceRosterProvider(id).overrideWith((ref) => const Stream.empty()),
      userProfileProvider.overrideWith(
        (ref, id) async => api.UserProfile(
          id: id,
          username: id,
          displayName: detailsNames[id] ?? id,
          createdAt: 0,
        ),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => inCall
            ? FixedVoiceController(
                ref,
                VoiceState(
                  state: VoiceSessionState.connected,
                  channelId: callId,
                  participants: participants,
                ),
              )
            : VoiceController(ref, session: FakeSession()),
      ),
    ],
  );
  final store = await fixture.container.read(storeProvider.future);
  await tester.runAsync(
    () => store.upsertChannels([
      const api.Channel(
        id: detailsVoiceId,
        name: 'hangout',
        kind: 'voice',
        createdAt: 0,
        position: 0,
      ),
      const api.Channel(
        id: otherVoiceId,
        name: 'lounge',
        kind: 'voice',
        createdAt: 0,
        position: 1,
      ),
    ]),
  );
  final router = testRouter(location);
  shell = CallDetailsShell(
    container: fixture.container,
    db: fixture.db,
    router: router,
    events: events,
    tokenRequests: tokenRequests,
    startedAt: DateTime.now().millisecondsSinceEpoch - 12 * _min,
  );
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: dark
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        ),
      ),
    ),
  );
  await pumpFrames(tester, frames: 20);
  return shell;
}

/// Midday on the local day before [nowMs], so "yesterday" holds at any hour, midnight included.
int yesterdayNoonMs(int nowMs) {
  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  return DateTime(now.year, now.month, now.day - 1, 12).millisecondsSinceEpoch;
}

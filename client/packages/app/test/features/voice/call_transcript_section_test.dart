// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle pane's "Transcript" section (decision 0113): the first lines, Show
/// all, paging by `after_seq`, Delete only for those who may, a failure that
/// stays on screen, a refresh on the live event, and the jump from search.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_call_history.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_transcript_section.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/voice_channel_idle.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/call_header_fixture.dart';

const _tokens = api.TokenPair(
  userId: 'nick',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

final _start = DateTime(2026, 10, 13, 19, 2).millisecondsSinceEpoch;
final _now = DateTime(2026, 10, 14, 10, 0).millisecondsSinceEpoch;

Map<String, dynamic> _wireLine(int seq) => {
  'seq': seq,
  'speaker_id': 'kiki',
  'at': _start + seq * 1000,
  'text': 'line number $seq',
};

class _Rig {
  _Rig(this.container, this.events, this.requests);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final List<String> requests;
}

/// A finished call in `voice-1` with transcript `t1`, served [pages] in turn
/// by `after_seq` (the first for no cursor).
Future<_Rig> _pump(
  WidgetTester tester, {
  required List<List<int>> pages,
  bool canManage = false,
  int deleteStatus = 204,
  bool withTranscript = true,
  bool newerCall = false,
  double width = 1100,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final requests = <String>[];
  var served = 0;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      ...callPeople(const [], const {}),
      liveEventsProvider.overrideWithValue(events.stream),
      userProfileProvider.overrideWith(
        (ref, id) async => api.UserProfile(
          id: id,
          username: id,
          displayName: 'Kiki',
          createdAt: 0,
        ),
      ),
      myChannelPermissionsProvider(
        'voice-1',
      ).overrideWithValue(canManage ? Perm.manageMessages : Perm.viewChannel),
      voiceCallHistoryProvider.overrideWith(
        (ref, channelId) async => api.VoiceCallHistory(
          retentionDays: 30,
          canvasObjectCount: 0,
          calls: [
            if (newerCall)
              api.VoiceCall(
                startedAt: _start + 86400000,
                endedAt: _start + 86400000 + 60000,
                events: const [],
                canvas: const [],
              ),
            api.VoiceCall(
              startedAt: _start,
              endedAt: _start + 600000,
              events: const [],
              canvas: const [],
              transcriptId: withTranscript ? 't1' : null,
            ),
          ],
        ),
      ),
      apiProvider.overrideWith((ref) {
        final client = testApi((request) async {
          requests.add(
            '${request.method} ${request.url.path}'
            '${request.url.query.isEmpty ? '' : '?${request.url.query}'}',
          );
          if (request.method == 'DELETE') {
            return http.Response(
              deleteStatus == 204 ? '' : jsonEncode({'error': 'no'}),
              deleteStatus,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path != '/voice/transcripts/t1') {
            return http.Response('{}', 200);
          }
          final index = served < pages.length ? served++ : pages.length - 1;
          final page = pages[index];
          return http.Response(
            jsonEncode({
              'id': 't1',
              'channel_id': 'voice-1',
              'started_at': _start,
              'ended_at': _start + 600000,
              'mode': 'always',
              'lines': [for (final seq in page) _wireLine(seq)],
              'next_after_seq': index < pages.length - 1 ? page.last : null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }, session: api.SessionStore(tokens: _tokens));
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
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
  );
  await _frames(tester);
  return _Rig(container, events, requests);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pump();
  await tester.tap(find.byKey(key));
  await _frames(tester);
}

Finder _line(int seq) => find.byKey(transcriptLineKey(seq));

int _shown(WidgetTester tester, int upTo) => [
  for (var seq = 1; seq <= upTo; seq++)
    if (_line(seq).evaluate().isNotEmpty) seq,
].length;

void main() {
  for (final width in [1100.0, 390.0]) {
    group('at $width wide', () {
      testWidgets('the first lines show, then Show all opens the rest', (
        tester,
      ) async {
        await _pump(
          tester,
          pages: [
            [for (var i = 1; i <= 12; i++) i],
          ],
          width: width,
        );

        expect(find.text('Transcript'), findsOneWidget);
        expect(_shown(tester, 12), transcriptCollapsedLines);
        expect(find.text('line number 1'), findsOneWidget);
        expect(find.text('Kiki'), findsWidgets);

        await _tapKey(tester, transcriptShowAllKey);

        expect(_shown(tester, 12), 12);
        expect(find.byKey(transcriptShowAllKey), findsNothing);
      });

      testWidgets('Delete shows only with Manage messages', (tester) async {
        await _pump(
          tester,
          pages: [
            [1, 2],
          ],
          width: width,
        );
        expect(find.byKey(transcriptDeleteKey), findsNothing);
      });
    });
  }

  testWidgets('Show more reads the next page after the last line', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      pages: [
        [for (var i = 1; i <= 10; i++) i],
        [11, 12, 13],
      ],
    );

    await _tapKey(tester, transcriptShowAllKey);
    expect(_shown(tester, 13), 10);

    await _tapKey(tester, transcriptShowMoreKey);

    expect(_shown(tester, 13), 13);
    expect(find.byKey(transcriptShowMoreKey), findsNothing);
    expect(
      rig.requests,
      contains('GET /voice/transcripts/t1?after_seq=10&limit=50'),
    );
  });

  testWidgets('a call without a transcript has no section', (tester) async {
    final rig = await _pump(tester, pages: const [[]], withTranscript: false);

    expect(find.text('Transcript'), findsNothing);
    expect(rig.requests.where((r) => r.contains('transcripts')), isEmpty);
  });

  testWidgets('Delete asks, deletes, and the section goes', (tester) async {
    final rig = await _pump(
      tester,
      pages: [
        [1, 2],
      ],
      canManage: true,
    );
    expect(find.byKey(transcriptDeleteKey), findsOneWidget);

    await _tapKey(tester, transcriptDeleteKey);
    expect(find.text('Delete this transcript?'), findsOneWidget);
    await tester.tap(find.text('Delete transcript'));
    await _frames(tester);

    expect(rig.requests, contains('DELETE /voice/transcripts/t1'));
    expect(find.text('line number 1'), findsNothing);
  });

  testWidgets('a failed Delete stays on screen as an error, not a snackbar', (
    tester,
  ) async {
    await _pump(
      tester,
      pages: [
        [1, 2],
      ],
      canManage: true,
      deleteStatus: 500,
    );

    await _tapKey(tester, transcriptDeleteKey);
    await tester.tap(find.text('Delete transcript'));
    await _frames(tester);
    await _frames(tester);

    expect(find.text('Could not delete the transcript.'), findsOneWidget);
    expect(find.text('line number 1'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('the live event reads the transcript again for new lines', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      pages: [
        [1, 2],
        [3],
      ],
    );
    expect(_shown(tester, 3), 2);

    rig.events.add(
      const api.CallTranscriptChanged(
        channelId: 'voice-1',
        transcriptId: 't1',
        ended: true,
      ),
    );
    await _frames(tester);

    expect(_shown(tester, 3), 3);
  });

  testWidgets('a search hit expands the transcript to its line and lights it', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      pages: [
        [for (var i = 1; i <= 10; i++) i],
        [for (var i = 11; i <= 20; i++) i],
      ],
    );
    expect(_line(15), findsNothing);

    rig.container.read(transcriptFocusProvider.notifier).state = (
      channelId: 'voice-1',
      transcriptId: 't1',
      seq: 15,
    );
    await _frames(tester);
    await _frames(tester);

    expect(_line(15), findsOneWidget);
    expect(rig.container.read(transcriptFocusProvider), isNull);
  });

  testWidgets('a hit for an earlier call selects that call first', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      pages: [
        [for (var i = 1; i <= 3; i++) i],
      ],
      newerCall: true,
    );
    expect(find.text('Transcript'), findsNothing);

    rig.container.read(transcriptFocusProvider.notifier).state = (
      channelId: 'voice-1',
      transcriptId: 't1',
      seq: 2,
    );
    await _frames(tester);
    await _frames(tester);

    expect(find.text('Transcript'), findsOneWidget);
    expect(_line(2), findsOneWidget);
    expect(rig.container.read(selectedVoiceCallProvider('voice-1')), _start);
  });
}

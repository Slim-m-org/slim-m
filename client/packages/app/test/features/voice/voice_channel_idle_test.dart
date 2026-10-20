// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle voice pane's behaviour (design 13): its button joins muted,
/// tapping an earlier call swaps it into the timeline, a failed join shows
/// its reason with a retry, and a server without history still gets a
/// join bar and no error.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/call_recap.dart';
import 'package:slimm_app/src/features/voice/providers/voice_call_history.dart';
import 'package:slimm_app/src/features/voice/widgets/call_recap_card.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/voice_channel_idle.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/call_header_fixture.dart';

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

Future<void> _pump(
  WidgetTester tester, {
  required VoidCallback onJoin,
  api.VoiceCallHistory? history,
  String? error,
  bool canRetry = true,
  CallRecap? recap,
  double width = 1100,
  double? paneWidth,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
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
      ...callPeople(const [], const {}),
      userProfileProvider.overrideWith(
        (ref, id) async => api.UserProfile(
          id: id,
          username: id,
          displayName: _names[id] ?? id,
          createdAt: 0,
        ),
      ),
      voiceCallHistoryProvider.overrideWith(
        (ref, channelId) async =>
            history ??
            const api.VoiceCallHistory(
              retentionDays: 0,
              canvasObjectCount: 0,
              calls: [],
            ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: paneWidth,
              child: VoiceChannelIdle(
                channelId: 'voice-1',
                onJoin: onJoin,
                onOpenCanvas: () {},
                errorMessage: error,
                canRetry: canRetry,
                recap: recap,
                clock: () => _now,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the last call timeline labels never overlap in a narrow pane', (
    tester,
  ) async {
    await _pump(
      tester,
      onJoin: () {},
      history: api.VoiceCallHistory(
        retentionDays: 30,
        canvasObjectCount: 0,
        calls: [_history().calls.first],
      ),
      width: 1280,
      paneWidth: 436,
    );
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => RegExp(r'^\d{1,2}:\d{2}\s[AP]M$').hasMatch(t.data ?? ''))
        .map((t) => tester.getRect(find.byWidget(t)))
        .toList();
    expect(labels.length, greaterThan(1));
    for (var i = 0; i < labels.length; i++) {
      for (var j = i + 1; j < labels.length; j++) {
        expect(labels[i].overlaps(labels[j]), isFalse);
      }
      expect(labels[i].right, lessThanOrEqualTo(436));
    }
  });

  testWidgets('the button joins, and says it joins muted', (tester) async {
    var joins = 0;
    await _pump(tester, onJoin: () => joins++, history: _history());
    await tester.tap(find.text('Join muted'));
    expect(joins, 1);
    expect(find.textContaining('joining starts you muted'), findsOneWidget);
  });

  testWidgets('tapping an earlier call swaps it into the timeline', (
    tester,
  ) async {
    await _pump(tester, onJoin: () {}, history: _history());
    expect(find.text('Last call'), findsOneWidget);
    expect(find.text('Kiki'), findsOneWidget);

    await tester.tap(find.text('Sat'));
    await tester.pumpAndSettle();
    expect(find.text('Call'), findsOneWidget, reason: 'not the last call');
    expect(find.text('Kiki'), findsNothing, reason: 'Kiki was not on Saturday');
    expect(find.textContaining('3 h 30 min'), findsOneWidget);
  });

  testWidgets('a failed join shows why, with a retry', (tester) async {
    var joins = 0;
    await _pump(
      tester,
      onJoin: () => joins++,
      error: 'Could not join the call.',
    );
    expect(find.text('Could not join the call.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(joins, 1);
  });

  testWidgets('a failure a retry cannot fix offers no button', (tester) async {
    await _pump(
      tester,
      onJoin: () {},
      error: 'This Space has no voice configured.',
      canRetry: false,
    );
    expect(find.text('This Space has no voice configured.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Join muted'), findsNothing);
  });

  testWidgets('no history is just a join bar, never an error', (tester) async {
    await _pump(tester, onJoin: () {});
    expect(find.text("Can't tell who else is here right now."), findsOneWidget);
    expect(find.text('Last call'), findsNothing);
    expect(find.byType(AppErrorState), findsNothing);
  });

  group('after a hang-up (decision 0077)', () {
    CallRecap recapOf(Duration length, {bool withKiki = true}) {
      final start = DateTime(2026, 10, 14, 9);
      return CallRecap(
        channelId: 'voice-1',
        startedAt: start,
        endedAt: start.add(length),
        others: [
          if (withKiki)
            CallParticipantActivity(
              identity: 'kiki',
              name: 'Kiki',
              joinedAt: start,
            ),
        ],
        sharedScreen: false,
        usedCamera: false,
      );
    }

    testWidgets('shows how long, who was there, and a Rejoin that joins', (
      tester,
    ) async {
      var joins = 0;
      await _pump(
        tester,
        onJoin: () => joins++,
        recap: recapOf(const Duration(minutes: 23)),
      );
      expect(find.text('Call ended'), findsOneWidget);
      expect(find.text('23 min'), findsOneWidget);
      expect(find.text('Kiki'), findsOneWidget);
      expect(find.text('Join muted'), findsNothing);

      await tester.tap(find.text('Rejoin muted'));
      expect(joins, 1);
    });

    testWidgets('a three minute call is summarised too', (tester) async {
      await _pump(
        tester,
        onJoin: () {},
        recap: recapOf(const Duration(minutes: 3)),
      );
      expect(find.byType(CallRecapCard), findsOneWidget);
      expect(find.text('3 min'), findsOneWidget);
    });

    testWidgets('a mis-click gets Rejoin but no summary', (tester) async {
      await _pump(
        tester,
        onJoin: () {},
        recap: recapOf(const Duration(seconds: 6), withKiki: false),
      );
      expect(find.byType(CallRecapCard), findsNothing);
      expect(find.text('Rejoin muted'), findsOneWidget);
    });

    testWidgets('without a recap it is the plain join bar', (tester) async {
      await _pump(tester, onJoin: () {});
      expect(find.byType(CallRecapCard), findsNothing);
      expect(find.text('Join muted'), findsOneWidget);
      expect(find.text('Rejoin muted'), findsNothing);
    });

    testWidgets('on a phone the button is a bare Rejoin', (tester) async {
      await _pump(
        tester,
        onJoin: () {},
        recap: recapOf(const Duration(minutes: 8)),
        width: 390,
      );
      expect(find.text('Rejoin'), findsOneWidget);
      expect(find.text('Call ended'), findsOneWidget);
    });
  });
}

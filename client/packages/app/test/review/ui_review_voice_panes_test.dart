// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice panes a channel swaps in: the call with its text chat, a DM's
/// call pane, the lobby that makes a room, and a watch party's position bar.
///
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// each pane lays out without overflow.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart'
    show membersProvider;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/watch_room.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart'
    show voiceChatPaneVisibleProvider;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_rtc/rtc.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_voice_support.dart';

VoiceState _call(String channel, List<VoiceParticipant> people) => VoiceState(
  channelId: channel,
  state: VoiceSessionState.connected,
  connectedAt: callStartedAgo(const Duration(minutes: 6, seconds: 12)),
  participants: people,
);

final _inCall = _call('c-main', [
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', speaking: true),
  reviewPerson('user-grace', 'Grace Hopper', muted: true),
]);

Future<void> _openChat(WidgetTester tester, ProviderContainer container) async {
  container.read(voiceChatPaneVisibleProvider.notifier).state = true;
  await reviewFrames(tester);
}

api.Message _chat(int seq, String author, String name, String text) =>
    api.Message(
      id: 'mc-$seq',
      channelId: 'c-main',
      authorId: author,
      authorDisplayName: name,
      seq: seq,
      content: text,
      createdAt: 1753600000000 + seq * 90000,
      editedAt: null,
    );

/// What a voice channel's own chat holds mid-call, on top of the matrix messages.
final _callChat = [
  ...fixtureMessages,
  _chat(1, 'user-ada', 'Ada Lovelace', 'Can everyone see the build board?'),
  _chat(2, 'user-nick', 'Nick', 'Yes, sharing the second screen now.'),
  _chat(
    3,
    'user-long-name',
    'Christoph Bartholomew Fitzgerald-Huang III',
    'Dropping the link here so it is in the transcript afterwards: '
        'https://example.com/boards/voice-review-2026',
  ),
  _chat(4, 'user-ada', 'Ada Lovelace', 'Thanks. Back in two minutes.'),
];

Future<void> _seedLobby(ProviderContainer container) async {
  final store = await container.read(storeProvider.future);
  await store.upsertChannels(const [
    api.Channel(
      id: 'c-lobby',
      name: 'Pairing lobby',
      kind: 'voice',
      createdAt: 0,
      categoryId: 'cat-voice',
      createsRooms: true,
    ),
  ]);
}

Override _roomApi(Future<http.Response> Function() answer) =>
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient(
          (request) => request.url.path.endsWith('/voice/room')
              ? answer()
              : fixtureResponse(request),
        ),
      );
      ref.onDispose(client.close);
      return client;
    });

WatchRoom _room({required bool playing}) => WatchRoom(
  botUserId: 'jelly',
  itemId: 'item-1',
  title: 'Spirited Away (2001)',
  playing: playing,
  position: const Duration(hours: 1, minutes: 3, seconds: 41),
  sampledAtMs: DateTime.now().millisecondsSinceEpoch,
  epoch: 1,
  ttl: const Duration(minutes: 5),
  clockOffset: Duration.zero,
  duration: const Duration(hours: 2, minutes: 5, seconds: 12),
);

const _jelly = api.UserProfile(
  id: 'jelly',
  username: 'jellyfin',
  displayName: 'Jellyfin',
  createdAt: 0,
  isBot: true,
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('voice text pane, docked, at desktop', (tester) async {
    await renderReview(
      tester,
      surface: 'voice-text-pane',
      state: 'docked',
      viewport: 'desktop',
      route: '/channels/c-main',
      messages: _callChat,
      overrides: [reviewVoice(_inCall)],
      step: _openChat,
    );
  });

  testWidgets('voice text pane, over the call, at phone', (tester) async {
    await renderReview(
      tester,
      surface: 'voice-text-pane',
      state: 'over-call',
      viewport: 'phone',
      route: '/channels/c-main',
      messages: _callChat,
      overrides: [reviewVoice(_inCall)],
      step: _openChat,
    );
  });

  for (final viewport in reviewViewports) {
    testWidgets('voice text pane, not joined, at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-text-pane',
        state: 'not-joined',
        viewport: viewport,
        route: '/channels/c-main',
        openChat: true,
        messages: _callChat,
        overrides: [reviewVoice(const VoiceState())],
        step: _openChat,
      );
    });

    for (final creating in [true, false]) {
      testWidgets('voice lobby redirect, ${creating ? 'creating' : 'failed'}, '
          'at $viewport', (tester) async {
        final pending = Completer<http.Response>();
        await renderReview(
          tester,
          surface: 'voice-lobby-redirect',
          state: creating ? 'creating' : 'failed',
          viewport: viewport,
          route: '/channels/c-lobby',
          seed: _seedLobby,
          release: () => pending.complete(http.Response('{}', 500)),
          overrides: [
            reviewVoice(const VoiceState()),
            _roomApi(
              () => creating
                  ? pending.future
                  : Future.value(
                      http.Response(
                        '{"error":{"code":"forbidden","message":"You cannot '
                        'start a room in this lobby."}}',
                        403,
                        headers: {'content-type': 'application/json'},
                      ),
                    ),
            ),
          ],
        );
      });
    }

    for (final playing in [true, false]) {
      testWidgets('watch party, ${playing ? 'playing' : 'paused'}, '
          'at $viewport', (tester) async {
        await renderReview(
          tester,
          surface: 'voice-watch-party',
          state: playing ? 'playing' : 'paused',
          viewport: viewport,
          route: '/channels/c-main',
          overrides: [
            reviewVoice(
              _call('c-main', [
                reviewPerson('user-nick', 'Nick', local: true),
                reviewPerson('user-ada', 'Ada Lovelace'),
                reviewPerson('jelly', 'Jellyfin', sharing: true),
              ]),
            ),
            membersProvider.overrideWith(
              (ref) async => const [
                api.UserProfile(
                  id: 'user-ada',
                  username: 'ada',
                  displayName: 'Ada Lovelace',
                  createdAt: 0,
                ),
                _jelly,
              ],
            ),
            watchRoomProvider.overrideWith(
              (ref, id) => Stream.value(_room(playing: playing)),
            ),
          ],
        );
      });
    }
  }
}

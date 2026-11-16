// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every list that previews a message reads it the same way: a mention as the
/// member's name, markup flattened, and a text-less message named by what it
/// carried - Pinned, Saved, Threads, the Inbox and the reply banner alike.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/members/providers/mention_names.dart';
import 'package:slimm_app/src/features/messages/providers/inbox.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/widgets/inbox_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/pinned_messages_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_banner.dart';
import 'package:slimm_app/src/features/messages/widgets/saved_messages_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/threads_sheet.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_data/data.dart';

import 'message_row_harness.dart';

const _mentioning = '@nc1107 **look**';
const _named = '@Nick look';

/// The reply banner writes its snippet into one rich line after the author.
Finder _shows(String preview) =>
    find.textContaining(preview, findRichText: true);

const _voice = api.Attachment(
  id: 'v1',
  filename: 'voice.ogg',
  contentType: 'audio/ogg',
  size: 1024,
  voice: api.VoiceInfo(duration: Duration(seconds: 3), waveform: []),
);

api.Message _apiMessage(
  String content, [
  List<api.Attachment> att = const [],
]) => api.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'a1',
  authorDisplayName: 'Priya',
  seq: 1,
  content: content,
  createdAt: 0,
  editedAt: null,
  attachments: att,
);

Message _localMessage(String content) => Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'a1',
  authorDisplayName: 'Priya',
  seq: 1,
  content: content,
  createdAt: 0,
  pending: false,
  failed: false,
);

const _channel = Channel(
  id: 'c1',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  cursor: 1,
  lastReadSeq: 0,
  mentionedSeq: 1,
  isPersonalSpace: false,
  position: 0,
  slowModeSeconds: 0,
  joinMuted: false,
);

/// The member roster names nc1107 Nick; [held] are the extras the transcript
/// already fetched for m1.
List<Override> _overrides({List<api.Attachment> held = const []}) => [
  mentionNamesProvider.overrideWith((ref) => const {'nc1107': 'Nick'}),
  liveEventsProvider.overrideWithValue(const Stream<api.ServerEvent>.empty()),
  channelByIdProvider('c1').overrideWith((ref) => Stream.value(null)),
  messageExtrasProvider.overrideWith((ref) {
    final controller = MessageExtrasController(ref);
    if (held.isNotEmpty) controller.applyMessage(_apiMessage('', held));
    return controller;
  }),
];

Future<void> _pump(
  WidgetTester tester,
  Widget Function(GoRouter router) row, {
  List<api.Attachment> held = const [],
}) async {
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    harness(row(router), overrides: _overrides(held: held)),
  );
  await tester.pump();
}

api.ThreadListItem _thread(String parentContent) => api.ThreadListItem(
  id: 't1',
  parentMessageId: 'm1',
  parentContent: parentContent,
  parentAuthorId: 'a1',
  parentAuthorDisplayName: 'Priya',
  createdAt: 0,
  replyCount: 2,
  lastReplyAt: 0,
  unreadCount: 0,
);

InboxEntry _inbox(String content) => InboxEntry(
  channel: _channel,
  mentioned: true,
  unread: 1,
  message: _localMessage(content),
);

void main() {
  final rows =
      <String, Widget Function(GoRouter, String, List<api.Attachment>)>{
        'Pinned': (router, content, att) => PinnedMessageRow(
          channelId: 'c1',
          pin: api.PinnedMessage(
            message: _apiMessage(content, att),
            pinnedAt: 0,
            pinnedBy: 'a1',
          ),
          router: router,
          currentChannelId: 'c1',
        ),
        'Saved': (router, content, att) => SavedMessageRow(
          saved: api.SavedMessage(
            message: _apiMessage(content, att),
            savedAt: 0,
          ),
          router: router,
          currentChannelId: 'c1',
        ),
        'Threads': (router, content, _) =>
            ThreadRow(thread: _thread(content), router: router),
        'Inbox': (router, content, _) => InboxRow(
          entry: _inbox(content),
          router: router,
          currentChannelId: 'c1',
        ),
        'Reply banner': (_, content, _) =>
            ReplyBanner(message: _localMessage(content), onCancel: () {}),
      };

  for (final MapEntry(key: list, value: build) in rows.entries) {
    testWidgets('$list writes a mention as the member\'s name, markup '
        'flattened', (tester) async {
      await _pump(tester, (router) => build(router, _mentioning, const []));
      expect(_shows(_named), findsOneWidget);
    });

    testWidgets('$list names a voice message rather than leaving it blank', (
      tester,
    ) async {
      await _pump(
        tester,
        (router) => build(router, '', const [_voice]),
        held: const [_voice],
      );
      expect(_shows('Voice message'), findsOneWidget);
    });
  }
}

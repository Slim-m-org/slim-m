// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheets a conversation opens over itself: the full topic, pinned
/// messages, threads, saved messages and the inbox. A dialog from 600 wide, a
/// bottom sheet below.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_header.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_app/src/features/messages/widgets/inbox_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/pinned_messages_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/saved_messages_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/threads_sheet.dart';
import 'package:slimm_data/data.dart' show MessageStore;

import '../ui_snapshot_support.dart';
import 'ui_review_conversation_and_search_data.dart';
import 'ui_review_conversation_and_search_support.dart';

const _longTopic =
    'General chat for the whole Space. Keep it friendly, keep call logistics in '
    '#main instead of here, read the pinned rules before posting your first '
    'message, and move anything longer than a screen into a thread so the rest '
    'of the channel can keep up. Release questions go to #releases.';

const _linkTopic =
    'Roadmap: https://example.com/roadmap/2026-q4 - bugs go to '
    'https://example.com/issues/new, chat norms are pinned in #main.';

api.Channel _general(String topic) => api.Channel(
  id: 'c-general',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  categoryId: 'cat-text',
  topic: topic,
);

/// The topic in the bar that carries it: the wide header, or the phone's app bar.
Future<void> _openTopic(ReviewRig rig, String topic) async {
  final bar = find.byWidgetPredicate(
    (w) => rig.isPhone ? w is CompactChannelAppBar : w is ChannelHeader,
  );
  await rig.tester.tap(find.descendant(of: bar, matching: find.text(topic)));
  await rig.settle();
}

ReviewAct _open(void Function(ReviewRig rig) show) => (rig) async {
  unawaited(Future.sync(() => show(rig)));
  await rig.settle();
};

ReviewServe _serving(String path, Object body) =>
    (request) => request.url.path == path ? jsonOk(body) : null;

ReviewServe _failing(String path) =>
    (request) => request.url.path == path
    ? http.Response('{"error":"boom"}', 500)
    : null;

Future<void> _seedInbox(MessageStore store) async {
  await store.upsertChannels(extraChannels);
  api.Message note(
    String channel,
    int seq,
    String text, {
    bool mention = false,
  }) => api.Message(
    id: '$channel-$seq',
    channelId: channel,
    authorId: 'user-ada',
    authorDisplayName: 'Ada Lovelace',
    seq: seq,
    content: text,
    createdAt: 1753600000000 + seq * 600000,
    editedAt: null,
    mentionsMe: mention,
  );
  await store.applyMessages([
    note('c-releases', 1, 'Release candidate is cut, tag it when CI is green.'),
    note(
      'c-releases',
      2,
      '@nick the freeze is at 17:00 UTC, can you review the notes?',
      mention: true,
    ),
    note('c-bugs', 1, 'Call audio drops on the USB headset after a replug.'),
    note('c-bugs', 2, 'Reproduced on Fedora, not on Windows.'),
    note('c-bugs', 3, 'Attaching the debug log from the failing call.'),
    note('c-announce', 1, 'The Thursday demo moves to 15:00 this week.'),
  ]);
  await store.setReadMarker('c-design', 99);
}

/// Everything read, so the inbox has nothing to list.
Future<void> _seedCaughtUp(MessageStore store) async {
  for (final channel in await store.allChannels()) {
    if (channel.cursor > channel.lastReadSeq) {
      await store.setReadMarker(channel.id, channel.cursor);
    }
  }
}

void main() {
  setUpAll(loadRealFonts);

  reviewCase(
    'sheet-channel-topic',
    state: 'long-topic',
    seed: (store) => store.upsertChannels([_general(_longTopic)]),
    act: (rig) => _openTopic(rig, _longTopic),
  );
  reviewCase(
    'sheet-channel-topic',
    state: 'links',
    seed: (store) => store.upsertChannels([_general(_linkTopic)]),
    act: (rig) => _openTopic(rig, _linkTopic),
  );

  reviewCase(
    'sheet-pinned-messages',
    state: 'populated',
    messages: fullTranscript,
    serve: _serving('/channels/c-general/pins', pinsJson()),
    act: _open((rig) => showPinnedMessagesSheet(rig.shellContext, 'c-general')),
  );
  reviewCase(
    'sheet-pinned-messages',
    state: 'empty',
    serve: _serving('/channels/c-general/pins', <Object>[]),
    act: _open((rig) => showPinnedMessagesSheet(rig.shellContext, 'c-general')),
  );
  reviewCase(
    'sheet-pinned-messages',
    state: 'error',
    serve: _failing('/channels/c-general/pins'),
    act: _open((rig) => showPinnedMessagesSheet(rig.shellContext, 'c-general')),
  );

  reviewCase(
    'sheet-threads',
    state: 'populated',
    serve: _serving('/channels/c-general/threads', threadsJson()),
    act: _open((rig) => showThreadsSheet(rig.shellContext, 'c-general')),
  );
  reviewCase(
    'sheet-threads',
    state: 'empty',
    serve: _serving('/channels/c-general/threads', <Object>[]),
    act: _open((rig) => showThreadsSheet(rig.shellContext, 'c-general')),
  );

  reviewCase(
    'sheet-saved-messages',
    state: 'populated',
    serve: _serving('/saved', savedJson()),
    act: _open((rig) => showSavedMessagesSheet(rig.shellContext)),
  );
  reviewCase(
    'sheet-saved-messages',
    state: 'empty',
    serve: _serving('/saved', <Object>[]),
    act: _open((rig) => showSavedMessagesSheet(rig.shellContext)),
  );

  reviewCase(
    'sheet-inbox',
    state: 'mentions-and-unread',
    seed: _seedInbox,
    act: _open((rig) => showInboxSheet(rig.shellContext)),
  );
  reviewCase(
    'sheet-inbox',
    state: 'empty',
    seed: _seedCaughtUp,
    act: _open((rig) => showInboxSheet(rig.shellContext)),
  );
}

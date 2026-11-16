// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tester on an iPhone (2026-11-15): "how I get rid of the little indicator that looks like I'm missing a chat in the voice channel?"
/// Opening a voice channel joins its call with the chat closed, so the chat toggle has to say the unread text is in there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/unread_indicator_rules.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_chat_unread_dot.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../settings/home_shell_harness.dart' show teardown;
import '../../support/async_wait.dart';
import '../../support/call_screen_phone_harness.dart';

const _phone = Size(390, 844);

Finder get _unreadToggle =>
    find.bySemanticsLabel('Toggle text chat, new messages');

api.Message _message(int seq, {bool mentionsMe = false}) => api.Message(
  id: 'v$seq',
  channelId: callChannelId,
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: 'hello $seq',
  createdAt: 1000,
  editedAt: null,
  mentionsMe: mentionsMe,
);

Future<void> _arrive(
  WidgetTester tester,
  CallScreen s,
  List<api.Message> messages,
) async {
  final store = await s.container.read(storeProvider.future);
  await tester.runAsync(() => store.applyMessages(messages));
  await pumpFrames(tester);
}

Future<UnreadIndicator> _railIndicator(
  WidgetTester tester,
  CallScreen s,
) async {
  final store = await s.container.read(storeProvider.future);
  final rows = (await tester.runAsync(store.allChannels))!;
  return unreadIndicatorForChannel(
    rows.singleWhere((c) => c.id == callChannelId),
    channelOverride: null,
    isDm: false,
  );
}

void _expectDotOnToggle(WidgetTester tester) {
  final toggle = tester.getRect(_unreadToggle);
  final dot = tester.getRect(find.byKey(voiceChatUnreadKey));
  expect(toggle.contains(dot.center), isTrue, reason: 'on the chat toggle');
}

void main() {
  testWidgets('on a phone the call says its chat holds what the rail lit', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final s = await pumpCallScreen(tester, _phone);

    await _arrive(tester, s, [_message(1), _message(2, mentionsMe: true)]);

    expect((await _railIndicator(tester, s)).mentioned, isTrue);
    expect(_unreadToggle, findsOneWidget);
    _expectDotOnToggle(tester);

    await tester.tap(_unreadToggle);
    await pumpFrames(tester);
    expect(await _railIndicator(tester, s), (unread: false, mentioned: false));
    expect(find.byKey(voiceChatUnreadKey), findsNothing, reason: 'chat open');

    await tester.tap(find.bySemanticsLabel('Toggle text chat'));
    await pumpFrames(tester);
    expect(find.byKey(voiceChatUnreadKey), findsNothing, reason: 'all read');

    semantics.dispose();
    await teardown(tester, s.container, s.db);
  });

  testWidgets('the wide call header marks its chat toggle the same way', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final s = await pumpCallScreen(tester, const Size(1280, 800));

    await _arrive(tester, s, [_message(1)]);

    expect(_unreadToggle, findsOneWidget);
    _expectDotOnToggle(tester);

    semantics.dispose();
    await teardown(tester, s.container, s.db);
  });
}

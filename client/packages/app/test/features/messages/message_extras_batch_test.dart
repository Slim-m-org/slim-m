// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening a channel used to rebuild the transcript once per message.
///
/// [MessageExtrasController.applyMessages] looped over [applyMessage], so
/// hydrating a 50-message window published 50 successive whole-map copies;
/// and `ChannelScreen` watched that map's identity, so every one of them
/// rebuilt the whole list. Both halves are needed: batching alone still
/// rebuilds the transcript for one unrelated reaction, and selecting alone
/// still walks every row's selector 50 times for one fetch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

import '../../channel_history_harness.dart';

api.Message _withReaction(int seq, String emoji) {
  final base = channelMessage(seq);
  return api.Message(
    id: base.id,
    channelId: base.channelId,
    authorId: base.authorId,
    authorDisplayName: base.authorDisplayName,
    seq: base.seq,
    content: base.content,
    createdAt: base.createdAt,
    editedAt: null,
    reactions: [api.ReactionSummary(emoji: emoji, count: 1, reacted: false)],
  );
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

List<int> _range(int from, int to) => [
  for (var seq = from; seq <= to; seq++) seq,
];

void main() {
  test('a page of messages is one state write, not one per message', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var emissions = 0;
    container.listen(messageExtrasProvider, (_, _) => emissions++);

    container.read(messageExtrasProvider.notifier).applyMessages([
      for (var seq = 1; seq <= 50; seq++) channelMessage(seq),
    ]);

    expect(
      emissions,
      1,
      reason: 'every listener pays for each emission, and a fetch is one event',
    );
    expect(container.read(messageExtrasProvider), hasLength(50));
  });

  test('clear drops everything cached, once, and is a no-op after', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(messageExtrasProvider.notifier).applyMessages([
      for (var seq = 1; seq <= 5; seq++) channelMessage(seq),
    ]);
    expect(container.read(messageExtrasProvider), isNotEmpty);

    var emissions = 0;
    container.listen(messageExtrasProvider, (_, _) => emissions++);
    container.read(messageExtrasProvider.notifier).clear();

    expect(
      container.read(messageExtrasProvider),
      isEmpty,
      reason:
          'nothing else ever drops an entry, so this is the only thing that '
          'stops a stranger\'s cached reactions answering for the next '
          'account on the same device',
    );

    container.read(messageExtrasProvider.notifier).clear();
    expect(
      emissions,
      1,
      reason: 'an already-empty map has nothing left to clear',
    );
  });

  testWidgets('one message gaining a reaction does not rebuild the transcript', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: _range(1, 40),
      seededSeqs: _range(1, 40),
    );

    final before = tester.widget<ListView>(find.byType(ListView));
    harness.container
        .read(messageExtrasProvider.notifier)
        .applyMessage(_withReaction(40, 'x'));
    await flush(tester);

    expect(
      identical(tester.widget<ListView>(find.byType(ListView)), before),
      isTrue,
      reason:
          'the list is rebuilt from scratch whenever the transcript rebuilds, '
          'so a fresh ListView instance means the whole screen ran again',
    );
    expect(
      find.text('x'),
      findsOneWidget,
      reason: 'the row it is about still has to hear about it',
    );

    await _unmount(tester);
  });
}

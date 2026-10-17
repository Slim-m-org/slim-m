// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `applyLocalReactionToggle` is the optimistic preview a reaction chip shows
/// the instant you tap it, before the `reactions.changed` broadcast confirms
/// it. Its arithmetic was untested, and it is where a wrong count or a chip
/// that will not clear would first appear: adding a new reaction, bumping one
/// you had not reacted to, doing nothing when you already had, and removing the
/// chip only when your own removal takes it to zero.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

import '../../channel_history_harness.dart';

api.Message _withReactions(List<api.ReactionSummary> reactions) {
  final base = channelMessage(1);
  return api.Message(
    id: base.id,
    channelId: base.channelId,
    authorId: base.authorId,
    authorDisplayName: base.authorDisplayName,
    seq: base.seq,
    content: base.content,
    createdAt: base.createdAt,
    editedAt: null,
    reactions: reactions,
  );
}

List<api.ReactionSummary> _reactions(MessageExtrasController c) =>
    c.extrasFor('m1').reactions;

void main() {
  test('toggling on with no prior reaction adds it, reacted', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(messageExtrasProvider.notifier);

    c.applyLocalReactionToggle('m1', 'thumb', true);

    expect(_reactions(c), hasLength(1));
    expect(_reactions(c).single.emoji, 'thumb');
    expect(_reactions(c).single.count, 1);
    expect(_reactions(c).single.reacted, isTrue);
  });

  test('toggling off your own last reaction removes the chip entirely', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(messageExtrasProvider.notifier);
    c.applyLocalReactionToggle('m1', 'thumb', true);

    c.applyLocalReactionToggle('m1', 'thumb', false);

    expect(_reactions(c), isEmpty);
  });

  test('toggling on a reaction you had not reacted to bumps and marks it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(messageExtrasProvider.notifier);
    c.applyMessages([
      _withReactions([
        const api.ReactionSummary(emoji: 'thumb', count: 3, reacted: false),
      ]),
    ]);

    c.applyLocalReactionToggle('m1', 'thumb', true);

    expect(_reactions(c).single.count, 4);
    expect(_reactions(c).single.reacted, isTrue);
  });

  test('toggling on a reaction you already have changes nothing', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(messageExtrasProvider.notifier);
    c.applyLocalReactionToggle('m1', 'thumb', true);

    c.applyLocalReactionToggle('m1', 'thumb', true);

    expect(_reactions(c).single.count, 1);
    expect(_reactions(c).single.reacted, isTrue);
  });

  test('toggling off leaves the chip when others still hold it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(messageExtrasProvider.notifier);
    c.applyMessages([
      _withReactions([
        const api.ReactionSummary(emoji: 'thumb', count: 2, reacted: true),
      ]),
    ]);

    c.applyLocalReactionToggle('m1', 'thumb', false);

    expect(_reactions(c).single.count, 1);
    expect(_reactions(c).single.reacted, isFalse);
  });
}

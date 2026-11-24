// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reaction toggle a message row offers, and whether the viewer has reacted.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import 'message_extras.dart';
import 'reaction_toggle_queue.dart';

/// Toggles a reaction: off if [wasActive], on otherwise. Applied
/// optimistically before the request, so a chip responds immediately; a tap
/// while an earlier one on the same emoji is out waits its turn (see
/// [sendReactionInOrder]), and a refusal puts back what the server holds.
Future<void> setReaction(
  WidgetRef ref,
  String messageId,
  String emoji, {
  required bool wasActive,
}) async {
  final extras = ref.read(messageExtrasProvider.notifier);
  final client = ref.read(apiProvider);
  extras.applyLocalReactionToggle(messageId, emoji, !wasActive);
  Future<bool> send(bool active) async {
    try {
      if (active) {
        await client.addReaction(messageId: messageId, emoji: emoji);
      } else {
        await client.removeReaction(messageId: messageId, emoji: emoji);
      }
      return true;
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'change a reaction', error, stack);
      return false;
    }
  }

  final serverHolds = await sendReactionInOrder(
    ref.read(reactionTogglesInFlightProvider),
    (messageId: messageId, emoji: emoji),
    want: !wasActive,
    held: wasActive,
    send: send,
  );
  if (serverHolds != null && serverHolds != hasReacted(ref, messageId, emoji)) {
    extras.applyLocalReactionToggle(messageId, emoji, serverHolds);
  }
}

/// Whether the caller has already reacted to [messageId] with [emoji],
/// according to whatever this session currently has cached.
bool hasReacted(WidgetRef ref, String messageId, String emoji) => ref
    .read(messageExtrasProvider.notifier)
    .extrasFor(messageId)
    .reactions
    .any((r) => r.emoji == emoji && r.reacted);
